# HYD Build Deploy helper: stops running console programs the clean way (used by Stop recording for PS5).
#   HYD_CtrlC.ps1 -Ids 1234,5678         sends Ctrl+C  ("prospero-ctrl target video" closes its file on Ctrl+C)
param([string]$Ids)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HydCtrlC {
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint dwProcessId);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);
}
'@
$sent = 0
foreach ($id in ($Ids -split ',')) {
    $id = $id.Trim()
    if (-not $id) { continue }
    [void][HydCtrlC]::FreeConsole()
    if ([HydCtrlC]::AttachConsole([uint32]$id)) {
        # this helper shares the program's console now - make it ignore the Ctrl+C it is about to send
        [void][HydCtrlC]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
        if ([HydCtrlC]::GenerateConsoleCtrlEvent(0, 0)) { $sent++ }
        Start-Sleep -Milliseconds 300
    }
}
[void][HydCtrlC]::FreeConsole()
exit $(if ($sent) { 0 } else { 1 })
