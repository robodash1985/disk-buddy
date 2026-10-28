<#
  Disk Buddy - keeps an eye on your system drive and nudges you with Windows notifications.

  Modes
    Check    run by the scheduled task every 15 min; only notifies, never cleans anything.
             Once a day it also measures the whole drive and, at most once a week, tells you when a lot of
             rebuildable cache has piled up - even while the drive still has plenty of room.
    Clean    removes safe, rebuildable caches: old Docker images/build cache, pnpm/npm/pip caches, old Temp files,
             GPU shader caches, crash dumps, unpacked driver installers, browser caches (only while the browser is
             closed) and old Playwright browser versions
    Report   opens a breakdown of where the space went: caches Clean can remove, things worth a look (phone backups,
             big Python packages, old installers, app data nothing has touched in months) and the biggest folders
    Compact  shrinks Docker's virtual disk so freed space returns to the drive (asks for admin)
    Volumes  removes leftover anonymous Docker volumes after you confirm (named volumes are never touched)
    Snooze   silences "getting full" warnings for SnoozeHours
    Profile  switches the active profile ("diskbuddy profile gaming"). A profile in config.json picks which cache
             groups count, which folders the report focuses on, and can override any threshold - one tool, several
             people or purposes (dev machine, gaming rig, a family member's laptop)
    Test     shows a sample notification
    Demo     shows one example of every notification type, with its sound (made-up numbers)
    Build    (internal) measures everything and writes the report HTML to -Out; the report server runs it

  Everything except Check runs only when you ask: a notification button, a report button (served on localhost),
  or Win+R "diskbuddy <mode>" (diskbuddy.exe and the diskbuddy: link handler pass it as -Uri).
  Never deletes project files, named Docker volumes, or anything in the Recycle Bin.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Clean', 'Report', 'Build', 'Compact', 'Volumes', 'Snooze', 'Profile', 'Test', 'Demo')]
    [string]$Mode = 'Check',
    [string]$Uri,
    [switch]$Elevated,
    [string]$Out,       # Build: where to write the report HTML
    [string]$ProfileArg # Profile: the profile name (also taken from -Uri diskbuddy:profile/<name>)
)

# Toasts need Windows PowerShell 5.1 (WinRT projection); hand off if started from pwsh.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Mode', $Mode)
    if ($Uri) { $argList += @('-Uri', $Uri) }
    if ($Elevated) { $argList += '-Elevated' }
    if ($Out) { $argList += @('-Out', $Out) }
    if ($ProfileArg) { $argList += @('-ProfileArg', $ProfileArg) }
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" @argList
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Continue'
$Inv = [Globalization.CultureInfo]::InvariantCulture   # system culture may use a non-Gregorian calendar
$Root = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $Root 'config.json'
$StatePath = Join-Path $Root 'state.json'
$LogPath = Join-Path $Root 'diskbuddy.log'
$ReportPath = Join-Path $Root 'report.html'
$AppId = 'DiskBuddy'
$DockerVhdx = Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'
$Dot = ' ' + [char]0x00B7 + ' '
$Dash = [char]0x2014

if ($Uri) {
    $action = ($Uri -replace '^diskbuddy:(//)?', '').Trim('/').ToLowerInvariant()
    if ($action -match '^profile[/ ](.+)$') { $ProfileArg = $Matches[1].Trim(); $action = 'profile' }
    $Mode = switch ($action) {
        'profile' { 'Profile' }
        'clean' { 'Clean' }
        'compact' { 'Compact' }
        'volumes' { 'Volumes' }
        'snooze' { 'Snooze' }
        'demo' { 'Demo' }
        default { 'Report' }
    }
}

#region helpers

function Write-Log([string]$Message) {
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) { Move-Item $LogPath "$LogPath.old" -Force }
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $Inv)
        Add-Content -Path $LogPath -Value "$stamp  [$Mode] $Message" -Encoding UTF8
    } catch {}
}

function Get-Config {
    $cfg = @{
        Drive = 'C'; WarnFreeGB = 50; CriticalFreeGB = 25; DropAlertGB = 10
        WarnRepeatHours = 24; CriticalRepeatHours = 4; SnoozeHours = 24
        DockerPruneOlderThanHours = 168; TempOlderThanDays = 7; ArchiveMinMB = 50
        DeepScanHours = 24; CacheAlertGB = 15; DigestRepeatHours = 168   # daily measure; weekly "caches piled up" note
        OrphanMonths = 6; OldInstallerDays = 30; BigPackageGB = 0.5; BigFolderMinGB = 2
        Sound = $true; SoundAlert = 'Windows Notify System Generic.wav'; SoundCritical = 'Windows Notify Calendar.wav'; SoundDone = 'Windows Notify Messaging.wav'
        WaitForDesktopMinutes = 13
        Profile = 'default'; Profiles = @{ default = @{ Groups = '*'; Focus = @() } }
    }
    if (Test-Path $ConfigPath) {
        try { (Get-Content $ConfigPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } }
        catch { Write-Log "config.json unreadable, using defaults: $_" }
    }
    # The active profile: its Groups say which catalogue groups count (Clean, report and the daily digest all follow
    # it), Focus lists folders the report breaks down, and any other key overrides the setting above.
    $all = ConvertTo-Hashtable $cfg.Profiles
    if (-not $all.ContainsKey('default')) { $all['default'] = @{ Groups = '*'; Focus = @() } }
    $name = [string]$cfg.Profile
    if (-not $name -or -not $all.ContainsKey($name)) { if ($name -and $name -ne 'default') { Write-Log "profile '$name' is not in config.json, using default" }; $name = 'default' }
    $p = ConvertTo-Hashtable $all[$name]
    foreach ($k in @($p.Keys)) { if ($k -ne 'Groups' -and $k -ne 'Focus') { $cfg[$k] = $p[$k] } }
    $cfg.ProfileName = $name
    $cfg.ProfileNames = @($all.Keys | Sort-Object)
    $groups = @($p.Groups | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $cfg.Groups = if (-not $groups -or $groups -contains '*') { '*' } else { $groups }
    $cfg.Focus = @($p.Focus | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_) })
    $cfg
}

function ConvertTo-Hashtable($Object) {   # JSON gives PSCustomObjects; defaults are hashtables - treat both alike
    if ($Object -is [hashtable]) { return $Object }
    $h = @{}
    if ($Object) { $Object.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } }
    $h
}

function Test-Group([string]$Group) { ($cfg.Groups -is [string]) -or ($cfg.Groups -contains $Group) }

# Focus patterns may use wildcards and environment variables; returns the existing folders they name.
function Resolve-Focus([string]$Pattern) {
    @(Resolve-Path -Path $Pattern -ErrorAction SilentlyContinue | ForEach-Object { $_.ProviderPath } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container })
}

function Get-State {
    $s = @{}
    if (Test-Path $StatePath) {
        try { (Get-Content $StatePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $s[$_.Name] = $_.Value } } catch {}
    }
    $s
}

function Save-State($State) { $State | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8 }

function ConvertTo-Stamp([datetime]$Date) { $Date.ToString('o', $Inv) }

function ConvertFrom-Stamp($Value) {
    if (-not $Value) { return [datetime]::MinValue }
    if ($Value -is [datetime]) { return $Value }
    try { [datetime]::Parse($Value, $Inv, [Globalization.DateTimeStyles]::RoundtripKind) } catch { [datetime]::MinValue }
}

function Format-GB([double]$GB) {
    if ([math]::Abs($GB) -ge 10) { '{0:N0} GB' -f $GB } else { '{0:N1} GB' -f $GB }
}

# Runs an exe/cmd with a hard timeout - a wedged Docker engine must never hang the watcher.
function Invoke-Native([string]$Command, [string]$Arguments, [int]$TimeoutSec = 60) {
    $exe = Get-Command "$Command.exe", "$Command.cmd" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { return $null }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe.Source
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try { $p = [System.Diagnostics.Process]::Start($psi) } catch { Write-Log "could not start ${Command}: $_"; return $null }
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        Write-Log "$Command $Arguments timed out after ${TimeoutSec}s"
        return $null
    }
    [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}

function Get-DriveInfo([string]$Drive) {
    $d = New-Object System.IO.DriveInfo $Drive
    [pscustomobject]@{
        Letter  = $Drive
        FreeGB  = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
        TotalGB = [math]::Round($d.TotalSize / 1GB, 1)
        UsedGB  = [math]::Round(($d.TotalSize - $d.AvailableFreeSpace) / 1GB, 1)
    }
}

function Get-FolderGB([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    # robocopy's list-only mode totals a tree several times faster than Get-ChildItem (nothing is copied)
    $out = & robocopy.exe $Path "$env:TEMP\diskbuddy-nul" /L /S /NFL /NDL /NJH /BYTES /XJ /R:0 /W:0 /NP 2>$null
    $total = $out | Select-String '^\s*Bytes\s*:\s*(\d+)' | Select-Object -First 1
    if ($total) { return [math]::Round([double]$total.Matches[0].Groups[1].Value / 1GB, 2) }
    # summary line is localized on some systems - fall back to the slow way
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    [math]::Round([double]$sum / 1GB, 2)
}

function Get-FileGB([string]$Path) {
    if (Test-Path -LiteralPath $Path) { [math]::Round((Get-Item -LiteralPath $Path -Force).Length / 1GB, 1) } else { 0 }
}

function Get-RecycleBinPath([string]$Drive) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    "$($Drive):\`$Recycle.Bin\$sid"
}

#endregion
#region scan

