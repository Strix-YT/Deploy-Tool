# HYD Build Deploy - PC direct install helper.
# Started by the tool WITH administrator rights (Program Files + HKLM need them).
# Reads a job file, then: clean the folder -> extract the ZIPs -> check every file -> Touchup.exe -> registry.
# ZIPs are read with Windows' own tar.exe: the .NET ZIP reader in Windows PowerShell 5.1 misreads the
# large (Zip64) EA build ZIPs - it reported 6,916 GB for an 84.7 GB ZIP and would extract bad files.
# Progress goes to a status file the tool reads; creating the cancel file stops it.
param([Parameter(Mandatory = $true)][string]$JobFile)

$ErrorActionPreference = 'Stop'
$job = Get-Content -LiteralPath $JobFile -Raw | ConvertFrom-Json
$st = [ordered]@{ Stage = 'Starting'; Done = [double]0; Total = [double]0; Current = ''; Finished = $false; Ok = $false; Error = ''; Warnings = @() }

# The tool reads the status and log files while this script writes them. Both sides open them with
# shared access, writes retry briefly, and a failed progress / log write never stops the install.
function Write-SharedFile([string]$path, [string]$text, [bool]$append, [int]$tries) {
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)
    for ($i = 0; $i -lt $tries; $i++) {
        try {
            $mode = $(if ($append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::OpenOrCreate })
            $fs = New-Object System.IO.FileStream($path, $mode, [System.IO.FileAccess]::Write, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            try { if (-not $append) { $fs.SetLength(0) }; $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
            return $true
        } catch { Start-Sleep -Milliseconds 100 }
    }
    return $false
}
function Save-Status([int]$tries = 5) { [void](Write-SharedFile $job.StatusFile ($st | ConvertTo-Json -Compress) $false $tries) }
function Log([string]$m) { [void](Write-SharedFile $job.LogFile (('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) + "`r`n") $true 20) }
function Test-Cancel { if (Test-Path -LiteralPath $job.CancelFile) { throw 'Cancelled by user' } }

function Get-TarExe {
    if ($job.TarExe) { return [string]$job.TarExe }
    $w = Join-Path ([string]$env:WINDIR) 'System32\tar.exe'
    if ($env:WINDIR -and (Test-Path -LiteralPath $w)) { return $w }
    throw "Windows tar.exe was not found ($w) - it is part of Windows 10 (1803) and later"
}

function Start-Tar([string]$argText) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-TarExe; $psi.Arguments = $argText
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}

# Files inside a ZIP (directories skipped): Name (as stored, / separators) and Size
function Get-ZipFiles([string]$zip) {
    $p = Start-Tar "-tvf `"$zip`""
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "tar could not read $([System.IO.Path]::GetFileName($zip)): $($errTask.Result.Trim())" }
    $files = New-Object System.Collections.ArrayList
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -notmatch '^(\S)\S*\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\w{3}\s+\d+\s+\S+\s(.+)$') { continue }
        if ($Matches[1] -eq 'd') { continue }
        $name = $Matches[3]
        if ($name -match '(^|[\\/])\.\.([\\/]|$)' -or $name -match '^[\\/]' -or $name -match '^[A-Za-z]:') { throw "unsafe path inside $([System.IO.Path]::GetFileName($zip)): $name" }
        [void]$files.Add([pscustomobject]@{ Name = $name; Size = [double]$Matches[2] })
    }
    return $files
}

try {
    $dest = [System.IO.Path]::GetFullPath([string]$job.InstallDir).TrimEnd('\', '/')
    if (@($dest -split '[\\/]' | Where-Object { $_ }).Count -lt 3) { throw "refusing to install into '$dest' - too close to the drive root" }
    Log "Install folder: $dest"

    # 1. size of everything to extract (read from the ZIP directories)
    $st.Stage = 'Reading the ZIPs'; Save-Status
    $total = [double]0
    $lists = @{}
    foreach ($z in $job.Zips) {
        Test-Cancel
        $lists[[string]$z.Path] = @(Get-ZipFiles ([string]$z.Path))
        $sz = [double](($lists[[string]$z.Path] | Measure-Object Size -Sum).Sum)
        $total += $sz
        Log ("{0}: {1} files, {2:N1} GB" -f $z.Name, $lists[[string]$z.Path].Count, ($sz / 1GB))
    }
    $st.Total = $total; Save-Status

    # 2. clean install: empty the folder (the folder itself is kept)
    if ($job.Clean -and (Test-Path -LiteralPath $dest)) {
        $st.Stage = 'Removing the old build'; Save-Status
        Log 'Clean install: removing the previous build'
        Get-ChildItem -LiteralPath $dest -Force | Remove-Item -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    # 3. extract with tar, main game first then each DLC. tar prints "x <name>" when a file is done;
    #    the file being written is the next one in the list, so its size on disk gives live progress.
    $done = [double]0
    foreach ($z in $job.Zips) {
        Test-Cancel
        $st.Stage = "Extracting $($z.Name)"; $st.Current = [string]$z.Name; Save-Status
        Log "Extracting $($z.Path)"
        $files = $lists[[string]$z.Path]
        $sizeOf = @{}; foreach ($f in $files) { $sizeOf[$f.Name] = $f.Size }
        $idx = 0; $zipDone = [double]0; $errs = New-Object System.Collections.ArrayList
        $p = Start-Tar "-xvf `"$($z.Path)`" -C `"$dest`""
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $lineTask = $p.StandardError.ReadLineAsync()
        try {
            while ($true) {
                if ($lineTask.Wait(700)) {
                    $line = $lineTask.Result
                    if ($null -eq $line) { break }
                    if ($line -match '^x (.+?)(: .*)?$' -and -not $Matches[2]) {
                        $n = $Matches[1]
                        if ($sizeOf.ContainsKey($n)) { $zipDone += $sizeOf[$n]; $sizeOf.Remove($n) }
                    } elseif ($line.Trim()) { [void]$errs.Add($line.Trim()) }
                    $lineTask = $p.StandardError.ReadLineAsync()
                }
                while ($idx -lt $files.Count -and -not $sizeOf.ContainsKey($files[$idx].Name)) { $idx++ }
                $cur = [double]0
                if ($idx -lt $files.Count) { try { $fi = New-Object System.IO.FileInfo((Join-Path $dest $files[$idx].Name)); if ($fi.Exists) { $cur = [double]$fi.Length } } catch {} }
                $st.Done = $done + $zipDone + [math]::Min($cur, [double]$files[[math]::Min($idx, [math]::Max(0, $files.Count - 1))].Size)
                Save-Status
                if (Test-Path -LiteralPath $job.CancelFile) { try { $p.Kill() } catch {}; throw 'Cancelled by user' }
            }
            $p.WaitForExit()
        } finally { if (-not $p.HasExited) { try { $p.Kill() } catch {} } }
        if ($p.ExitCode -ne 0) { throw ("tar could not extract $($z.Name): " + $(if ($errs.Count) { ($errs | Select-Object -Last 3) -join ' | ' } else { "exit code $($p.ExitCode)" })) }

        # every file must be there at the size the ZIP lists
        $bad = @($files | Where-Object { $fi = New-Object System.IO.FileInfo((Join-Path $dest $_.Name)); -not $fi.Exists -or [double]$fi.Length -ne $_.Size })
        # tar.exe prints accented / non-English letters in names in another encoding ("tecnico" with
        # an accent came out as "tÕcnico"), so those names cannot be looked up directly. For them,
        # find the file on disk with the odd letters as wildcards and require the exact size.
        $odd = '(?:[^\x20-\x7E]|\?)+'
        $unsure = @($bad | Where-Object { $_.Name -match $odd })
        $bad = @($bad | Where-Object { $_.Name -notmatch $odd })
        if ($unsure.Count) {
            $disk = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force | ForEach-Object { [pscustomobject]@{ Rel = $_.FullName.Substring($dest.Length + 1).Replace('\', '/'); Size = [double]$_.Length } })
            foreach ($f in $unsure) {
                $rx = '^' + ((($f.Name -split "($odd)") | ForEach-Object { if ($_ -match "^$odd$") { '.+' } else { [regex]::Escape($_) } }) -join '') + '$'
                $hit = @($disk | Where-Object { $_.Size -eq $f.Size -and $_.Rel -match $rx } | Select-Object -First 1)
                if ($hit.Count) { Log "Checked by size (tar shows this name differently): $($hit[0].Rel)" } else { $bad += $f }
            }
        }
        if ($bad.Count) { throw "$($bad.Count) file(s) from $($z.Name) are missing or the wrong size after extraction, e.g. $($bad[0].Name)" }
        $done += [double](($files | Measure-Object Size -Sum).Sum)
        $st.Done = $done; Save-Status
        Log "Extracted and checked $($z.Name) ($($files.Count) files)"
    }

    # 4. Touchup.exe from the build, if it has one
    $tc = $job.Touchup
    if ($tc -and $tc.Enabled) {
        $tu = $null
        foreach ($rel in @($tc.Paths)) { $p = Join-Path $dest ([string]$rel); if (Test-Path -LiteralPath $p) { $tu = $p; break } }
        if ($tu) {
            $st.Stage = 'Running Touchup.exe'; Save-Status
            $targs = ([string]$tc.Args).Replace('{InstallDir}', $dest)
            Log "Touchup: `"$tu`" $targs"
            $sp = @{ FilePath = $tu; ArgumentList = $targs; WorkingDirectory = (Split-Path -Parent $tu); PassThru = $true }
            if ($env:OS -eq 'Windows_NT') { $sp.WindowStyle = 'Hidden' }
            # a Touchup problem is a warning: the files are in place and the registry step still runs
            try {
                $proc = Start-Process @sp
                $limit = [int]$tc.TimeoutSec; if ($limit -le 0) { $limit = 120 }
                if (-not $proc.WaitForExit($limit * 1000)) {
                    try { $proc.Kill() } catch {}
                    $st.Warnings += "Touchup.exe did not finish within $limit s and was stopped"
                    Log "Touchup did not finish within $limit s - stopped"
                } else {
                    Log "Touchup exit code $($proc.ExitCode)"
                    if ($proc.ExitCode -ne 0) { $st.Warnings += "Touchup.exe finished with exit code $($proc.ExitCode)" }
                }
            } catch {
                $st.Warnings += "Touchup.exe could not run: $($_.Exception.Message)"
                Log "Touchup could not run: $($_.Exception.Message)"
            }
        } else { Log 'No Touchup.exe in this build - skipped' }
    }

    # 5. registry: tells Windows and the EA app where the game is installed
    $regs = @($job.Registry)
    if ($regs.Count) {
        $st.Stage = 'Writing registry'; Save-Status
        foreach ($r in $regs) {
            $key = 'Registry::' + (([string]$r.Key) -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\' -replace '^HKCU\\', 'HKEY_CURRENT_USER\')
            $val = ([string]$r.Value).Replace('{InstallDir}', $dest)
            if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
            New-ItemProperty -LiteralPath $key -Name ([string]$r.Name) -Value $val -PropertyType String -Force | Out-Null
            Log "Registry: $($r.Key)  [$($r.Name)] = $val"
        }
    }

    $st.Stage = 'Done'; $st.Ok = $true
    Log 'Install finished'
} catch {
    $st.Error = $_.Exception.Message
    Log "STOPPED: $($_.Exception.Message)"
} finally {
    $st.Finished = $true
    Save-Status 100
}
