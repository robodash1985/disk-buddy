# Removes everything Install-DiskBuddy.ps1 registered. The folder itself is left for you to delete.
Unregister-ScheduledTask -TaskName 'DiskBuddy' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Classes\diskbuddy' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Classes\AppUserModelId\DiskBuddy' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\diskbuddy.exe' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'Disk Buddy.lnk') -Force -ErrorAction SilentlyContinue
Write-Host "Disk Buddy removed. You can now delete $(Split-Path -Parent $PSCommandPath)."
