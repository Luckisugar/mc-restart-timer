#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root "profiles.json"
$StatePath = Join-Path $Root "state.json"
$LogPath = Join-Path $Root "timer.log"

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [Console]::OutputEncoding
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class McWin {
    public class Item {
        public IntPtr Hwnd;
        public string Title;
        public string ClassName;
        public uint Pid;
        public string ProcessName;
    }

    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool FlashWindow(IntPtr hWnd, bool bInvert);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    public static string TitleOf(IntPtr hWnd) {
        var sb = new StringBuilder(512);
        GetWindowText(hWnd, sb, 512);
        return sb.ToString();
    }

    public static List<Item> GetWindows() {
        var list = new List<Item>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            var title = new StringBuilder(512);
            GetWindowText(h, title, 512);
            if (title.Length == 0) return true;
            var cls = new StringBuilder(256);
            GetClassName(h, cls, 256);
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            string pname = "";
            try { pname = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch {}
            list.Add(new Item {
                Hwnd = h,
                Title = title.ToString(),
                ClassName = cls.ToString(),
                Pid = pid,
                ProcessName = pname
            });
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static bool FocusWindow(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) return false;
        IntPtr fore = GetForegroundWindow();
        uint foreThread = 0;
        if (fore != IntPtr.Zero) {
            uint dummy;
            foreThread = GetWindowThreadProcessId(fore, out dummy);
        }
        uint appThread = GetCurrentThreadId();
        if (foreThread != 0 && foreThread != appThread) {
            AttachThreadInput(appThread, foreThread, true);
        }
        keybd_event(0x12, 0, 0, UIntPtr.Zero); // ALT down, unlock foreground
        ShowWindow(hwnd, 9); // SW_RESTORE
        BringWindowToTop(hwnd);
        bool ok = SetForegroundWindow(hwnd);
        keybd_event(0x12, 0, 2, UIntPtr.Zero); // ALT up
        if (foreThread != 0 && foreThread != appThread) {
            AttachThreadInput(appThread, foreThread, false);
        }
        return ok || GetForegroundWindow() == hwnd;
    }
}
"@

$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:FiredWarnings = @{}
$script:SkippedTargets = New-Object System.Collections.Generic.List[datetime]
$script:Paused = $false
$script:Busy = $false
$script:ForcedTarget = $null
$script:LastStatus = "No window"
$script:Connected = $false
$script:JavaAlive = $false
$script:LastJavaCheck = [datetime]::MinValue
$script:Quit = $false
$script:SwitchProfile = $false
$script:PickWindow = $false
$script:CurrentTarget = $null
$script:TargetHwnd = [IntPtr]::Zero
$script:TargetPid = 0
$script:TargetTitle = ""
$script:SavedFocus = [IntPtr]::Zero
$script:CompletedTargets = New-Object System.Collections.Generic.List[datetime]
$script:LastHeartbeat = [datetime]::MinValue
$script:LastTestAt = [datetime]::MinValue
$script:Config = $null
$script:CurrentProfile = $null
$script:DefaultMessages = @{
    test       = "say [Restart] ping from timer. If you see this, typing works."
    warn15     = "say Restart in 15 min ({time})."
    warn5      = "say Restart in 5 min ({time})."
    warn1      = "say Restart in 1 min ({time})."
    warn10s    = "say Restart in 10 seconds."
    restartNow = "say Restarting now. Back in a few minutes."
    online     = "say Server is online."
}

function Write-Log([string]$Message) {
    $line = "{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $script:LogLines.Add($line)
    while ($script:LogLines.Count -gt 8) { $script:LogLines.RemoveAt(0) }
    Add-Content -Path $LogPath -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -Encoding UTF8
}

function Load-Config {
    if (-not (Test-Path $ConfigPath)) {
        throw "Missing profiles.json next to the timer."
    }
    Get-Content -Raw -Path $ConfigPath -Encoding UTF8 | ConvertFrom-Json
}

function Get-EnabledProfiles($Config) {
    @($Config.profiles | Where-Object { $_.enabled -eq $true })
}

function Select-Profile($Config) {
    $enabled = Get-EnabledProfiles $Config
    if ($enabled.Count -eq 0) { throw "No enabled profiles in profiles.json." }

    $default = $enabled | Where-Object { $_.id -eq $Config.activeProfile } | Select-Object -First 1
    if (-not $default) { $default = $enabled[0] }

    if ($enabled.Count -eq 1) { return $default }

    Clear-Host
    Write-Host ""
    Write-Host "  MC RESTART TIMER" -ForegroundColor Yellow
    Write-Host "  Pick a server. Enter = $($default.name)" -ForegroundColor DarkGray
    Write-Host ""
    for ($i = 0; $i -lt $enabled.Count; $i++) {
        $mark = if ($enabled[$i].id -eq $default.id) { "*" } else { " " }
        Write-Host ("    [{0}] {1}  {2}" -f ($i + 1), $enabled[$i].name, $mark)
    }
    Write-Host ""
    while ($true) {
        Write-Host "  > " -NoNewline
        $key = [Console]::ReadKey($true)
        Write-Host ""
        if ($key.Key -eq "Enter") { return $default }
        $n = 0
        if ([int]::TryParse($key.KeyChar.ToString(), [ref]$n) -and $n -ge 1 -and $n -le $enabled.Count) {
            return $enabled[$n - 1]
        }
        Write-Host "  That is not a pack number. Use 1-$($enabled.Count) or Enter." -ForegroundColor Yellow
        Write-Host ""
    }
}

function Get-TitleNeedles($Profile) {
    $needles = New-Object System.Collections.Generic.List[string]
    $needles.Add([string]$Profile.name)
    foreach ($n in @($Profile.windowTitleContains)) {
        if ($n) { $needles.Add([string]$n) }
    }
    if ($Profile.workingDirectory) {
        $needles.Add([IO.Path]::GetFileName($Profile.workingDirectory.TrimEnd("\")))
    }
    @($needles | Where-Object { $_ } | Select-Object -Unique)
}

function Test-TitleMatch([string]$Title, $Needles) {
    $t = $Title.ToLowerInvariant()
    foreach ($n in @($Needles)) {
        if ($t.Contains(([string]$n).ToLowerInvariant())) { return $true }
    }
    $false
}

function Get-ProcessTree {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $children = @{}
    foreach ($p in $all) {
        $pp = [int]$p.ParentProcessId
        if (-not $children.ContainsKey($pp)) {
            $children[$pp] = New-Object System.Collections.Generic.List[object]
        }
        $children[$pp].Add($p)
    }
    @{ All = $all; Children = $children }
}

function Get-Descendants($Tree, [int]$ProcessId) {
    $out = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($ProcessId)
    $seen = @{}
    while ($queue.Count -gt 0) {
        $id = $queue.Dequeue()
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        if ($Tree.Children.ContainsKey($id)) {
            foreach ($c in $Tree.Children[$id]) {
                $out.Add($c)
                $queue.Enqueue([int]$c.ProcessId)
            }
        }
    }
    $out
}

function Get-JavaTag($Tree, [int]$ProcId, $Needles) {
    foreach ($c in (Get-Descendants $Tree $ProcId)) {
        $name = [string]$c.Name
        if ($name -ne "java.exe" -and $name -ne "javaw.exe") { continue }
        $cmd = [string]$c.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { return "java" }
        foreach ($n in @($Needles)) {
            if ($cmd.ToLowerInvariant().Contains(([string]$n).ToLowerInvariant())) {
                return "JAVA  $($n)"
            }
        }
        if ($cmd -match '\\([^\\]+)\\(?:run\.bat|start\.bat|server\.jar|user_jvm_args)') {
            return "JAVA  $($Matches[1])"
        }
        return "java"
    }
    $null
}

function Get-CandidateWindows($Profile) {
    $needles = Get-TitleNeedles $Profile
    $tree = Get-ProcessTree
    $all = [McWin]::GetWindows() | Where-Object {
        $_.Title -notmatch "MC Restart Timer" -and $_.Title -notmatch "START TIMER"
    }
    $ranked = foreach ($w in $all) {
        $console = $false
        $cls = $w.ClassName
        if ($cls -eq "ConsoleWindowClass" -or $cls -eq "CASCADIA_HOSTING_WINDOW_CLASS" -or $cls -like "*Console*") {
            $console = $true
        }
        $proc = $w.ProcessName.ToLowerInvariant()
        if ($proc -in @("cmd", "powershell", "pwsh", "windowsterminal", "conhost", "java")) {
            $console = $true
        }
        $javaTag = Get-JavaTag $tree ([int]$w.Pid) $needles
        $titleMatch = Test-TitleMatch $w.Title $needles
        $javaMatch = $false
        if ($javaTag -and $javaTag.StartsWith("JAVA")) { $javaMatch = $true }
        $score = 0
        if ($javaMatch) { $score += 200 }
        if ($titleMatch) { $score += 50 }
        if ($console) { $score += 10 }
        [pscustomobject]@{
            Hwnd        = $w.Hwnd
            Title       = $w.Title
            ClassName   = $w.ClassName
            Pid         = $w.Pid
            ProcessName = $w.ProcessName
            Match       = ($javaMatch -or ($titleMatch -and $console))
            Console     = $console
            JavaTag     = $javaTag
            Score       = $score
        }
    }
    @($ranked | Sort-Object -Property @{Expression = "Score"; Descending = $true }, @{Expression = "Title"; Descending = $false })
}

function Get-WindowItemFromHwnd([IntPtr]$Hwnd, $Profile) {
    foreach ($w in (Get-CandidateWindows $Profile)) {
        if ($w.Hwnd -eq $Hwnd) { return $w }
    }
    $title = [McWin]::TitleOf($Hwnd)
    [pscustomobject]@{
        Hwnd        = $Hwnd
        Title       = $title
        ClassName   = ""
        Pid         = 0
        ProcessName = ""
        Match       = $false
        Console     = $true
        JavaTag     = $null
        Score       = 0
    }
}

function Show-WindowPreview($Item) {
    if ($null -eq $Item) { return }
    $here = [McWin]::GetForegroundWindow()
    for ($i = 0; $i -lt 6; $i++) {
        [void][McWin]::FlashWindow($Item.Hwnd, $true)
        Start-Sleep -Milliseconds 120
    }
    [void][McWin]::FocusWindow($Item.Hwnd)
    Start-Sleep -Milliseconds 450
    [void][McWin]::FocusWindow($here)
}

function Wait-ClickWindow($Profile) {
    $original = [McWin]::GetForegroundWindow()
    $mine = [McWin]::GetConsoleWindow()
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq "Escape") { return $null }
        }
        $fg = [McWin]::GetForegroundWindow()
        if ($fg -ne [IntPtr]::Zero -and $fg -ne $original -and $fg -ne $mine -and [McWin]::IsWindow($fg)) {
            Start-Sleep -Milliseconds 250
            if ([McWin]::GetForegroundWindow() -eq $fg) {
                $item = Get-WindowItemFromHwnd $fg $Profile
                [void][McWin]::FocusWindow($original)
                return $item
            }
        }
        Start-Sleep -Milliseconds 80
    }
    $null
}

function Select-ServerWindow($Profile) {
    $restored = Restore-BindState $Profile
    if ($restored) { return $restored }

    $highlighted = 0
    while ($true) {
        $candidates = Get-CandidateWindows $Profile
        $show = @($candidates | Select-Object -First 12)
        if ($highlighted -ge $show.Count) { $highlighted = 0 }

        Clear-Host
        Write-Host ""
        Write-Host "  WINDOW PICKER" -ForegroundColor Yellow
        Write-Host "  Pack: $($Profile.name)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Click the Minecraft server console now.  (30s)"
        Write-Host "  Or use the list: number to highlight, Enter to bind, Esc to skip."
        Write-Host ""
        if ($show.Count -eq 0) {
            Write-Host "  No windows found." -ForegroundColor Red
        }
        for ($i = 0; $i -lt $show.Count; $i++) {
            $mark = " "
            if ($i -eq $highlighted) { $mark = ">" }
            $tag = ""
            if ($show[$i].JavaTag) { $tag = "  [" + $show[$i].JavaTag + "]" }
            $title = $show[$i].Title
            if ($title.Length -gt 42) { $title = $title.Substring(0, 42) + "..." }
            $line = ("  {0}[{1}] {2,-16} {3}{4}" -f $mark, ($i + 1), $show[$i].ProcessName, $title, $tag)
            if ($i -eq $highlighted) {
                Write-Host $line -ForegroundColor Yellow
            } elseif ($show[$i].JavaTag) {
                Write-Host $line -ForegroundColor Green
            } else {
                Write-Host $line
            }
        }
        Write-Host ""
        Write-Host "  [1-9] highlight   [P] preview flash   [Enter] bind   [Esc] skip"

        $original = [McWin]::GetForegroundWindow()
        $mine = [McWin]::GetConsoleWindow()
        $sliceDeadline = (Get-Date).AddSeconds(1.5)
        $picked = $null
        while ((Get-Date) -lt $sliceDeadline -and $null -eq $picked) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    "Escape" { return $null }
                    "Enter" {
                        if ($show.Count -gt 0) { return $show[$highlighted] }
                    }
                    "P" {
                        if ($show.Count -gt 0) { Show-WindowPreview $show[$highlighted] }
                    }
                    "UpArrow" {
                        if ($show.Count -gt 0) {
                            $highlighted = ($highlighted + $show.Count - 1) % $show.Count
                            break
                        }
                    }
                    "DownArrow" {
                        if ($show.Count -gt 0) {
                            $highlighted = ($highlighted + 1) % $show.Count
                            break
                        }
                    }
                    default {
                        $n = 0
                        if ([int]::TryParse($key.KeyChar.ToString(), [ref]$n) -and $n -ge 1 -and $n -le $show.Count) {
                            $highlighted = $n - 1
                            Show-WindowPreview $show[$highlighted]
                        }
                    }
                }
                break
            }
            $fg = [McWin]::GetForegroundWindow()
            if ($fg -ne [IntPtr]::Zero -and $fg -ne $original -and $fg -ne $mine -and [McWin]::IsWindow($fg)) {
                Start-Sleep -Milliseconds 200
                if ([McWin]::GetForegroundWindow() -eq $fg) {
                    $picked = Get-WindowItemFromHwnd $fg $Profile
                    [void][McWin]::FocusWindow($original)
                }
            }
            Start-Sleep -Milliseconds 80
        }
        if ($picked) {
            Write-Log ("Picked by click: " + $picked.Title)
            return $picked
        }
    }
}

