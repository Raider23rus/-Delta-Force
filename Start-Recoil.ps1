<#
.SYNOPSIS
    Точка входа Recoil Control v15.8 (modular).
.DESCRIPTION
    Только: проверка путей → импорт Bootstrap → старт → wait → stop.
    Вся логика — в модулях, чтобы этот файл оставался тривиальным.
.NOTES
    Run as Administrator. Save as UTF-8 with BOM.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

# $PSScriptRoot — папка, где лежит этот скрипт (работает и при -File, и при двойном клике).
$root     = $PSScriptRoot
$modules  = Join-Path $root 'Modules'
$htmlPath = Join-Path $root 'Web\index.html'

# -Force: при повторных запусках в том же сеансе перечитываем модули.
Import-Module (Join-Path $modules 'RecoilBootstrap.psm1') -Force

$system = $null
try {
    # Start-RecoilSystem сам проверит админа и бросит исключение, если нет.
    $system = Start-RecoilSystem -HtmlPath $htmlPath -Prefix 'http://127.0.0.1:8765/'

    if ($system.Web) {
        Write-Host "Web UI: http://127.0.0.1:8765/" -ForegroundColor Green
    } else {
        Write-Host "Web UI not available (port busy or access denied)" -ForegroundColor Yellow
    }
    Write-Host "System ACTIVE (console UI disabled - use Web UI)" -ForegroundColor Cyan
    Write-Host "F7: Pause/Resume | F12: Exit" -ForegroundColor DarkGray

    # Блокируемся, пока жив C#-поток (F12 в игре или Stop-RecoilThread).
    Wait-RecoilSystem -Thread $system.Thread
    Write-Host "System DEACTIVATED" -ForegroundColor Cyan
}
catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host ("STACK: " + $_.ScriptStackTrace) -ForegroundColor DarkGray
    Read-Host "Press ENTER to exit"
}
finally {
    # finally сработает и при Ctrl+C, и при исключении — порт не останется занятым.
    if ($system) { Stop-RecoilSystem -Thread $system.Thread }
}

Write-Host "Press any key to close..." -ForegroundColor White
try { [Console]::ReadKey($true) | Out-Null } catch { }
exit 0
