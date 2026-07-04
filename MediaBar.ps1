# ============================================================
#  MediaBar  -  mini player living inside the taskbar (Win 11)
#  Controls any media app: Spotify, YouTube, VLC, Winamp...
#  Recommended start: double-click "Start MediaBar.vbs"
# ============================================================

try {

# --- single instance --------------------------------------------------------
$script:mtx = New-Object System.Threading.Mutex($false, 'MediaBar_Iulian_SingleInstance')
if (-not $script:mtx.WaitOne(0)) { exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- native Windows helpers (media keys, window style, memory) --------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MediaNative {
    [DllImport("user32.dll")]
    static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("shell32.dll")]
    public static extern int SHQueryUserNotificationState(out int pquns);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    public static extern bool SetProcessWorkingSetSize(IntPtr hProcess, IntPtr dwMin, IntPtr dwMax);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int maxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, System.Text.StringBuilder lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    // reads another window's title without ever blocking our UI thread:
    // WM_GETTEXT with SMTO_ABORTIFHUNG and a timeout; null on failure
    public static string GetWindowTextSafe(IntPtr hWnd, int timeoutMs) {
        try {
            var sb = new System.Text.StringBuilder(512);
            IntPtr res;
            IntPtr ok = SendMessageTimeout(hWnd, 0x000D, (IntPtr)512, sb, 2, (uint)timeoutMs, out res);
            if (ok == IntPtr.Zero) return null;
            return sb.ToString();
        } catch { return null; }
    }
    // native Z-order pinner: re-pins the bar above the taskbar from a tiny
    // background thread, so the fast 200ms pulse costs the script engine
    // nothing at all; controlled via SetZPin (visibility / dragging)
    static System.Threading.Thread zThread;
    static volatile bool zRun;
    static volatile bool zPin;
    static IntPtr zHwnd;
    public static void StartZPinner(IntPtr hwnd, int intervalMs) {
        zHwnd = hwnd;
        zRun = true;
        if (zThread != null) return;
        zThread = new System.Threading.Thread(delegate() {
            while (zRun) {
                try {
                    if (zPin) SetWindowPos(zHwnd, new IntPtr(-1), 0, 0, 0, 0, 0x0413);
                } catch { }
                System.Threading.Thread.Sleep(intervalMs);
            }
        });
        zThread.IsBackground = true;
        zThread.Start();
    }
    public static void SetZPin(bool on) { zPin = on; }
    public static void StopZPinner() { zRun = false; }
    public static void Tap(byte vk) {
        keybd_event(vk, 0, 1, UIntPtr.Zero);       // key down (extended key)
        keybd_event(vk, 0, 1 | 2, UIntPtr.Zero);   // key up
    }
}
'@

# --- per-app volume via Windows Core Audio sessions (the Volume Mixer) -------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class MMDeviceEnumeratorCom { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    int NotImpl1();   // EnumAudioEndpoints
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
}