function Get-JsonProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    $null
}

function Save-BindState($Profile) {
    if ($null -eq $Profile) { return }
    $obj = [ordered]@{
        profileId = [string]$Profile.id
        hwnd      = $script:TargetHwnd.ToInt64()
        pid       = [int]$script:TargetPid
        title     = [string]$script:TargetTitle
        savedAt   = (Get-Date).ToString("o")
    }
    ($obj | ConvertTo-Json) | Set-Content -Path $StatePath -Encoding UTF8
}

function Restore-BindState($Profile) {
    if (-not (Test-Path $StatePath)) { return $null }
    try {
        $s = Get-Content -Raw -Path $StatePath -Encoding UTF8 | ConvertFrom-Json
    } catch { return $null }
    if ([string]$s.profileId -ne [string]$Profile.id) { return $null }

    $fromJava = Find-WindowForServer $Profile
    if ($fromJava) {
        Write-Log ("Restored window via Java: " + $fromJava.Title)
        return $fromJava
    }

    $hwndVal = [int64]$s.hwnd
    if ($hwndVal -ne 0) {
        $hwnd = [IntPtr]$hwndVal
        if ([McWin]::IsWindow($hwnd)) {
            $title = [McWin]::TitleOf($hwnd)
            if ($title -and $title -notmatch "MC Restart Timer") {
                Write-Log ("Restored saved window: " + $title)
                return (Get-WindowItemFromHwnd $hwnd $Profile)
            }
        }
    }
    if ($s.title) {
        foreach ($w in [McWin]::GetWindows()) {
            if ($w.Title -eq [string]$s.title -and $w.Title -notmatch "MC Restart Timer") {
                Write-Log ("Restored window by title: " + $w.Title)
                return $w
            }
        }
    }
    $null
}

