<#
.SYNOPSIS
    Локальный HTTP-сервер для Web UI.
.DESCRIPTION
    HttpListener на 127.0.0.1:8765 + REST API.
    Крутится в отдельном Runspace, чтобы не блокировать главный поток
    (который ждёт F12 / завершения C#-потока).
.NOTES
    Без аутентификации. Слушает только loopback — из сети недоступен.
#>

# Импортируем Config: функции Get-RecoilStatus и т.п. нужны внутри Runspace,
# но Runspace не наследует функции модуля автоматически — поэтому ниже
# мы заново определяем их как локальные внутри AddScript.
Import-Module (Join-Path $PSScriptRoot 'RecoilConfig.psm1') -Force

# Хранилище состояния веб-сервера, чтобы Stop-RecoilWebUI мог всё закрыть.
$script:Web = $null

function Start-RecoilWebUI {
    <#
    .SYNOPSIS
        Поднимает HttpListener и запускает цикл обработки запросов в Runspace.
    .PARAMETER Prefix
        URL-префикс, например http://127.0.0.1:8765/.
    .PARAMETER HtmlPath
        Путь к HTML-файлу, который отдаётся на GET /.
    .OUTPUTS
        @{ Listener; Runspace; PS } или $null если порт занят/нет прав.
    #>
    [CmdletBinding()]
    param(
        [string]$Prefix  = 'http://127.0.0.1:8765/',
        [string]$HtmlPath
    )

    if (-not (Test-Path $HtmlPath)) {
        throw "HTML file not found: $HtmlPath"
    }
    # -Raw: читаем как одну строку, а не массив строк — так быстрее отдавать.
    $html = Get-Content -LiteralPath $HtmlPath -Raw -Encoding UTF8

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($Prefix)
    try {
        $listener.Start()
    } catch {
        # Порт занят или нет urlacl — не валим весь скрипт, просто без веба.
        Write-Warning ("Web UI disabled: " + $_.Exception.Message)
        return $null
    }

    # Runspace: изолированное пространство выполнения.
    # Через SessionStateProxy кладём туда пути и HTML — их увидят функции в AddScript.
    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('configDir',  (Get-RecoilConfigDir))
    $runspace.SessionStateProxy.SetVariable('statusFile', (Get-RecoilStatusFile))
    $runspace.SessionStateProxy.SetVariable('htmlPage',   $html)
    $runspace.SessionStateProxy.SetVariable('listener',   $listener)

    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace

    # Внутри Runspace заново определяем функции — они не наследуются из модуля.
    # Это дублирование осознанное: Runspace изолирован.
    [void]$ps.AddScript({
        function Get-Status {
            $r = @{ Profile='default'; Vertical=1.5; Horizontal=0.0; Speed=50; Paused=$false }
            if (Test-Path $statusFile) {
                foreach ($line in Get-Content -LiteralPath $statusFile -ErrorAction SilentlyContinue) {
                    $kv = $line -split '=',2
                    if ($kv.Count -ne 2) { continue }
                    switch ($kv[0]) {
                        'PROFILE'    { $r.Profile = $kv[1] }
                        'VERTICAL'   { $v=0.0; [void][double]::TryParse($kv[1],[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$v); $r.Vertical=$v }
                        'HORIZONTAL' { $h=0.0; [void][double]::TryParse($kv[1],[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$h); $r.Horizontal=$h }
                        'SPEED'      { $s=50; [void][int]::TryParse($kv[1],[ref]$s); $r.Speed=[Math]::Max(1,[Math]::Min(100,$s)) }
                        'PAUSED'     { $r.Paused = ($kv[1] -eq '1') }
                    }
                }
            }
            return $r
        }

        # Атомарная запись status.txt (та же логика, что в модуле Config).
        function Set-StatusAtomic($Profile,$Vertical,$Horizontal,$Speed,$Paused) {
            $c = @(
                "PROFILE=$Profile"
                "VERTICAL=$($Vertical.ToString('0.00',[System.Globalization.CultureInfo]::InvariantCulture))"
                "HORIZONTAL=$($Horizontal.ToString('0.00',[System.Globalization.CultureInfo]::InvariantCulture))"
                "SPEED=$Speed"
                "PAUSED=$([int]$Paused)"
            ) -join [Environment]::NewLine
            $tmp = "$statusFile.tmp"
            Set-Content -LiteralPath $tmp -Value $c -Encoding UTF8
            if (Test-Path $statusFile) { Remove-Item -LiteralPath $statusFile -Force }
            Move-Item -LiteralPath $tmp -Destination $statusFile -Force
        }

        function Get-ProfileList {
            if (-not (Test-Path $configDir)) { return @() }
            Get-ChildItem -LiteralPath $configDir -Filter '*.cfg' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.BaseName } | Sort-Object
        }

        function Load-ProfileByName($Name) {
            $file = Join-Path $configDir "$Name.cfg"
            if (-not (Test-Path $file)) { return $false }
            $lines = Get-Content -LiteralPath $file -ErrorAction SilentlyContinue
            if (-not $lines -or $lines.Count -lt 2) { return $false }
            $v=0.0; $h=0.0; $sp=50
            [void][double]::TryParse($lines[0],[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$v)
            [void][double]::TryParse($lines[1],[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$h)
            if ($lines.Count -ge 3) { [void][int]::TryParse($lines[2],[ref]$sp) }
            $sp = [Math]::Max(1,[Math]::Min(100,$sp))
            $s = Get-Status
            Set-StatusAtomic -Profile $Name -Vertical $v -Horizontal $h -Speed $sp -Paused $s.Paused
            return $true
        }

        function Save-ProfileByName($Name) {
            $s = Get-Status
            $c = @(
                $s.Vertical.ToString([System.Globalization.CultureInfo]::InvariantCulture)
                $s.Horizontal.ToString([System.Globalization.CultureInfo]::InvariantCulture)
                $s.Speed
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $configDir "$Name.cfg") -Value $c -Encoding UTF8
        }

        # ---------- HTTP-цикл ----------
        while ($listener.IsListening) {
            try { $ctx = $listener.GetContext() } catch { break } // listener.Stop() → исключение → выходим

            $req = $ctx.Request
            $res = $ctx.Response
            try {
                $path   = $req.Url.AbsolutePath
                $method = $req.HttpMethod

                if ($method -eq 'GET' -and $path -eq '/') {
                    # Отдаём HTML один раз, без кеша (заголовки не ставим — браузер сам решит).
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($htmlPage)
                    $res.ContentType = 'text/html; charset=utf-8'
                    $res.ContentLength64 = $bytes.Length
                    $res.OutputStream.Write($bytes,0,$bytes.Length)
                }
                elseif ($method -eq 'GET' -and $path -eq '/api/status') {
                    # Текущее состояние + список профилей одним JSON.
                    $s = Get-Status
                    $profiles = @(Get-ProfileList)
                    $obj = [ordered]@{
                        profile    = $s.Profile
                        vertical   = $s.Vertical
                        horizontal = $s.Horizontal
                        speed      = $s.Speed
                        paused     = $s.Paused
                        profiles   = $profiles
                    }
                    $json = $obj | ConvertTo-Json -Compress
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType='application/json'
                    $res.ContentLength64=$bytes.Length
                    $res.OutputStream.Write($bytes,0,$bytes.Length)
                }
                elseif ($method -eq 'POST' -and $path -eq '/api/set') {
                    # Установка значений. Отсутствующие поля берём из текущего статуса.
                    $reader = New-Object System.IO.StreamReader($req.InputStream,[System.Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd(); $reader.Close()
                    $data = $body | ConvertFrom-Json

                    $s  = Get-Status
                    $v  = if ($null -ne $data.vertical)   { [double]$data.vertical }   else { $s.Vertical }
                    $h  = if ($null -ne $data.horizontal) { [double]$data.horizontal } else { $s.Horizontal }
                    $sp = if ($null -ne $data.speed)      { [int]$data.speed }         else { $s.Speed }
                    $sp = [Math]::Max(1,[Math]::Min(100,$sp))
                    $p  = if ($null -ne $data.paused)     { [bool]$data.paused }       else { $s.Paused }

                    Set-StatusAtomic -Profile $s.Profile -Vertical $v -Horizontal $h -Speed $sp -Paused $p
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                    $res.ContentType='application/json'
                    $res.ContentLength64=$bytes.Length
                    $res.OutputStream.Write($bytes,0,$bytes.Length)
                }
                elseif ($method -eq 'POST' -and $path -eq '/api/profile/load') {
                    $reader = New-Object System.IO.StreamReader($req.InputStream,[System.Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd(); $reader.Close()
                    $data = $body | ConvertFrom-Json
                    $ok = Load-ProfileByName ([string]$data.name)
                    $json = if ($ok) {'{"ok":true}'} else {'{"ok":false}'}
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType='application/json'
                    $res.ContentLength64=$bytes.Length
                    $res.OutputStream.Write($bytes,0,$bytes.Length)
                }
                elseif ($method -eq 'POST' -and $path -eq '/api/profile/save') {
                    $reader = New-Object System.IO.StreamReader($req.InputStream,[System.Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd(); $reader.Close()
                    $data = $body | ConvertFrom-Json
                    $name = [string]$data.name
                    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'default' }
                    Save-ProfileByName $name
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                    $res.ContentType='application/json'
                    $res.ContentLength64=$bytes.Length
                    $res.OutputStream.Write($bytes,0,$bytes.Length)
                }
                else { $res.StatusCode = 404 }
            } catch {
                try { $res.StatusCode = 500 } catch {}
            } finally {
                # Всегда закрываем поток, иначе браузер будет ждать ответ.
                try { $res.OutputStream.Close() } catch {}
            }
        }
    })

    # BeginInvoke: запускаем цикл асинхронно и сразу возвращаемся.
    $ps.BeginInvoke() | Out-Null

    $script:Web = @{ Listener = $listener; Runspace = $runspace; PS = $ps }
    return $script:Web
}

function Stop-RecoilWebUI {
    <#
    .SYNOPSIS
        Останавливает listener и освобождает Runspace.
    .NOTES
        Вызывать в finally, иначе порт останется занятым до перезагрузки.
    #>
    [CmdletBinding()]
    param()

    if ($script:Web -eq $null) { return }
    try { $script:Web.Listener.Stop(); $script:Web.Listener.Close() } catch { }
    try { $script:Web.PS.Dispose() } catch { }
    try { $script:Web.Runspace.Close() } catch { }
    $script:Web = $null
}

Export-ModuleMember -Function Start-RecoilWebUI, Stop-RecoilWebUI