[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2 {
    int NotImpl1();   // GetAudioSessionControl
    int NotImpl2();   // GetSimpleAudioVolume
    [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnum);
}

[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int GetSession(int index, out IAudioSessionControl session);
}

[ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl {
    [PreserveSig] int GetState(out int state);
}

[ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl2 {
    [PreserveSig] int GetState(out int state);
    int NotImpl1();   // GetDisplayName
    int NotImpl2();   // SetDisplayName
    int NotImpl3();   // GetIconPath
    int NotImpl4();   // SetIconPath
    int NotImpl5();   // GetGroupingParam
    int NotImpl6();   // SetGroupingParam
    int NotImpl7();   // RegisterAudioSessionNotification
    int NotImpl8();   // UnregisterAudioSessionNotification
    int NotImpl9();   // GetSessionIdentifier
    int NotImpl10();  // GetSessionInstanceIdentifier
    [PreserveSig] int GetProcessId(out uint pid);
    [PreserveSig] int IsSystemSoundsSession();
}

[ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISimpleAudioVolume {
    [PreserveSig] int SetMasterVolume(float level, ref Guid eventContext);
    [PreserveSig] int GetMasterVolume(out float level);
}

public static class AppVolume {
    // the audio device/manager chain is REUSED between calls instead of
    // being re-activated every time; it is rebuilt on any failure and
    // refreshed every ~60 uses to pick up default-device changes
    static readonly object cLock = new object();
    static IMMDeviceEnumerator cDevEnum;
    static IMMDevice cDev;
    static IAudioSessionManager2 cMgr;
    static int cUses;

    static IAudioSessionManager2 GetMgr() {
        if (cMgr != null && cUses < 60) { cUses++; return cMgr; }
        ReleaseMgr();
        try {
            cDevEnum = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            IMMDevice dev;
            if (cDevEnum.GetDefaultAudioEndpoint(0, 1, out dev) != 0 || dev == null) { ReleaseMgr(); return null; }
            cDev = dev;
            Guid iid = typeof(IAudioSessionManager2).GUID;
            object o;
            if (cDev.Activate(ref iid, 0x17, IntPtr.Zero, out o) != 0 || o == null) { ReleaseMgr(); return null; }
            cMgr = (IAudioSessionManager2)o;
            cUses = 1;
            return cMgr;
        } catch { ReleaseMgr(); return null; }
    }

    static void ReleaseMgr() {
        try { if (cMgr != null) Marshal.ReleaseComObject(cMgr); } catch { }
        try { if (cDev != null) Marshal.ReleaseComObject(cDev); } catch { }
        try { if (cDevEnum != null) Marshal.ReleaseComObject(cDevEnum); } catch { }
        cMgr = null; cDev = null; cDevEnum = null; cUses = 0;
    }

    // Adjusts the volume of every audio session that is ACTIVELY rendering
    // sound right now and belongs to an allowed app (empty list = all).
    // Returns how many sessions were adjusted; 0 means nothing matched.
    public static int AdjustPlaying(float delta, string[] allowed) {
        lock (cLock) {
            int adjusted = 0;
            IAudioSessionEnumerator en = null;
            try {
                var mgr = GetMgr();
                if (mgr == null) return 0;
                if (mgr.GetSessionEnumerator(out en) != 0 || en == null) { ReleaseMgr(); return 0; }
                int count; en.GetCount(out count);
                for (int i = 0; i < count; i++) {
                    IAudioSessionControl c = null;
                    try {
                        if (en.GetSession(i, out c) != 0 || c == null) continue;
                        var c2 = (IAudioSessionControl2)c;
                        int state; c2.GetState(out state);
                        uint pid; c2.GetProcessId(out pid);
                        if (state == 1 && pid != 0) {           // Active, not system sounds
                            bool ok = (allowed == null || allowed.Length == 0);
                            if (!ok) {
                                string pn = "";
                                try {
                                    var pp = System.Diagnostics.Process.GetProcessById((int)pid);
                                    pn = pp.ProcessName;
                                    pp.Dispose();
                                } catch { }
                                for (int a = 0; a < allowed.Length; a++) {
                                    if (string.Equals(pn, allowed[a], StringComparison.OrdinalIgnoreCase)) { ok = true; break; }
                                }
                            }
                            if (!ok) continue;
                            var vol = (ISimpleAudioVolume)c;
                            float v; vol.GetMasterVolume(out v);
                            v += delta;
                            if (v < 0f) v = 0f; if (v > 1f) v = 1f;
                            Guid empty = Guid.Empty;
                            vol.SetMasterVolume(v, ref empty);
                            adjusted++;
                        }
                    } catch { }
                    finally { if (c != null) Marshal.ReleaseComObject(c); }
                }
            } catch { ReleaseMgr(); }
            finally { if (en != null) Marshal.ReleaseComObject(en); }
            return adjusted;
        }
    }

    // Returns the process IDs of every audio session that is actively
    // rendering sound right now (the same channel the wheel uses).
    public static int[] GetActivePids() {
        lock (cLock) {
            var list = new System.Collections.Generic.List<int>();
            IAudioSessionEnumerator en = null;
            try {
                var mgr = GetMgr();
                if (mgr == null) return list.ToArray();
                if (mgr.GetSessionEnumerator(out en) != 0 || en == null) { ReleaseMgr(); return list.ToArray(); }
                int count; en.GetCount(out count);
                for (int i = 0; i < count; i++) {
                    IAudioSessionControl c = null;
                    try {
                        if (en.GetSession(i, out c) != 0 || c == null) continue;
                        var c2 = (IAudioSessionControl2)c;
                        int state; c2.GetState(out state);
                        uint pid; c2.GetProcessId(out pid);
                        if (state == 1 && pid != 0) list.Add((int)pid);
                    } catch { }
                    finally { if (c != null) Marshal.ReleaseComObject(c); }
                }
            } catch { ReleaseMgr(); }
            finally { if (en != null) Marshal.ReleaseComObject(en); }
            return list.ToArray();
        }
    }

    // --- UI-thread-safe wrappers: the audio service can be busy (e.g. the
    // Windows volume mixer is open) and the synchronous COM calls above can
    // then block for a long time; these run them on a worker thread with a
    // timeout, so the bar never freezes waiting for audio enumeration.
    // A stalled worker keeps holding cLock, so the next one simply waits
    // past its own timeout and reports "busy" - the UI stays untouched.

    // returns null on timeout (caller should keep its previous data)
    public static int[] GetActivePidsSafe(int timeoutMs) {
        int[][] box = new int[1][];
        var t = new System.Threading.Thread(delegate() {
            try { box[0] = GetActivePids(); } catch { box[0] = new int[0]; }
        });
        t.IsBackground = true;
        try { t.SetApartmentState(System.Threading.ApartmentState.MTA); } catch { }
        t.Start();
        if (!t.Join(timeoutMs)) return null;
        return box[0];
    }

    // returns -1 on timeout (caller should do nothing at all)
    public static int AdjustPlayingSafe(float delta, string[] allowed, int timeoutMs) {
        int[] box = new int[] { -1 };
        var t = new System.Threading.Thread(delegate() {
            try { box[0] = AdjustPlaying(delta, allowed); } catch { box[0] = 0; }
        });
        t.IsBackground = true;
        try { t.SetApartmentState(System.Threading.ApartmentState.MTA); } catch { }
        t.Start();
        if (!t.Join(timeoutMs)) return -1;
        return box[0];
    }
}
'@

[void][MediaNative]::SetProcessDPIAware()
# low priority: the bar never competes with your apps for CPU
try { [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
try {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
} catch { }

# scaling factor for high-DPI screens (125%, 150% etc.)
$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:scale = $g.DpiX / 96.0
$g.Dispose()
function S([double]$v) { [int][math]::Round($v * $script:scale) }

# --- WinRT: reading the current track (optional; buttons work without it) ---
$script:WinRtOk  = $false
$script:MediaMgr = $null
$script:MediaErr = ''
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                       $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' }) |
        Select-Object -First 1
    if (-not $script:asTaskGeneric) { throw 'AsTask method not found in System.Runtime.WindowsRuntime' }
    # resolve the WinRT types once and reuse them everywhere
    $script:TypeMgr   = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
    $script:TypeProps = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties,Windows.Media.Control,ContentType=WindowsRuntime]
    # prepare the generic methods up front; never rebuilt per call
    $script:asTaskMgr   = $script:asTaskGeneric.MakeGenericMethod($script:TypeMgr)
    $script:asTaskProps = $script:asTaskGeneric.MakeGenericMethod($script:TypeProps)
    $script:asTaskBool  = $script:asTaskGeneric.MakeGenericMethod([bool])
    $script:WinRtOk = $true
} catch {
    $script:WinRtOk  = $false
    $script:MediaErr = "WinRT init: $($_.Exception.Message)"
}

function Await($WinRtTask, $AsTaskMethod) {
    $netTask = $AsTaskMethod.Invoke($null, @($WinRtTask))
    [void]$netTask.Wait(500)
    if ($netTask.IsCompleted) { return $netTask.Result }
    return $null
}

function Get-MediaInfo {
    if (-not $script:WinRtOk) { return $null }
    try {
        if (-not $script:MediaMgr) {
            $script:MediaMgr = Await ($script:TypeMgr::RequestAsync()) $script:asTaskMgr
        }
        if (-not $script:MediaMgr) { $script:MediaErr = 'Media manager did not respond'; return $null }
        $s = $script:MediaMgr.GetCurrentSession()
        if (-not $s) { $script:smtcSession = $null; $script:smtcApp = ''; $script:lastSmtc = $null; $script:lastPlaying = $null; return $null }
        $script:smtcSession = $s
        try { $script:smtcApp = Get-SessionAppName $s } catch { $script:smtcApp = '' }
        $playing = ($s.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing')
        # while paused nothing changes: the (heavier) track properties are
        # re-read only on state changes and as a slow safety refresh
        $needProps = $playing -or ($script:lastPlaying -ne $playing) -or
                     (-not $script:lastSmtc) -or (($script:tick % 10) -eq 0)
        $script:lastPlaying = $playing
        # circuit breaker: if this session's track info recently timed out,
        # serve the cached title for a while instead of freezing the bar on
        # every cycle (some Chrome streams stall this call)
        if ($needProps -and $script:tick -lt $script:propsBad) { $needProps = $false }
        if (-not $needProps) {
            if ($script:lastSmtc) {
                return [pscustomobject]@{ Display = $script:lastSmtc; Playing = $playing }
            }
            return $null
        }
        $p = Await ($s.TryGetMediaPropertiesAsync()) $script:asTaskProps
        if (-not $p) {
            $script:propsBad = $script:tick + 10
            if ($script:lastSmtc) {
                return [pscustomobject]@{ Display = $script:lastSmtc; Playing = $playing }
            }
            return $null
        }
        $dt = $p.Title
        if ($dt -and $p.Artist) { $dt = "$($p.Artist) - $dt" }
        $script:lastSmtc = $dt
        [pscustomobject]@{ Display = $dt; Playing = $playing }
    } catch {
        $script:MediaErr = $_.Exception.Message
        $script:MediaMgr = $null
        $script:smtcSession = $null
        return $null
    }
}

# fallback players: some apps (VLC 3, classic WMP, Winamp) never announce
# their track to Windows; we scan their windows instead, cheaply: at most one
# scan every 5 seconds, collecting ALL of them (window handle and exe path
# included, so each one can be paused individually from the panel)
$script:fbSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($n in 'Spotify', 'vlc', 'wmplayer', 'winamp', 'foobar2000', 'MusicBee', 'AIMP') { [void]$script:fbSet.Add($n) }
$script:fbList = @()
$script:fbNext = [datetime]::MinValue

function Get-CleanTitle([string]$t) {
    if (-not $t) { return $null }
    $t = $t.Trim()
    $t = $t -replace ' \[(Paused|Stopped)\]$', ''
    $t = $t -replace ' - VLC media player$', ''
    $t = $t -replace ' - Windows Media Player$', ''
    $t = $t -replace ' - Winamp$', ''
    $t = $t -replace ' \[foobar2000[^\]]*\]$', ''
    $t = $t -replace '^\d+\. ', ''
    # "idle" window titles (app open, nothing playing) are ignored
    if ($t -and $t -notmatch '^(Spotify( Free| Premium)?|VLC media player|Windows Media Player|Winamp|foobar2000.*|MusicBee.*|AIMP.*)$') { return $t }
    return $null
}

function Get-FallbackPlayers {
    $now = [datetime]::UtcNow
    if ($now -lt $script:fbNext) { return $script:fbList }
    $found = @()
    try {
        # direct process check: a known player counts simply because its
        # process is running; title and audio state just enrich the entry.
        # Apps like Spotify spawn several same-named processes, so we keep
        # one best candidate per name (title > window > audio > anything)
        $byName = @{}
        foreach ($pr in [System.Diagnostics.Process]::GetProcesses()) {
            if ($script:fbSet.Contains($pr.ProcessName)) {
                $raw = $pr.MainWindowTitle
                $t = Get-CleanTitle $raw
                # players like Winamp mark their title with [Paused]/[Stopped];
                # trust that over the audio session, which can linger "active"
                $pausedHint = ($raw -match '\[(Paused|Stopped)\]')
                $path = $null
                try { $path = $pr.MainModule.FileName } catch { }
                $cand = [pscustomobject]@{
                    Name       = $pr.ProcessName
                    Title      = $t
                    Hwnd       = $pr.MainWindowHandle
                    Path       = $path
                    PausedHint = $pausedHint
                    Playing    = $false
                }
                $score = 0
                if ($t) { $score += 4 }
                if ($pr.MainWindowHandle -ne [IntPtr]::Zero) { $score += 2 }
                $key = $pr.ProcessName.ToLowerInvariant()
                if (-not $byName.ContainsKey($key) -or $score -gt $byName[$key].Score) {
                    $byName[$key] = [pscustomobject]@{ Score = $score; Entry = $cand }
                }
            }
            $pr.Dispose()
        }
        # the audio system is queried once, and only if any player exists
        $activeNames = @()
        if ($byName.Count -gt 0) { $activeNames = @(Get-ActiveAudioNames) }
        foreach ($k in $byName.Keys) {
            $e = $byName[$k].Entry
            $e.Playing = ($activeNames -contains $e.Name) -and (-not $e.PausedHint)
            $found += $e
        }
    } catch { }
    # Winamp specifics: refresh its entry via its classic window class
    # (fills the title and a working handle even when tray-minimized,
    # and picks up the [Paused]/[Stopped] marker)
    foreach ($f0 in $found) {
        if ($f0.Name -eq 'winamp') {
            Update-WinampEntry $f0
            if ($f0.PausedHint) { $f0.Playing = $false }
        }
    }
    $script:fbList = $found
    # adaptive pace: every 5s while such players exist, every 12s otherwise,
    # so machines that never run them are barely touched
    $script:fbNext = $now.AddSeconds($(if ($found.Count -gt 0) { 5 } else { 12 }))
    return $found
}

# send prev / playpause / next to ONE specific player that has no Windows
# media integration, by talking straight to its own window or command line
function Send-PlayerCommand($player, [string]$action) {
    try {
        $r = [IntPtr]::Zero
        switch -Regex ($player.Name) {
            '^winamp$' {
                # classic Winamp API: WM_COMMAND 40044 prev, 40045 play,
                # 40046 pause/unpause, 40048 next; find the window by its
                # classic class when tray-minimized
                $h = $player.Hwnd
                if ($h -eq [IntPtr]::Zero) { $h = [MediaNative]::FindWindow('Winamp v1.x', [NullString]::Value) }
                if ($h -ne [IntPtr]::Zero) {
                    $id = switch ($action) {
                        'prev' { 40044 }
                        'next' { 40048 }
                        default { if ($player.Playing) { 40046 } else { 40045 } }
                    }
                    [void][MediaNative]::SendMessageTimeout($h, 0x0111, [IntPtr]::new($id), [IntPtr]::Zero, 2, 800, [ref]$r)
                }
                return
            }
            '^foobar2000$' {
                if ($player.Path) {
                    $arg = switch ($action) { 'prev' { '/prev' } 'next' { '/next' } default { '/playpause' } }
                    Start-Process -FilePath $player.Path -ArgumentList $arg -WindowStyle Hidden
                    return
                }
            }
            '^MusicBee$' {
                if ($player.Path) {
                    $arg = switch ($action) { 'prev' { '/Previous' } 'next' { '/Next' } default { '/PlayPause' } }
                    Start-Process -FilePath $player.Path -ArgumentList $arg -WindowStyle Hidden
                    return
                }
            }
            '^AIMP$' {
                if ($player.Path) {
                    $arg = switch ($action) { 'prev' { '/PREV' } 'next' { '/NEXT' } default { '/PAUSE' } }
                    Start-Process -FilePath $player.Path -ArgumentList $arg -WindowStyle Hidden
                    return
                }
            }
        }
        # generic: WM_APPCOMMAND straight to the app window
        # (14 = play/pause, 11 = next track, 12 = previous track)
        $cmd = switch ($action) { 'prev' { 12 } 'next' { 11 } default { 14 } }
        [void][MediaNative]::SendMessageTimeout($player.Hwnd, 0x0319, $player.Hwnd, [IntPtr]::new($cmd -shl 16), 2, 800, [ref]$r)
    } catch { }
}

function Send-PlayerPause($player) { Send-PlayerCommand $player 'playpause' }

# the process names behind the audio sessions that are actively rendering
# sound right now (same channel the wheel uses); read on a worker thread
# with a timeout - if the audio service is busy (volume mixer open etc.),
# we keep the last known list instead of freezing
function Get-ActiveAudioNames {
    $pids = $null
    try { $pids = [AppVolume]::GetActivePidsSafe(600) } catch { }
    if ($null -eq $pids) { return $script:lastActive }
    $an = @()
    foreach ($pid2 in @($pids)) {
        $pr2 = $null
        try {
            $pr2 = [System.Diagnostics.Process]::GetProcessById($pid2)
            $an += $pr2.ProcessName
        } catch { }
        if ($pr2) { $pr2.Dispose() }
    }
    $script:lastActive = $an
    return $an
}

# Winamp marks its own window title with [Paused]/[Stopped]; read it fresh
# (works from the tray too, via its classic window class) and refresh the
# entry - this beats the audio session, which Winamp keeps open while paused
function Update-WinampEntry($f) {
    try {
        $hw = $f.Hwnd
        if ($hw -eq [IntPtr]::Zero) {
            $hw = [MediaNative]::FindWindow('Winamp v1.x', [NullString]::Value)
            if ($hw -ne [IntPtr]::Zero) { $f.Hwnd = $hw }
        }
        if ($hw -ne [IntPtr]::Zero) {
            $raw = [MediaNative]::GetWindowTextSafe($hw, 300)
            if ($null -eq $raw) { return }   # window busy: keep previous state
            $f.PausedHint = ($raw -match '\[(Paused|Stopped)\]')
            $t = Get-CleanTitle $raw
            if ($t) { $f.Title = $t }
        }
    } catch { }
}

# --- colors and fonts --------------------------------------------------------
$colBack  = [System.Drawing.Color]::FromArgb(28, 28, 30)
$colHover = [System.Drawing.Color]::FromArgb(62, 62, 66)
$colDown  = [System.Drawing.Color]::FromArgb(84, 84, 90)
$colText  = [System.Drawing.Color]::FromArgb(235, 235, 235)

$glyphFont = [System.Drawing.Font]::new('Segoe Fluent Icons', 11)
if ($glyphFont.Name -ne 'Segoe Fluent Icons') {
    $glyphFont = [System.Drawing.Font]::new('Segoe MDL2 Assets', 11)
}
$textFont = [System.Drawing.Font]::new('Times New Roman', 10)
$glyphFontSmall = [System.Drawing.Font]::new($glyphFont.FontFamily, 8)

# text drawn by hand with our own end-ellipsis: the built-in AutoEllipsis
# would otherwise pop its own internal tooltip on hover, which we don't want
$script:txtFlags = [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor
                   [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
                   [System.Windows.Forms.TextFormatFlags]::SingleLine -bor
                   [System.Windows.Forms.TextFormatFlags]::NoPrefix

$GLYPH_PREV  = [string][char]0xE892
$GLYPH_PLAY  = [string][char]0xE768
$GLYPH_PAUSE = [string][char]0xE769
$GLYPH_NEXT  = [string][char]0xE893
$GLYPH_UP    = [string][char]0xE70E
$GLYPH_DOWN  = [string][char]0xE70D

# --- main window --------------------------------------------------------------
$form = [System.Windows.Forms.Form]::new()
$form.FormBorderStyle = 'None'
$form.StartPosition   = 'Manual'
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.BackColor       = $colBack
$form.BackgroundImageLayout = 'None'
$form.Opacity         = 1.0

# --- taskbar band geometry -----------------------------------------------------
# Taskbar band = the space between the working area and the screen bottom edge.
function Get-TaskbarBand {
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen
    $h = $scr.Bounds.Bottom - $scr.WorkingArea.Bottom
    if ($h -gt (S 20)) {
        [pscustomobject]@{ Top = $scr.WorkingArea.Bottom; Height = $h; InBar = $true }
    } else {
        # taskbar auto-hidden or moved: sit just above the working area instead
        [pscustomobject]@{ Top = $scr.WorkingArea.Bottom - (S 40) - (S 6); Height = (S 40); InBar = $false }
    }
}

$band = Get-TaskbarBand
$barH = [math]::Min((S 40), ($band.Height - (S 6)))
if ($barH -lt (S 24)) { $barH = [math]::Max((S 22), $band.Height - 2) }
$form.Size = [System.Drawing.Size]::new((S 438), $barH)

# inner sizes derived from the bar height
$btnH = $barH - (S 10)
if ($btnH -lt (S 16)) { $btnH = [math]::Max(10, $barH - 4) }
$btnY = [int][math]::Floor(($barH - $btnH) / 2)

function Get-BarY {
    $b = Get-TaskbarBand
    return [int]($b.Top + [math]::Floor(($b.Height - $form.Height) / 2))
}

# horizontal position: we anchor the RIGHT edge (buttons stay put while the
# width adapts to the title); default is on the right, near the clock area
$cfgPath = Join-Path $env:APPDATA 'MediaBar.cfg'
$scrB = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$rightEdge = $scrB.Right - (S 240)
if (Test-Path $cfgPath) {
    try {
        $raw = (Get-Content $cfgPath -First 1).Trim()
        if ($raw -like 'R=*') {
            $r = [int]$raw.Substring(2)
        } else {
            # migration from the old format: left edge at the fixed 420 width
            $r = [int](($raw -split ',')[0]) + (S 420)
        }
        if ($r -gt ($scrB.Left + (S 160)) -and $r -le $scrB.Right) { $rightEdge = $r }
    } catch { }
}
$form.Location = [System.Drawing.Point]::new(($rightEdge - $form.Width), (Get-BarY))

function Save-Pos {
    try { "R=$($form.Left + $form.Width)" | Set-Content -Path $cfgPath -Encoding ASCII } catch { }
}

# chameleon background: we photograph a WIDE strip of the taskbar (at the
# bar's maximum width), anchored to the right; resizes only crop from it,
# so there is no re-capture and no flicker when the track changes
$script:masterBg   = $null
$script:masterCapX = 0
function Update-ChameleonBackground {
    try {
        $capW = if ($script:maxW) { $script:maxW } else { $form.Width }
        $scr  = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $r    = $form.Left + $form.Width
        $capX = [math]::Max($scr.Left, $r - $capW)
        $bmp  = [System.Drawing.Bitmap]::new($capW, $form.Height)
        $gfx  = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen([System.Drawing.Point]::new($capX, $form.Top), [System.Drawing.Point]::Empty, [System.Drawing.Size]::new($capW, $form.Height))
        $gfx.Dispose()
        if ($script:masterBg) { $script:masterBg.Dispose() }
        $script:masterBg   = $bmp
        $script:masterCapX = $capX
        Apply-ChameleonCrop
    } catch { }
}

# crops from the master photo exactly the part beneath the bar, current width
function Apply-ChameleonCrop {
    try {
        if (-not $script:masterBg) { return }
        $w = $form.Width; $h = $form.Height
        $srcX = $form.Left - $script:masterCapX
        if ($srcX -lt 0) { $srcX = 0 }
        if (($srcX + $w) -gt $script:masterBg.Width) { $srcX = $script:masterBg.Width - $w }
        $bmp = $script:masterBg.Clone([System.Drawing.Rectangle]::new($srcX, 0, $w, $h), $script:masterBg.PixelFormat)
        $old = $form.BackgroundImage
        $form.BackgroundImage = $bmp
        if ($old) { $old.Dispose() }
    } catch { }
}

$toolTip = [System.Windows.Forms.ToolTip]::new()

# --- current track label -------------------------------------------------------
$lbl = [System.Windows.Forms.Label]::new()
$lbl.AutoSize     = $false
$lbl.AutoEllipsis = $false
$lbl.Text         = ''
$lbl.Font         = $textFont
$lbl.ForeColor    = $colText
$lbl.BackColor    = [System.Drawing.Color]::Transparent
$lbl.TextAlign    = 'MiddleLeft'
# the text lives in $script:lastText and is painted by hand (see above)
$lbl.Add_Paint({
    param($s, $e)
    if ($script:lastText) {
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $script:lastText, $textFont, $s.ClientRectangle, $colText, $script:txtFlags)
    }
})
# label height = exactly one text line, vertically centered by position;
# otherwise Windows tries to wrap long titles onto two lines and pushes
# the visible text upward
$lblH = [System.Windows.Forms.TextRenderer]::MeasureText('Ag', $textFont).Height + 2
if ($lblH -gt $btnH) { $lblH = $btnH }
$lblY = [int][math]::Floor(($barH - $lblH) / 2)
$lbl.Location     = [System.Drawing.Point]::new((S 30), $lblY)
$lbl.Size         = [System.Drawing.Size]::new((S 290), $lblH)
$lbl.Anchor       = 'Top, Left, Right'
$form.Controls.Add($lbl)

# --- buttons --------------------------------------------------------------------
function New-GlyphButton([string]$glyph, [int]$x, [int]$w, [int]$h, [int]$y, $font, [string]$tip) {
    $b = [System.Windows.Forms.Button]::new()
    $b.Text      = $glyph
    $b.Font      = $font
    $b.ForeColor = $colText
    $b.BackColor = [System.Drawing.Color]::Transparent
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize         = 0
    $b.FlatAppearance.MouseOverBackColor = $colHover
    $b.FlatAppearance.MouseDownBackColor = $colDown
    $b.Size     = [System.Drawing.Size]::new($w, $h)
    $b.Location = [System.Drawing.Point]::new($x, $y)
    $b.TabStop  = $false
    if ($tip) { $toolTip.SetToolTip($b, $tip) }
    $form.Controls.Add($b)
    return $b
}

$btnPrev  = New-GlyphButton $GLYPH_PREV  (S 328) (S 32) $btnH $btnY $glyphFont ''
$btnPlay  = New-GlyphButton $GLYPH_PLAY  (S 362) (S 32) $btnH $btnY $glyphFont ''
$btnNext  = New-GlyphButton $GLYPH_NEXT  (S 396) (S 32) $btnH $btnY $glyphFont ''

# arrow left of the title: appears only when 2+ players are running at once
$arrowSize = [math]::Min((S 18), $btnH)
$btnMore = New-GlyphButton $GLYPH_UP (S 6) $arrowSize $arrowSize ([int][math]::Floor(($barH - $arrowSize) / 2)) $glyphFontSmall 'Active media'
$btnMore.Visible = $false
$btnMore.Anchor  = 'Top, Left'

$btnPrev.Add_Click({
    $script:lockUntil = $script:tick + 5   # grace: hold the shown source
    if ($script:target) { Send-PlayerCommand $script:target 'prev' }
    elseif ($script:smtcSession) {
        # talk to the exact Windows session first; if it refuses or fails,
        # fall back to the media key (some pages don't support skipping)
        $ok = $false
        try { $ok = [bool](Await ($script:smtcSession.TrySkipPreviousAsync()) $script:asTaskBool) } catch { $ok = $false }
        if (-not $ok) { [MediaNative]::Tap([byte]0xB1) }
    }
    else { [MediaNative]::Tap([byte]0xB1) }                        # VK_MEDIA_PREV_TRACK
    $form.ActiveControl = $null
})
$btnPlay.Add_Click({
    if ($script:target) {
        Send-PlayerCommand $script:target 'playpause'
        $script:target.Playing = -not [bool]$script:target.Playing
    } elseif ($script:smtcSession) {
        $ok = $false
        try { $ok = [bool](Await ($script:smtcSession.TryTogglePlayPauseAsync()) $script:asTaskBool) } catch { $ok = $false }
        if (-not $ok) { [MediaNative]::Tap([byte]0xB3) }
    } else {
        [MediaNative]::Tap([byte]0xB3)                             # VK_MEDIA_PLAY_PAUSE
    }
    # flip the icon optimistically, without waiting for the next refresh
    if ($btnPlay.Text -eq $GLYPH_PLAY) { $btnPlay.Text = $GLYPH_PAUSE } else { $btnPlay.Text = $GLYPH_PLAY }
    $form.ActiveControl = $null
})
$btnNext.Add_Click({
    $script:lockUntil = $script:tick + 5   # grace: hold the shown source
    if ($script:target) { Send-PlayerCommand $script:target 'next' }
    elseif ($script:smtcSession) {
        $ok = $false
        try { $ok = [bool](Await ($script:smtcSession.TrySkipNextAsync()) $script:asTaskBool) } catch { $ok = $false }
        if (-not $ok) { [MediaNative]::Tap([byte]0xB0) }
    }
    else { [MediaNative]::Tap([byte]0xB0) }                        # VK_MEDIA_NEXT_TRACK
    $form.ActiveControl = $null
})

# which apps the wheel is allowed to touch: media players and browsers only,
# never voice/chat apps (Discord, Teams...) or games; extend the list freely
$script:volNames = @(
    'Spotify', 'vlc', 'wmplayer', 'winamp', 'foobar2000', 'MusicBee', 'AIMP',
    'chrome', 'msedge', 'firefox', 'opera', 'brave', 'vivaldi',
    'iTunes', 'Deezer', 'TIDAL', 'Player', 'Music.UI', 'Amazon Music'
)

# mouse wheel over the bar adjusts the volume of whatever is PLAYING right
# now, but only for media apps from the list above (plus the app currently
# shown in the title and any app with a Windows media session); voice apps
# like Discord are never touched. If none of them is actively playing, it
# falls back to the system master volume
$wheel = {
    param($s, $e)
    $steps = [math]::Min(5, [math]::Max(1, [int]([math]::Abs($e.Delta) / 120)))
    $sign  = if ($e.Delta -gt 0) { 1.0 } else { -1.0 }
    $allowed = $script:volNames
    if ($script:smtcNames) { $allowed = $allowed + $script:smtcNames }
    if ($script:target)    { $allowed = $allowed + @($script:target.Name) }
    $done = -1
    try { $done = [AppVolume]::AdjustPlayingSafe([float](0.04 * $steps * $sign), [string[]]$allowed, 400) } catch { }
    if ($done -eq 0) {
        # audio enumerated fine, but no allowed media app is playing:
        # fall back to the system master volume
        $vk = if ($e.Delta -gt 0) { [byte]0xAF } else { [byte]0xAE }   # VOL_UP / VOL_DOWN
        for ($i = 0; $i -lt $steps; $i++) { [MediaNative]::Tap($vk) }
    }
    if ($e -is [System.Windows.Forms.HandledMouseEventArgs]) { $e.Handled = $true }
}
$form.Add_MouseWheel($wheel)
$lbl.Add_MouseWheel($wheel)
$btnPrev.Add_MouseWheel($wheel)
$btnPlay.Add_MouseWheel($wheel)
$btnNext.Add_MouseWheel($wheel)
$btnMore.Add_MouseWheel($wheel)

# anchor the buttons to the right: when the bar width changes, they stay put
$btnPrev.Anchor = 'Top, Right'
$btnPlay.Anchor = 'Top, Right'
$btnNext.Anchor = 'Top, Right'

# adaptive width constants
$script:chromeW   = $form.Width - $lbl.Width      # everything that is not title
$script:maxLabelW = (S 330)
$script:maxW      = $script:chromeW + $script:maxLabelW

# resize the bar to the title, keeping the right edge in place
function Set-BarWidth([string]$text) {
    try {
        $tw = [System.Windows.Forms.TextRenderer]::MeasureText($text, $textFont).Width
        $lw = [math]::Max((S 60), [math]::Min($script:maxLabelW, $tw + (S 8)))
        $newW = $script:chromeW + $lw
        if ($newW -ne $form.Width) {
            $rightEdge = $form.Left + $form.Width
            $form.SetBounds(($rightEdge - $newW), $form.Top, $newW, $form.Height)
            Apply-ChameleonCrop
        }
    } catch { }
}

# change the title: resize and repaint, all in one place
# (no hover tooltip on the title - by design; text is painted by hand)
function Set-Title([string]$t) {
    if ($t -eq $script:lastText) { return }
    Set-BarWidth $t
    $script:lastText = $t
    $lbl.Invalidate()
}

# --- active-players panel: opened by the arrow left of the title ---------------
# reads the sessions defensively (both enumeration and indexed access), since
# the projected WinRT list can be quirky, and always asks Windows for a FRESH
# session manager, because a cached one can serve a stale session list
function Get-SessionList([bool]$fresh) {
    $out = New-Object System.Collections.ArrayList
    if (-not $script:WinRtOk) { return $out }
    try {
        if ($fresh -or -not $script:MediaMgr) {
            $script:MediaMgr = Await ($script:TypeMgr::RequestAsync()) $script:asTaskMgr
        }
        if (-not $script:MediaMgr) { return $out }
        $sessions = $script:MediaMgr.GetSessions()
        if (-not $sessions) { return $out }

        # how many sessions does Windows claim to have?
        $claimed = -1
        try { $claimed = [int]$sessions.Count } catch { try { $claimed = [int]$sessions.Size } catch { } }

        # path 1: explicit enumerator (avoids foreach collection heuristics)
        try {
            $en = $sessions.GetEnumerator()
            while ($en.MoveNext()) { if ($en.Current) { [void]$out.Add($en.Current) } }
        } catch { }

        # path 2: plain foreach, if no enumerator was available
        if ($out.Count -lt 1) {
            try {
                foreach ($s0 in $sessions) {
                    if ($s0 -and -not $s0.Equals($sessions)) { [void]$out.Add($s0) }
                }
            } catch { }
        }

        # path 3: indexed access, if we still got fewer than Windows claims
        if ($claimed -gt $out.Count) {
            $out.Clear()
            for ($j = 0; $j -lt $claimed; $j++) {
                $it = $null
                try { $it = $sessions.get_Item($j) } catch {
                    try { $it = $sessions.Item($j) } catch {
                        try { $it = $sessions.GetAt([uint32]$j) } catch { }
                    }
                }
                if ($it) { [void]$out.Add($it) }
            }
        }
        $script:SessDbg = "claimed=$claimed, collected=$($out.Count)"
    } catch { $script:MediaErr = $_.Exception.Message }
    return $out
}

function Get-SessionAppName($sess) {
    $app = "$($sess.SourceAppUserModelId)"
    if ($app -match '!') { $app = $app.Split('!')[-1] }
    return ($app -replace '\.exe$', '')
}

$script:popup   = $null
$script:popMiss = 0
$script:popupWatch = [System.Windows.Forms.Timer]::new()
$script:popupWatch.Interval = 500
$script:popupWatch.Add_Tick({
    if (-not $script:popup) { $script:popupWatch.Stop(); return }
    $c = [System.Windows.Forms.Cursor]::Position
    $inPopup = $script:popup.Bounds.Contains($c)
    $inArrow = $btnMore.RectangleToScreen($btnMore.ClientRectangle).Contains($c)
    if ($inPopup -or $inArrow) { $script:popMiss = 0 }
    else {
        $script:popMiss++
        if ($script:popMiss -ge 3) { Close-SessionPanel }   # ~1.5s with the mouse away
    }
})

function Close-SessionPanel {
    $script:popupWatch.Stop()
    $script:popMiss = 0
    if ($script:popup) {
        try { $script:popup.Close(); $script:popup.Dispose() } catch { }
        $script:popup = $null
    }
    $btnMore.Text = $GLYPH_UP
}

function Show-SessionPanel {
    Close-SessionPanel
    try {
        # unified list: Windows media sessions + Winamp-style players (deduped)
        # the player already shown in the main title is not repeated here:
        # the three main buttons control it, the panel lists the OTHERS
        $shownAumid = $null
        $shownFb    = $null
        if ($script:srcKey -like 'smtc*' -and $script:smtcSession) {
            try { $shownAumid = "$($script:smtcSession.SourceAppUserModelId)" } catch { }
        } elseif ($script:srcKey -like 'fb:*') {
            $shownFb = $script:srcKey.Substring(3)
        }
        $rows = New-Object System.Collections.ArrayList
        $smtcNames = @()
        foreach ($sess in (Get-SessionList $true)) {
            $aum = ''
            $app = ''
            try {
                $aum = "$($sess.SourceAppUserModelId)"
                $app = Get-SessionAppName $sess
            } catch { continue }
            # still counts for dedupe, even when hidden as the shown one
            $smtcNames += $app
            if ($shownAumid -and $aum -eq $shownAumid) { continue }
            $title = ''
            try {
                $p = Await ($sess.TryGetMediaPropertiesAsync()) $script:asTaskProps
                if ($p -and $p.Title) { $title = $p.Title }
            } catch { }
            $playing = $false
            try { $playing = ($sess.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') } catch { }
            [void]$rows.Add([pscustomobject]@{ Kind = 'smtc'; Session = $sess; Player = $null; App = $app; Title = $title; Playing = $playing })
        }
        foreach ($fp in @(Get-FallbackPlayers)) {
            if ($smtcNames -contains $fp.Name) { continue }
            if ($shownFb -and $fp.Name -eq $shownFb) { continue }
            [void]$rows.Add([pscustomobject]@{ Kind = 'proc'; Session = $null; Player = $fp; App = $fp.Name; Title = $fp.Title; Playing = [bool]$fp.Playing })
        }
        $n = $rows.Count
        if ($n -lt 1) { return }

        $rowH = [math]::Max((S 26), $lblH + (S 8))
        $padV = (S 6)
        # the panel spans the full width of the bar (aligned edge to edge)
        $popW = [math]::Max((S 280), $form.Width)
        $popH = 2 + ($padV * 2) + ($rowH * $n)

        $pop = [System.Windows.Forms.Form]::new()
        $pop.FormBorderStyle = 'None'
        $pop.StartPosition   = 'Manual'
        $pop.TopMost         = $true
        $pop.ShowInTaskbar   = $false
        $pop.BackColor       = $colHover        # acts as a 1 px frame
        $pop.Size            = [System.Drawing.Size]::new($popW, $popH)

        $inner = [System.Windows.Forms.Panel]::new()
        $inner.BackColor = $colBack
        $inner.Location  = [System.Drawing.Point]::new(1, 1)
        $inner.Size      = [System.Drawing.Size]::new(($popW - 2), ($popH - 2))
        $pop.Controls.Add($inner)

        for ($i = 0; $i -lt $n; $i++) {
            $row  = $rows[$i]
            $rowY = $padV + ($i * $rowH)

            # individual pause/play button for this player
            $bp = [System.Windows.Forms.Button]::new()
            $bp.Text      = if ($row.Playing) { $GLYPH_PAUSE } else { $GLYPH_PLAY }
            $bp.Font      = $glyphFont
            $bp.ForeColor = $colText
            $bp.BackColor = $colBack
            $bp.FlatStyle = 'Flat'
            $bp.FlatAppearance.BorderSize         = 0
            $bp.FlatAppearance.MouseOverBackColor = $colHover
            $bp.FlatAppearance.MouseDownBackColor = $colDown
            $bp.Size      = [System.Drawing.Size]::new((S 28), ($rowH - (S 4)))
            $bp.Location  = [System.Drawing.Point]::new((S 6), ($rowY + (S 2)))
            $bp.TabStop   = $false
            $bp.Tag       = $row
            $bp.Add_Click({
                param($ss, $ee)
                try {
                    if ($ss.Tag.Kind -eq 'smtc') {
                        [void](Await ($ss.Tag.Session.TryTogglePlayPauseAsync()) $script:asTaskBool)
                    } else {
                        Send-PlayerPause $ss.Tag.Player
                    }
                } catch { }
                if ($ss.Text -eq $GLYPH_PAUSE) { $ss.Text = $GLYPH_PLAY } else { $ss.Text = $GLYPH_PAUSE }
                try { $ss.FindForm().ActiveControl = $null } catch { }
            })
            $inner.Controls.Add($bp)

            $lr = [System.Windows.Forms.Label]::new()
            $lr.AutoSize     = $false
            $lr.AutoEllipsis = $false
            $lr.Text         = ''
            $lr.Tag          = if ($row.Title) { "$($row.App) - $($row.Title)" } else { $row.App }
            $lr.Font         = $textFont
            $lr.ForeColor    = $colText
            $lr.BackColor    = $colBack
            $lr.TextAlign    = 'MiddleLeft'
            $lr.Add_Paint({
                param($s, $e)
                [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, "$($s.Tag)", $textFont, $s.ClientRectangle, $colText, $script:txtFlags)
            })
            $lr.Location     = [System.Drawing.Point]::new((S 42), ($rowY + [int][math]::Floor(($rowH - $lblH) / 2)))
            $lr.Size         = [System.Drawing.Size]::new(($popW - 2 - (S 50)), $lblH)
            $inner.Controls.Add($lr)
        }

        # position: above the bar, aligned to its left edge, kept on screen
        $sb = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $px = $form.Left
        if (($px + $popW) -gt $sb.Right) { $px = $sb.Right - $popW }
        if ($px -lt $sb.Left) { $px = $sb.Left }
        $py = $form.Top - $popH - (S 6)
        $pop.Location = [System.Drawing.Point]::new($px, $py)

        $pop.Add_Shown({
            param($ss, $ee)
            # WS_EX_TOOLWINDOW (no Alt-Tab) + WS_EX_NOACTIVATE (no focus stealing)
            $ex = [MediaNative]::GetWindowLong($ss.Handle, -20)
            [void][MediaNative]::SetWindowLong($ss.Handle, -20, ($ex -bor 0x80 -bor 0x08000000))
        })

        $script:popup = $pop
        $pop.Show()
        $btnMore.Text = $GLYPH_DOWN
        $script:popMiss = 0
        $script:popupWatch.Start()
    } catch { Close-SessionPanel }
}

$btnMore.Add_Click({
    if ($script:popup) { Close-SessionPanel } else { Show-SessionPanel }
    $form.ActiveControl = $null
})

# --- current track refresh ------------------------------------------------------
$script:busy = $false
$script:lastText    = ''
$script:lastCount   = $null
$script:lastSmtc    = $null
$script:lastPlaying = $null
$script:lastActive  = @()
$script:propsBad    = 0
$script:SessDbg     = ''
$script:CountDbg    = ''
$script:target      = $null
$script:smtcSession = $null
$script:smtcApp     = ''
$script:smtcNames   = @()
$script:lockUntil   = 0
$script:srcKey      = ''
$script:pendKey     = ''
$script:pendTicks   = 0
function Update-Media {
    if ($script:busy) { return }
    $script:busy = $true
    try {
        # insurance only: a brand-new manager every ~30s, in case the cached
        # one ever serves a stale list; everything else reads the cheap cache
        if (($script:tick % 30) -eq 0) { $script:MediaMgr = $null }
        $info = Get-MediaInfo
        $smtc = @(Get-SessionList $false)
        $names = @()
        foreach ($s3 in $smtc) { try { $names += (Get-SessionAppName $s3) } catch { } }
        $script:smtcNames = $names
        $fbs = @(Get-FallbackPlayers)
        # keep the Playing bit fresh every cycle: the scan cache is slower and
        # a stale "playing" flag is exactly what caused the title to flicker;
        # for Winamp the [Paused]/[Stopped] title marker wins over the audio
        # session, which it keeps open even while paused. When no such player
        # is running at all, the audio system is not touched, period.
        if ($fbs.Count -gt 0) {
            $activeNames = @(Get-ActiveAudioNames)
            foreach ($f in $fbs) {
                if ($f.Name -eq 'winamp') { Update-WinampEntry $f }
                $f.Playing = ($activeNames -contains $f.Name) -and (-not $f.PausedHint)
            }
        }
        # candidates, excluding apps already represented by a Windows session
        # (their own session is the authoritative view - never their process)
        $fbPlay = $null; $fbAny = $null
        foreach ($f in $fbs) {
            if ($names -contains $f.Name) { continue }
            if (-not $fbPlay -and $f.Playing) { $fbPlay = $f }
            if (-not $fbAny  -and $f.Title)   { $fbAny  = $f }
        }
        # decide the CANDIDATE source: what is audible first, then paused
        $candKey = 'none'; $candTitle = ' '
        $candTarget = $null; $candPlaying = $false
        if ($info -and $info.Display -and $info.Playing) {
            $candKey = "smtc:$($script:smtcApp)"; $candTitle = $info.Display
            $candPlaying = $true
        } elseif ($fbPlay) {
            $t = if ($fbPlay.Title) { $fbPlay.Title } else { $fbPlay.Name }
            $candKey = "fb:$($fbPlay.Name)"; $candTitle = $t
            $candTarget = $fbPlay; $candPlaying = $true
        } elseif ($info -and $info.Display) {
            $candKey = "smtc:$($script:smtcApp)"; $candTitle = $info.Display
        } elseif ($fbAny) {
            $candKey = "fb:$($fbAny.Name)"; $candTitle = $fbAny.Title
            $candTarget = $fbAny
        }
        # SAFETY NET against ugly flicker: updates within the same source and
        # sources that are audibly PLAYING apply instantly, but a silent
        # source may replace the display only after being the steady
        # candidate for 2 consecutive cycles (~4s) - this bridges the brief
        # audio gap between tracks and the moments right after a pause.
        # On top of that, prev/next on the bar lock the displayed source for
        # a few seconds: mid-transition blips (the current source looks
        # silent for a moment) can no longer let another player hijack the
        # title and the button target
        $apply = $false
        $locked = ($script:tick -lt $script:lockUntil)
        if ($candKey -eq $script:srcKey -or $script:srcKey -eq '') {
            $apply = $true
            $script:pendKey = ''; $script:pendTicks = 0
        } elseif ($locked) {
            $script:pendKey = ''; $script:pendTicks = 0
        } elseif ($candPlaying) {
            $apply = $true
            $script:pendKey = ''; $script:pendTicks = 0
        } else {
            if ($script:pendKey -eq $candKey) { $script:pendTicks++ }
            else { $script:pendKey = $candKey; $script:pendTicks = 1 }
            if ($script:pendTicks -ge 2) {
                $apply = $true
                $script:pendKey = ''; $script:pendTicks = 0
            }
        }
        if ($apply) {
            $script:srcKey = $candKey
            $script:target = $candTarget
            Set-Title $candTitle
            if ($candPlaying) { $btnPlay.Text = $GLYPH_PAUSE } else { $btnPlay.Text = $GLYPH_PLAY }
        }
        # the arrow shows with 2+ players in total (Windows sessions plus
        # Winamp-style players, deduped).
        # NOTE: @( ) is load-bearing - PowerShell unrolls returned lists, and
        # .Count on a bare COM/WinRT object silently yields nothing
        $extra = 0
        $fbNames = @()
        foreach ($fp in $fbs) {
            $fbNames += $fp.Name
            if ($names -notcontains $fp.Name) { $extra++ }
        }
        $script:lastCount = $smtc.Count + $extra
        $script:CountDbg = "smtc=$($smtc.Count) [$($names -join ', ')], players=[$($fbNames -join ', ')], extra=$extra, total=$($script:lastCount)"
        $btnMore.Visible = ($script:lastCount -ge 2)
        if (-not $btnMore.Visible -and $script:popup) { Close-SessionPanel }
    } catch { } finally { $script:busy = $false }
}

# --- visibility: behave exactly like the taskbar --------------------------------
function Update-Visibility {
    # when an app goes full screen (movie, game, F11) we hide, like the taskbar
    $state = 0
    $hr = [MediaNative]::SHQueryUserNotificationState([ref]$state)
    if ($hr -eq 0 -and ($state -eq 2 -or $state -eq 3 -or $state -eq 4)) {
        if ($script:popup) { Close-SessionPanel }
        if ($form.Visible) {
            $form.Hide()
            $timer.Interval = 2000   # slow heartbeat while hidden (gaming etc.)
            [MediaNative]::SetZPin($false)
        }
        return
    }
    if (-not $form.Visible) {
        $timer.Interval = 1000
        Update-ChameleonBackground
        $form.Visible = $true
        [MediaNative]::SetZPin($true)
    }
    # the band is re-measured only every few seconds; it rarely changes
    if ($null -eq $script:cachedY -or ($script:tick % 5) -eq 1) { $script:cachedY = Get-BarY }
    if ($form.Top -ne $script:cachedY) {
        $form.Top = $script:cachedY
        $form.Hide()
        Update-ChameleonBackground
        $form.Show()
    }
    # the Z-order re-pin lives on a native 200ms background thread (see
    # MediaNative.StartZPinner):
    # the shell raises the taskbar above us whenever it gets activated
    # (volume flyout, tray clicks) and a 1s re-pin left the bar buried
}

# periodically release unused memory; pages return only if actually needed
function Optimize-Memory {
    try {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [void][MediaNative]::SetProcessWorkingSetSize([MediaNative]::GetCurrentProcess(), [IntPtr]::new(-1), [IntPtr]::new(-1))
    } catch { }
}

$script:tick    = 0
$script:cachedY = $null
$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 1000
$timer.Add_Tick({
    $script:tick++
    Update-Visibility
    # the track is checked every 2 seconds: just as responsive, half the cost
    if ($form.Visible -and (($script:tick % 2) -eq 0)) { Update-Media }
    # roughly every 5 minutes, trim the residual memory
    if (($script:tick % 300) -eq 0) { Optimize-Memory }
})

# the fast Z-order re-pin runs on a NATIVE background thread (see
# MediaNative.StartZPinner): the shell raises the taskbar above us whenever
# it is activated (volume flyout, tray clicks...) and would bury the bar;
# the native pinner makes any burial imperceptible at zero script cost

# --- mouse dragging (hold the title or the background and drag) -----------------
$script:drag      = $false
$script:dragMoved = $false
$script:dragCur   = [System.Drawing.Point]::new(0, 0)
$script:dragForm  = [System.Drawing.Point]::new(0, 0)

$dragDown = {
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($script:popup) { Close-SessionPanel }
        $script:drag      = $true
        $script:dragMoved = $false
        $script:dragCur   = [System.Windows.Forms.Cursor]::Position
        $script:dragForm  = $form.Location
        $timer.Stop()
        [MediaNative]::SetZPin($false)
    }
}
$dragMove = {
    param($s, $e)
    if ($script:drag) {
        $c = [System.Windows.Forms.Cursor]::Position
        if (-not $script:dragMoved) {
            # a few pixels of jitter still count as a click, not a drag
            if (([math]::Abs($c.X - $script:dragCur.X) + [math]::Abs($c.Y - $script:dragCur.Y)) -le 4) { return }
            $script:dragMoved = $true
            # while dragging we show a plain box; we melt back in on release
            if ($form.BackgroundImage) {
                $img = $form.BackgroundImage
                $form.BackgroundImage = $null
                $img.Dispose()
            }
        }
        $sb = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $nx = $script:dragForm.X + ($c.X - $script:dragCur.X)
        if ($nx -lt $sb.Left) { $nx = $sb.Left }
        if ($nx -gt ($sb.Right - $form.Width)) { $nx = $sb.Right - $form.Width }
        # horizontal only; vertically we stay glued to the taskbar band
        $form.Location = [System.Drawing.Point]::new($nx, (Get-BarY))
    }
}
$dragUp = {
    param($s, $e)
    if ($script:drag) {
        $script:drag = $false
        if ($script:dragMoved) {
            Save-Pos
            $form.Hide()
            Update-ChameleonBackground
            $form.Show()
        }
        $timer.Start()
        [MediaNative]::SetZPin($true)
    }
}
$form.Add_MouseDown($dragDown); $form.Add_MouseMove($dragMove); $form.Add_MouseUp($dragUp)
$lbl.Add_MouseDown($dragDown);  $lbl.Add_MouseMove($dragMove);  $lbl.Add_MouseUp($dragUp)

# --- right-click menu -------------------------------------------------------------
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'MediaBar.lnk'
function Set-Startup([bool]$on) {
    try {
        if ($on) {
            $ws  = New-Object -ComObject WScript.Shell
            $lnk = $ws.CreateShortcut($startupLnk)
            $vbs = Join-Path (Split-Path $PSCommandPath) 'Start MediaBar.vbs'
            if (Test-Path $vbs) {
                # fully silent start, no console window at all
                $lnk.TargetPath = "$env:WINDIR\System32\wscript.exe"
                $lnk.Arguments  = "`"$vbs`""
            } else {
                $lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
                $lnk.Arguments  = "-NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
            }
            $lnk.WorkingDirectory = Split-Path $PSCommandPath
            $lnk.WindowStyle = 7
            $lnk.Save()
        } elseif (Test-Path $startupLnk) {
            Remove-Item $startupLnk -Force
        }
    } catch { }
}

$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$miReset   = $menu.Items.Add('Move back next to the clock')
$miStartup = $menu.Items.Add('Start with Windows')
$miStartup.CheckOnClick = $true
$miStartup.Checked = (Test-Path $startupLnk)
$miDiag = $menu.Items.Add('Media detection status')
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Close MediaBar')

$miReset.Add_Click({
    $sb = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $rightEdge = $sb.Right - (S 240)
    $form.Location = [System.Drawing.Point]::new(($rightEdge - $form.Width), (Get-BarY))
    $form.Hide()
    Update-ChameleonBackground
    $form.Show()
    Save-Pos
})
$miStartup.Add_Click({ Set-Startup $miStartup.Checked })
$miDiag.Add_Click({
    $mgrTxt = 'no'; $sesTxt = 'no'; $app = '-'; $allTxt = '-'
    if ($script:WinRtOk) {
        try {
            $all = @(Get-SessionList $true)
            if ($script:MediaMgr) {
                $mgrTxt = 'yes'
                $s = $script:MediaMgr.GetCurrentSession()
                if ($s) { $sesTxt = 'yes'; $app = $s.SourceAppUserModelId }
            }
            if ($all.Count -gt 0) {
                $names = @()
                foreach ($s2 in $all) {
                    $st = ''
                    try { $st = $s2.GetPlaybackInfo().PlaybackStatus.ToString() } catch { }
                    $names += "$(Get-SessionAppName $s2) [$st]"
                }
                $allTxt = "$($all.Count): $($names -join ', ')"
            } else { $allTxt = '0' }
        } catch { $script:MediaErr = $_.Exception.Message }
    }
    $msg = "WinRT loaded: $(if ($script:WinRtOk) { 'yes' } else { 'no' })`n" +
           "Media manager: $mgrTxt`n" +
           "Active media session: $sesTxt`n" +
           "Detected app: $app`n" +
           "All sessions: $allTxt`n" +
           "Detected players: $(
                $fbs2 = @(Get-FallbackPlayers)
                if ($fbs2.Count -gt 0) { ($fbs2 | ForEach-Object { $_.Name }) -join ', ' } else { '-' }
           )`n" +
           "List read: $(if ($script:SessDbg) { $script:SessDbg } else { '-' })`n" +
           "Arrow logic: $(if ($script:CountDbg) { $script:CountDbg } else { '-' })`n" +
           "Last error: $(if ($script:MediaErr) { $script:MediaErr } else { '-' })`n`n" +
           "Note: VLC 3, classic WMP and Winamp never announce their track" +
           " to Windows; for those, the title is read from the app window."
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'MediaBar - media diagnostics')
})
$miExit.Add_Click({ $form.Close() })

$form.ContextMenuStrip = $menu
$lbl.ContextMenuStrip  = $menu

# --- Windows 11 finishing touches: invisible window, no focus stealing ----------
$form.Add_Shown({
    # no rounded corners and no thin outline drawn by Windows around windows:
    # the bar must be completely invisible
    $pref = 1        # DWMWCP_DONOTROUND
    [void][MediaNative]::DwmSetWindowAttribute($form.Handle, 33, [ref]$pref, 4)
    $noBorder = -2   # DWMWA_BORDER_COLOR = COLOR_NONE
    [void][MediaNative]::DwmSetWindowAttribute($form.Handle, 34, [ref]$noBorder, 4)
    $ex = [MediaNative]::GetWindowLong($form.Handle, -20)
    # WS_EX_TOOLWINDOW (no Alt-Tab) + WS_EX_NOACTIVATE (never steals focus)
    [void][MediaNative]::SetWindowLong($form.Handle, -20, ($ex -bor 0x80 -bor 0x08000000))
    Update-Visibility
    Update-Media
    $timer.Start()
    [MediaNative]::StartZPinner($form.Handle, 200)
    [MediaNative]::SetZPin($true)
    Optimize-Memory
})

$form.Add_FormClosing({
    Close-SessionPanel
    Save-Pos
    $timer.Stop()
    [MediaNative]::StopZPinner()
})

# initial taskbar capture, before the bar becomes visible
Update-ChameleonBackground

[System.Windows.Forms.Application]::Run($form)

} catch {
    try { $_ | Out-String | Set-Content -Path (Join-Path $env:APPDATA 'MediaBar.log') } catch { }
}