function Bind-Window($Item) {
    if ($null -eq $Item) {
        $script:TargetHwnd = [IntPtr]::Zero
        $script:TargetTitle = ""
        $script:TargetPid = 0
        $script:Connected = $false
        return
    }
    $script:TargetHwnd = [IntPtr]$Item.Hwnd
    $script:TargetTitle = [string]$Item.Title
    $script:TargetPid = 0
    if ($Item.PSObject.Properties["Pid"] -and $Item.Pid) {
        $script:TargetPid = [int]$Item.Pid
    }
    $script:Connected = [McWin]::IsWindow($script:TargetHwnd)
    Write-Log ("Target window: " + $script:TargetTitle)
    if ($script:CurrentProfile) { Save-BindState $script:CurrentProfile }
}

function Refresh-WindowTitle {
    if ($script:TargetHwnd -eq [IntPtr]::Zero -or -not [McWin]::IsWindow($script:TargetHwnd)) {
        $script:Connected = $false
        return
    }
    $script:Connected = $true
    foreach ($w in [McWin]::GetWindows()) {
        if ($w.Hwnd -eq $script:TargetHwnd) {
            $script:TargetTitle = $w.Title
            $script:TargetPid = [int]$w.Pid
            break
        }
    }
}

function Find-WindowByProfile($Profile) {
    $hits = @((Get-CandidateWindows $Profile) | Where-Object { $_.Match -and $_.Console })
    if ($hits.Count -ge 1) { return $hits[0] }
    $null
}

