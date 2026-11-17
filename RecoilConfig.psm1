<#
.SYNOPSIS
    Конфиг, статус и профили — общие для C#-ядра и Web UI.
.DESCRIPTION
    Единая точка правды по путям и формату файлов.
    Все функции используют InvariantCulture, чтобы не зависеть от локали.
#>

# Пути определяются один раз при импорте модуля.
# Documents\RecoilProfiles — выбрано, чтобы файлы не терялись при обновлении скрипта.
$script:ConfigDir  = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'RecoilProfiles'
$script:StatusFile = Join-Path $script:ConfigDir 'status.txt'

function Get-RecoilConfigDir  { return $script:ConfigDir }
function Get-RecoilStatusFile { return $script:StatusFile }

function Initialize-RecoilConfig {
    <#
    .SYNOPSIS
        Создаёт папку профилей, если её нет.
    #>
    [CmdletBinding()]
    param()
    if (-not (Test-Path $script:ConfigDir)) {
        New-Item -ItemType Directory -Path $script:ConfigDir | Out-Null
    }
}

function Get-RecoilStatus {
    <#
    .SYNOPSIS
        Читает status.txt и возвращает hashtable.
    .OUTPUTS
        @{ Profile; Vertical; Horizontal; Speed; Paused; MTime }
    .NOTES
        MTime — LastWriteTimeUtc. По нему основная петля решает,
        перерисовывать ли UI.
    #>
    [CmdletBinding()]
    param()

    $result = @{
        Profile    = 'default'
        Vertical   = 1.5
        Horizontal = 0.0
        Speed      = 50
        Paused     = $false
        MTime      = [datetime]::MinValue
    }

    if (Test-Path $script:StatusFile) {
        try {
            $result.MTime = (Get-Item -LiteralPath $script:StatusFile).LastWriteTimeUtc
            foreach ($line in Get-Content -LiteralPath $script:StatusFile -ErrorAction SilentlyContinue) {
                $kv = $line -split '=', 2
                if ($kv.Count -ne 2) { continue }
                switch ($kv[0]) {
                    'PROFILE'    { $result.Profile = $kv[1] }
                    'VERTICAL'   { $v = 0.0; [void][double]::TryParse($kv[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v); $result.Vertical = $v }
                    'HORIZONTAL' { $h = 0.0; [void][double]::TryParse($kv[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$h); $result.Horizontal = $h }
                    'SPEED'      { $s = 50;  [void][int]::TryParse($kv[1], [ref]$s);    $result.Speed = [Math]::Max(1, [Math]::Min(100, $s)) }
                    'PAUSED'     { $result.Paused = ($kv[1] -eq '1') }
                }
            }
        } catch { }
    }
    return $result
}

function Set-RecoilStatus {
    <#
    .SYNOPSIS
        Атомарно пишет status.txt (через .tmp + Move).
    .DESCRIPTION
        Атомарность важна: Web UI читает файл параллельно с записью,
        и без Move-подмены возможна "половина" файла.
    #>
    [CmdletBinding()]
    param(
        [string]$Profile    = 'default',
        [double]$Vertical   = 1.5,
        [double]$Horizontal = 0.0,
        [int]   $Speed      = 50,
        [bool]  $Paused     = $false
    )

    Initialize-RecoilConfig

    $c = @(
        "PROFILE=$Profile"
        "VERTICAL=$($Vertical.ToString('0.00',[System.Globalization.CultureInfo]::InvariantCulture))"
        "HORIZONTAL=$($Horizontal.ToString('0.00',[System.Globalization.CultureInfo]::InvariantCulture))"
        "SPEED=$Speed"
        "PAUSED=$([int]$Paused)"
    ) -join [Environment]::NewLine

    $tmp = "$script:StatusFile.tmp"
    Set-Content -LiteralPath $tmp -Value $c -Encoding UTF8
    if (Test-Path $script:StatusFile) { Remove-Item -LiteralPath $script:StatusFile -Force }
    Move-Item -LiteralPath $tmp -Destination $script:StatusFile -Force
}

function Get-RecoilProfileList {
    <#
    .SYNOPSIS
        Возвращает отсортированный список имён профилей (без .cfg).
    #>
    [CmdletBinding()]
    param()
    if (-not (Test-Path $script:ConfigDir)) { return @() }
    Get-ChildItem -LiteralPath $script:ConfigDir -Filter '*.cfg' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName } | Sort-Object
}

function Save-RecoilProfile {
    <#
    .SYNOPSIS
        Сохраняет текущий status.txt в профиль <Name>.cfg.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    Initialize-RecoilConfig
    $s = Get-RecoilStatus
    $c = @(
        $s.Vertical.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $s.Horizontal.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $s.Speed
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $script:ConfigDir "$Name.cfg") -Value $c -Encoding UTF8
}

function Load-RecoilProfile {
    <#
    .SYNOPSIS
        Загружает профиль в status.txt (с сохранением текущего Paused).
    .OUTPUTS
        bool — true если профиль найден и корректен.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $file = Join-Path $script:ConfigDir "$Name.cfg"
    if (-not (Test-Path $file)) { return $false }

    $lines = Get-Content -LiteralPath $file -ErrorAction SilentlyContinue
    if (-not $lines -or $lines.Count -lt 2) { return $false }

    $v = 0.0; $h = 0.0; $sp = 50
    [void][double]::TryParse($lines[0], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)
    [void][double]::TryParse($lines[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$h)
    if ($lines.Count -ge 3) { [void][int]::TryParse($lines[2], [ref]$sp) }
    $sp = [Math]::Max(1, [Math]::Min(100, $sp))

    $s = Get-RecoilStatus
    Set-RecoilStatus -Profile $Name -Vertical $v -Horizontal $h -Speed $sp -Paused $s.Paused
    return $true
}

Export-ModuleMember -Function `
    Initialize-RecoilConfig, Get-RecoilConfigDir, Get-RecoilStatusFile, `
    Get-RecoilStatus, Set-RecoilStatus, `
    Get-RecoilProfileList, Save-RecoilProfile, Load-RecoilProfile
