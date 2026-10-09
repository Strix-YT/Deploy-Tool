# HYD Build Deploy helper: records live video from one Xbox kit with the GDK's own capture function
# (XtfCaptureLiveVideo in XtfConsoleControl.dll - the one behind Xbox Manager's red RECORD button).
# Stop: the Build Deploy tool sets the named event -StopEvent; the capture then finishes the .mp4 properly
# (index written, plays everywhere) - no Ctrl+C, nothing to repair.
# If the tool is closed / crashes (-ParentPid gone), the recording is stopped the same clean way.
#
# Usage: HYD_XboxRecord.ps1 -IP <kit> -File <mp4> -Seconds <max length, 6-21600> -StopEvent <name> [-Bin <GDK bin>] [-ParentPid <pid>]
# Output: STARTED, then RESULT|OK|<what> or RESULT|FAIL|<why> (exit code 0 / 1)
param([string]$IP, [string]$File, [int]$Seconds = 21600, [string]$StopEvent, [string]$Bin = '', [int]$ParentPid = 0)

function Done([string]$kind, [string]$msg) { try { [Console]::Out.WriteLine("RESULT|$kind|$msg"); [Console]::Out.Flush() } catch {}; [Environment]::Exit($(if ($kind -eq 'FAIL') { 1 } else { 0 })) }

if (-not $IP -or -not $File -or -not $StopEvent) { Done 'FAIL' 'usage: -IP -File -StopEvent are needed' }
if (-not [Environment]::Is64BitProcess) { Done 'FAIL' 'needs 64-bit PowerShell (the GDK capture DLL is 64-bit)' }
if (-not $Bin) { $Bin = Join-Path $(if ($env:GameDK) { $env:GameDK.TrimEnd('\') } else { Join-Path ${env:ProgramFiles(x86)} 'Microsoft GDK' }) 'bin' }
if (-not (Test-Path -LiteralPath (Join-Path $Bin 'XtfConsoleControl.dll'))) { Done 'FAIL' "XtfConsoleControl.dll not found in $Bin (GDK not installed there?)" }
$Seconds = [Math]::Max(6, [Math]::Min(21600, $Seconds))

$src = @'
using System;
using System.Threading;
using System.Runtime.InteropServices;
public static class HydXtfRec {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SetDllDirectory(string path);
    [DllImport("XtfConsoleControl.dll", CharSet = CharSet.Unicode)]
    static extern int XtfCaptureLiveVideo(string address, string fullFileName, uint numSeconds, IntPtr hEvent, IntPtr hOtherEvent);
    [DllImport("XtfApi.dll", CharSet = CharSet.Unicode)]
    static extern int XtfGetErrorText(int hr, System.Text.StringBuilder msg, ref uint msgLen, System.Text.StringBuilder action, ref uint actionLen);
    public static string ErrorText(int hr) {
        try { var m = new System.Text.StringBuilder(1024); var a = new System.Text.StringBuilder(1024); uint ml = 1024, al = 1024;
              if (XtfGetErrorText(hr, m, ref ml, a, ref al) >= 0) return (m.ToString() + " " + a.ToString()).Trim(); } catch { }
        return "";
    }
    public static volatile bool Done; public static int Hr; public static string Error = "";
    // runs the capture on its own thread; it returns when the time is up or an event is set
    public static void Start(string address, string file, uint seconds, EventWaitHandle stop1, EventWaitHandle stop2) {
        IntPtr h1 = stop1.SafeWaitHandle.DangerousGetHandle(), h2 = stop2.SafeWaitHandle.DangerousGetHandle();
        var t = new Thread(() => {
            try { Hr = XtfCaptureLiveVideo(address, file, seconds, h1, h2); } catch (Exception e) { Error = e.GetType().Name + ": " + e.Message; Hr = -1; }
            Done = true;
        });
        t.IsBackground = true; t.Start();
    }
}
'@
try { Add-Type -TypeDefinition $src -Language CSharp -IgnoreWarnings -ErrorAction Stop } catch { Done 'FAIL' "could not load the capture code: $($_.Exception.Message)" }
[void][HydXtfRec]::SetDllDirectory($Bin)

# the stop signal the tool sets (named, so another process can set it). The capture takes a second event
# handle too; it is passed but never set.
$created = $false
$stop1 = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $StopEvent, [ref]$created)
$stop2 = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset)

$dir = Split-Path -Parent $File
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$t0 = Get-Date
[HydXtfRec]::Start($IP, $File, [uint32]$Seconds, $stop1, $stop2)
[Console]::Out.WriteLine('STARTED'); [Console]::Out.Flush()

$stopSeen = $null; $how = 'time limit reached'
while (-not [HydXtfRec]::Done) {
    Start-Sleep -Milliseconds 200
    if (-not $stopSeen -and $ParentPid -gt 0) {
        $alive = $true; try { $pp = Get-Process -Id $ParentPid -ErrorAction Stop; $alive = -not $pp.HasExited } catch { $alive = $false }
        if (-not $alive) { [void]$stop1.Set(); $how = 'the Build Deploy tool closed' }
    }
    if (-not $stopSeen -and $stop1.WaitOne(0)) { $stopSeen = Get-Date; if ($how -eq 'time limit reached') { $how = 'stopped' } }
}
$secs = [int]((Get-Date) - $t0).TotalSeconds
$hr = [HydXtfRec]::Hr
if ($hr -lt 0) {
    $txt = [HydXtfRec]::ErrorText($hr)
    Done 'FAIL' ("0x{0:X8} {1} {2}" -f $hr, $txt, [HydXtfRec]::Error).Trim()
}
Done 'OK' "$how after $secs s"