function Get-MatchNeedle($Profile) {
    $needle = ([string]$Profile.processMatch).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($needle) -and $Profile.workingDirectory) {
        $needle = ([IO.Path]::GetFileName($Profile.workingDirectory.TrimEnd("\"))).ToLowerInvariant()
    }
    $needle
}

function Get-JavaProcess($Profile) {
    $needle = Get-MatchNeedle $Profile
    $wd = ""
    if ($Profile.workingDirectory) { $wd = ([string]$Profile.workingDirectory).ToLowerInvariant() }
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue
        foreach ($p in @($procs)) {
            if (-not $p.CommandLine) { continue }
            $cl = $p.CommandLine.ToLowerInvariant()
            if ($needle -and $cl.Contains($needle)) { return $p }
            if ($wd -and $cl.Contains($wd)) { return $p }
        }
    } catch {}
    $null
}

function Test-JavaAlive($Profile) {
    if (Get-JavaProcess $Profile) { return $true }
    if ($script:TargetPid -gt 0) {
        try {
            $tree = Get-ProcessTree
            foreach ($c in (Get-Descendants $tree ([int]$script:TargetPid))) {
                $name = [string]$c.Name
                if ($name -eq "java.exe" -or $name -eq "javaw.exe") { return $true }
            }
        } catch {}
    }
    $false
}

function Get-PidAncestry([int]$ProcessId) {
    $ids = New-Object System.Collections.Generic.List[int]
    $current = $ProcessId
    for ($i = 0; $i -lt 10; $i++) {
        if ($current -le 4) { break }
        if ($ids.Contains($current)) { break }
        $ids.Add($current)
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $current" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $proc) { break }
        $current = [int]$proc.ParentProcessId
    }
    $ids
}

function Find-WindowForServer($Profile) {
    $java = Get-JavaProcess $Profile
    if ($null -eq $java) { return $null }
    $ancestry = Get-PidAncestry ([int]$java.ProcessId)
    $windows = [McWin]::GetWindows()
    foreach ($id in $ancestry) {
        foreach ($w in $windows) {
            if ([int]$w.Pid -eq $id -and $w.Title -notmatch "MC Restart Timer") {
                return $w
            }
        }
    }
    $null
}

function Escape-SendKeys([string]$Text) {
    $special = "+^%~(){}[]"
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        if ($special.IndexOf($ch) -ge 0) {
            [void]$sb.Append("{").Append($ch).Append("}")
        } else {
            [void]$sb.Append($ch)
        }
    }
    $sb.ToString()
}

function Send-ServerLine([string]$Command) {
    Refresh-WindowTitle
    if (-not $script:Connected) {
        Write-Log "No server window to type into."
        return $false
    }
    $script:SavedFocus = [McWin]::GetForegroundWindow()
    $ok = [McWin]::FocusWindow($script:TargetHwnd)
    if (-not $ok) {
        Write-Log "Could not focus the server window."
        return $false
    }
    Start-Sleep -Milliseconds 80
    $escaped = Escape-SendKeys $Command
    [System.Windows.Forms.SendKeys]::SendWait($escaped)
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Start-Sleep -Milliseconds 150
    if ($script:SavedFocus -ne [IntPtr]::Zero -and $script:SavedFocus -ne $script:TargetHwnd) {
        [void][McWin]::FocusWindow($script:SavedFocus)
    }
    Write-Log ("> " + $Command)
    $true
}

function Parse-Clock([string]$Hhmm, [datetime]$Day) {
    $parts = $Hhmm.Split(":")
    Get-Date -Year $Day.Year -Month $Day.Month -Day $Day.Day -Hour ([int]$parts[0]) -Minute ([int]$parts[1]) -Second 0 -Millisecond 0
}

