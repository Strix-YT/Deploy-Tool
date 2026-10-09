@echo off
rem Starts HYD Build Deploy without a console window.
rem If the tool will not start, run START_HYD_BUILD_DEPLOY_debug.cmd to see the full error.
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -Command "try { & '%~dp0HYD_Build_Deploy_GUI.ps1' } catch { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show(('HYD Build Deploy could not start:' + [char]10 + [char]10 + $_.Exception.Message + [char]10 + [char]10 + 'Run START_HYD_BUILD_DEPLOY_debug.cmd to see the details.'), 'HYD Build Deploy', 'OK', 'Error') }"
