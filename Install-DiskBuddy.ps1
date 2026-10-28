# Installs Disk Buddy for the current user (no admin needed):
#   1. a notification identity ("Disk Buddy" with its own icon)
#   2. the diskbuddy: link handler that notification buttons and the report use
#   3. a diskbuddy.exe launcher (Win+R "diskbuddy", Start menu "Disk Buddy")
#   4. a scheduled task running DiskBuddy.ps1 -Mode Check every 15 minutes, hidden
# Re-run any time to repair. Uninstall-DiskBuddy.ps1 removes all of it.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$Script = Join-Path $Root 'DiskBuddy.ps1'

# First install: start from the example settings (your config.json is never overwritten)
if (-not (Test-Path (Join-Path $Root 'config.json')) -and (Test-Path (Join-Path $Root 'config.example.json'))) {
    Copy-Item (Join-Path $Root 'config.example.json') (Join-Path $Root 'config.json')
}
$PowerShell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$Conhost = "$env:WINDIR\System32\conhost.exe"
# conhost --headless runs PowerShell without flashing a console window
$HiddenArgs = "--headless `"$PowerShell`" -NoProfile -ExecutionPolicy Bypass -File `"$Script`""

# 1. Notification identity + icon (a small donut chart)
$icon = Join-Path $Root 'icon.png'
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap 96, 96
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)
$blue = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(47, 111, 222))
$white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$g.FillEllipse($blue, 2, 2, 92, 92)
$g.FillPie($white, 20, 20, 56, 56, -90, 270)
$g.FillEllipse($blue, 35, 35, 26, 26)
$g.Dispose()
$bmp.Save($icon, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$aumid = 'HKCU:\Software\Classes\AppUserModelId\DiskBuddy'
New-Item -Path $aumid -Force | Out-Null
Set-ItemProperty -Path $aumid -Name DisplayName -Value 'Disk Buddy'
Set-ItemProperty -Path $aumid -Name IconUri -Value $icon
Set-ItemProperty -Path $aumid -Name ShowInSettings -Value 1 -Type DWord

# 2. diskbuddy: link handler
$proto = 'HKCU:\Software\Classes\diskbuddy'
New-Item -Path "$proto\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path $proto -Name '(default)' -Value 'URL:Disk Buddy'
Set-ItemProperty -Path $proto -Name 'URL Protocol' -Value ''
Set-ItemProperty -Path "$proto\shell\open\command" -Name '(default)' -Value "`"$Conhost`" $HiddenArgs -Uri `"%1`""

# 3. diskbuddy.exe launcher so Win+R "diskbuddy" / "diskbuddy clean" and the Start menu work.
#    It just runs DiskBuddy.ps1 with no window; the first argument picks the action (default: report).
$exe = Join-Path $Root 'diskbuddy.exe'
$launcher = @'
using System;
using System.Diagnostics;
using System.IO;
static class Launcher {
    static void Main(string[] args) {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string action = args.Length > 0 ? string.Join("/", args).Trim().ToLowerInvariant() : "report";   // "profile gaming" -> profile/gaming
        string ps = Path.Combine(Environment.GetEnvironmentVariable("WINDIR"), @"System32\WindowsPowerShell\v1.0\powershell.exe");
        var psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(dir, "DiskBuddy.ps1") + "\" -Uri \"diskbuddy:" + action + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        Process.Start(psi);
    }
}
'@
if (Test-Path $exe) { Remove-Item $exe -Force }
Add-Type -TypeDefinition $launcher -OutputAssembly $exe -OutputType WindowsApplication

$appPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\diskbuddy.exe'
New-Item -Path $appPath -Force | Out-Null
Set-ItemProperty -Path $appPath -Name '(default)' -Value $exe

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Disk Buddy.lnk'))
$lnk.TargetPath = $exe
$lnk.WorkingDirectory = $Root
$lnk.Description = 'Open the Disk Buddy report'
$lnk.Save()

# 4. Scheduled task: every 15 min, forever; catches up after sleep/boot
$action = New-ScheduledTaskAction -Execute $Conhost -Argument "$HiddenArgs -Mode Check"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName 'DiskBuddy' -Description "Disk Buddy: watches free space and notifies you. Files in $Root" `
    -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

& $PowerShell -NoProfile -ExecutionPolicy Bypass -File $Script -Mode Test
Write-Host "Disk Buddy installed. It checks every 15 minutes. Settings: $(Join-Path $Root 'config.json')"