function Get-NextScheduled([string[]]$Times, [datetime]$From) {
    $candidates = New-Object System.Collections.Generic.List[datetime]
    foreach ($t in $Times) {
        $today = Parse-Clock $t $From
        if ($today -gt $From) { $candidates.Add($today) }
        $candidates.Add((Parse-Clock $t ($From.AddDays(1))))
    }
    $candidates | Sort-Object | Select-Object -First 1
}

function Test-SlotList($List, [datetime]$Target) {
    $key = $Target.ToString("yyyy-MM-dd HH:mm")
    foreach ($s in $List) {
        if ($s.ToString("yyyy-MM-dd HH:mm") -eq $key) { return $true }
    }
    $false
}

function Test-Skipped([datetime]$Target) { Test-SlotList $script:SkippedTargets $Target }
function Test-Completed([datetime]$Target) { Test-SlotList $script:CompletedTargets $Target }

function Get-DueSlot($Profile, [datetime]$From) {
    $grace = [timespan]::FromMinutes(5)
    foreach ($t in @($Profile.restartTimes)) {
        $slot = Parse-Clock $t $From
        $delta = $From - $slot
        if ($delta.TotalSeconds -ge 0 -and $delta -le $grace) {
            if (-not (Test-Skipped $slot) -and -not (Test-Completed $slot)) { return $slot }
        }
    }
    $null
}

function Get-NextTarget($Profile) {
    if ($script:ForcedTarget) { return $script:ForcedTarget }
    $from = Get-Date
    $due = Get-DueSlot $Profile $from
    if ($due) { return $due }
    for ($i = 0; $i -lt 16; $i++) {
        $next = Get-NextScheduled @($Profile.restartTimes) $from
        if (-not (Test-Skipped $next) -and -not (Test-Completed $next)) { return $next }
        $from = $next.AddSeconds(1)
    }
    Get-NextScheduled @($Profile.restartTimes) (Get-Date)
}

function Get-ArmedReason($Profile, $Target) {
    if ($script:Paused) { return "BLOCKED  schedule paused" }
    if ($script:Busy) { return "BUSY  restart in progress" }
    if (-not $script:Connected) { return "BLOCKED  no window bound  (press W)" }
    $when = if ($Target) { $Target.ToString("HH:mm") } else { "next slot" }
    if ($script:JavaAlive) { return "ARMED  will type into the bound window at $when" }
    return "ARMED  window bound, Java not confirmed  (press T to test)"
}

function Format-Countdown([timespan]$Span) {
    if ($Span.TotalSeconds -lt 0) { $Span = [timespan]::Zero }
    if ($Span.TotalHours -ge 1) {
        return "{0}h {1:00}m {2:00}s" -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds
    }
    "{0}m {1:00}s" -f [int]$Span.TotalMinutes, $Span.Seconds
}

function Get-WarnMessageKey([int]$Seconds) {
    switch ($Seconds) {
        900 { "warn15" }
        300 { "warn5" }
        60  { "warn1" }
        10  { "warn10s" }
        default {
            if ($Seconds -ge 60) { "warn{0}" -f [int]($Seconds / 60) }
            else { "warn{0}s" -f $Seconds }
        }
    }
}