# One pass over the whole drive in C# (PowerShell loops are far too slow for millions of files). Sizes every
# folder, remembers each folder's newest file, skips junctions/symlinks and cloud-only placeholders, and does not
# expand dependency trees (node_modules, .git, WinSxS...) - they are counted in their parent, just not listed.
$WalkerSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace DiskBuddy {
    public class Folder { public string Path; public long Bytes; public int Depth; public DateTime Newest; }
    public static class Walker {
        // Raw FindFirstFileEx with large fetch: one pass per folder, no per-file objects. Several times faster than DirectoryInfo.
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct FindData {
            public uint Attributes;
            public uint CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
            public uint SizeHigh, SizeLow, Reserved0, Reserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string AltName;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr FindFirstFileExW(string fileName, int infoLevel, out FindData data, int searchOp, IntPtr filter, int flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool FindNextFileW(IntPtr handle, out FindData data);
        [DllImport("kernel32.dll")]
        static extern bool FindClose(IntPtr handle);
        static readonly IntPtr Invalid = new IntPtr(-1);
        const uint IsDir = 0x10, Reparse = 0x400, Recall = 0x400000;   // Recall: OneDrive "online-only" placeholder, no bytes on disk
        const int MaxDepth = 12;
        static readonly string[] NoDescend = { "node_modules", ".git", "winsxs", ".pnpm", "__pycache__", ".next", ".gradle", ".nuget", "$recycle.bin", "system volume information" };
        public static List<Folder> All;
        public static Dictionary<string, Folder> Index;
        public static Dictionary<string, List<Folder>> Kids;
        public static string Key(string path) { return path.TrimEnd('\\').ToLowerInvariant(); }
        public static void Scan(string root) {   // later calls add to the same index (focus folders on other drives)
            if (All == null) { All = new List<Folder>(); Index = new Dictionary<string, Folder>(); Kids = new Dictionary<string, List<Folder>>(); }
            long newest = 0;
            Walk(root, null, 0, true, true, ref newest);
        }
        // record: list this folder; descend: list its children too (false inside node_modules & co - they are
        // sized and shown as one entry, their thousands of subfolders are not)
        static long Walk(string path, string parentKey, int depth, bool record, bool descend, ref long newest) {
            long total = 0, mine = 0;
            string key = Key(path);
            string prefix = path.EndsWith("\\") ? path : path + "\\";
            FindData d;
            IntPtr h = FindFirstFileExW("\\\\?\\" + prefix + "*", 1, out d, 0, IntPtr.Zero, 2);   // FindExInfoBasic, FIND_FIRST_EX_LARGE_FETCH
            if (h != Invalid) {
                List<string> subs = null;
                do {
                    if ((d.Attributes & IsDir) != 0) {
                        if (d.Name == "." || d.Name == ".." || (d.Attributes & Reparse) != 0) continue;
                        if (subs == null) subs = new List<string>();
                        subs.Add(d.Name);
                    } else {
                        if ((d.Attributes & Recall) != 0) continue;
                        total += ((long)d.SizeHigh << 32) | d.SizeLow;
                        long w = ((long)d.WriteHigh << 32) | d.WriteLow;
                        if (w > mine) mine = w;
                    }
                } while (FindNextFileW(h, out d));
                FindClose(h);
                if (subs != null) foreach (string s in subs) {
                    bool kidsDescend = descend && depth + 1 < MaxDepth && Array.IndexOf(NoDescend, s.ToLowerInvariant()) < 0;
                    total += Walk(prefix + s, record ? key : null, depth + 1, descend, kidsDescend, ref mine);
                }
            }
            if (record) {
                DateTime when = DateTime.MinValue;
                if (mine > 0) { try { when = DateTime.FromFileTimeUtc(mine); } catch { } }
                Folder f = new Folder { Path = path, Bytes = total, Depth = depth, Newest = when };
                All.Add(f);
                Index[key] = f;
                if (parentKey != null) {
                    List<Folder> list;
                    if (!Kids.TryGetValue(parentKey, out list)) { list = new List<Folder>(); Kids[parentKey] = list; }
                    list.Add(f);
                }
            }
            if (mine > newest) newest = mine;
            return total;
        }
    }
}
'@

$script:Scanned = $false
function Get-Scan {   # runs once per process; later lookups are dictionary hits
    if ($script:Scanned) { return }
    if (-not ('DiskBuddy.Walker' -as [type])) { Add-Type -TypeDefinition $WalkerSource }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [DiskBuddy.Walker]::Scan("$($cfg.Drive):\")
    $script:Scanned = $true
    # Focus folders on other drives are scanned on their own and added to the same index.
    foreach ($pattern in $cfg.Focus) {
        foreach ($root in (Resolve-Focus $pattern)) {
            if ($root -notlike "$($cfg.Drive):*" -and -not (Get-ScanFolder $root)) { [DiskBuddy.Walker]::Scan($root) }
        }
    }
    Write-Log ('scan: {0} folders in {1}s' -f [DiskBuddy.Walker]::All.Count, [int]$sw.Elapsed.TotalSeconds)
}

# Each focus folder of the profile with its five biggest subfolders - the dev's project tree, the gamer's library...
function Get-FocusFolders($cfg) {
    Get-Scan
    $out = foreach ($pattern in $cfg.Focus) {
        $paths = Resolve-Focus $pattern
        if (-not $paths) { [pscustomobject]@{ Path = $pattern; GB = 0; Newest = $null; Kids = @(); Missing = $true }; continue }
        foreach ($p in $paths) {
            $f = Get-ScanFolder $p
            $kids = @(Get-Children $p | Where-Object { $_.Bytes -ge 50MB } | Sort-Object Bytes -Descending | Select-Object -First 5)
            [pscustomobject]@{ Path = $p; GB = $(if ($f) { [math]::Round($f.Bytes / 1GB, 2) } else { Get-FolderGB $p }); Newest = (Get-Newest $f); Kids = $kids; Missing = $false }
        }
    }
    @($out | Sort-Object Missing, { -$_.GB })
}

function Get-ScanFolder([string]$Path) {   # $null when the folder is missing or sits inside an unexpanded tree
    Get-Scan
    $f = $null
    if ([DiskBuddy.Walker]::Index.TryGetValue([DiskBuddy.Walker]::Key($Path), [ref]$f)) { $f }
}

function Get-ScanGB([string]$Path) {
    $f = Get-ScanFolder $Path
    if ($f) { return [math]::Round($f.Bytes / 1GB, 2) }
    Get-FolderGB $Path
}

function Get-Children([string]$Path) {   # direct subfolders, with sizes
    Get-Scan
    $l = $null
    if ([DiskBuddy.Walker]::Kids.TryGetValue([DiskBuddy.Walker]::Key($Path), [ref]$l)) { @($l) } else { @() }
}

function Get-Newest($Folder) {   # local time of the newest file anywhere below, or $null
    if ($Folder -and $Folder.Newest -gt [datetime]::MinValue) { $Folder.Newest.ToLocalTime() }
}

# The folders that explain where the space is: big ones, skipping any that is mostly a single child
# (C:\Users is just a box around C:\Users\<you>; the child says more).
function Get-BigFolders($cfg, [int]$Top = 15) {
    Get-Scan
    $min = [double]$cfg.BigFolderMinGB * 1GB
    $out = foreach ($f in [DiskBuddy.Walker]::All) {
        if ($f.Depth -lt 1 -or $f.Bytes -lt $min -or $f.Path -notlike "$($cfg.Drive):*") { continue }
        $maxKid = 0
        foreach ($k in (Get-Children $f.Path)) { if ($k.Bytes -gt $maxKid) { $maxKid = $k.Bytes } }
        if ($maxKid -lt $f.Bytes * 0.7) { $f }
    }
    @($out | Sort-Object Bytes -Descending | Select-Object -First $Top)
}

#endregion
#region docker

$script:DockerUp = $null   # probed once per run; a hung engine costs the full timeout each time

function Test-DockerUp {
    if ($null -ne $script:DockerUp) { return $script:DockerUp }
    $script:DockerUp = $false
    if (Get-Process 'com.docker.backend' -ErrorAction SilentlyContinue) {
        $r = Invoke-Native 'docker' 'version --format "{{.Server.Version}}"' 15
        $script:DockerUp = [bool]($r -and $r.ExitCode -eq 0 -and $r.Out.Trim())
    }
    $script:DockerUp
}

function ConvertFrom-DockerSize([string]$Text) {
    $units = @{ 'B' = 1; 'KB' = 1e3; 'MB' = 1e6; 'GB' = 1e9; 'TB' = 1e12 }
    if ($Text -match '^\s*([\d.]+)\s*([kKMGT]?B)') { return [double]::Parse($Matches[1], $Inv) * $units[$Matches[2]] / 1GB }
    0
}

function Get-DockerUsage {
    $r = Invoke-Native 'docker' 'system df --format "{{json .}}"' 60
    if (-not $r -or $r.ExitCode -ne 0) { return }
    foreach ($line in ($r.Out -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $row = $line | ConvertFrom-Json
        [pscustomobject]@{
            Type          = $row.Type
            SizeGB        = ConvertFrom-DockerSize $row.Size
            ReclaimableGB = ConvertFrom-DockerSize $row.Reclaimable
        }
    }
}

# Volumes no container uses. 64-hex names are anonymous leftovers (e.g. docker:dind's /var/lib/docker).
function Get-UnusedVolumes {
    $r = Invoke-Native 'docker' 'volume ls -q --filter dangling=true' 30
    if (-not $r -or $r.ExitCode -ne 0) { return }
    $names = @($r.Out -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
    if (-not $names) { return }
    $sizes = @{}
    $df = Invoke-Native 'docker' 'system df -v' 120
    if ($df -and $df.ExitCode -eq 0) {
        $inVolumes = $false
        foreach ($line in ($df.Out -split "`r?`n")) {
            if ($line -match '^Local Volumes space usage') { $inVolumes = $true; continue }
            if ($line -match 'space usage|^Build cache') { $inVolumes = $false }
            if ($inVolumes -and $line -match '^(\S+)\s+\d+\s+(\S+)\s*$') { $sizes[$Matches[1]] = ConvertFrom-DockerSize $Matches[2] }
        }
    }
    foreach ($n in $names) {
        [pscustomobject]@{ Name = $n; SizeGB = [double]$sizes[$n]; Anonymous = ($n -match '^[0-9a-f]{64}$') }
    }
}

# Space inside docker_data.vhdx that Docker no longer uses; only Compact returns it to the drive.
# Remembers the last measured usage so it still has an answer while Docker is stopped.
function Get-DockerSlackGB($State) {
    $file = Get-FileGB $DockerVhdx
    if ($file -eq 0) { return 0 }
    if (Test-DockerUp) {
        $usage = @(Get-DockerUsage)
        if ($usage) { $State.DockerUsedGB = [math]::Round(($usage | Measure-Object SizeGB -Sum).Sum, 1) }
    }
    if ($null -eq $State.DockerUsedGB) { return 0 }
    [math]::Max(0, [math]::Round($file - [double]$State.DockerUsedGB - 2, 1))   # ~2 GB is the engine itself
}

#endregion
#region notifications

function Get-AppId {
    if (Test-Path "HKCU:\Software\Classes\AppUserModelId\$AppId") { return $AppId }
    '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
}

# Buttons only run something when you press them (via the diskbuddy: link handler).
function Btn([string]$Label, [string]$Action) { [pscustomobject]@{ Label = $Label; Uri = "diskbuddy:$Action" } }

# Plays the configured sound itself (the toast stays silent), so it works regardless of per-app sound settings.
# A file name is looked up in C:\Windows\Media; a full path works too.
function Invoke-Sound([string]$Kind) {
    if (-not $cfg.Sound -or $Kind -eq 'none') { return }
    $name = @{ alert = $cfg.SoundAlert; critical = $cfg.SoundCritical; done = $cfg.SoundDone }[$Kind]
    if (-not $name) { return }
    $path = if ([IO.Path]::IsPathRooted($name)) { $name } else { Join-Path "$env:WINDIR\Media" $name }
    if (-not (Test-Path -LiteralPath $path)) { Write-Log "sound not found: $path"; return }
    try { (New-Object System.Media.SoundPlayer $path).PlaySync() } catch { Write-Log "sound failed: $_" }   # sync: hidden process would exit mid-sound
}

function Show-Toast {
    param(
        [string]$Title,
        [string[]]$Lines = @(),
        [object[]]$Buttons = @(),
        $Drive,
        [string]$Tag,
        [ValidateSet('', 'alert', 'critical', 'done', 'none')]
        [string]$Sound = ''   # default: 'done', or silent for tagged "working..." toasts
    )
    if (-not $Sound) { $Sound = if ($Tag) { 'none' } else { 'done' } }
    $e = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $texts = (@($Title) + @($Lines) | Where-Object { $_ } | Select-Object -First 3 | ForEach-Object { "<text>$(& $e $_)</text>" }) -join ''
    $bar = ''
    if ($Drive) {
        $ratio = ($Drive.UsedGB / $Drive.TotalGB).ToString('0.00', $Inv)
        $used = '{0:N0} of {1:N0} GB used' -f $Drive.UsedGB, $Drive.TotalGB
        $bar = '<progress title="{0}: drive" value="{1}" valueStringOverride="{2}" status="{3}"/>' -f $Drive.Letter, $ratio, (& $e $used), (& $e "$(Format-GB $Drive.FreeGB) free")
    }
    $actions = ''
    if ($Buttons) {
        $btn = ($Buttons | ForEach-Object { '<action content="{0}" activationType="protocol" arguments="{1}"/>' -f (& $e $_.Label), (& $e $_.Uri) }) -join ''
        $actions = "<actions>$btn</actions>"
    }
    $xml = "<toast activationType=`"protocol`" launch=`"diskbuddy:report`"><visual><binding template=`"ToastGeneric`">$texts$bar</binding></visual>$actions<audio silent=`"true`"/></toast>"
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        if ($Tag) { $toast.Tag = $Tag; $toast.Group = 'diskbuddy' }
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier((Get-AppId)).Show($toast)
        if (-not $Tag) { Write-Log "notified: $Title" }
        Invoke-Sound $Sound
    } catch { Write-Log "toast failed: $_" }
}

# Alerts only pop up while the desktop itself (wallpaper) has focus, e.g. after Win+D,
# so they never land on top of a game or any other app.
function Test-DesktopFocused {
    try {
        if (-not ('DiskBuddy.User32' -as [type])) {
            Add-Type -Namespace DiskBuddy -Name User32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int max);
'@
        }
        $name = New-Object System.Text.StringBuilder 256
        [void][DiskBuddy.User32]::GetClassName([DiskBuddy.User32]::GetForegroundWindow(), $name, $name.Capacity)
        return @('Progman', 'WorkerW') -contains $name.ToString()
    } catch {
        return $true   # can't tell - better to show the alert than hold it forever
    }
}

# Polls cheaply until the desktop is focused or the wait runs out (kept under the 15-min task interval).
function Wait-ForDesktop($cfg) {
    $until = (Get-Date).AddMinutes([double]$cfg.WaitForDesktopMinutes)
    while ($true) {
        if (Test-DesktopFocused) { return $true }
        if ((Get-Date) -ge $until) { return $false }
        Start-Sleep -Seconds 2
    }
}

function Remove-Toast([string]$Tag) {
    try { [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($Tag, 'diskbuddy', (Get-AppId)) } catch {}
}

# Cheap "what's big" line for notifications (single file + two small folders).
function Get-QuickHints($cfg) {
    $items = @(
        [pscustomobject]@{ Name = 'Docker disk'; GB = Get-FileGB $DockerVhdx }
        [pscustomobject]@{ Name = 'Recycle Bin'; GB = Get-FolderGB (Get-RecycleBinPath $cfg.Drive) }
        [pscustomobject]@{ Name = 'Temp'; GB = Get-FolderGB $env:TEMP }
    )
    $top = @($items | Where-Object { $_.GB -ge 1 } | Sort-Object GB -Descending)
    if ($top) { 'Biggest: ' + (($top | ForEach-Object { "$($_.Name) $(Format-GB $_.GB)" }) -join $Dot) }
}

#endregion
#region catalog

# Everything Disk Buddy knows how to look at, in one list. Kind decides what happens:
#   clean   rebuildable cache - Clean runs its Remove block (which returns the GB it freed)
#   review  your data or tools - shown with advice, never touched automatically
#   info    context only (Docker disk, page file...)
# CleanGB is what Clean would actually remove when that is less than the whole item (old Playwright versions).
# Group is what a profile switches on or off: system docker node python ai gpu browsers apple apps games downloads dotnet java
function Item([string]$Name, [double]$GB, [string]$Hint, [string]$Kind = 'info', [scriptblock]$Remove = $null, [string]$Path = '', $CleanGB = $null) {
    if ($null -eq $CleanGB) { $CleanGB = $GB }
    [pscustomobject]@{ Name = $Name; GB = [math]::Round($GB, 2); Hint = $Hint; Kind = $Kind; Remove = $Remove; Path = $Path; CleanGB = [math]::Round([double]$CleanGB, 2); Group = 'system' }
}

# Deletes what it can (locked files are simply left behind) and returns the GB that actually went.
function Remove-Tree([string]$Path, [switch]$KeepRoot) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    $before = Get-FolderGB $Path
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not $KeepRoot) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
    $after = if (Test-Path -LiteralPath $Path) { Get-FolderGB $Path } else { 0 }
    [math]::Max(0, [math]::Round($before - $after, 2))
}

function Remove-Many([string[]]$Paths, [switch]$KeepRoot) {
    $t = 0
    foreach ($p in @($Paths)) { if ($p) { $t += Remove-Tree $p -KeepRoot:$KeepRoot } }
    $t
}

function Measure-Paths([string[]]$Paths) {
    $t = 0
    foreach ($p in @($Paths)) { if ($p -and (Test-Path -LiteralPath $p)) { $t += Get-ScanGB $p } }
    [math]::Round($t, 2)
}

function Get-SpaceCatalog($cfg, $State) {
    $L = $env:LOCALAPPDATA; $R = $env:APPDATA; $LL = Join-Path $env:USERPROFILE 'AppData\LocalLow'
    $U = $env:USERPROFILE; $D = "$($cfg.Drive):"
    $items = New-Object System.Collections.Generic.List[object]
    $add = { param($i, [string]$g = 'system') $i.Group = $g; if ($i.GB -ge 0.05) { $items.Add($i) } }
    $day = { param($t) if ($t) { $t.ToString('yyyy-MM-dd', $Inv) } else { '?' } }

    # --- context
    if (Test-Group 'docker') {
        $slack = Get-DockerSlackGB $State
        $dockerHint = if ($slack -ge 1) { "About $(Format-GB $slack) of this is empty space. Compact gives it back." }
                      else { 'Grows with images, volumes and build cache; never shrinks on its own.' }
        & $add (Item 'Docker virtual disk' (Get-FileGB $DockerVhdx) $dockerHint 'info' $null $DockerVhdx) 'docker'
    }
    & $add (Item 'Recycle Bin' (Get-FolderGB (Get-RecycleBinPath $cfg.Drive)) 'Empty it yourself once you are sure.')
    & $add (Item 'Previous Windows (Windows.old)' (Get-ScanGB "$D\Windows.old") 'Kept after a Windows update so you can roll back (~10 days). Remove it in Settings > System > Storage > Temporary files > Previous Windows installation(s).')
    & $add (Item 'Page file (pagefile.sys)' (Get-FileGB "$D\pagefile.sys") 'Virtual memory, sized by Windows. Leave it unless you know why you would change it.')
    & $add (Item 'Hibernation file (hiberfil.sys)' (Get-FileGB "$D\hiberfil.sys") 'Holds memory for hibernate and Fast Startup. "powercfg /h off" (admin) removes it if you never hibernate.')
    & $add (Item 'Windows Update downloads' (Get-ScanGB "$env:WINDIR\SoftwareDistribution\Download") 'Settings > System > Storage > Temporary files > Windows Update Cleanup.')

    # --- caches Clean removes (the first four are handled by Clean itself, hence no Remove block)
    & $add (Item 'Temp files' (Get-ScanGB $env:TEMP) "Clean removes files older than $($cfg.TempOlderThanDays) days." 'clean')
    & $add (Item 'pnpm store' (Get-ScanGB "$L\pnpm\store") 'Clean prunes packages no project uses (what is left is shared by all your Node projects).' 'clean' $null '' 0) 'node'
    & $add (Item 'npm cache' (Get-ScanGB "$L\npm-cache") 'Clean empties it.' 'clean') 'node'
    & $add (Item 'Yarn cache' (Get-ScanGB "$L\Yarn") 'Shared by Yarn projects; "yarn cache clean" empties it.' 'info') 'node'

    $pip = "$L\pip\cache"
    & $add (Item 'pip cache' (Get-ScanGB $pip) 'Downloaded Python packages; pip fetches again when needed.' 'clean' { Remove-Tree $pip -KeepRoot }.GetNewClosure() $pip) 'python'

    $shader = @("$L\NVIDIA\DXCache", "$L\NVIDIA\GLCache", "$L\NVIDIA\OptixCache", "$L\NVIDIA Corporation\NV_Cache", "$L\D3DSCache",
                "$L\AMD\DxCache", "$L\AMD\GLCache", "$L\AMD\VkCache") | Where-Object { Test-Path -LiteralPath $_ }
    & $add (Item 'GPU shader caches' (Measure-Paths $shader) 'Compiled shaders for games and apps. Rebuilt automatically; the first launch afterwards stutters a little.' 'clean' { Remove-Many $shader -KeepRoot }.GetNewClosure() ($shader -join '; ')) 'gpu'

    $dumps = @("$L\CrashDumps", "$L\Microsoft\Windows\WER") | Where-Object { Test-Path -LiteralPath $_ }
    & $add (Item 'Crash dumps and error reports' (Measure-Paths $dumps) 'Only useful while debugging a crash that already happened.' 'clean' { Remove-Many $dumps -KeepRoot }.GetNewClosure() ($dumps -join '; '))

    $drivers = @("$D\AMD", "$D\NVIDIA") | Where-Object { Test-Path -LiteralPath $_ }
    & $add (Item 'Unpacked driver installers' (Measure-Paths $drivers) "Setup files left in $D\AMD or $D\NVIDIA; the driver itself is installed. The next driver update unpacks again." 'clean' { Remove-Many $drivers }.GetNewClosure() ($drivers -join '; '))

    $browsers = @(
        @{ Name = 'Edge'; Proc = 'msedge'; Root = "$L\Microsoft\Edge\User Data" },
        @{ Name = 'Chrome'; Proc = 'chrome'; Root = "$L\Google\Chrome\User Data" },
        @{ Name = 'Brave'; Proc = 'brave'; Root = "$L\BraveSoftware\Brave-Browser\User Data" }
    )
    $cacheDirs = @('Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache', 'DawnWebGPUCache', 'DawnGraphiteCache', 'GrShaderCache', 'ShaderCache')
    foreach ($b in $browsers) {
        if (-not (Test-Path -LiteralPath $b.Root)) { continue }
        $paths = @(Get-ChildItem -LiteralPath $b.Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Preferences') } |
            ForEach-Object { $p = $_.FullName; $cacheDirs | ForEach-Object { Join-Path $p $_ } })
        $paths += @('ShaderCache', 'GrShaderCache', 'GraphiteDawnCache' | ForEach-Object { Join-Path $b.Root $_ })
        $paths = @($paths | Where-Object { Test-Path -LiteralPath $_ })
        if (-not $paths) { continue }
        $name = $b.Name; $proc = $b.Proc
        & $add (Item "$name cache" (Measure-Paths $paths) 'Web page cache, rebuilt as you browse. Clean clears it only while the browser is closed; bookmarks, passwords and history are never touched.' 'clean' {
            if (Get-Process $proc -ErrorAction SilentlyContinue) { return "$name cache skipped ($name is open)" }   # a string result is a note, not a size
            Remove-Many $paths -KeepRoot
        }.GetNewClosure() $b.Root) 'browsers'
    }

    $pw = "$L\ms-playwright"
    if (Test-Path -LiteralPath $pw) {
        $vers = @(Get-ChildItem -LiteralPath $pw -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match '^(.+)-(\d+)$') { [pscustomobject]@{ Dir = $_.FullName; Family = $Matches[1]; Build = [int]$Matches[2] } } })
        $old = @($vers | Group-Object Family | ForEach-Object { $_.Group | Sort-Object Build -Descending | Select-Object -Skip 1 })
        $oldDirs = @($old | ForEach-Object { $_.Dir })
        & $add (Item 'Playwright browsers' (Get-ScanGB $pw) "Browsers for Playwright tests ($($vers.Count) versions installed). Clean removes old versions and keeps the newest of each browser; a test run downloads what it needs." 'clean' { Remove-Many $oldDirs }.GetNewClosure() $pw (Measure-Paths $oldDirs)) 'node'
    }

    $appleRoots = @("$R\Apple Computer") + @(Get-ChildItem "$L\Packages\AppleInc.iTunes_*\LocalCache\Roaming\Apple Computer" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $ipsw = @(foreach ($a in $appleRoots) { foreach ($n in 'iPhone', 'iPad', 'iPod') { "$a\iTunes\$n Software Updates" } }) | Where-Object { Test-Path -LiteralPath $_ }
    & $add (Item 'iOS update files (iTunes)' (Measure-Paths $ipsw) 'Firmware (.ipsw) iTunes downloaded to update an iPhone or iPad. Downloaded again the next time a device needs it.' 'clean' { Remove-Many $ipsw -KeepRoot }.GetNewClosure() ($ipsw -join '; ')) 'apple'

    # --- worth a look: your data or tools, never touched automatically
    $backupRoots = @($appleRoots | ForEach-Object { "$_\MobileSync\Backup" })
    foreach ($root in $backupRoots) {
        foreach ($b in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $f = Get-ScanFolder $b.FullName
            $gb = if ($f) { $f.Bytes / 1GB } else { Get-FolderGB $b.FullName }
            $when = Get-Newest $f; if (-not $when) { $when = $b.LastWriteTime }
            & $add (Item "iPhone/iPad backup from $(& $day $when)" $gb 'A full backup of the device. If iCloud Backup is on, delete it in the Apple Devices app (Manage Backups), or move it to another drive. Never cleaned automatically.' 'review' $null $b.FullName) 'apple'
        }
    }

    foreach ($m in @(Get-ChildItem "$U\.cache\huggingface\hub" -Directory -Filter 'models--*' -ErrorAction SilentlyContinue)) {
        & $add (Item "AI model: $($m.Name -replace '^models--', '' -replace '--', '/')" (Get-ScanGB $m.FullName) 'Downloaded by a Python tool; it downloads again on next use. Delete the folder by hand if you no longer use that tool.' 'review' $null $m.FullName) 'ai'
    }
    & $add (Item 'Ollama models' (Get-ScanGB "$U\.ollama\models") '"ollama list" shows them; "ollama rm <name>" removes one.' 'review' $null "$U\.ollama\models") 'ai'

    $pyRoots = @(Get-ChildItem "$L\Programs\Python\Python3*", "$env:ProgramFiles\Python3*" -Directory -ErrorAction SilentlyContinue) + @(Get-Item "$U\miniconda3", "$U\anaconda3" -ErrorAction SilentlyContinue)
    foreach ($py in $pyRoots) {
        foreach ($pkg in @(Get-Children (Join-Path $py.FullName 'Lib\site-packages'))) {
            $gb = $pkg.Bytes / 1GB
            $n = Split-Path $pkg.Path -Leaf
            if ($gb -ge [double]$cfg.BigPackageGB -and $n -notmatch '\.dist-info$|^__pycache__$') {
                & $add (Item "Python package: $n ($($py.Name))" $gb "Remove with: pip uninstall $n - only if nothing you run imports it. One pip install brings it back." 'review' $null $pkg.Path) 'python'
            }
        }
    }

    $cutOld = (Get-Date).AddDays(-[double]$cfg.OldInstallerDays)
    foreach ($f in @(Get-ChildItem -LiteralPath "$U\Downloads" -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(exe|msi|msix|iso|img)$' -and $_.Length -ge 100MB -and $_.LastWriteTime -lt $cutOld })) {
        & $add (Item "Downloads: $($f.Name)" ($f.Length / 1GB) "Installer from $(& $day $f.LastWriteTime). Once the program is installed this can go; delete it by hand." 'review' $null $f.FullName) 'downloads'
    }

    # App data nothing has written to in months: a leftover if the app or game is gone.
    $system = @('Microsoft', 'Packages', 'Programs', 'Temp', 'Docker', 'pnpm', 'npm-cache', 'NVIDIA', 'NVIDIA Corporation', 'AMD', 'Apple Computer', 'Comms', 'ConnectedDevicesPlatform', 'D3DSCache', 'CrashDumps', 'ms-playwright', 'pip', 'Yarn', 'Intel', 'PlaceholderTileLogoFolder', 'Publishers')
    $orphanCut = (Get-Date).AddMonths(-[int]$cfg.OrphanMonths)
    foreach ($where in @(@{ Dir = $L; Tag = 'Local' }, @{ Dir = $R; Tag = 'Roaming' }, @{ Dir = $LL; Tag = 'LocalLow' })) {
        foreach ($f in @(Get-Children $where.Dir)) {
            $n = Split-Path $f.Path -Leaf
            if ($system -contains $n -or $f.Bytes -lt 1GB) { continue }
            $when = Get-Newest $f
            if (-not $when -or $when -ge $orphanCut) { continue }
            $months = [int](((Get-Date) - $when).TotalDays / 30)
            & $add (Item "Old app data: $n ($($where.Tag))" ($f.Bytes / 1GB) "Nothing in it changed for $months months (last: $(& $day $when)). If that app or game is gone from Settings > Apps, this is a leftover you can delete by hand." 'review' $null $f.Path) 'apps'
        }
    }

    & $add (Item '3DMark benchmark downloads' (Get-ScanGB "$env:ProgramData\UL\3DMark") 'Test assets 3DMark fetches again when you run a benchmark.' 'review' $null "$env:ProgramData\UL\3DMark") 'games'

    foreach ($app in @(Get-Children "$L\Programs" | Where-Object { $_.Bytes -ge 1GB })) {
        & $add (Item "App: $(Split-Path $app.Path -Leaf) (per-user install)" ($app.Bytes / 1GB) 'An installed program. Remove it from Settings > Apps if you no longer use it.' 'info' $null $app.Path) 'apps'
    }

    & $add (Item 'Downloads' (Get-ScanGB "$U\Downloads") 'Your own files - review by hand.' 'info' $null "$U\Downloads") 'downloads'
    & $add (Item 'NuGet packages' (Get-ScanGB "$U\.nuget\packages") '' 'info') 'dotnet'
    & $add (Item 'Gradle caches' (Get-ScanGB "$U\.gradle\caches") '' 'info') 'java'

    # The profile decides which groups count.
    if ($cfg.Groups -is [string]) { $items } else { @($items | Where-Object { $cfg.Groups -contains $_.Group }) }
}

#endregion
#region modes

function Invoke-Check($cfg) {
    $state = Get-State
    $drive = Get-DriveInfo $cfg.Drive
    $now = Get-Date
    $dockerFile = Get-FileGB $DockerVhdx
    $rank = @{ ok = 0; warn = 1; critical = 2 }
    $levelOf = { param($free) if ($free -lt $cfg.CriticalFreeGB) { 'critical' } elseif ($free -lt $cfg.WarnFreeGB) { 'warn' } else { 'ok' } }
    $level = & $levelOf $drive.FreeGB
    $lastLevel = if ($state.LastLevel) { $state.LastLevel } else { 'ok' }
    $snoozed = $now -lt (ConvertFrom-Stamp $state.SnoozeUntil)

    # Decide what to say first, then wait for the desktop before saying (or cleaning) anything.
    $todo = $null
    if ($null -ne $state.LastFreeGB -and -not $snoozed) {
        # Sudden drop between two checks: a big build, image pull, or download.
        $drop = [double]$state.LastFreeGB - $drive.FreeGB
        $minutes = [math]::Max(1, [math]::Round(($now - (ConvertFrom-Stamp $state.LastCheck)).TotalMinutes))
        if ($drop -ge $cfg.DropAlertGB -and $minutes -le 120) { $todo = 'drop' }
    }
    if (-not $todo -and $level -ne 'ok') {
        $repeat = if ($level -eq 'critical') { $cfg.CriticalRepeatHours } else { $cfg.WarnRepeatHours }
        $due = ($rank[$level] -gt $rank[$lastLevel]) -or (($now - (ConvertFrom-Stamp $state.LastNotified)).TotalHours -ge $repeat)
        if ($level -eq 'warn' -and $snoozed) { $due = $false }
        if ($due) { $todo = 'alert' }
    }

    # Once a day, measure the whole drive. When a lot of rebuildable cache has piled up, say so - at most once a
    # week, and even while the drive is fine. That is what a manual look through the folders would have found.
    if (-not $todo -and ((Get-Date) - (ConvertFrom-Stamp $state.LastDeepScan)).TotalHours -ge [double]$cfg.DeepScanHours) {
        try {
            $cat = @(Get-SpaceCatalog $cfg $state)
            $clean = @($cat | Where-Object { $_.Kind -eq 'clean' -and $_.CleanGB -ge 0.05 } | Sort-Object CleanGB -Descending)
            $review = @($cat | Where-Object { $_.Kind -eq 'review' } | Sort-Object GB -Descending)
            $state.CleanableGB = [math]::Round(($clean | Measure-Object CleanGB -Sum).Sum, 1)
            $state.ReviewGB = [math]::Round(($review | Measure-Object GB -Sum).Sum, 1)
            $lines = @(($clean | Select-Object -First 3 | ForEach-Object { "$($_.Name) $(Format-GB $_.CleanGB)" }) -join $Dot)
            if ($review) { $lines += 'Worth a look: ' + (($review | Select-Object -First 2 | ForEach-Object { "$($_.Name) $(Format-GB $_.GB)" }) -join $Dot) }
            $state.DigestLines = $lines
            $state.LastDeepScan = ConvertTo-Stamp (Get-Date)
            Write-Log "deep scan: $(Format-GB $state.CleanableGB) of caches, $(Format-GB $state.ReviewGB) worth a look"
        } catch { Write-Log "deep scan failed: $_" }
    }
    $digestDue = $null -ne $state.CleanableGB -and [double]$state.CleanableGB -ge [double]$cfg.CacheAlertGB -and -not $snoozed -and
        ((Get-Date) - (ConvertFrom-Stamp $state.LastDigest)).TotalHours -ge [double]$cfg.DigestRepeatHours
    if (-not $todo -and $digestDue) { $todo = 'digest' }

    # Not reaching the desktop in time keeps the old baseline, so the next run raises the same alert.
    $deferred = $todo -and -not (Wait-ForDesktop $cfg)
    if ($deferred) {
        Write-Log "holding back ($todo) until you're on the desktop"
        $todo = $null
    }
    $notified = [bool]$todo

    if ($todo -eq 'drop') {
        $grew = $dockerFile - [double]$state.LastDockerFileGB
        $why = if ($grew -ge $drop * 0.5) { "Docker's disk grew $(Format-GB $grew) $Dash a build or image pull is filling it." }
               else { 'Not Docker. Maybe Windows Update, a download, or a build output.' }
        Show-Toast -Title "$($cfg.Drive): lost $(Format-GB $drop) in $minutes min" -Lines @($why) -Drive (Get-DriveInfo $cfg.Drive) `
            -Buttons @((Btn 'Details' 'report'), (Btn 'Snooze 1 day' 'snooze')) -Sound alert
    } elseif ($todo -eq 'digest') {
        Show-Toast -Title "$(Format-GB ([double]$state.CleanableGB)) of caches can go on $($cfg.Drive):" -Lines @($state.DigestLines) -Drive $drive `
            -Buttons @((Btn 'Clean' 'clean'), (Btn 'Details' 'report'), (Btn 'Snooze 1 day' 'snooze')) -Sound alert
        $state.LastDigest = ConvertTo-Stamp (Get-Date)
    } elseif ($todo) {
        $drive = Get-DriveInfo $cfg.Drive   # may have changed while waiting
        $slack = Get-DockerSlackGB $state
        $title = if ($level -eq 'critical') { "$($cfg.Drive): is almost full $Dash $(Format-GB $drive.FreeGB) left" }
                 else { "$($cfg.Drive): is getting full $Dash $(Format-GB $drive.FreeGB) left" }
        $lines = @(Get-QuickHints $cfg)
        $buttons = @(Btn 'Clean' 'clean')
        if ($slack -ge 10) {
            $lines += "Docker's disk has $(Format-GB $slack) of empty space it can give back."
            $buttons += Btn 'Compact Docker' 'compact'
        }
        $buttons += Btn 'Details' 'report'
        if ($level -eq 'warn') { $buttons += Btn 'Snooze 1 day' 'snooze' }
        Show-Toast -Title $title -Lines $lines -Drive $drive -Buttons $buttons -Sound $(if ($level -eq 'critical') { 'critical' } else { 'alert' })
    }

    if ($notified -and $todo -ne 'digest') { $state.LastNotified = ConvertTo-Stamp (Get-Date) }
    if (-not $deferred) {
        $state.LastLevel = $level
        $state.LastFreeGB = $drive.FreeGB
        $state.LastDockerFileGB = $dockerFile
        $state.LastCheck = ConvertTo-Stamp $now
    }
    Save-State $state
    Write-Log ('check: {0} free, {1}{2}' -f (Format-GB $drive.FreeGB), $level, $(if ($notified) { ', notified' } else { '' }))
}

function Invoke-Clean($cfg) {
    $before = (Get-DriveInfo $cfg.Drive).FreeGB
    $notes = New-Object System.Collections.Generic.List[string]
    $dockerFreed = 0

    if (-not (Test-Group 'docker')) {
        # profile leaves Docker alone
    } elseif (Test-DockerUp) {
        $usedBefore = (@(Get-DockerUsage) | Measure-Object SizeGB -Sum).Sum
        $filter = "until=$($cfg.DockerPruneOlderThanHours)h"
        Invoke-Native 'docker' "container prune -f --filter $filter" 120 | Out-Null
        Invoke-Native 'docker' "image prune -a -f --filter $filter" 600 | Out-Null
        Invoke-Native 'docker' "builder prune -a -f --filter $filter" 600 | Out-Null
        $usedAfter = (@(Get-DockerUsage) | Measure-Object SizeGB -Sum).Sum
        $dockerFreed = [math]::Max(0, [math]::Round($usedBefore - $usedAfter, 1))
        $notes.Add("Docker $(Format-GB $dockerFreed)")
    } else {
        $notes.Add('Docker skipped (not running)')
    }

    if (Test-Group 'node') {
        if (Invoke-Native 'pnpm' 'store prune' 600) { $notes.Add('pnpm store pruned') }
        if (Invoke-Native 'npm' 'cache clean --force' 300) { $notes.Add('npm cache cleared') }
    }

    if (Test-Group 'system') {
        # .esd = a Windows Update image that may still be pending install
        $cut = (Get-Date).AddDays(-[double]$cfg.TempOlderThanDays)
        $tempBytes = 0
        Get-ChildItem -LiteralPath $env:TEMP -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cut -and $_.Extension -ne '.esd' } |
            ForEach-Object {
                $len = $_.Length
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $tempBytes += $len } catch {}
            }
        $notes.Add("Temp $(Format-GB ($tempBytes / 1GB))")
    }

    # Everything else the catalogue marks as a cache: shader caches, crash dumps, driver leftovers,
    # browser caches (skipped while that browser is open), old Playwright browsers, pip cache.
    # A Remove block returns the GB it freed, or a string explaining why it did nothing.
    foreach ($item in @(Get-SpaceCatalog $cfg (Get-State) | Where-Object { $_.Kind -eq 'clean' -and $_.Remove })) {
        $r = 0
        try { $r = & $item.Remove } catch { Write-Log "clean $($item.Name) failed: $_" }
        if ($r -is [string]) { $notes.Add($r) }
        elseif ([double]$r -ge 0.05) { $notes.Add("$($item.Name) $(Format-GB ([double]$r))") }
    }
    $s = Get-State; $s.CleanableGB = 0; Save-State $s   # the next daily scan measures afresh

    $after = (Get-DriveInfo $cfg.Drive).FreeGB
    $result = [pscustomobject]@{
        FreedGB       = [math]::Max(0, [math]::Round($after - $before, 1))
        DockerFreedGB = $dockerFreed
        Notes         = $notes
    }
    Write-Log ('clean: {0} freed on drive, {1} inside Docker ({2})' -f (Format-GB $result.FreedGB), (Format-GB $dockerFreed), ($notes -join ', '))
    $result
}

function Show-CleanResult($cfg, $Result, $Drive) {
    $lines = @($Result.Notes -join $Dot)
    $buttons = @()
    if ($Result.DockerFreedGB -ge 2 -or (Get-DockerSlackGB (Get-State)) -ge 10) {
        $lines += 'Docker keeps freed space inside its disk until you compact it.'
        $buttons += Btn 'Compact Docker' 'compact'
    }
    $buttons += Btn 'Details' 'report'
    Show-Toast -Title "Cleaned up $(Format-GB $Result.FreedGB) on $($cfg.Drive):" -Lines $lines -Drive $Drive -Buttons $buttons
}

function Invoke-Compact($cfg) {
    if (-not (Test-Path -LiteralPath $DockerVhdx)) {
        Show-Toast -Title 'No Docker disk found' -Lines @($DockerVhdx)
        return
    }
    if (-not $Elevated) {
        try {
            # -Wait so the report's button shows "running" until the admin window finishes
            Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -Wait `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Compact -Elevated"
        } catch { Write-Log 'compact: admin prompt declined' }
        return
    }

    $Host.UI.RawUI.WindowTitle = 'Disk Buddy - compacting Docker disk'
    $before = Get-FileGB $DockerVhdx
    $dockerWasRunning = [bool](Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)
    Write-Host "Docker disk is $(Format-GB $before). Docker is stopped while this runs (a few minutes).`n"
    Write-Host 'Stopping Docker Desktop...'
    Invoke-Native 'docker' 'desktop stop' 90 | Out-Null
    Get-Process 'Docker Desktop', 'com.docker.backend', 'com.docker.build' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host 'Shutting down WSL...'
    wsl.exe --shutdown
    Start-Sleep -Seconds 5

    Write-Host 'Compacting...'
    $ok = $false
    if (Get-Command Optimize-VHD -ErrorAction SilentlyContinue) {
        try { Optimize-VHD -Path $DockerVhdx -Mode Full -ErrorAction Stop; $ok = $true } catch { Write-Host "Optimize-VHD failed: $_" }
    }
    if (-not $ok) {
        $dp = Join-Path $env:TEMP 'diskbuddy-compact.txt'
        @("select vdisk file=`"$DockerVhdx`"", 'attach vdisk readonly', 'compact vdisk', 'detach vdisk') | Set-Content -Path $dp -Encoding ASCII
        diskpart.exe /s $dp
        $ok = ($LASTEXITCODE -eq 0)
        Remove-Item $dp -ErrorAction SilentlyContinue
    }

    $after = Get-FileGB $DockerVhdx
    $msg = "Docker disk: $(Format-GB $before) -> $(Format-GB $after)"
    Write-Log "compact: $msg (ok=$ok)"
    if ($dockerWasRunning) {
        Write-Host 'Starting Docker Desktop again...'
        # via explorer so Docker Desktop doesn't inherit this admin session
        Start-Process explorer.exe "`"$env:ProgramFiles\Docker\Docker\Docker Desktop.exe`""
    }
    Show-Toast -Title "Gave back $(Format-GB ($before - $after)) to $($cfg.Drive):" -Lines @($msg) -Drive (Get-DriveInfo $cfg.Drive)
    Write-Host "`n$msg"
    Start-Sleep -Seconds 4
}

function Remove-UnusedVolumes($cfg) {
    if (-not (Test-DockerUp)) {
        Show-Toast -Title 'Docker is not running' -Lines @('Start Docker Desktop, then try again.')
        return
    }
    $vols = @(Get-UnusedVolumes | Where-Object Anonymous | Sort-Object SizeGB -Descending)
    if (-not $vols) {
        Show-Toast -Title 'No leftover Docker volumes' -Lines @('Nothing to remove.')
        return
    }
    $total = ($vols | Measure-Object SizeGB -Sum).Sum
    $list = ($vols | ForEach-Object { '{0}...   {1}' -f $_.Name.Substring(0, 12), (Format-GB $_.SizeGB) }) -join "`n"
    Add-Type -AssemblyName System.Windows.Forms
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    $answer = [System.Windows.Forms.MessageBox]::Show($owner,
        "Remove $($vols.Count) unused anonymous Docker volumes ($(Format-GB $total))?`n`n$list`n`nThese are unnamed leftovers, e.g. from docker:dind runs. Named volumes such as databases are never touched.",
        'Disk Buddy', 'YesNo', 'Question')
    $owner.Dispose()
    if ($answer -ne 'Yes') { return }

    $removed = 0
    foreach ($v in $vols) {
        $r = Invoke-Native 'docker' "volume rm $($v.Name)" 60
        if ($r -and $r.ExitCode -eq 0) { $removed++ }
    }
    Write-Log "volumes: removed $removed of $($vols.Count) ($(Format-GB $total))"
    Show-Toast -Title "Removed $removed leftover Docker volumes" `
        -Lines @("$(Format-GB $total) freed inside Docker's disk.", 'Compact the disk to give it back to the drive.') `
        -Buttons @((Btn 'Compact Docker' 'compact'))
}

# Makes a profile from config.json the active one; the next report, Clean and daily scan follow it.
function Invoke-Profile($cfg, [string]$Name) {
    $Name = [string]$Name
    if (-not $Name -or $cfg.ProfileNames -notcontains $Name) {
        Show-Toast -Title $(if ($Name) { "No profile named '$Name'" } else { "Profile: $($cfg.ProfileName)" }) `
            -Lines @("Profiles in config.json: $($cfg.ProfileNames -join ', ')", 'Switch with Win+R: diskbuddy profile <name>')
        return
    }
    $raw = if (Test-Path $ConfigPath) { Get-Content $ConfigPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    if ($raw.PSObject.Properties['Profile']) { $raw.Profile = $Name } else { $raw | Add-Member -NotePropertyName Profile -NotePropertyValue $Name }
    $raw | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding UTF8
    $state = Get-State
    $state.Remove('LastDeepScan'); $state.Remove('CleanableGB'); $state.Remove('DigestLines')   # measure again under the new profile
    Save-State $state
    $new = Get-Config
    $groups = if ($new.Groups -is [string]) { 'everything' } else { $new.Groups -join ', ' }
    Write-Log "profile: $Name"
    Show-Toast -Title "Profile: $Name" -Lines @("Looks at: $groups", $(if ($new.Focus) { "Focus: $($new.Focus.Count) folder pattern(s)" } else { 'No focus folders' })) `
        -Buttons @((Btn 'Details' 'report'))
}

function Invoke-Snooze($cfg) {
    $state = Get-State
    $until = (Get-Date).AddHours([double]$cfg.SnoozeHours)
    $state.SnoozeUntil = ConvertTo-Stamp $until
    Save-State $state
    Write-Log "snoozed until $(ConvertTo-Stamp $until)"
    Show-Toast -Title 'Snoozed' -Lines @("No 'getting full' warnings until $($until.ToString('ddd HH:mm', $Inv)). Critical alerts still come through.")
}

function Invoke-Test($cfg) {
    Show-Toast -Title "Disk Buddy is watching $($cfg.Drive):" `
        -Lines @("Checks every 15 min. You'll hear from me below $($cfg.WarnFreeGB) GB free.", (Get-QuickHints $cfg)) `
        -Drive (Get-DriveInfo $cfg.Drive) -Buttons @((Btn 'Details' 'report')) -Sound alert
}

# One of each notification with made-up numbers. The buttons are real: pressing one runs that action.
function Invoke-Demo($cfg) {
    $full = [pscustomobject]@{ Letter = $cfg.Drive; FreeGB = 42; UsedGB = 423; TotalGB = 465 }
    $critical = [pscustomobject]@{ Letter = $cfg.Drive; FreeGB = 18; UsedGB = 447; TotalGB = 465 }
    $after = [pscustomobject]@{ Letter = $cfg.Drive; FreeGB = 48; UsedGB = 417; TotalGB = 465 }
    $examples = @(
        { Show-Toast -Title "Example: $($cfg.Drive): is getting full $Dash 42 GB left" -Drive $full -Sound alert `
            -Lines @("Biggest: Docker disk 35 GB$($Dot)Recycle Bin 8.1 GB$($Dot)Temp 5.8 GB", "Docker's disk has 30 GB of empty space it can give back.") `
            -Buttons @((Btn 'Clean' 'clean'), (Btn 'Compact Docker' 'compact'), (Btn 'Details' 'report'), (Btn 'Snooze 1 day' 'snooze')) }
        { Show-Toast -Title "Example: $($cfg.Drive): is almost full $Dash 18 GB left" -Drive $critical -Sound critical `
            -Lines @("Biggest: Docker disk 52 GB$($Dot)Recycle Bin 8.1 GB") `
            -Buttons @((Btn 'Clean' 'clean'), (Btn 'Compact Docker' 'compact'), (Btn 'Details' 'report')) }
        { Show-Toast -Title "Example: $($cfg.Drive): lost 12 GB in 15 min" -Drive $full -Sound alert `
            -Lines @("Docker's disk grew 11 GB $Dash a build or image pull is filling it.") `
            -Buttons @((Btn 'Details' 'report'), (Btn 'Snooze 1 day' 'snooze')) }
        { Show-Toast -Title "Example: Cleaned up 6.4 GB on $($cfg.Drive):" -Drive $after -Sound done `
            -Lines @("Docker 5.2 GB$($Dot)pnpm store pruned$($Dot)npm cache cleared$($Dot)Temp 1.2 GB", 'Docker keeps freed space inside its disk until you compact it.') `
            -Buttons @((Btn 'Compact Docker' 'compact'), (Btn 'Details' 'report')) }
    )
    foreach ($show in $examples) { & $show; Start-Sleep -Seconds 4 }
}

# Big archives (exported images, build tars, zips) anywhere under the profile, skipping dependency folders.
function Find-Archives([string]$Start, [int]$MinMB, [int]$MaxDepth = 6) {
    $skip = @('node_modules', '.git', '.venv', 'venv', '.next', '__pycache__', '.gradle', '.idea', 'AppData', 'Disk Buddy')
    $stack = New-Object System.Collections.Stack
    $stack.Push([pscustomobject]@{ Path = $Start; Depth = 0 })
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($cur.Path)) {
                if ($f -match '\.(tar|gz|tgz|zip|7z|rar|iso)$') {
                    $fi = New-Object IO.FileInfo $f
                    if ($fi.Length -ge $MinMB * 1MB) { $fi }
                }
            }
        } catch {}
        if ($cur.Depth -ge $MaxDepth) { continue }
        try {
            foreach ($d in [IO.Directory]::EnumerateDirectories($cur.Path)) {
                $name = [IO.Path]::GetFileName($d)
                if ($skip -contains $name -or $name -like 'OneDrive*') { continue }
                if ((New-Object IO.DirectoryInfo $d).Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push([pscustomobject]@{ Path = $d; Depth = $cur.Depth + 1 })
            }
        } catch {}
    }
}

function Row([string]$Name, [double]$GB, [string]$Hint) { [pscustomobject]@{ Name = $Name; GB = $GB; Hint = $Hint } }

function Get-ReportHtml($cfg) {
    $state = Get-State
    $drive = Get-DriveInfo $cfg.Drive
    $dockerUp = Test-DockerUp
    $usage = @(); $volumes = @()
    if ($dockerUp) { $usage = @(Get-DockerUsage); $volumes = @(Get-UnusedVolumes) }
    $slack = Get-DockerSlackGB $state
    $U = $env:USERPROFILE

    $cat = @(Get-SpaceCatalog $cfg $state)
    Save-State $state
    $cleanRows = @($cat | Where-Object { $_.Kind -eq 'clean' } | Sort-Object GB -Descending)
    $reviewRows = @($cat | Where-Object { $_.Kind -eq 'review' } | Sort-Object GB -Descending)
    $infoRows = @($cat | Where-Object { $_.Kind -eq 'info' } | Sort-Object GB -Descending)
    $cleanGB = [math]::Round(($cleanRows | Measure-Object CleanGB -Sum).Sum, 1)
    $big = @(Get-BigFolders $cfg 15)
    $focus = @(Get-FocusFolders $cfg)
    $archiveRoots = @($focus | Where-Object { -not $_.Missing } | ForEach-Object { $_.Path })
    if (-not $archiveRoots) { $archiveRoots = @($U) }
    $archives = @($archiveRoots | ForEach-Object { Find-Archives $_ ([int]$cfg.ArchiveMinMB) } | Sort-Object Length -Descending | Select-Object -First 40)

    $h = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $level = if ($drive.FreeGB -lt $cfg.CriticalFreeGB) { 'bad' } elseif ($drive.FreeGB -lt $cfg.WarnFreeGB) { 'warn' } else { 'ok' }
    $status = @{ ok = 'Healthy'; warn = 'Getting full'; bad = 'Almost full' }[$level]
    $pct = [math]::Round(100 * $drive.UsedGB / $drive.TotalGB)

    $table = {
        param($rows, [string]$Empty)
        if (-not $rows) { return "<p class='hint'>$(& $h $Empty)</p>" }
        $max = [math]::Max(1, ($rows | Measure-Object GB -Maximum).Maximum)
        $tr = ($rows | ForEach-Object {
            $w = [math]::Round(100 * $_.GB / $max)
            $path = if ($_.Path) { "<div class='hint path'>$(& $h $_.Path)</div>" } else { '' }
            "<tr><td>$(& $h $_.Name)<div class='mini'><span style='width:$w%'></span></div><div class='hint'>$(& $h $_.Hint)</div>$path</td><td class='num'>$(Format-GB $_.GB)</td></tr>"
        }) -join "`n"
        "<table>$tr</table>"
    }
    $cleanHtml = & $table $cleanRows 'No caches worth mentioning right now.'
    $reviewHtml = & $table $reviewRows 'Nothing stood out.'
    $infoHtml = & $table $infoRows ''

    $bigHtml = if ($big) {
        '<table><tr><th>Folder</th><th>Last changed</th><th class="num">Size</th></tr>' + (($big | ForEach-Object {
            $when = Get-Newest $_
            "<tr><td class='path'>$(& $h $_.Path)</td><td class='hint'>$(if ($when) { $when.ToString('yyyy-MM-dd', $Inv) })</td><td class='num'>$(Format-GB ($_.Bytes / 1GB))</td></tr>"
        }) -join '') + '</table>'
    } else { "<p class='hint'>Nothing over $($cfg.BigFolderMinGB) GB.</p>" }

    $focusHtml = if ($focus) {
        '<table>' + (($focus | ForEach-Object {
            if ($_.Missing) { "<tr><td class='path'>$(& $h $_.Path)</td><td class='hint'>not found</td><td class='num'></td></tr>"; return }
            $when = if ($_.Newest) { $_.Newest.ToString('yyyy-MM-dd', $Inv) } else { '' }
            $row = "<tr><td class='path'><b>$(& $h $_.Path)</b></td><td class='hint'>$when</td><td class='num'>$(Format-GB $_.GB)</td></tr>"
            $row + (($_.Kids | ForEach-Object {
                $kw = Get-Newest $_
                "<tr><td class='path sub'>$(& $h (Split-Path $_.Path -Leaf))</td><td class='hint'>$(if ($kw) { $kw.ToString('yyyy-MM-dd', $Inv) })</td><td class='num'>$(Format-GB ($_.Bytes / 1GB))</td></tr>"
            }) -join '')
        }) -join '') + '</table>'
    } else { "<p class='hint'>This profile has no focus folders. Add patterns under Profiles &gt; $(& $h $cfg.ProfileName) &gt; Focus in config.json, e.g. &quot;%USERPROFILE%\\projects\\*&quot;.</p>" }
    $others = @($cfg.ProfileNames | Where-Object { $_ -ne $cfg.ProfileName })
    $profileHtml = "Profile: <b>$(& $h $cfg.ProfileName)</b>" + $(if ($others) { ' &middot; switch to ' + (($others | ForEach-Object { "<button class='btn small' onclick=`"profile('$(& $h $_)')`">$(& $h $_)</button>" }) -join ' ') } else { '' })

    $anon = @($volumes | Where-Object Anonymous | Sort-Object SizeGB -Descending)
    if ($dockerUp) {
        $dockerRows = ($usage | ForEach-Object { "<tr><td>$(& $h $_.Type)</td><td class='num'>$(Format-GB $_.SizeGB)</td><td class='num'>$(Format-GB $_.ReclaimableGB)</td></tr>" }) -join ''
        $volRows = ($volumes | Sort-Object SizeGB -Descending | ForEach-Object {
            $kind = if ($_.Anonymous) { 'leftover (unnamed)' } else { 'named - may hold data' }
            "<tr><td class='path'>$(& $h $_.Name)</td><td class='hint'>$kind</td><td class='num'>$(Format-GB $_.SizeGB)</td></tr>"
        }) -join ''
        $dockerHtml = "<table><tr><th>Type</th><th class='num'>Size</th><th class='num'>Reclaimable</th></tr>$dockerRows</table>"
        if ($volumes) { $dockerHtml += "<h3>Volumes no container uses</h3><table>$volRows</table>" }
    } else {
        $dockerHtml = "<p class='hint'>Docker isn't running (or isn't responding), so its contents can't be inspected. Start Docker Desktop and reopen this report.</p>"
    }

    $archiveHtml = if ($archives) {
        '<table><tr><th>File</th><th>Modified</th><th class="num">Size</th></tr>' + (($archives | ForEach-Object {
            "<tr><td class='path'>$(& $h $_.FullName)</td><td class='hint'>$($_.LastWriteTime.ToString('yyyy-MM-dd', $Inv))</td><td class='num'>$(Format-GB ($_.Length / 1GB))</td></tr>"
        }) -join '') + '</table>'
    } else { "<p class='hint'>No archives over $($cfg.ArchiveMinMB) MB found.</p>" }

    # Nothing runs until you press a button; each press goes to the local report server (Start-ReportServer).
    $compactNote = if ($slack -ge 1) { "Docker's disk has about $(Format-GB $slack) of empty space. " } else { '' }
    $actions = @()   # (action, label, description) triples; the leading comma keeps them from flattening
    $actions += , @('clean', 'Clean', "Removes the caches listed above (about $(Format-GB $cleanGB)): Docker images and build cache older than $($cfg.DockerPruneOlderThanHours / 24) days, pnpm/npm/pip caches, Temp files older than $($cfg.TempOlderThanDays) days, GPU shader caches, crash dumps, unpacked driver installers, browser caches while the browser is closed, and old Playwright browser versions. Never project files, named Docker volumes, the Recycle Bin, or anything under 'Worth a look'.")
    $actions += , @('compact', 'Compact', "${compactNote}Shrinks Docker's disk file so freed space returns to $($drive.Letter):. Windows asks for admin; Docker stops for a few minutes.")
    if ($anon) { $actions += , @('volumes', 'Remove', "Removes $($anon.Count) leftover unnamed Docker volumes ($(Format-GB (($anon | Measure-Object SizeGB -Sum).Sum))). Shows the list and asks first.") }
    $actions += , @('snooze', 'Snooze', "Silences 'getting full' warnings for $($cfg.SnoozeHours) hours.")
    $actionHtml = ($actions | ForEach-Object {
        "<tr><td>$(& $h $_[2])<div class='status' id='st-$($_[0])'></div><div class='hint'>or Win+R: <code>diskbuddy $($_[0])</code></div></td><td class='num'><button class='btn primary' data-label='$($_[1])' onclick=`"run(this,'$($_[0])')`">$($_[1])</button></td></tr>"
    }) -join "`n"

    $logTail = if (Test-Path $LogPath) { (Get-Content $LogPath -Tail 15 -Encoding UTF8) -join "`n" } else { '' }
    $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm', $Inv)

    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Disk Buddy</title>
<style>
:root{--bg:#f6f6f3;--card:#fff;--text:#1d1d1b;--muted:#6b6b66;--line:#e6e5e0;--accent:#2f6fde;--ok:#2e8b57;--warn:#c98a00;--bad:#d1453b;--track:#ecebe6}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--card:#1f1f1d;--text:#ecebe6;--muted:#9b9a94;--line:#2e2e2b;--accent:#6c9cff;--ok:#4cbf7f;--warn:#e0a82e;--bad:#ef6a5f;--track:#2b2b28}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:880px;margin:0 auto;padding:32px 16px 64px}
h1{font-size:22px;margin:0}
h2{font-size:16px;margin:0 0 12px}
h3{font-size:14px;margin:20px 0 8px;color:var(--muted);font-weight:600}
.sub{color:var(--muted);margin:2px 0 24px;font-size:13px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:20px;margin-bottom:16px;overflow-x:auto}
.big{font-size:30px;font-weight:600;font-variant-numeric:tabular-nums}
.pill{display:inline-block;padding:2px 10px;border-radius:999px;font-size:13px;font-weight:600;color:#fff;background:var(--$level);vertical-align:middle;margin-left:8px}
.bar{height:14px;background:var(--track);border-radius:7px;overflow:hidden;margin:12px 0 6px}
.bar>span{display:block;height:100%;width:$pct%;background:var(--$level)}
.mini{height:4px;background:var(--track);border-radius:2px;margin:6px 0 2px;max-width:320px}
.mini>span{display:block;height:100%;background:var(--accent);border-radius:2px}
.btn{display:inline-block;min-width:96px;padding:8px 14px;border-radius:8px;border:1px solid var(--line);background:transparent;color:var(--text);font:600 14px "Segoe UI",system-ui,sans-serif;cursor:pointer}
.btn:hover{border-color:var(--accent)}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.btn:disabled{opacity:.6;cursor:default}
.btn.small{min-width:0;padding:2px 10px;font-size:12px;vertical-align:baseline}
.sub{padding-left:24px;color:var(--muted)}
.head{display:flex;justify-content:space-between;align-items:baseline;gap:12px;flex-wrap:wrap}
.status{font-size:13px;font-weight:600;color:var(--accent);margin-top:4px}
.status:empty{display:none}
code{font:12px Consolas,monospace}
table{width:100%;border-collapse:collapse}
td,th{padding:8px 6px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
tr:last-child td{border-bottom:0}
th{color:var(--muted);font-weight:500;font-size:13px}
.num{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}
.hint{color:var(--muted);font-size:13px}
.path{word-break:break-all;font-family:Consolas,monospace;font-size:13px}
pre{white-space:pre-wrap;font:12px/1.6 Consolas,monospace;color:var(--muted);margin:0}
</style></head><body><main>
<div class="head"><h1>Disk Buddy</h1><button class="btn" id="refresh" onclick="location.search='?fresh=1'">Refresh numbers</button></div>
<p class="sub">Report generated $generated &middot; $profileHtml<span class="status" id="st-profile"></span></p>

<section class="card">
  <div><span class="big">$(Format-GB $drive.FreeGB) free</span><span class="pill">$status</span></div>
  <div class="bar"><span></span></div>
  <div class="hint">$($drive.Letter): $('{0:N0}' -f $drive.UsedGB) of $('{0:N0}' -f $drive.TotalGB) GB used ($pct%) &middot; warns below $($cfg.WarnFreeGB) GB, critical below $($cfg.CriticalFreeGB) GB</div>
</section>

<section class="card"><h2>Caches Clean can remove &middot; $(Format-GB $cleanGB)</h2><p class="hint" style="margin-top:-6px">Rebuilt automatically when something needs them again.</p>$cleanHtml</section>

<section class="card"><h2>Worth a look</h2><p class="hint" style="margin-top:-6px">Your data and tools. Disk Buddy never touches these; each row says how to deal with it yourself.</p>$reviewHtml</section>

<section class="card"><h2>Other big items</h2>$infoHtml</section>

<section class="card"><h2>Free up space</h2><p class="hint" style="margin-top:-6px">Nothing runs until you press a button. You'll also get a notification when it's done.</p><table>$actionHtml</table></section>

<section class="card"><h2>Docker</h2>$dockerHtml</section>

<section class="card"><h2>Focus folders &middot; profile $(& $h $cfg.ProfileName)</h2><p class="hint" style="margin-top:-6px">The folders this profile keeps an eye on, each with its five biggest subfolders. Nothing here is ever cleaned automatically.</p>$focusHtml</section>

<section class="card"><h2>Biggest folders on $($drive.Letter):</h2><p class="hint" style="margin-top:-6px">Folders over $($cfg.BigFolderMinGB) GB, shown at the level that explains the size. Dependency folders (node_modules, .git) are counted but not opened up.</p>$bigHtml</section>

<section class="card"><h2>Large archives in your folders</h2><p class="hint" style="margin-top:-6px">Exported images and build tars you can usually rebuild. Review and delete by hand.</p>$archiveHtml</section>

<section class="card"><h2>Recent activity</h2><pre>$(& $h $logTail)</pre>
<p class="hint" style="margin:12px 0 0">Settings: $(& $h $ConfigPath)</p></section>
</main>
<script>
var BASE = location.pathname;   // "/<token>/" - the server only answers under this secret path
var NOTE = { compact: 'Approve the admin prompt; a window shows progress.', volumes: 'A confirmation box lists the volumes first.' };
function setStatus(action, text) { document.getElementById('st-' + action).textContent = text; }
function run(btn, action) {
  if (location.protocol === 'file:') { setStatus(action, 'Buttons need the live report: press Win+R and type diskbuddy.'); return; }
  btn.disabled = true; btn.textContent = 'Running...';
  setStatus(action, NOTE[action] || 'Working on it...');
  fetch(BASE + 'run/' + action, { method: 'POST' })
    .then(function (r) { if (!r.ok) { throw new Error(r.status); } poll(btn, action); })
    .catch(function () {
      btn.disabled = false; btn.textContent = btn.getAttribute('data-label');
      setStatus(action, 'Could not reach Disk Buddy (it stops after 15 idle minutes). Press Win+R, type diskbuddy, and try again.');
    });
}
function profile(name) {
  var st = document.getElementById('st-profile');
  if (location.protocol === 'file:') { st.textContent = ' Switching needs the live report: press Win+R and type diskbuddy.'; return; }
  st.textContent = ' Switching to ' + name + '...';
  fetch(BASE + 'profile/' + encodeURIComponent(name), { method: 'POST' })
    .then(function (r) { if (!r.ok) { throw new Error(r.status); } setTimeout(function () { location.search = '?fresh=1'; }, 2500); })
    .catch(function () { st.textContent = ' Could not reach Disk Buddy. Press Win+R, type diskbuddy, and try again.'; });
}
function poll(btn, action) {
  setTimeout(function () {
    fetch(BASE + 'status').then(function (r) { return r.json(); }).then(function (s) {
      if (s[action] === 'running') { poll(btn, action); return; }
      btn.textContent = 'Done';
      setStatus(action, 'Finished. Press Refresh numbers to see the new sizes.');
      document.getElementById('refresh').classList.add('primary');
    }).catch(function () { poll(btn, action); });
  }, 2000);
}
</script>
</body></html>
"@
    $html
}

function Send-Response($Response, [string]$Body, [string]$Type = 'text/html; charset=utf-8', [int]$Status = 200) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode = $Status
    $Response.ContentType = $Type
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

# Runs this script again as a hidden process, so the server stays responsive and can report "running"/"done".
function Start-Hidden([string]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $Arguments"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [System.Diagnostics.Process]::Start($psi)
}

function Start-Action([string]$Action) { Start-Hidden "-Uri `"diskbuddy:$Action`"" }

function Write-Report([string]$Path) {
    $html = Get-ReportHtml $cfg
    [IO.File]::WriteAllText("$Path.tmp", $html, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force   # appears only once complete
    [IO.File]::WriteAllText($ReportPath, $html, (New-Object Text.UTF8Encoding $false))   # static copy for reference
}

# Shown instantly while the real report is measured in the background; swaps itself out when ready.
function Get-LoadingHtml {
    @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Disk Buddy</title>
<style>
:root{--bg:#f6f6f3;--text:#1d1d1b;--muted:#6b6b66;--track:#ecebe6;--accent:#2f6fde}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--text:#ecebe6;--muted:#9b9a94;--track:#2b2b28;--accent:#6c9cff}}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:var(--bg);color:var(--text);font:15px/1.5 "Segoe UI",system-ui,sans-serif}
.box{text-align:center;padding:16px}
.spin{width:36px;height:36px;margin:0 auto 16px;border-radius:50%;border:4px solid var(--track);border-top-color:var(--accent);animation:r 0.9s linear infinite}
@keyframes r{to{transform:rotate(360deg)}}
h1{font-size:20px;margin:0 0 4px}
p{color:var(--muted);margin:0}
</style></head><body><div class="box">
<div class="spin" id="spin"></div><h1 id="title">Measuring your disk...</h1><p id="msg">Usually under a minute: every folder on the drive is measured. This page fills in by itself.</p>
</div>
<script>
var BASE = location.pathname;
function check() {
  fetch(BASE + 'ready').then(function (r) { return r.json(); }).then(function (s) {
    if (s.ready) { location.replace(BASE); return; }
    if (s.failed) {
      document.getElementById('spin').style.display = 'none';
      document.getElementById('title').textContent = 'Could not measure the disk';
      document.getElementById('msg').textContent = 'Check diskbuddy.log in the Disk Buddy folder, then press Win+R and type diskbuddy to try again.';
      return;
    }
    setTimeout(check, 1000);
  }).catch(function () { setTimeout(check, 2000); });
}
check();
</script>
</body></html>
'@
}

# Serves the report on localhost so its buttons can run actions (browsers block custom links from local files).
# Only answers under a random per-run path and refuses cross-site requests; exits after 15 idle minutes.
# The page opens immediately; measuring runs as a separate hidden process (Build mode).
function Start-ReportServer($cfg) {
    $probe = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()
    $token = [guid]::NewGuid().ToString('N')
    $origin = "http://localhost:$port"
    $htmlPath = Join-Path $env:TEMP "diskbuddy-report-$token.html"
    $build = Start-Hidden "-Mode Build -Out `"$htmlPath`""
    Start-Process "$origin/$token/"
    Write-Log "report opened at $origin/$token/"

    $running = @{}
    $lastSeen = Get-Date
    while ($listener.IsListening) {
        $next = $listener.GetContextAsync()
        while (-not $next.Wait(1000)) {
            $busy = @($running.Values | Where-Object { -not $_.HasExited }).Count + [int](-not $build.HasExited)
            if (-not $busy -and ((Get-Date) - $lastSeen).TotalMinutes -ge 15) {
                $listener.Stop()
                Remove-Item -LiteralPath $htmlPath -ErrorAction SilentlyContinue
                Write-Log 'report server stopped (idle)'
                return
            }
        }
        $lastSeen = Get-Date
        $ctx = $next.Result
        $req = $ctx.Request
        try {
            $path = $req.Url.AbsolutePath
            $sentOrigin = $req.Headers['Origin']
            if (-not $path.StartsWith("/$token/") -or ($sentOrigin -and $sentOrigin -ne $origin)) {
                Send-Response $ctx.Response 'Not found' 'text/plain' 404
                continue
            }
            $route = $path.Substring($token.Length + 2)
            if ($route -eq '' -and $req.HttpMethod -eq 'GET') {
                if ($req.QueryString['fresh'] -and $build.HasExited) {
                    Remove-Item -LiteralPath $htmlPath -ErrorAction SilentlyContinue
                    $build = Start-Hidden "-Mode Build -Out `"$htmlPath`""
                }
                $page = if ($build.HasExited -and (Test-Path -LiteralPath $htmlPath)) { [IO.File]::ReadAllText($htmlPath) } else { Get-LoadingHtml }
                Send-Response $ctx.Response $page
            } elseif ($route -eq 'ready') {
                $done = $build.HasExited
                $have = Test-Path -LiteralPath $htmlPath
                Send-Response $ctx.Response ('{{"ready":{0},"failed":{1}}}' -f "$($done -and $have)".ToLower(), "$($done -and -not $have)".ToLower()) 'application/json'
            } elseif ($route -match '^run/(clean|compact|volumes|snooze)$' -and $req.HttpMethod -eq 'POST') {
                $action = $Matches[1]
                if (-not $running[$action] -or $running[$action].HasExited) {
                    $running[$action] = Start-Action $action
                    Write-Log "report button: $action"
                }
                Send-Response $ctx.Response '{"ok":true}' 'application/json'
            } elseif ($route -match '^profile/([A-Za-z0-9_.-]+)$' -and $req.HttpMethod -eq 'POST') {
                $p = Start-Action "profile/$($Matches[1])"
                try { $p.WaitForExit(15000) | Out-Null } catch {}   # so the refresh that follows already sees the new profile
                Write-Log "report button: profile $($Matches[1])"
                Send-Response $ctx.Response '{"ok":true}' 'application/json'
            } elseif ($route -eq 'status') {
                $pairs = $running.Keys | ForEach-Object { '"{0}":"{1}"' -f $_, $(if ($running[$_].HasExited) { 'done' } else { 'running' }) }
                Send-Response $ctx.Response ('{' + ($pairs -join ',') + '}') 'application/json'
            } else {
                Send-Response $ctx.Response 'Not found' 'text/plain' 404
            }
        } catch {
            Write-Log "report server: $_"
        } finally {
            $ctx.Response.Close()
        }
    }
}

function Invoke-Report($cfg) {
    try {
        Start-ReportServer $cfg
    } catch {
        Write-Log "report server failed, opening static copy: $_"
        $html = Get-ReportHtml $cfg
        [IO.File]::WriteAllText($ReportPath, $html, (New-Object Text.UTF8Encoding $false))
        Start-Process $ReportPath
    }
}

#endregion

$cfg = Get-Config
try {
    switch ($Mode) {
        'Check' { Invoke-Check $cfg }
        'Clean' {
            Show-Toast -Title 'Cleaning up...' -Lines @('Old Docker images and build cache, package and browser caches, shader caches, old Temp files...') -Tag 'working'
            $result = Invoke-Clean $cfg
            Remove-Toast 'working'
            Show-CleanResult $cfg $result (Get-DriveInfo $cfg.Drive)
        }
        'Report' { Invoke-Report $cfg }
        'Build' { Write-Report $Out }
        'Compact' { Invoke-Compact $cfg }
        'Volumes' { Remove-UnusedVolumes $cfg }
        'Snooze' { Invoke-Snooze $cfg }
        'Profile' { Invoke-Profile $cfg $ProfileArg }
        'Test' { Invoke-Test $cfg }
        'Demo' { Invoke-Demo $cfg }
    }
} catch {
    Write-Log "error: $_ | $($_.ScriptStackTrace -replace "`r?`n", ' <- ')"
}