function Get-ChatMessage($Profile, [string]$Key, [datetime]$At) {
    $clock = $At.ToString("HH:mm")
    $text = $null
    $pm = Get-JsonProp $Profile "messages"
    if ($pm) { $text = Get-JsonProp $pm $Key }
    if ([string]::IsNullOrWhiteSpace($text)) {
        $gm = Get-JsonProp $script:Config "messages"
        if ($gm) { $text = Get-JsonProp $gm $Key }
    }
    if ([string]::IsNullOrWhiteSpace($text) -and $script:DefaultMessages.ContainsKey($Key)) {
        $text = $script:DefaultMessages[$Key]
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $text = $text.Replace("{time}", $clock)
    $trim = $text.Trim()
    if ($trim -match "^(say|tellraw|title|save-all|stop)\b") { return $trim }
    "say $trim"
}

function Close-DeadServerWindow {
    $hwnd = $script:TargetHwnd
    if ($hwnd -eq [IntPtr]::Zero -or -not [McWin]::IsWindow($hwnd)) { return }
    $procName = ""
    if ($script:TargetPid -gt 0) {
        try { $procName = [string](Get-Process -Id $script:TargetPid -ErrorAction SilentlyContinue).ProcessName } catch {}
    }
    Write-Log "Closing leftover server window ($procName)..."
    [void][McWin]::FocusWindow($hwnd)
    Start-Sleep -Milliseconds 120
    foreach ($stroke in @("{ENTER}", "{ENTER}", "exit{ENTER}", "{ENTER}")) {
        if (-not [McWin]::IsWindow($hwnd)) { break }
        [System.Windows.Forms.SendKeys]::SendWait($stroke)
        Start-Sleep -Milliseconds 300
    }
    if (-not [McWin]::IsWindow($hwnd)) {
        Write-Log "Old window closed after Enter."
        return
    }
    $safeToClose = $procName -in @("cmd", "conhost", "powershell", "pwsh", "java", "")
    if ($safeToClose) {
        [void][McWin]::PostMessage($hwnd, [uint32]0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        $deadline = (Get-Date).AddSeconds(6)
        while ((Get-Date) -lt $deadline -and [McWin]::IsWindow($hwnd)) {
            Start-Sleep -Milliseconds 200
        }
    }
    if (-not [McWin]::IsWindow($hwnd)) {
        Write-Log "Old window closed."
        return
    }
    if ($procName -eq "cmd" -and $script:TargetPid -gt 0) {
        try {
            Stop-Process -Id $script:TargetPid -Force -ErrorAction Stop
            Write-Log ("Killed leftover cmd.exe " + $script:TargetPid)
            Start-Sleep -Milliseconds 400
            return
        } catch {
            Write-Log "Could not kill leftover cmd window."
        }
    }
    Write-Log "Old window still open. Close the Press any key window by hand if it is still there."
}

function Reset-WarningState([datetime]$Target) {
    $key = $Target.ToString("yyyy-MM-dd HH:mm")
    if ($script:CurrentTarget -ne $key) {
        $script:CurrentTarget = $key
        $script:FiredWarnings = @{}
    }
}

function Start-ServerWindow($Profile) {
    if ([string]::IsNullOrWhiteSpace($Profile.workingDirectory) -or [string]::IsNullOrWhiteSpace($Profile.startCommand)) {
        Write-Log "No start command on this profile."
        return $false
    }
    if (-not (Test-Path $Profile.workingDirectory)) {
        Write-Log "Working folder not found: $($Profile.workingDirectory)"
        return $false
    }
    $bat = Join-Path $Profile.workingDirectory $Profile.startCommand
    if (-not (Test-Path $bat)) {
        Write-Log "Start script not found: $bat"
        return $false
    }
    $before = @()
    foreach ($w in [McWin]::GetWindows()) { $before += $w.Hwnd.ToInt64() }
    $inner = "title $($Profile.name) && `"$($Profile.startCommand)`""
    $conhost = Join-Path $env:SystemRoot "System32\conhost.exe"
    $proc = $null
    if (Test-Path $conhost) {
        $proc = Start-Process -FilePath $conhost -ArgumentList @("cmd.exe", "/c", $inner) -WorkingDirectory $Profile.workingDirectory -PassThru
    } else {
        $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $inner) -WorkingDirectory $Profile.workingDirectory -PassThru
    }
    Write-Log ("Launched $($Profile.startCommand) pid=" + $proc.Id)
    @{ Process = $proc; Before = $before }
}

function Wait-NewServerWindow($Profile, $LaunchInfo, [int]$TimeoutSeconds) {
    if ($LaunchInfo -isnot [hashtable]) { return $null }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $before = @($LaunchInfo.Before)
    $proc = $LaunchInfo.Process
    while ((Get-Date) -lt $deadline) {
        try {
            if ($proc -and -not $proc.HasExited -and $proc.MainWindowHandle -ne [IntPtr]::Zero) {
                if ([McWin]::IsWindow($proc.MainWindowHandle)) {
                    return (Get-WindowItemFromHwnd $proc.MainWindowHandle $Profile)
                }
            }
        } catch {}
        foreach ($w in [McWin]::GetWindows()) {
            if ($before -contains $w.Hwnd.ToInt64()) { continue }
            if ($w.Title -match "MC Restart Timer") { continue }
            $procName = $w.ProcessName.ToLowerInvariant()
            $cls = [string]$w.ClassName
            $isConsole = ($cls -eq "ConsoleWindowClass" -or $cls -eq "CASCADIA_HOSTING_WINDOW_CLASS" -or $cls -like "*Console*" -or $procName -in @("cmd", "conhost", "windowsterminal", "powershell", "pwsh", "java"))
            if ($isConsole) { return $w }
        }
        Start-Sleep -Milliseconds 400
    }
    $null
}

function Invoke-RestartSequence($Profile) {
    $script:Busy = $true
    $script:LastStatus = "Saving and stopping"
    $slot = Get-NextTarget $Profile
    if ($slot -and -not $script:ForcedTarget) { $script:CompletedTargets.Add($slot) }
    try {
        $nowMsg = Get-ChatMessage $Profile "restartNow" (Get-Date)
        if ($nowMsg) { [void](Send-ServerLine $nowMsg) }
        [void](Send-ServerLine "save-all flush")
        Start-Sleep -Seconds ([int]$Profile.saveFlushSeconds)
        [void](Send-ServerLine "stop")
        Write-Log "Sent stop. Waiting for Java to exit."
        $script:LastStatus = "Waiting for shutdown"
        $deadline = (Get-Date).AddSeconds([int]$Profile.stopTimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if (-not (Test-JavaAlive $Profile)) { break }
            Start-Sleep -Milliseconds 500
            Pump-Keys $Profile
            if ($script:Quit) { return }
        }
        Close-DeadServerWindow
        $script:TargetHwnd = [IntPtr]::Zero
        $script:TargetPid = 0
        $script:Connected = $false
        $script:LastStatus = "Settling files"
        Start-Sleep -Seconds ([int]$Profile.settleSecondsAfterStop)
        if ($Profile.relaunch -eq $true) {
            $script:LastStatus = "Relaunching"
            $launch = Start-ServerWindow $Profile
            $script:LastStatus = "Waiting for window"
            $item = Wait-NewServerWindow $Profile $launch 60
            if (-not $item) { $item = Find-WindowForServer $Profile }
            if (-not $item) { $item = Find-WindowByProfile $Profile }
            if ($item) {
                Bind-Window $item
                $script:LastStatus = "Waiting for Java"
            }
            $waitStart = Get-Date
            $bootDeadline = $waitStart.AddSeconds([int]$Profile.bootTimeoutSeconds)
            $onlineSent = $false
            while ((Get-Date) -lt $bootDeadline -and -not $script:Quit) {
                Pump-Keys $Profile
                if (-not $script:Connected) {
                    $item = Wait-NewServerWindow $Profile $launch 2
                    if (-not $item) { $item = Find-WindowForServer $Profile }
                    if ($item) { Bind-Window $item }
                }
                $script:JavaAlive = Test-JavaAlive $Profile
                $waited = ((Get-Date) - $waitStart).TotalSeconds
                if ($script:Connected -and -not $onlineSent -and ($script:JavaAlive -or $waited -ge 25)) {
                    Start-Sleep -Seconds 8
                    $online = Get-ChatMessage $Profile "online" (Get-Date)
                    if ($online) { [void](Send-ServerLine $online) }
                    $onlineSent = $true
                    $script:LastStatus = "Connected"
                    Write-Log "Server is back."
                    if ($script:JavaAlive) { break }
                }
                if ($onlineSent -and $script:JavaAlive) { break }
                Start-Sleep -Seconds 2
            }
            if ($script:LastStatus -ne "Connected") {
                $script:LastStatus = "Boot timed out"
                Write-Log "Timed out waiting after relaunch."
            }
        } else {
            $script:LastStatus = "Stopped (no relaunch)"
            Write-Log "Relaunch is off. Server stays down."
        }
    } catch {
        Write-Log ("Restart sequence error: " + $_.Exception.Message)
        $script:LastStatus = "Error"
    } finally {
        $script:ForcedTarget = $null
        $script:FiredWarnings = @{}
        $script:Busy = $false
    }
}

function Pump-Keys($Profile) {
    while ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        $k = $key.Key
        if ($k -eq "Q") {
            $script:Quit = $true
            return
        }
        if ($script:Busy) { continue }
        switch ($k) {
            "S" {
                $target = Get-NextTarget $Profile
                if ($target) {
                    $script:SkippedTargets.Add($target)
                    Write-Log ("Skipped " + $target.ToString("HH:mm"))
                    $script:LastStatus = "Skipped $($target.ToString('HH:mm'))"
                }
            }
            "R" {
                if (-not $script:Connected) {
                    Write-Log "Cannot restart now: no window bound. Press W."
                    break
                }
                $script:ForcedTarget = (Get-Date).AddSeconds(10)
                $script:FiredWarnings = @{}
                Write-Log "Manual restart in 10s."
                $script:LastStatus = "Manual restart armed"
            }
            "T" {
                if (-not $script:Connected) {
                    Write-Log "Test failed: no window bound. Press W."
                    $script:LastStatus = "Test failed (no window)"
                    break
                }
                $ok = Send-ServerLine (Get-ChatMessage $Profile "test" (Get-Date))
                $script:LastTestAt = Get-Date
                if ($ok) {
                    $script:LastStatus = "TEST SENT  look in Minecraft chat"
                    Write-Log "Test say sent. Check in-game chat."
                } else {
                    $script:LastStatus = "Test failed (could not type)"
                }
            }
            "P" {
                $script:Paused = -not $script:Paused
                if ($script:Paused) {
                    Write-Log "Schedule paused."
                    $script:LastStatus = "Paused"
                } else {
                    Write-Log "Schedule resumed."
                    $script:LastStatus = "Connected"
                }
            }
            "I" {
                if ($script:JavaAlive) {
                    Write-Log "Java is already running."
                } else {
                    $launch = Start-ServerWindow $Profile
                    $item = Wait-NewServerWindow $Profile $launch 30
                    if ($item) { Bind-Window $item }
                    $script:LastStatus = "Starting server"
                }
            }
            "W" {
                $script:PickWindow = $true
            }
            "N" {
                $script:Quit = $true
                $script:SwitchProfile = $true
            }
        }
    }
}

function Draw-Dashboard($Profile, $Target, $Remaining) {
    $conn = if ($script:JavaAlive) { "JAVA UP" } elseif ($script:Connected) { "WINDOW ONLY" } else { "DOWN" }
    $connColor = if ($script:JavaAlive) { "Green" } elseif ($script:Connected) { "Yellow" } else { "Red" }
    $armed = Get-ArmedReason $Profile $Target
    $armedColor = if ($armed.StartsWith("ARMED")) { "Green" } else { "Red" }
    $pauseText = if ($script:Paused) { "PAUSED" } else { $script:LastStatus }
    $warnBits = @()
    foreach ($w in (@($Profile.warningsSeconds) | Sort-Object -Descending)) {
        $label = if ($w -ge 60) { "{0}m" -f [int]($w / 60) } else { "{0}s" -f $w }
        if ($script:FiredWarnings.ContainsKey("$w")) { $warnBits += "$label done" } else { $warnBits += "$label" }
    }
    $title = $script:TargetTitle
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "(none)" }
    if ($title.Length -gt 52) { $title = $title.Substring(0, 52) + "..." }
    $eta = "--"
    if ($Remaining) {
        if ($Remaining.TotalSeconds -le 0) { $eta = "DUE NOW" } else { $eta = Format-Countdown $Remaining }
    }

    [Console]::SetCursorPosition(0, 0)
    $lines = @(
        "==============================================================================="
        "  MC RESTART TIMER"
        "==============================================================================="
        ("  Clock   : {0}" -f (Get-Date -Format "HH:mm:ss"))
        ("  Profile : {0}" -f $Profile.name)
        ("  Window  : {0}" -f $title)
        ("  Link    : {0}" -f $conn)
        ("  Next    : {0}      {1}" -f $(if ($Target) { $Target.ToString("HH:mm") } else { "--:--" }), $eta)
        ("  Armed   : {0}" -f $armed)
        ("  Status  : {0}" -f $pauseText)
        ("  Warns   : {0}" -f ($warnBits -join "  |  "))
        "-------------------------------------------------------------------------------"
        "  [T] TEST CHAT  types a say into the server, check in-game"
        "  [S] skip next    [R] restart now    [P] pause    [W] pick window"
        "  [I] start server [N] switch profile [Q] quit timer"
        "-------------------------------------------------------------------------------"
        "  Log"
    )
    foreach ($log in $script:LogLines) { $lines += "    $log" }
    while ($lines.Count -lt 24) { $lines += "" }
    $lines += "==============================================================================="

    $i = 0
    foreach ($line in $lines) {
        $padded = $line.PadRight(79)
        if ($padded.Length -gt 79) { $padded = $padded.Substring(0, 79) }
        if ($i -eq 1) {
            Write-Host $padded -ForegroundColor Yellow
        } elseif ($i -eq 6) {
            Write-Host $padded -ForegroundColor $connColor
        } elseif ($i -eq 8) {
            Write-Host $padded -ForegroundColor $armedColor
        } else {
            Write-Host $padded
        }
        $i++
    }
}

function Invoke-TimerLoop($Profile) {
    $script:Quit = $false
    $script:SwitchProfile = $false
    $script:PickWindow = $false
    $script:FiredWarnings = @{}
    $script:ForcedTarget = $null
    $script:Busy = $false
    $script:CurrentProfile = $Profile
    $host.UI.RawUI.WindowTitle = "MC Restart Timer - $($Profile.name)"
    Write-Log "Profile $($Profile.name)"

    $picked = Select-ServerWindow $Profile
    Bind-Window $picked
    if ($script:Connected) { $script:LastStatus = "Window bound" } else { $script:LastStatus = "No window" }

    Clear-Host
    while (-not $script:Quit) {
        Pump-Keys $Profile
        if ($script:Quit) { break }

        if ($script:PickWindow) {
            $script:PickWindow = $false
            $picked = Select-ServerWindow $Profile
            if ($picked) { Bind-Window $picked }
            Clear-Host
        }

        Refresh-WindowTitle
        if (-not $script:Connected) {
            $auto = Find-WindowForServer $Profile
            if (-not $auto) { $auto = Find-WindowByProfile $Profile }
            if ($auto) {
                Bind-Window $auto
                $script:LastStatus = "Window bound"
            }
        }

        if (((Get-Date) - $script:LastJavaCheck).TotalSeconds -ge 3) {
            $script:LastJavaCheck = Get-Date
            $script:JavaAlive = Test-JavaAlive $Profile
            if ($script:JavaAlive -and $script:Connected -and $script:LastStatus -in @("No window", "Window bound", "Waiting for Java", "Starting server")) {
                $script:LastStatus = "Connected"
            }
        }

        $target = Get-NextTarget $Profile
        Reset-WarningState $target
        $remaining = $target - (Get-Date)

        $canFire = $script:Connected -and -not $script:Paused -and -not $script:Busy
        if ($canFire) {
            foreach ($w in (@($Profile.warningsSeconds) | Sort-Object -Descending)) {
                $key = "$w"
                if ($script:FiredWarnings.ContainsKey($key)) { continue }
                $secs = [int][Math]::Floor($remaining.TotalSeconds)
                if ($secs -le $w -and ($w - $secs) -le 20) {
                    $script:FiredWarnings[$key] = $true
                    $msg = Get-ChatMessage $Profile (Get-WarnMessageKey $w) $target
                    if ($msg) { [void](Send-ServerLine $msg) }
                }
            }

            if ($remaining.TotalSeconds -le 0) {
                Invoke-RestartSequence $Profile
            }
        }

        if (((Get-Date) - $script:LastHeartbeat).TotalMinutes -ge 10) {
            $script:LastHeartbeat = Get-Date
            Write-Log ("Heartbeat  next " + $(if ($target) { $target.ToString("HH:mm") } else { "--" }) + "  " + (Get-ArmedReason $Profile $target))
        }

        Draw-Dashboard $Profile $target $remaining
        Start-Sleep -Milliseconds 800
    }
}

if (-not $Host.Name.Equals("ConsoleHost")) {
    Write-Host "Run START TIMER.bat so this stays in a console window."
    exit 1
}

try { [Console]::CursorVisible = $false } catch {}
Write-Log "Timer started."

try {
    do {
        $config = Load-Config
        $script:Config = $config
        $profile = Select-Profile $config
        Invoke-TimerLoop $profile
        if ($script:SwitchProfile) {
            $script:Quit = $false
            Write-Log "Switching profile."
        }
    } while ($script:SwitchProfile)
} catch {
    Write-Log $_.Exception.Message
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "See timer.log in this folder." -ForegroundColor DarkGray
    exit 1
} finally {
    try { [Console]::CursorVisible = $true } catch {}
    Write-Log "Timer closed."
}
