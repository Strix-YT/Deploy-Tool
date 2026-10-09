Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Stop'
$base       = Split-Path -Parent $MyInvocation.MyCommand.Path
$csvPath    = Join-Path $base 'Consoles.csv'
$configPath = Join-Path $base 'DeployConfig.json'
$logDir     = Join-Path $base 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$script:consoles = @()
$script:cfg      = $null
$script:Jobs     = @()
$script:Pool     = $null
$script:RunStamp = ''

# Shared state between the UI thread and the background deploy workers
$sync = [hashtable]::Synchronized(@{
    Rows   = [hashtable]::Synchronized(@{})
    Log    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    Cancel = $false
    Asks    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'   # worker -> UI questions
    Answers = [hashtable]::Synchronized(@{})                                         # UI -> worker answers
})

# ---------------------------------------------------------------- config

function Load-Config {
    if (-not (Test-Path $configPath)) { throw "DeployConfig.json was not found: $configPath" }
    $script:cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
}

function Get-PlatformKey([string]$platform) {
    $p = ([string]$platform -replace '[\s\-_|]','').ToUpperInvariant()
    if ($p -match '^(XBOX|XBSX|XSX|XSS|XBS|SERIESX|SERIESS|SCARLETT)') { return 'Xbox' }
    if ($p -match '^(PS5|PROSPERO)') { return 'PS5' }
    return $null
}

# A step in DeployConfig.json is either one {Exe,Args} or a list of them run in order.
function Get-StepDefs([string]$pkey,[string]$stepName) {
    $p = $script:cfg.$pkey
    if (-not $p) { return @() }
    $raw = $p.Steps.$stepName
    if (-not $raw) { return @() }
    $defs = @()
    foreach ($s in @($raw)) {
        if (-not $s -or [string]::IsNullOrWhiteSpace([string]$s.Exe)) { continue }
        $exe = [string]$s.Exe
        if (-not [System.IO.Path]::IsPathRooted($exe)) { $exe = [System.IO.Path]::Combine([string]$p.ToolDir, $exe) }
        $defs += ,@{ Exe = $exe; Args = [string]$s.Args; OkOutput = [string]$s.OkOutput; NotFoundOutput = [string]$s.NotFoundOutput }
    }
    return $defs
}
function Get-StepDef([string]$pkey,[string]$stepName) {
    $d = @(Get-StepDefs $pkey $stepName)
    if ($d.Count -eq 0) { return $null }
    return $d[0]
}

function Expand-Template([string]$template,[hashtable]$values,[string]$context) {
    $out = $template
    foreach ($m in [regex]::Matches($template,'\{([A-Za-z0-9_]+)\}')) {
        $key = $m.Groups[1].Value
        if (-not $values.ContainsKey($key)) { throw "$context uses {$key}, which is not defined." }
        if ([string]::IsNullOrWhiteSpace([string]$values[$key])) {
            # optional placeholders: empty = left out (no launch parameters, no time limit, no extra options)
            if ($key -in @('LaunchArgs','Length','Options')) { $out = [regex]::Replace($out, '\s*\{' + $key + '\}', ''); continue }
            throw "$context needs {$key}, but it is empty. Set it in DeployConfig.json."
        }
        $out = $out.Replace('{' + $key + '}', [string]$values[$key])
    }
    return $out
}

function Get-ToolSummary {
    $parts = @()
    foreach ($pkey in 'Xbox','PS5') {
        $deployReady = (Get-StepDef $pkey 'DeployLoose') -or (Get-StepDef $pkey 'InstallPackage')
        $tool = Get-StepDef $pkey 'Reboot'
        $toolOk = $tool -and (Test-Path -LiteralPath $tool.Exe)
        $t = "{0} tools: {1}" -f $pkey, $(if ($toolOk) { 'OK' } else { 'NOT FOUND' })
        if (-not $deployReady) { $t += " | $pkey deploy: NOT CONFIGURED" }
        $parts += $t
    }
    return ($parts -join ' | ')
}

# ---------------------------------------------------------------- logging

function Write-Log($name,$platform,$ip,$action,$result,$details) {
    $file = Join-Path $logDir ("ConsoleLog_{0}.csv" -f (Get-Date -Format 'yyyyMMdd'))
    if (-not (Test-Path $file)) { 'Timestamp,Name,Platform,IP,Action,Result,Details' | Out-File -FilePath $file -Encoding UTF8 }
    $safe = ([string]$details -replace '"','""')
    '"{0}","{1}","{2}","{3}","{4}","{5}","{6}"' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$name,$platform,$ip,$action,$result,$safe | Add-Content -Path $file -Encoding UTF8
}

function Append-UiLog([string]$line) {
    $txtLog.AppendText($line + [Environment]::NewLine)
}

# ---------------------------------------------------------------- form

$form = New-Object System.Windows.Forms.Form
$form.Text = 'HYD PS5 + Xbox Build Deploy'
$form.Size = New-Object System.Drawing.Size(1280,960)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1000,720)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'HYD PS5 + Xbox Build Deploy'
$title.Font = New-Object System.Drawing.Font('Segoe UI',16,[System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20,12)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Loose folder or package | parallel deploy | optional reboot before and launch after'
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(22,45)
$form.Controls.Add($subtitle)

function New-Button([string]$text,[int]$x,[int]$y,[int]$w,[string]$anchor='Bottom,Left',$parent=$form) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Size = New-Object System.Drawing.Size($w,34)
    $b.Location = New-Object System.Drawing.Point($x,$y)
    $b.Anchor = $anchor
    $parent.Controls.Add($b)
    return $b
}

function New-Label([string]$text,[int]$x,[int]$y,$parent) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point($x,$y)
    $parent.Controls.Add($l)
    return $l
}

# --- Build library strip (shared): Branch / Config / Build. The platform comes from the visible tab.
[void](New-Label 'Branch:' 22 72 $form)
$cmbStream = New-Object System.Windows.Forms.ComboBox
$cmbStream.DropDownStyle = 'DropDownList'
$cmbStream.Location = New-Object System.Drawing.Point(72,68)
$cmbStream.Size = New-Object System.Drawing.Size(150,24)
$form.Controls.Add($cmbStream)
[void](New-Label 'Config:' 232 72 $form)
$cmbConfig = New-Object System.Windows.Forms.ComboBox
$cmbConfig.DropDownStyle = 'DropDownList'
$cmbConfig.Location = New-Object System.Drawing.Point(282,68)
$cmbConfig.Size = New-Object System.Drawing.Size(135,24)
$form.Controls.Add($cmbConfig)
[void](New-Label 'Build:' 428 72 $form)
$cmbBuild = New-Object System.Windows.Forms.ComboBox
$cmbBuild.DropDownStyle = 'DropDownList'
$cmbBuild.Location = New-Object System.Drawing.Point(470,68)
$cmbBuild.Size = New-Object System.Drawing.Size(480,24)
$cmbBuild.DropDownWidth = 640
$cmbBuild.Anchor = 'Top,Left,Right'
$form.Controls.Add($cmbBuild)
$btnScan = New-Button 'Scan' 958 64 70 'Top,Right'
$btnUseBuild = New-Button 'Use This Build' 1034 64 120 'Top,Right'
$chkRmOnly = New-Object System.Windows.Forms.CheckBox
$chkRmOnly.Text = 'RM only'
$chkRmOnly.AutoSize = $true
$chkRmOnly.Checked = $true
$chkRmOnly.Location = New-Object System.Drawing.Point(1164,72)
$chkRmOnly.Anchor = 'Top,Right'
$form.Controls.Add($chkRmOnly)

# --- Tabs: one per platform. Controls inside the tabs are positioned by Layout-XboxPage /
#     Layout-PS5Page (called on resize), so they never depend on the tab's initial size.
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(20,102)
$tabs.Size = New-Object System.Drawing.Size(1225,440)
$tabs.Anchor = 'Top,Bottom,Left,Right'
$tabXbox = New-Object System.Windows.Forms.TabPage
$tabXbox.Text = '  Xbox Series X|S  '
$tabXbox.UseVisualStyleBackColor = $true
$tabPS5 = New-Object System.Windows.Forms.TabPage
$tabPS5.Text = '  PS5  '
$tabPS5.UseVisualStyleBackColor = $true
$tabs.TabPages.Add($tabXbox)
$tabs.TabPages.Add($tabPS5)
$tabPC = New-Object System.Windows.Forms.TabPage
$tabPC.Text = '  PC (EA app)  '
$tabPC.UseVisualStyleBackColor = $true
$tabs.TabPages.Add($tabPC)
$form.Controls.Add($tabs)

function Add-TextColumn([string]$name,[string]$header,[int]$width) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $name; $c.HeaderText = $header; $c.Width = $width
    return $c
}
function New-ConsoleGrid([bool]$withAlwaysOn) {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.ReadOnly = $false                 # only the tick-box column is editable (others set read-only below)
    $g.SelectionMode = 'FullRowSelect'
    $g.MultiSelect = $false
    $g.AutoGenerateColumns = $false
    $g.RowHeadersVisible = $false
    $g.ColumnHeadersHeightSizeMode = 'AutoSize'
    $g.BackgroundColor = [System.Drawing.SystemColors]::Window
    $g.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(205,225,248)
    $g.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black
    $sel = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $sel.Name = 'Sel'; $sel.HeaderText = ''; $sel.Width = 32; $sel.ReadOnly = $false
    [void]$g.Columns.Add($sel)
    [void]$g.Columns.Add((Add-TextColumn 'Name' 'Name' 140))
    [void]$g.Columns.Add((Add-TextColumn 'IP' 'IP Address' 115))
    [void]$g.Columns.Add((Add-TextColumn 'Enabled' 'Enabled' 60))
    [void]$g.Columns.Add((Add-TextColumn 'Idle' 'Idle' 45))
    if ($withAlwaysOn) { [void]$g.Columns.Add((Add-TextColumn 'AlwaysOn' 'AlwaysOn' 70)) }
    [void]$g.Columns.Add((Add-TextColumn 'Status' 'Status' 110))
    [void]$g.Columns.Add((Add-TextColumn 'Step' 'Step' 130))
    [void]$g.Columns.Add((Add-TextColumn 'Progress' 'Progress / last output' 320))
    [void]$g.Columns.Add((Add-TextColumn 'Result' 'Result' 90))
    [void]$g.Columns.Add((Add-TextColumn 'Notes' 'Notes' 170))
    foreach ($col in $g.Columns) { if ($col.Name -ne 'Sel') { $col.ReadOnly = $true } }
    $g.Columns['Progress'].AutoSizeMode = 'Fill'

    # tick-box: apply a click on the box immediately (not when the cell loses focus)
    $g.Add_CurrentCellDirtyStateChanged({ if ($this.IsCurrentCellDirty) { [void]$this.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) } })
    $g.Add_CellValueChanged({ param($sender, $e) if ($e.RowIndex -ge 0 -and $sender.Columns[$e.ColumnIndex].Name -eq 'Sel') { Paint-Ticked $sender.Rows[$e.RowIndex]; if (-not $script:BulkTick) { Update-TabTitles } } })
    # click anywhere on a row ticks / unticks it; Shift-click ticks every shown row between the last click and this one
    $g.Add_CellClick({
        param($sender, $e)
        if ($e.RowIndex -lt 0 -or $sender.Columns[$e.ColumnIndex].Name -eq 'Sel') { $sender.Tag = $e.RowIndex; return }
        $row = $sender.Rows[$e.RowIndex]
        $last = $sender.Tag
        if (([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) -and $last -is [int] -and $last -ge 0 -and $last -lt $sender.Rows.Count) {
            $a = [math]::Min($last, $e.RowIndex); $b = [math]::Max($last, $e.RowIndex)
            $script:BulkTick = $true
            try { for ($i = $a; $i -le $b; $i++) { if ($sender.Rows[$i].Visible) { $sender.Rows[$i].Cells['Sel'].Value = $true } } } finally { $script:BulkTick = $false }
            Update-TabTitles
        } else {
            $row.Cells['Sel'].Value = -not [bool]$row.Cells['Sel'].Value
        }
        $sender.Tag = $e.RowIndex
    })
    # Space ticks / unticks the highlighted row
    $g.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq 'Space' -and $sender.CurrentRow -and $sender.CurrentCell.OwningColumn.Name -ne 'Sel') {
            $sender.CurrentRow.Cells['Sel'].Value = -not [bool]$sender.CurrentRow.Cells['Sel'].Value
            $e.Handled = $true
        }
    })
    return $g
}

# ticked rows get a light tint so they stand out even when another row is highlighted
function Paint-Ticked($row) {
    $row.DefaultCellStyle.BackColor = $(if ([bool]$row.Cells['Sel'].Value) { [System.Drawing.Color]::FromArgb(226,239,218) } else { [System.Drawing.Color]::Empty })
}

# --- Xbox tab
$lblXboxBuild = New-Label 'Xbox build:' 8 14 $tabXbox
$txtXbox = New-Object System.Windows.Forms.TextBox
$tabXbox.Controls.Add($txtXbox)
$btnXboxFolder = New-Button 'Folder...' 0 0 85 'Top,Left' $tabXbox
$btnXboxPkg    = New-Button 'Package...' 0 0 90 'Top,Left' $tabXbox
$lblXboxMode = New-Label '' 0 14 $tabXbox
$gridXbox = New-ConsoleGrid $true
$tabXbox.Controls.Add($gridXbox)
$lblAo = New-Label 'AlwaysOn (selected):' 8 0 $tabXbox
$btnAoOn   = New-Button 'On' 0 0 55 'Top,Left' $tabXbox
$btnAoOff  = New-Button 'Off' 0 0 55 'Top,Left' $tabXbox
$btnAoRead = New-Button 'Read' 0 0 60 'Top,Left' $tabXbox
$btnXbLaunch = New-Button 'Launch game...' 0 0 120 'Top,Left' $tabXbox
$btnXbShot     = New-Button 'Screenshot' 0 0 90 'Top,Left' $tabXbox
$btnXbClip     = New-Button 'Save last 90 s' 0 0 110 'Top,Left' $tabXbox
$btnXbRec      = New-Button 'Record...' 0 0 80 'Top,Left' $tabXbox
$btnXbRecStop  = New-Button 'Stop recording' 0 0 130 'Top,Left' $tabXbox
$btnXbCaptures = New-Button 'Captures' 0 0 75 'Top,Left' $tabXbox
$btnXbRec.ForeColor = [System.Drawing.Color]::DarkRed
$btnXbRecStop.Enabled = $false
$lblXbLaunch = New-Label '' 0 0 $tabXbox
$lblXbLaunch.ForeColor = [System.Drawing.Color]::DimGray
$lblXbLaunch.AutoSize = $false; $lblXbLaunch.AutoEllipsis = $true

function Layout-XboxPage {
    $w = $tabXbox.ClientSize.Width; $h = $tabXbox.ClientSize.Height
    if ($w -lt 500 -or $h -lt 200) { return }
    $txtXbox.SetBounds(85, 10, $w - 85 - 320, 24)
    $btnXboxFolder.SetBounds($w - 228 - 92, 6, 85, 32)
    $btnXboxPkg.SetBounds($w - 228, 6, 90, 32)
    $lblXboxMode.Location = New-Object System.Drawing.Point(($w - 132), 14)
    $gridXbox.SetBounds(8, 46, $w - 16, $h - 46 - 46)
    $y = $h - 40
    $lblAo.Location = New-Object System.Drawing.Point(8, ($y + 9))
    $btnAoOn.SetBounds(145, $y, 55, 32)
    $btnAoOff.SetBounds(206, $y, 55, 32)
    $btnAoRead.SetBounds(267, $y, 60, 32)
    $btnXbLaunch.SetBounds(345, $y, 120, 32)
    $btnXbShot.SetBounds(471, $y, 90, 32)
    $btnXbClip.SetBounds(567, $y, 110, 32)
    $btnXbRec.SetBounds(683, $y, 80, 32)
    $btnXbRecStop.SetBounds(769, $y, 130, 32)
    $btnXbCaptures.SetBounds(905, $y, 75, 32)
    $lblXbLaunch.SetBounds(988, ($y + 9), [math]::Max(100, $w - 996), 20)
}

# --- PS5 tab
#   Row 1:  ( ) Install packages   ( ) Deploy loose folder   <what will deploy>      [x] Connect   [Add PS5 kits to TM]
#   Row 2:  [ Packages: Main + DLC list ]   [ Loose build: folder + workspace ]
#   Grid
$rbPkg = New-Object System.Windows.Forms.RadioButton
$rbPkg.Text = 'Install packages (main + DLC)'
$rbPkg.AutoSize = $true
$rbPkg.Checked = $true
$tabPS5.Controls.Add($rbPkg)
$rbLoose = New-Object System.Windows.Forms.RadioButton
$rbLoose.Text = 'Deploy loose folder'
$rbLoose.AutoSize = $true
$tabPS5.Controls.Add($rbLoose)
$lblPS5Mode = New-Label '' 0 14 $tabPS5
$lblPS5Mode.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$chkConnect = New-Object System.Windows.Forms.CheckBox
$chkConnect.Text = 'Connect before deploy'
$chkConnect.AutoSize = $true
$chkConnect.Checked = $true
$tabPS5.Controls.Add($chkConnect)
$chkForceOwn = New-Object System.Windows.Forms.CheckBox
$chkForceOwn.Text = 'Take ownership if needed (asks first)'
$chkForceOwn.AutoSize = $true
$chkForceOwn.Checked = $false
$chkForceOwn.ForeColor = [System.Drawing.Color]::DarkRed
$tabPS5.Controls.Add($chkForceOwn)
$btnTmSync = New-Button 'Add PS5 kits to Target Manager' 0 0 215 'Top,Left' $tabPS5

# Packages box: one main package + any number of DLC packages, each from any folder
$grpPkgs = New-Object System.Windows.Forms.GroupBox
$grpPkgs.Text = 'Packages (each file can come from a different folder)'
$tabPS5.Controls.Add($grpPkgs)
$lblMainL = New-Label 'Main:' 10 30 $grpPkgs
$txtMain = New-Object System.Windows.Forms.TextBox
$grpPkgs.Controls.Add($txtMain)
$btnMainBrowse = New-Button 'Browse...' 0 0 90 'Top,Left' $grpPkgs
$btnMainClear  = New-Button 'Clear' 0 0 72 'Top,Left' $grpPkgs
$lblDlcL = New-Label 'DLC:' 10 66 $grpPkgs
$lstDlc = New-Object System.Windows.Forms.ListBox
$lstDlc.SelectionMode = 'MultiExtended'
$lstDlc.HorizontalScrollbar = $true
$lstDlc.IntegralHeight = $false
$lstDlc.AllowDrop = $true
$grpPkgs.Controls.Add($lstDlc)
$btnDlcAdd    = New-Button 'Add DLC(s)...' 0 0 166 'Top,Left' $grpPkgs
$btnDlcRemove = New-Button 'Remove' 0 0 90 'Top,Left' $grpPkgs
$btnDlcClear  = New-Button 'Clear' 0 0 72 'Top,Left' $grpPkgs
$lblPkgInfo = New-Label 'Pick the main package and/or add DLC packages' 55 138 $grpPkgs
$lblPkgInfo.ForeColor = [System.Drawing.Color]::DimGray
$txtMain.AllowDrop = $true

# Loose box: folder with eboot.bin + workspace name on the kit
$grpLoose = New-Object System.Windows.Forms.GroupBox
$grpLoose.Text = 'Loose build'
$tabPS5.Controls.Add($grpLoose)
$lblLooseFolder = New-Label 'Folder:' 10 30 $grpLoose
$txtPS5 = New-Object System.Windows.Forms.TextBox
$grpLoose.Controls.Add($txtPS5)
$btnPS5Folder = New-Button 'Browse...' 0 0 84 'Top,Left' $grpLoose
$lblWsName = New-Label 'Workspace:' 10 66 $grpLoose
$txtWorkspace = New-Object System.Windows.Forms.TextBox
$txtWorkspace.Text = 'playtest'
$grpLoose.Controls.Add($txtWorkspace)
$lblWsHint = New-Label 'On the kit: "sce_nolimit playtest"' 10 100 $grpLoose
$lblWsHint.ForeColor = [System.Drawing.Color]::DimGray

$gridPS5 = New-ConsoleGrid $false
$tabPS5.Controls.Add($gridPS5)
$btnPs5Launch = New-Button 'Launch game...' 0 0 120 'Top,Left' $tabPS5
$btnPs5Shot     = New-Button 'Screenshot' 0 0 95 'Top,Left' $tabPS5
$btnPs5Rec      = New-Button 'Record...' 0 0 85 'Top,Left' $tabPS5
$btnPs5RecStop  = New-Button 'Stop recording' 0 0 135 'Top,Left' $tabPS5
$btnPs5Captures = New-Button 'Captures' 0 0 80 'Top,Left' $tabPS5
$btnPs5Rec.ForeColor = [System.Drawing.Color]::DarkRed
$btnPs5RecStop.Enabled = $false
$lblPs5Launch = New-Label '' 0 0 $tabPS5
$lblPs5Launch.ForeColor = [System.Drawing.Color]::DimGray
$lblPs5Launch.AutoSize = $false; $lblPs5Launch.AutoEllipsis = $true

$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($txtWorkspace, 'Loose PS5 builds go into this workspace on the kit. Placeholders: {TitleId} {Build} {Stream} {Config} {Name}')
$tip.SetToolTip($txtMain, 'The main (application) package - installed first. Leave empty to install DLC onto a game already on the kit. You can also drop a .pkg here.')
$tip.SetToolTip($lstDlc, 'DLC packages, installed after the main package in this order. Select one or more and press Delete to remove. You can drop .pkg files here.')
$tip.SetToolTip($chkForceOwn, 'If another PC owns a kit, take it over (target connect /force). The other PC loses control of the kit - only use on kits you are allowed to take.')
$tip.SetToolTip($btnDlcAdd, 'Pick one or more DLC .pkg files (Ctrl/Shift-click to select several). Run it again to add DLC from another folder.')

function Layout-PS5Page {
    $w = $tabPS5.ClientSize.Width; $h = $tabPS5.ClientSize.Height
    if ($w -lt 700 -or $h -lt 280) { return }
    $rbPkg.Location = New-Object System.Drawing.Point(8, 12)
    $rbLoose.Location = New-Object System.Drawing.Point(230, 12)
    $lblPS5Mode.Location = New-Object System.Drawing.Point(390, 13)
    $chkConnect.Location = New-Object System.Drawing.Point(($w - 580), 12)
    $chkForceOwn.Location = New-Object System.Drawing.Point(($w - 410), 12)
    $btnTmSync.SetBounds($w - 223, 6, 215, 32)

    $lw = [int][math]::Max(340, ($w * 0.32))
    $pw = $w - 16 - $lw - 8
    $grpPkgs.SetBounds(8, 44, $pw, 162)
    $grpLoose.SetBounds(8 + $pw + 8, 44, $lw, 162)

    $fw = $pw - 55 - 186
    $txtMain.SetBounds(55, 26, $fw, 24)
    $btnMainBrowse.SetBounds($pw - 178, 22, 90, 30)
    $btnMainClear.SetBounds($pw - 82, 22, 72, 30)
    $lstDlc.SetBounds(55, 60, $fw, 72)
    $btnDlcAdd.SetBounds($pw - 178, 58, 168, 30)
    $btnDlcRemove.SetBounds($pw - 178, 94, 90, 30)
    $btnDlcClear.SetBounds($pw - 82, 94, 72, 30)
    $lblPkgInfo.Location = New-Object System.Drawing.Point(55, 138)
    $lblPkgInfo.MaximumSize = New-Object System.Drawing.Size(($pw - 65), 20)

    $txtPS5.SetBounds(70, 26, $lw - 70 - 100, 24)
    $btnPS5Folder.SetBounds($lw - 94, 22, 84, 30)
    $txtWorkspace.SetBounds(85, 62, [int][math]::Min(220, $lw - 100), 24)
    $lblWsHint.Location = New-Object System.Drawing.Point(10, 100)
    $lblWsHint.MaximumSize = New-Object System.Drawing.Size(($lw - 20), 0)

    $gridPS5.SetBounds(8, 214, $w - 16, $h - 214 - 46)
    $btnPs5Launch.SetBounds(8, ($h - 40), 120, 32)
    $btnPs5Shot.SetBounds(136, ($h - 40), 95, 32)
    $btnPs5Rec.SetBounds(237, ($h - 40), 85, 32)
    $btnPs5RecStop.SetBounds(328, ($h - 40), 135, 32)
    $btnPs5Captures.SetBounds(469, ($h - 40), 80, 32)
    $lblPs5Launch.SetBounds(557, ($h - 31), [math]::Max(100, $w - 565), 20)
}

$tabXbox.Add_Resize({ Layout-XboxPage })
$tabPS5.Add_Resize({ Layout-PS5Page })
# --- PC tab: EA app override.cfg (main game + DLC zips from the NAS)
$lblPcFile = New-Label 'EA app override file:' 8 14 $tabPC
$txtPcFile = New-Object System.Windows.Forms.TextBox
$tabPC.Controls.Add($txtPcFile)
$btnPcFileBrowse = New-Button 'Browse...' 0 0 85 'Top,Left' $tabPC
$btnPcOpen       = New-Button 'Open file' 0 0 90 'Top,Left' $tabPC
$lblPcInfo = New-Label '' 140 40 $tabPC
$lblPcInfo.ForeColor = [System.Drawing.Color]::DimGray
$flowPcContent = New-Object System.Windows.Forms.FlowLayoutPanel
$flowPcContent.WrapContents = $false
$flowPcContent.AutoScroll = $false
$tabPC.Controls.Add($flowPcContent)
$lblPcContentInfo = New-Label '' 0 0 $tabPC
$lblPcInstHead = New-Label 'Install folder:' 8 0 $tabPC
$lblPcInstHead.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$txtPcInstallDir = New-Object System.Windows.Forms.TextBox
$tabPC.Controls.Add($txtPcInstallDir)
$btnPcInstallBrowse = New-Button 'Browse...' 0 0 85 'Top,Left' $tabPC
$btnPcInstallCancel = New-Button 'Cancel install' 0 0 105 'Top,Left' $tabPC
$btnPcInstallCancel.Enabled = $false
$lblPcInstall = New-Label 'Install game (direct): extracts the ticked content ZIPs here, runs Touchup.exe, writes the registry + overrides' 0 0 $tabPC
$lblPcInstall.ForeColor = [System.Drawing.Color]::DimGray
$lblPcInstall.AutoEllipsis = $true
$lblPcCopyHead = New-Label 'Loose build copy:' 8 0 $tabPC
$lblPcCopyHead.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$lblPcCopy = New-Label 'Files Final / Files Performance: Scan, pick a build, Use This Build - you choose where to copy it' 0 0 $tabPC
$lblPcCopy.ForeColor = [System.Drawing.Color]::DimGray
$lblPcCopy.AutoEllipsis = $true
$btnPcCopyCancel = New-Button 'Cancel copy' 0 0 100 'Top,Left' $tabPC
$btnPcCopyCancel.Enabled = $false
$btnPcCopyOpen = New-Button 'Open folder' 0 0 100 'Top,Left' $tabPC

$gridPC = New-Object System.Windows.Forms.DataGridView
$gridPC.AllowUserToAddRows = $false
$gridPC.AllowUserToDeleteRows = $false
$gridPC.RowHeadersVisible = $false
$gridPC.SelectionMode = 'CellSelect'
$gridPC.MultiSelect = $false
$gridPC.AutoGenerateColumns = $false
$gridPC.BackgroundColor = [System.Drawing.SystemColors]::Window
$gridPC.ColumnHeadersHeightSizeMode = 'AutoSize'
$c = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $c.Name = 'Use'; $c.HeaderText = 'Include'; $c.Width = 55; [void]$gridPC.Columns.Add($c)
foreach ($def in @(@('Offer','Offer ID',115,$true), @('Content','Content',175,$true), @('Zip','Expected zip',170,$true), @('Path','Full path to the .zip',300,$false))) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $c.Name = $def[0]; $c.HeaderText = $def[1]; $c.Width = $def[2]; $c.ReadOnly = $def[3]; [void]$gridPC.Columns.Add($c)
}
$c = New-Object System.Windows.Forms.DataGridViewButtonColumn; $c.Name = 'Browse'; $c.HeaderText = ''; $c.Text = '...'; $c.UseColumnTextForButtonValue = $true; $c.Width = 36; [void]$gridPC.Columns.Add($c)
foreach ($def in @(@('Version','Server version',115,$false), @('InFile','In file now',80,$true))) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $c.Name = $def[0]; $c.HeaderText = $def[1]; $c.Width = $def[2]; $c.ReadOnly = $def[3]; [void]$gridPC.Columns.Add($c)
}
$gridPC.Columns['Path'].AutoSizeMode = 'Fill'
$tabPC.Controls.Add($gridPC)

$btnPcWrite   = New-Button 'Write overrides to file' 0 0 175 'Top,Left' $tabPC
$btnPcRestore = New-Button 'Remove overrides (default)' 0 0 195 'Top,Left' $tabPC
$btnPcReread  = New-Button 'Re-read file' 0 0 105 'Top,Left' $tabPC
$btnPcRestart = New-Button 'Restart EA app' 0 0 125 'Top,Left' $tabPC
$btnPcWrite.ForeColor = [System.Drawing.Color]::DarkGreen
$btnPcInstall   = New-Button 'Install game (direct)' 0 0 175 'Top,Left' $tabPC
$btnPcLaunch    = New-Button 'Launch game...' 0 0 115 'Top,Left' $tabPC
$btnPcFind      = New-Button 'Find installed game' 0 0 140 'Top,Left' $tabPC
$btnPcUninstall = New-Button 'Uninstall (Windows entry)' 0 0 175 'Top,Left' $tabPC
$btnPcWipe      = New-Button 'Delete game files (fast)' 0 0 170 'Top,Left' $tabPC
$btnPcInstall.ForeColor = [System.Drawing.Color]::DarkGreen
$btnPcWipe.ForeColor = [System.Drawing.Color]::DarkRed
$lblPcGame = New-Label 'Installed game: (click Find installed game)' 0 0 $tabPC
$lblPcGame.ForeColor = [System.Drawing.Color]::DimGray
$lblPcHint = New-Label 'Only the qa.Origin.OFR lines of these offers are changed - everything else in the file is kept. A backup is saved first.' 0 0 $tabPC
$lblPcHint.ForeColor = [System.Drawing.Color]::DimGray
# screen capture row (this PC's screen, ffmpeg)
$lblPcCapHead = New-Label 'Screen capture:' 8 0 $tabPC
$lblPcCapHead.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$cmbPcMonitor = New-Object System.Windows.Forms.ComboBox
$cmbPcMonitor.DropDownStyle = 'DropDownList'
$tabPC.Controls.Add($cmbPcMonitor)
$lblPcAudioHead = New-Label 'Sound:' 0 0 $tabPC
$cmbPcAudio = New-Object System.Windows.Forms.ComboBox
$cmbPcAudio.DropDownStyle = 'DropDownList'
$tabPC.Controls.Add($cmbPcAudio)
$btnPcShot     = New-Button 'Screenshot' 0 0 90 'Top,Left' $tabPC
$btnPcRec      = New-Button 'Record...' 0 0 85 'Top,Left' $tabPC
$btnPcRecStop  = New-Button 'Stop recording' 0 0 125 'Top,Left' $tabPC
$btnPcCaptures = New-Button 'Captures' 0 0 75 'Top,Left' $tabPC
$btnPcRec.ForeColor = [System.Drawing.Color]::DarkRed
$btnPcRecStop.Enabled = $false
$lblPcRec = New-Label 'Pick the monitor (and a sound output to record what it plays), then Screenshot or Record... (MP4, needs ffmpeg.exe)' 0 0 $tabPC
$lblPcRec.ForeColor = [System.Drawing.Color]::DimGray
$lblPcRec.AutoSize = $false; $lblPcRec.AutoEllipsis = $true

function Layout-PCPage {
    $w = $tabPC.ClientSize.Width; $h = $tabPC.ClientSize.Height
    if ($w -lt 600 -or $h -lt 200) { return }
    $txtPcFile.SetBounds(140, 10, $w - 140 - 200, 24)
    $btnPcFileBrowse.SetBounds($w - 192, 6, 85, 32)
    $btnPcOpen.SetBounds($w - 100, 6, 92, 32)
    $lblPcInfo.Location = New-Object System.Drawing.Point(140, 40)
    $flowPcContent.SetBounds(8, 62, $w - 16, 30)
    $lblPcContentInfo.Location = New-Object System.Drawing.Point(140, 94)
    $lblPcInstHead.Location = New-Object System.Drawing.Point(8, 123)
    $txtPcInstallDir.SetBounds(130, 119, 330, 24)
    $btnPcInstallBrowse.SetBounds(466, 116, 85, 30)
    $lblPcInstall.AutoSize = $false
    $lblPcInstall.SetBounds(560, 123, [math]::Max(100, $w - 560 - 120), 20)
    $btnPcInstallCancel.SetBounds($w - 113, 116, 105, 30)
    $lblPcCopyHead.Location = New-Object System.Drawing.Point(8, 159)
    $lblPcCopy.AutoSize = $false
    $lblPcCopy.SetBounds(130, 159, $w - 130 - 224, 20)
    $btnPcCopyCancel.SetBounds($w - 214, 151, 100, 30)
    $btnPcCopyOpen.SetBounds($w - 108, 151, 100, 30)
    $gridPC.SetBounds(8, 188, $w - 16, $h - 188 - 160)
    $y3 = $h - 152
    $lblPcCapHead.Location = New-Object System.Drawing.Point(8, ($y3 + 9))
    $avail = $w - 600
    $mw = [math]::Min(300, [math]::Max(170, [int]($avail / 2)))
    $sw = [math]::Min(330, [math]::Max(160, $avail - $mw))
    $x = 130
    $cmbPcMonitor.SetBounds($x, ($y3 + 5), $mw, 24); $x += $mw + 8
    $lblPcAudioHead.AutoSize = $false; $lblPcAudioHead.SetBounds($x, ($y3 + 9), 44, 20); $x += 46
    $cmbPcAudio.SetBounds($x, ($y3 + 5), $sw, 24); $x += $sw + 8
    $btnPcShot.SetBounds($x, $y3, 90, 32); $x += 96
    $btnPcRec.SetBounds($x, $y3, 85, 32); $x += 91
    $btnPcRecStop.SetBounds($x, $y3, 120, 32); $x += 126
    $btnPcCaptures.SetBounds($x, $y3, 75, 32)
    $lblPcRec.SetBounds(130, ($y3 + 38), [math]::Max(100, $w - 138), 20)
    $y2 = $h - 84
    $btnPcInstall.SetBounds(8, $y2, 175, 34)
    $btnPcLaunch.SetBounds(189, $y2, 115, 34)
    $btnPcFind.SetBounds(310, $y2, 140, 34)
    $btnPcUninstall.SetBounds(456, $y2, 175, 34)
    $btnPcWipe.SetBounds(637, $y2, 170, 34)
    $lblPcGame.Location = New-Object System.Drawing.Point(818, ($y2 + 9))
    $lblPcGame.MaximumSize = New-Object System.Drawing.Size([math]::Max(100, $w - 826), 0)
    $y = $h - 42
    $btnPcWrite.SetBounds(8, $y, 175, 34)
    $btnPcRestore.SetBounds(189, $y, 195, 34)
    $btnPcReread.SetBounds(390, $y, 105, 34)
    $btnPcRestart.SetBounds(501, $y, 125, 34)
    $lblPcHint.Location = New-Object System.Drawing.Point(640, ($y + 9))
    $lblPcHint.MaximumSize = New-Object System.Drawing.Size([math]::Max(100, $w - 650), 0)
}
$tabPC.Add_Resize({ Layout-PCPage })

$tabs.Add_SelectedIndexChanged({ Layout-XboxPage; Layout-PS5Page; Layout-PCPage; Update-SharedButtons })

# --- Options group (shared - applies to the tab you deploy from)
$grpOpt = New-Object System.Windows.Forms.GroupBox
$grpOpt.Text = 'Deploy options (apply to the selected tab)'
$grpOpt.Location = New-Object System.Drawing.Point(20,548)
$grpOpt.Size = New-Object System.Drawing.Size(1225,55)
$grpOpt.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($grpOpt)

function New-Check([string]$text,[int]$x,[bool]$checked) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.AutoSize = $true
    $c.Checked = $checked
    $c.Location = New-Object System.Drawing.Point($x,22)
    $grpOpt.Controls.Add($c)
    return $c
}
$chkReboot    = New-Check 'Reboot before deploy' 12 $true
$chkUninstall = New-Check 'Uninstall existing first' 180 $false
$chkLaunch    = New-Check 'Launch after deploy' 360 $false
$chkDryRun    = New-Check 'Dry run (log commands only)' 520 $false
[void](New-Label 'Parallel:' 740 24 $grpOpt)
$numParallel = New-Object System.Windows.Forms.NumericUpDown
$numParallel.Location = New-Object System.Drawing.Point(800,20)
$numParallel.Size = New-Object System.Drawing.Size(55,24)
$numParallel.Minimum = 1
$numParallel.Maximum = 16
$numParallel.Value = 4
$grpOpt.Controls.Add($numParallel)
[void](New-Label 'Stagger (s):' 875 24 $grpOpt)
$numStagger = New-Object System.Windows.Forms.NumericUpDown
$numStagger.Location = New-Object System.Drawing.Point(950,20)
$numStagger.Size = New-Object System.Drawing.Size(60,24)
$numStagger.Minimum = 0
$numStagger.Maximum = 900
$numStagger.Increment = 15
$numStagger.Value = 30
$grpOpt.Controls.Add($numStagger)
$tip.SetToolTip($numStagger, 'Minimum gap in seconds between one kit starting its install and the next. 0 = all start together.')

# --- Buttons (shared - act on the selected kits in the visible tab)
$btnStatus     = New-Button '1. Check Selected' 20 610 130
$btnPreview    = New-Button '2. Preview Commands' 158 610 150
$btnDeploySel  = New-Button '3. Deploy Selected' 316 610 145
$btnDeployIdle = New-Button '4. Deploy All Idle' 469 610 140
$btnCancel     = New-Button 'Cancel Running' 617 610 125
$btnCancel.Enabled = $false

$lblFind = New-Object System.Windows.Forms.Label
$lblFind.Text = 'Filter:'
$lblFind.AutoSize = $true
$lblFind.Location = New-Object System.Drawing.Point(760,619)
$lblFind.Anchor = 'Bottom,Left'
$form.Controls.Add($lblFind)
$txtFind = New-Object System.Windows.Forms.TextBox
$txtFind.Location = New-Object System.Drawing.Point(795,615)
$txtFind.Size = New-Object System.Drawing.Size(150,24)
$txtFind.Anchor = 'Bottom,Left'
$form.Controls.Add($txtFind)
$btnFind = New-Button 'Clear Filter' 951 610 120

$btnSelectAll  = New-Button 'Select All' 20 650 95
$btnClearSel   = New-Button 'Clear Selection' 121 650 115
$btnOpenCsv    = New-Button 'Open Console List' 242 650 125
$btnReload     = New-Button 'Reload List + Config' 373 650 145
$btnOpenCfg    = New-Button 'Open Config' 524 650 95
$btnOpenLogs   = New-Button 'Open Logs' 625 650 85
$btnClose      = New-Button 'Exit' 716 650 60
$btnClearCache = New-Button 'Clear Cache' 782 650 100

$lblPower = New-Object System.Windows.Forms.Label
$lblPower.Text = 'Power (selected):'
$lblPower.AutoSize = $true
$lblPower.Location = New-Object System.Drawing.Point(20,699)
$lblPower.Anchor = 'Bottom,Left'
$form.Controls.Add($lblPower)
$btnPowerOn  = New-Button 'Power On' 135 690 95
$btnPowerOff = New-Button 'Power Off' 236 690 95
$btnRestart  = New-Button 'Restart' 337 690 95
$btnPowerOn.ForeColor  = [System.Drawing.Color]::DarkGreen
$btnPowerOff.ForeColor = [System.Drawing.Color]::DarkRed

# --- Log pane + status
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.WordWrap = $false
$txtLog.Font = New-Object System.Drawing.Font('Consolas',9)
$txtLog.Location = New-Object System.Drawing.Point(20,732)
$txtLog.Size = New-Object System.Drawing.Size(1225,145)
$txtLog.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($txtLog)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Ready'
$status.AutoSize = $true
$status.Location = New-Object System.Drawing.Point(20,886)
$status.Anchor = 'Bottom,Left'
$form.Controls.Add($status)

$form.Height = 1010   # extra room for the PS5 package boxes (anchors stretch the tabs)
# Fit smaller screens / display scaling: shrink after layout so anchors keep their margins
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($form.Height -gt $wa.Height) { $form.Height = $wa.Height }
if ($form.Width -gt $wa.Width) { $form.Width = $wa.Width }
$form.Add_Shown({ Layout-XboxPage; Layout-PS5Page; Layout-PCPage; Update-SharedButtons })

# Which tab / grid the user is working in
function Get-ActivePlatform { if ($tabs.SelectedTab -eq $tabPS5) { return 'PS5' } elseif ($tabs.SelectedTab -eq $tabPC) { return 'PC' } else { return 'Xbox' } }
function Get-GridFor([string]$pkey) { if ($pkey -eq 'PS5') { return $gridPS5 } else { return $gridXbox } }
function Get-ActiveGrid { return (Get-GridFor (Get-ActivePlatform)) }

# ---------------------------------------------------------------- build helpers

function Get-BuildMode([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return '' }
    if (Test-Path -LiteralPath $path -PathType Container) { return 'Loose' }
    if (Test-Path -LiteralPath $path -PathType Leaf) { return 'Package' }
    return 'Not found'
}

$script:PackagePatterns = @{ Xbox = @('*.xvc','*.msixvc'); PS5 = @('*.pkg') }
$script:LooseMarkers    = @{ Xbox = 'MicrosoftGame.config'; PS5 = 'eboot.bin' }

# Works out what the selected path really is for that platform.
# Returns Path (what gets deployed), Mode (Loose / Package / Not found / ''), Note, Problem.
function Resolve-Build([string]$pkey,[string]$path) {
    $r = @{ Path = $path; Mode = (Get-BuildMode $path); Note = ''; Problem = ''; Gp5 = '' }
    if ($r.Mode -ne 'Loose') { return $r }
    if (Test-Path -LiteralPath (Join-Path $path $script:LooseMarkers[$pkey])) {
        if ($pkey -eq 'PS5') {
            $g = @(Get-ChildItem -LiteralPath $path -Filter '*.gp5' -File -Recurse -Depth 1 -ErrorAction SilentlyContinue | Sort-Object FullName)
            if ($g.Count -ge 1) { $r.Gp5 = $g[0].FullName }
            if ($g.Count -gt 1) { $r.Note = "several .gp5 files - using $($g[0].Name)" }
        }
        return $r
    }
    $found = @()
    foreach ($pat in $script:PackagePatterns[$pkey]) {
        $found += @(Get-ChildItem -LiteralPath $path -Filter $pat -File -Recurse -Depth 1 -ErrorAction SilentlyContinue)
    }
    $found = @($found | Sort-Object FullName -Unique)
    if ($found.Count -eq 1) {
        $r.Path = $found[0].FullName; $r.Mode = 'Package'; $r.Note = "using package in folder: $($found[0].Name)"
    } elseif ($found.Count -gt 1 -and $pkey -eq 'PS5') {
        $r.Mode = 'Package'; $r.Note = "$($found.Count) packages - main + DLC chosen in the PS5 tab"
    } elseif ($found.Count -gt 1) {
        $r.Problem = "the $pkey folder holds $($found.Count) packages (" + (($found | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', ') + ") - click Package... and pick one"
    } else {
        $r.Problem = "the $pkey folder has no package and no $($script:LooseMarkers[$pkey]) at its root, so it is neither a package build nor a loose build - select the folder that contains $($script:LooseMarkers[$pkey]), or the package file itself"
    }
    return $r
}

# ---- PS5 packages: one main package + a list of DLC packages, each picked from any folder
$script:DlcPaths = New-Object System.Collections.ArrayList
$script:LastPkgDir = ''

function Get-PkgLabel([string]$name) {
    if ($name -match '[A-Z]{2}\d{4}-[A-Z]{4}\d{5}_\d{2}-([A-Z0-9]{16})') { return $Matches[1] }
    return [System.IO.Path]::GetFileNameWithoutExtension($name)
}
function New-PkgInfo([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    $name = [System.IO.Path]::GetFileName($path)
    $fi = $null
    try { if (Test-Path -LiteralPath $path -PathType Leaf) { $fi = Get-Item -LiteralPath $path } } catch {}
    $tid = $(if ($name -match '[A-Z]{2}\d{4}-([A-Z]{4}\d{5})_\d{2}-') { $Matches[1] } else { '' })
    return [pscustomobject]@{ Path = $path; Name = $name; Label = (Get-PkgLabel $name); Size = $(if ($fi) { [double]$fi.Length } else { 0 }); Exists = [bool]$fi; TitleId = $tid }
}
# Content labels that normally mean additional content rather than the game itself
function Test-LooksLikeDlc([string]$path) { return ((Get-PkgLabel ([System.IO.Path]::GetFileName($path))) -match '(?i)CONTENTPACK|DLC|ADDON|ADD-ON|SEASONPASS|BUNDLE') }

function Sync-DlcList {
    $lstDlc.Items.Clear()
    foreach ($p in $script:DlcPaths) { $i = New-PkgInfo $p; [void]$lstDlc.Items.Add(("{0}    {1}" -f $i.Label, $p)) }
    Update-Ps5Info
}

# Adds DLC paths (skips duplicates and the main package); returns what was skipped and why
function Add-DlcPaths([string[]]$paths) {
    $main = $txtMain.Text.Trim()
    $skipped = @()
    foreach ($p in $paths) {
        if (-not $p) { continue }
        if ($main -and $p -ieq $main) { $skipped += "$([System.IO.Path]::GetFileName($p)) (it is the main package)"; continue }
        if (@($script:DlcPaths | Where-Object { $_ -ieq $p }).Count -gt 0) { $skipped += "$([System.IO.Path]::GetFileName($p)) (already in the list)"; continue }
        [void]$script:DlcPaths.Add($p)
    }
    Sync-DlcList
    return $skipped
}

function Remove-SelectedDlcs {
    $idx = @($lstDlc.SelectedIndices | ForEach-Object { [int]$_ } | Sort-Object -Descending)
    foreach ($i in $idx) { $script:DlcPaths.RemoveAt($i) }
    Sync-DlcList
}

# What will be installed: main package (or $null) and the DLC packages in list order
function Get-Ps5PackageSelection {
    return @{ Main = (New-PkgInfo $txtMain.Text.Trim()); Dlcs = @($script:DlcPaths | ForEach-Object { New-PkgInfo $_ }) }
}

# Errors stop the deploy; warnings are shown in the confirm dialog
function Get-Ps5PackageProblems {
    $sel = Get-Ps5PackageSelection
    $err = @(); $warn = @()
    if ($sel.Main) {
        if ($sel.Main.Path -notmatch '\.pkg$') { $err += "Main package is not a .pkg file: $($sel.Main.Path)" }
        elseif (-not $sel.Main.Exists) { $err += "Main package not found: $($sel.Main.Path)" }
    }
    foreach ($d in $sel.Dlcs) { if (-not $d.Exists) { $err += "DLC package not found: $($d.Path)" } }
    $ref = $(if ($sel.Main -and $sel.Main.TitleId) { $sel.Main.TitleId } else { '' })
    if ($ref) {
        foreach ($d in $sel.Dlcs) { if ($d.TitleId -and $d.TitleId -ne $ref) { $warn += "DLC $($d.Label) is for title $($d.TitleId), but the main package is $ref" } }
    }
    if ($sel.Main -and (Test-LooksLikeDlc $sel.Main.Path)) { $warn += "The main package ($($sel.Main.Label)) looks like DLC - check it is really the game" }
    return @{ Errors = $err; Warnings = $warn }
}

function Update-Ps5Info {
    $sel = Get-Ps5PackageSelection
    $n = $sel.Dlcs.Count
    $dlcText = $(if ($n) { " + $n DLC (" + (($sel.Dlcs | ForEach-Object { $_.Label }) -join ', ') + ')' } else { '' })
    $info = $(if ($sel.Main) { "Will install: main $($sel.Main.Label)$dlcText" }
              elseif ($n) { "Will install: $n DLC only - the game must already be on the kit$(' (' + (($sel.Dlcs | ForEach-Object { $_.Label }) -join ', ') + ')')" }
              else { 'Pick the main package and/or add DLC packages' })
    $probs = Get-Ps5PackageProblems
    if ($probs.Errors.Count -gt 0) { $info = '! ' + $probs.Errors[0]; $lblPkgInfo.ForeColor = [System.Drawing.Color]::DarkRed }
    elseif ($probs.Warnings.Count -gt 0) { $info = '! ' + $probs.Warnings[0]; $lblPkgInfo.ForeColor = [System.Drawing.Color]::DarkOrange }
    else { $lblPkgInfo.ForeColor = [System.Drawing.Color]::DimGray }
    $lblPkgInfo.Text = $info
    if ($rbPkg.Checked) {
        $lblPS5Mode.Text = $(if ($sel.Main) { "Main + $n DLC" } elseif ($n) { "$n DLC only" } else { 'No packages picked' })
    } else {
        $r = Resolve-Build 'PS5' $txtPS5.Text.Trim()
        $lblPS5Mode.Text = $(if (-not $txtPS5.Text.Trim()) { 'No folder picked' } elseif ($r.Problem) { 'Check folder' } elseif ($r.Mode -eq 'Package') { 'Folder has packages - use Install packages' } elseif ($r.Gp5) { 'Loose (.gp5)' } else { $r.Mode })
    }
}

function Pick-PkgFiles([bool]$multi,[string]$title) {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'PS5 packages (*.pkg)|*.pkg|All files (*.*)|*.*'
    $d.Multiselect = $multi
    $d.Title = $title
    if ($script:LastPkgDir -and (Test-Path -LiteralPath $script:LastPkgDir)) { $d.InitialDirectory = $script:LastPkgDir }
    if ($d.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return @() }
    $files = @($d.FileNames)
    if ($files.Count -gt 0) { $script:LastPkgDir = Split-Path -Parent $files[0] }
    return $files
}

function Update-ModeLabels {
    foreach ($pair in @(@('Xbox',$txtXbox,$lblXboxMode), @('PS5',$txtPS5,$lblPS5Mode))) {
        $r = Resolve-Build $pair[0] $pair[1].Text.Trim()
        $pair[2].Text = $(if ($r.Problem) { 'Check path' } elseif ($r.Mode -eq 'Package' -and $r.Note) { 'Package (in folder)' } elseif ($r.Gp5) { 'Loose (.gp5)' } else { $r.Mode })
    }
    Update-Ps5Info
}

# ---- Folder picker: the Explorer-style Windows dialog (address bar, Quick access, Network) in
#      folder mode, instead of .NET's old tree-only FolderBrowserDialog. Falls back to the old one
#      if the new dialog cannot be created.
$hydPickerSource = @'
using System;
using System.Runtime.InteropServices;
public static class HydFolderPicker {
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] class FileOpenDialogCom {}
    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileDialog {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
    }
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IShellItem ppv);

    // Returns the chosen folder, or null when the user cancels
    public static string Pick(IntPtr owner, string title, string okLabel, string startFolder) {
        IFileDialog d = (IFileDialog)new FileOpenDialogCom();
        try {
            uint opts; d.GetOptions(out opts);
            d.SetOptions(opts | 0x20 /*PICKFOLDERS*/ | 0x40 /*FORCEFILESYSTEM*/ | 0x800 /*PATHMUSTEXIST*/);
            if (!string.IsNullOrEmpty(title)) d.SetTitle(title);
            if (!string.IsNullOrEmpty(okLabel)) d.SetOkButtonLabel(okLabel);
            if (!string.IsNullOrEmpty(startFolder)) {
                try { IShellItem si; SHCreateItemFromParsingName(startFolder, IntPtr.Zero, typeof(IShellItem).GUID, out si); d.SetFolder(si); } catch { }
            }
            int hr = d.Show(owner);
            if (hr != 0) return null;
            IShellItem res; d.GetResult(out res);
            string path; res.GetDisplayName(0x80058000 /*SIGDN_FILESYSPATH*/, out path);
            return path;
        } finally { Marshal.ReleaseComObject(d); }
    }
}
'@

function Select-Folder([string]$title, [string]$startFolder, [string]$okLabel = 'Select Folder') {
    if ($startFolder -and -not (Test-Path -LiteralPath $startFolder -PathType Container)) { $startFolder = '' }
    try {
        if (-not ('HydFolderPicker' -as [type])) { Add-Type -TypeDefinition $hydPickerSource -Language CSharp }
        $owner = $(if ($form -and $form.IsHandleCreated) { $form.Handle } else { [IntPtr]::Zero })
        $p = [HydFolderPicker]::Pick($owner, $title, $okLabel, $startFolder)
        if ($p) { return $p } else { return '' }
    } catch {
        # old-style tree dialog as a fallback
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = $title; $d.ShowNewFolderButton = $true
        if ($startFolder) { $d.SelectedPath = $startFolder }
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
        return ''
    }
}

function Pick-Folder([System.Windows.Forms.TextBox]$target) {
    $p = Select-Folder 'Select the loose build folder' $target.Text.Trim()
    if ($p) { $target.Text = $p }
}

function Pick-Package([System.Windows.Forms.TextBox]$target,[string]$filter) {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = $filter
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $target.Text = $d.FileName }
}

# ---------------------------------------------------------------- build library (NAS scan)
# <Root>\<Branch>\<Config>\<Platform>\ holds one entry per build: a numbered folder (e.g. 14759150) plus,
# beside it or as the folder name itself, a long name that ends with the CL and - for PS5 package
# builds - the role:  "14759305 - Glacier_PlayStation 5_Patch - ... 29715907-29672681 RM DLC1"
$script:LibBuilds = @()
$script:LibCache = @{}

function Get-LibraryDir([string]$pkey) {
    $lib = $script:cfg.BuildLibrary
    $root = ([string]$lib.Root).TrimEnd('\','/')
    $plat = [string]$lib.PlatformFolders.$pkey
    if (-not $root -or -not $plat -or -not $cmbStream.SelectedItem -or -not $cmbConfig.SelectedItem) { return '' }
    return [System.IO.Path]::Combine($root, [string]$cmbStream.SelectedItem, [string]$cmbConfig.SelectedItem, $plat)
}

function Test-PackageConfig([string]$config) {
    return (@($script:cfg.BuildLibrary.PackageConfigs) | Where-Object { [string]$_ -ieq $config }).Count -gt 0
}

# Id = leading build number; Cl = last "digits-digits" group; Role = Main / DLCn at the end (optionally "RM ")
function Read-BuildName([string]$name) {
    $n = $name -replace '(?i)\.txt$', ''
    $r = @{ Id = ''; Cl = ''; Role = ''; Rm = $false; DlcNo = 0 }
    if ($n -match '^(\d{5,})') { $r.Id = $Matches[1] }
    $cls = [regex]::Matches($n, '(?<!\d)(\d{6,}-\d{6,})(?!\d)')
    if ($cls.Count -gt 0) { $r.Cl = $cls[$cls.Count - 1].Groups[1].Value }
    if ($n -match '(?i)(?:^|[\s_-])(RM\s+)?(Main|DLC\s*(\d+))\s*$') {
        $r.Rm = [bool]$Matches[1]
        if ($Matches[3]) { $r.Role = 'DLC' + [int]$Matches[3]; $r.DlcNo = [int]$Matches[3] } else { $r.Role = 'Main' }
    }
    return $r
}

function Get-LibraryEntries([string]$dir) {
    $byId = @{}
    foreach ($it in @(Get-ChildItem -LiteralPath $dir -ErrorAction Stop)) {
        $isTxt = (-not $it.PSIsContainer) -and ($it.Name -match '(?i)\.txt$')
        if (-not $it.PSIsContainer -and -not $isTxt) { continue }
        $p = Read-BuildName $it.Name
        if (-not $p.Id) { continue }
        if (-not $byId.ContainsKey($p.Id)) {
            $byId[$p.Id] = [pscustomobject]@{ Id = $p.Id; Folder = ''; Name = ''; Cl = ''; Role = ''; Rm = $false; DlcNo = 0; Time = [datetime]::MinValue }
        }
        $e = $byId[$p.Id]
        if ($it.PSIsContainer) { $e.Folder = $it.FullName }
        if ($it.LastWriteTime -gt $e.Time) { $e.Time = $it.LastWriteTime }
        # the longest name (txt file or long folder name) carries the description
        $bare = $it.Name -replace '(?i)\.txt$', ''
        if ($bare.Length -gt $e.Name.Length) {
            $e.Name = $bare
            if ($p.Cl) { $e.Cl = $p.Cl }
            if ($p.Role) { $e.Role = $p.Role; $e.Rm = $p.Rm; $e.DlcNo = $p.DlcNo }
        }
    }
    return @($byId.Values | Where-Object { $_.Folder })
}

function Format-BuildTime([datetime]$t) { if ($t -eq [datetime]::MinValue) { return '' } else { return $t.ToString('dd MMM HH:mm') } }

# One list entry per deployable build, newest first
function Get-LibraryBuilds([string]$pkey, [bool]$rmOnly) {
    $dir = Get-LibraryDir $pkey
    if (-not $dir) { throw 'Build library: pick a branch and config (and set BuildLibrary.Root in DeployConfig.json)' }
    if ($false) { throw "PC tab: only package builds ($(@($script:cfg.BuildLibrary.PackageConfigs) -join ', ')) install through the EA app - pick that config" }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "Build library folder not found: $dir" }
    $entries = @(Get-LibraryEntries $dir | Sort-Object { [long]$_.Id } -Descending)
    $max = $(if ([int]$script:cfg.BuildLibrary.MaxBuilds -gt 0) { [int]$script:cfg.BuildLibrary.MaxBuilds } else { 40 })
    $isPkg = Test-PackageConfig ([string]$cmbConfig.SelectedItem)
    $builds = @()
    if ($pkey -eq 'PS5' -and $isPkg) {
        # PS5 package builds: Main + DLCs that share a CL form one build
        $use = @($entries | Where-Object { $_.Role -and (-not $rmOnly -or $_.Rm) })
        foreach ($g in @($use | Group-Object { "$($_.Cl)|$($_.Rm)" })) {
            $items = @($g.Group | Sort-Object { [long]$_.Id } -Descending)
            $main = @($items | Where-Object { $_.Role -eq 'Main' })[0]
            $dlcs = @($items | Where-Object { $_.DlcNo -gt 0 } | Group-Object DlcNo | ForEach-Object { $_.Group[0] } | Sort-Object DlcNo)
            $top = $items[0]
            $tag = $(if ($top.Rm) { 'RM ' } else { '' })
            $what = $(if ($main) { "${tag}Main + $($dlcs.Count) DLC" } else { "${tag}DLC only ($($dlcs.Count))" })
            $builds += [pscustomobject]@{ Kind = 'PS5Pkg'; Cl = $top.Cl; Main = $main; Dlcs = $dlcs; Key = [long]$top.Id; Time = ($items | Measure-Object Time -Maximum).Maximum
                Label = ("CL {0}    {1}    #{2}    {3}" -f $(if ($top.Cl) { $top.Cl } else { '(no CL)' }), $what, $top.Id, (Format-BuildTime ($items | Measure-Object Time -Maximum).Maximum)) }
        }
        if (-not $rmOnly) {
            foreach ($e in @($entries | Where-Object { -not $_.Role })) {
                $builds += [pscustomobject]@{ Kind = 'PS5Pkg'; Cl = $e.Cl; Main = $e; Dlcs = @(); Key = [long]$e.Id; Time = $e.Time
                    Label = ("CL {0}    package (no role in name)    #{1}    {2}" -f $(if ($e.Cl) { $e.Cl } else { '(no CL)' }), $e.Id, (Format-BuildTime $e.Time)) }
            }
        }
    } elseif ($pkey -eq 'PC' -and $isPkg) {
        if (-not $isPkg) { throw "PC tab: only package builds ($(@($script:cfg.BuildLibrary.PackageConfigs) -join ', ')) install through the EA app - pick that config" }
        foreach ($e in $entries) {
            if (-not $e.Cl) {
                $t = @(Get-ChildItem -LiteralPath $e.Folder -Filter '*.txt' -File -ErrorAction SilentlyContinue | Where-Object { (Read-BuildName $_.Name).Cl } | Select-Object -First 1)
                if ($t.Count) { $e.Cl = (Read-BuildName $t[0].Name).Cl }
            }
        }
        # folders that share a CL (main + each DLC zip) form one build; folders without a CL stand alone
        foreach ($g in @($entries | Group-Object { if ($_.Cl) { $_.Cl } else { 'id:' + $_.Id } })) {
            $items = @($g.Group | Sort-Object { [long]$_.Id } -Descending)
            $top = $items[0]
            $builds += [pscustomobject]@{ Kind = 'PCPkg'; Cl = $top.Cl; Entries = $items; Key = [long]$top.Id; Time = ($items | Measure-Object Time -Maximum).Maximum
                Label = ("CL {0}    {1} folder(s)    #{2}    {3}" -f $(if ($top.Cl) { $top.Cl } else { '(no CL)' }), $items.Count, $top.Id, (Format-BuildTime ($items | Measure-Object Time -Maximum).Maximum)) }
        }
    } else {
        # loose builds (every folder is a build) and Xbox package builds (one file each)
        foreach ($e in $entries) {
            if (-not $e.Cl) {
                # the CL text file may sit inside the folder instead of beside it
                $t = @(Get-ChildItem -LiteralPath $e.Folder -Filter '*.txt' -File -ErrorAction SilentlyContinue | Where-Object { (Read-BuildName $_.Name).Cl } | Select-Object -First 1)
                if ($t.Count) { $e.Cl = (Read-BuildName $t[0].Name).Cl; if (-not $e.Name -or $e.Name -eq $e.Id) { $e.Name = $t[0].BaseName } }
            }
            $builds += [pscustomobject]@{ Kind = $(if ($isPkg) { 'Package' } else { 'Loose' }); Cl = $e.Cl; Entry = $e; Key = [long]$e.Id; Time = $e.Time
                Label = ("CL {0}    #{1}    {2}" -f $(if ($e.Cl) { $e.Cl } else { '(no CL)' }), $e.Id, (Format-BuildTime $e.Time)) }
        }
    }
    return @($builds | Sort-Object Key -Descending | Select-Object -First $max)
}

# Largest matching file in a build folder; for RM builds the "remastered" package wins
function Find-InBuild([string]$folder, [string[]]$patterns) {
    $found = @()
    foreach ($pat in $patterns) { $found += @(Get-ChildItem -LiteralPath $folder -Filter $pat -File -Recurse -Depth 2 -ErrorAction SilentlyContinue) }
    if ($found.Count -eq 0) { return '' }
    $rm = @($found | Where-Object { $_.Name -match '(?i)remastered' })
    $pick = $(if ($rm.Count) { $rm } else { $found })
    return ($pick | Sort-Object Length -Descending | Select-Object -First 1).FullName
}
# Folder that holds the loose-build marker (may be the build folder itself or one/two levels down)
function Find-LooseRoot([string]$folder, [string]$marker) {
    if (Test-Path -LiteralPath (Join-Path $folder $marker)) { return $folder }
    $m = @(Get-ChildItem -LiteralPath $folder -Filter $marker -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } | Select-Object -First 1)
    if ($m.Count) { return $m[0].DirectoryName }
    return $folder
}

# Fill the tab's build fields from a library build. Returns problems (empty = all good).
function Use-LibraryBuild($b, [string]$pkey) {
    $problems = @()
    if ($pkey -eq 'PC') {
        # find every offer's zip among this build's folders (newest folder wins if a zip appears twice)
        $zips = @{}
        foreach ($e in $b.Entries) {
            foreach ($z in @(Get-ChildItem -LiteralPath $e.Folder -Filter '*.zip' -File -Recurse -Depth 1 -ErrorAction SilentlyContinue)) {
                if (-not $zips.ContainsKey($z.Name.ToLowerInvariant())) { $zips[$z.Name.ToLowerInvariant()] = $z.FullName }
            }
        }
        foreach ($r in $gridPC.Rows) {
            $o = $r.Tag
            if (-not $o.Zip) { continue }
            $hit = $zips[([string]$o.Zip).ToLowerInvariant()]
            if ($hit) { $r.Cells['Path'].Value = $hit; $r.Cells['Use'].Value = $true }
            else { $r.Cells['Path'].Value = ''; $r.Cells['Use'].Value = $false }
        }
        Apply-PcContentSelection
        $want = Get-PcWantedOffers
        foreach ($r in $gridPC.Rows) {
            $o = $r.Tag
            if (-not $o.Zip -or ([string]$r.Cells['Path'].Value)) { continue }
            if ($want.ContainsKey([string]$o.Id)) { $problems += "$($o.Name): $($o.Zip) is not in this build, but $((($want[[string]$o.Id]) | Sort-Object -Unique) -join ' / ') needs it" }
        }
        return $problems
    }
    if ($pkey -eq 'Xbox') {
        if ($b.Kind -eq 'Package') {
            $f = Find-InBuild $b.Entry.Folder @('*.xvc','*.msixvc')
            if ($f) { $txtXbox.Text = $f } else { $problems += "no .xvc / .msixvc package in $($b.Entry.Folder)" }
        } else { $txtXbox.Text = Find-LooseRoot $b.Entry.Folder 'MicrosoftGame.config' }
    } elseif ($b.Kind -eq 'PS5Pkg') {
        $mainPkg = ''
        if ($b.Main) { $mainPkg = Find-InBuild $b.Main.Folder @('*.pkg'); if (-not $mainPkg) { $problems += "no .pkg in the Main folder $($b.Main.Folder)" } }
        $dlcPkgs = @()
        foreach ($d in $b.Dlcs) {
            $f = Find-InBuild $d.Folder @('*.pkg')
            if ($f) { $dlcPkgs += $f } else { $problems += "no .pkg in the $($d.Role) folder $($d.Folder)" }
        }
        $txtMain.Text = $mainPkg
        $script:DlcPaths.Clear()
        foreach ($p in $dlcPkgs) { [void]$script:DlcPaths.Add($p) }
        $rbPkg.Checked = $true
        Sync-DlcList
    } else {
        $txtPS5.Text = Find-LooseRoot $b.Entry.Folder 'eboot.bin'
        $rbLoose.Checked = $true
    }
    return $problems
}

# Fill the Build list for the visible tab (cached per branch/config/platform unless forced)
function Scan-Library([bool]$force = $false) {
    $pkey = Get-ActivePlatform
    $rm = [bool]$chkRmOnly.Checked
    $key = "$pkey|$($cmbStream.SelectedItem)|$($cmbConfig.SelectedItem)|$rm"
    $cmbBuild.Items.Clear(); $script:LibBuilds = @()
    try {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        if ($force -or -not $script:LibCache.ContainsKey($key)) {
            $status.Text = "Scanning $(Get-LibraryDir $pkey) ..."; [System.Windows.Forms.Application]::DoEvents()
            $script:LibCache[$key] = @(Get-LibraryBuilds $pkey $rm)
        }
        $script:LibBuilds = @($script:LibCache[$key])
        foreach ($b in $script:LibBuilds) { [void]$cmbBuild.Items.Add($b.Label) }
        if ($cmbBuild.Items.Count -gt 0) { $cmbBuild.SelectedIndex = 0 }
        $status.Text = $(if ($script:LibBuilds.Count) { "$($script:LibBuilds.Count) $pkey build(s) in $($cmbStream.SelectedItem) / $($cmbConfig.SelectedItem) - newest first. Pick one and click Use This Build." }
                         else { "No $pkey builds found in $(Get-LibraryDir $pkey)" + $(if ($rm -and $pkey -eq 'PS5') { ' (RM only is ticked)' } else { '' }) })
    } catch {
        $status.Text = $_.Exception.Message
        Append-UiLog "Build library: $($_.Exception.Message)"
    } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

# Light sanity check on loose folders so an obviously wrong folder is caught before a long copy
function Get-BuildWarnings([string]$pkey,[string]$path) {
    $w = @()
    if ((Get-BuildMode $path) -ne 'Loose') { return $w }
    if ($pkey -eq 'Xbox' -and -not (Test-Path -LiteralPath (Join-Path $path 'MicrosoftGame.config'))) {
        $w += "Xbox folder has no MicrosoftGame.config at its root - it may be one level too high or too low."
    }
    if ($pkey -eq 'PS5' -and -not (Test-Path -LiteralPath (Join-Path $path 'eboot.bin'))) {
        $w += "PS5 folder has no eboot.bin at its root - it may be one level too high or too low."
    }
    if ($pkey -eq 'PS5' -and -not (Test-Path -LiteralPath (Join-Path $path 'sce_sys\param.json'))) {
        $w += "PS5 folder has no sce_sys\param.json - the Title ID cannot be read from the build."
    }
    return $w
}

# ---------------------------------------------------------------- plan builder (shared by preview + deploy)

function Get-BuildPathFor([string]$pkey) {
    if ($pkey -eq 'Xbox') { return $txtXbox.Text.Trim() }
    return $txtPS5.Text.Trim()
}

# PS5: read Title ID / Content ID from the build itself so they never need typing in.
# Package: from the content ID in the file name (e.g. UP0006-PPSA19534_00-GLACIERGAME00000-...pkg)
# Loose folder: from sce_sys\param.json
function Get-Ps5Ids([string]$path) {
    $r = @{ TitleId = ''; ContentId = '' }
    if ([string]::IsNullOrWhiteSpace($path)) { return $r }
    if (Test-Path -LiteralPath $path -PathType Container) {
        $pj = Join-Path $path 'sce_sys\param.json'
        if (Test-Path -LiteralPath $pj) {
            try {
                $j = Get-Content -LiteralPath $pj -Raw | ConvertFrom-Json
                if ($j.titleId)   { $r.TitleId = [string]$j.titleId }
                if ($j.contentId) { $r.ContentId = [string]$j.contentId }
            } catch {}
        }
    }
    $name = [System.IO.Path]::GetFileName($path.TrimEnd('\','/'))
    if ($name -match '([A-Z]{2}\d{4}-([A-Z]{4}\d{5})_\d{2}-[A-Z0-9]{16})') {
        if (-not $r.ContentId) { $r.ContentId = $Matches[1] }
        if (-not $r.TitleId)   { $r.TitleId = $Matches[2] }
    }
    return $r
}

# Xbox: Package Family Name (and, for loose builds, the launch ID) worked out from the build.
# Package file name:  <Name>_<Version>_<Arch>_<Resource>_<PublisherId>[_xs].xvc
# Loose folder:       MicrosoftGame.config Identity Name + Publisher (publisher ID = Windows hash)
function Get-PublisherId([string]$publisher) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $h = $sha.ComputeHash([System.Text.Encoding]::Unicode.GetBytes($publisher))
    $bits = (($h[0..7] | ForEach-Object { [Convert]::ToString($_,2).PadLeft(8,'0') }) -join '') + '0'
    $abc = '0123456789abcdefghjkmnpqrstvwxyz'
    return (-join (0..12 | ForEach-Object { $abc[[Convert]::ToInt32($bits.Substring($_*5,5),2)] }))
}
function Get-XboxIds([string]$path) {
    $r = @{ PackageFamilyName = ''; LaunchId = '' }
    if ([string]::IsNullOrWhiteSpace($path)) { return $r }
    $cfgFile = Join-Path $path 'MicrosoftGame.config'
    if ((Test-Path -LiteralPath $path -PathType Container) -and (Test-Path -LiteralPath $cfgFile)) {
        try {
            [xml]$x = Get-Content -LiteralPath $cfgFile -Raw
            $id = $x.SelectSingleNode("//*[local-name()='Identity']")
            if ($id -and $id.GetAttribute('Name') -and $id.GetAttribute('Publisher')) {
                $r.PackageFamilyName = $id.GetAttribute('Name') + '_' + (Get-PublisherId $id.GetAttribute('Publisher'))
                $exe = $x.SelectSingleNode("//*[local-name()='Executable']")
                if ($exe -and $exe.GetAttribute('Id')) { $r.LaunchId = $r.PackageFamilyName + '!' + $exe.GetAttribute('Id') }
            }
        } catch {}
        return $r
    }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($path)
    if ($name -match '^(?<n>[^_]+)_(?<v>\d+\.\d+\.\d+\.\d+)_(?<a>[^_]*)_(?<res>[^_]*)_(?<pub>[a-z0-9]{13})') {
        $r.PackageFamilyName = $Matches['n'] + '_' + $Matches['pub']
    }
    return $r
}

function Get-WorkspacePrefix {
    $p = $script:cfg.PS5.WorkspacePrefix
    if ($null -eq $p) { return 'sce_nolimit ' }
    return [string]$p
}

function Get-WorkspaceName([hashtable]$values,[string]$buildPath,[object]$c) {
    $name = $txtWorkspace.Text.Trim()
    if (-not $name) { $name = [string]$script:cfg.PS5.Values.Workspace }
    if (-not $name) { $name = 'playtest' }
    $leaf = [System.IO.Path]::GetFileName($buildPath.TrimEnd('\','/'))
    if ((Test-Path -LiteralPath $buildPath -PathType Leaf)) { $leaf = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($buildPath)) }
    $map = @{ TitleId = [string]$values['TitleId']; Build = $leaf; Stream = [string]$cmbStream.SelectedItem; Config = [string]$cmbConfig.SelectedItem; Name = [string]$c.Name }
    foreach ($k in $map.Keys) {
        if ($name -like "*{$k}*") {
            if (-not $map[$k]) { throw "Workspace name uses {$k}, but it has no value for this build" }
            $name = $name.Replace("{$k}", ($map[$k] -replace '[^A-Za-z0-9_\-]','_'))
        }
    }
    if ($name -match '\{[A-Za-z]+\}') { throw "Workspace name has an unknown placeholder: $($Matches[0]) (use {TitleId} {Build} {Stream} {Config} {Name})" }
    # Every workspace the tool uses is "<prefix><name>", e.g. "sce_nolimit playtest" (prefix not added twice)
    $prefix = Get-WorkspacePrefix
    if ($prefix -and $name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $name = $name.Substring($prefix.Length).Trim() }
    if ($name -notmatch '^[A-Za-z0-9_\-]+$') { throw "Workspace name '$name' can only use letters, digits, _ and - (no spaces; the tool adds '$prefix' in front)" }
    $full = $prefix + $name
    if ($full.Length -gt 64) { throw "Workspace name '$full' is longer than 64 characters" }
    return $full
}

function New-DeployPlan([object]$c,[int]$rowIndex) {
    $pkey = Get-PlatformKey ([string]$c.Platform)
    if (-not $pkey) { throw "Unsupported platform '$($c.Platform)'" }
    $pkgSel = $null
    if ($pkey -eq 'PS5' -and $rbPkg.Checked) {
        # package install: main + DLC from the Packages box (each file can be in its own folder)
        $pkgSel = Get-Ps5PackageSelection
        $probs = Get-Ps5PackageProblems
        if ($probs.Errors.Count -gt 0) { throw ($probs.Errors -join '; ') }
        $resolved = @{ Path = ''; Mode = 'Package'; Gp5 = ''; Note = ''; Problem = '' }
        $mode = 'Package'
    } else {
        $selected = Get-BuildPathFor $pkey
        $resolved = Resolve-Build $pkey $selected
        $buildPath = $resolved.Path
        $mode = $resolved.Mode
        if ($mode -eq '') { throw $(if ($pkey -eq 'PS5') { 'No PS5 loose folder picked' } else { "No $pkey build selected" }) }
        if ($mode -eq 'Not found') { throw "$pkey build path not found: $buildPath" }
        if ($resolved.Problem) { throw $resolved.Problem }
        if ($pkey -eq 'PS5' -and $mode -eq 'Package') { throw 'the loose folder holds .pkg files - for package builds choose "Install packages" and use Main / Add DLC(s)' }
    }
    if ($pkgSel) {
        if (-not $pkgSel.Main -and $pkgSel.Dlcs.Count -eq 0) { throw 'no PS5 package picked - choose the main package and/or add DLC in the PS5 tab' }
        if (-not $pkgSel.Main -and $chkUninstall.Checked) { throw '"Uninstall existing first" would also remove the main game - untick it for a DLC-only install' }
        # IDs (Title ID etc.) come from the main package, or the first DLC for a DLC-only install
        $buildPath = $(if ($pkgSel.Main) { $pkgSel.Main.Path } else { $pkgSel.Dlcs[0].Path })
    }

    $values = @{ IP = [string]$c.IP; Name = [string]$c.Name; BuildPath = $buildPath; LaunchArgs = '' }
    $pv = $script:cfg.$pkey.Values
    if ($pv) { foreach ($prop in $pv.PSObject.Properties) { $values[$prop.Name] = [string]$prop.Value } }
    if ($pkey -eq 'PS5') {
        # A value typed into DeployConfig.json wins; otherwise use what the build says
        $ids = Get-Ps5Ids $buildPath
        foreach ($k in 'TitleId','ContentId') {
            if ([string]::IsNullOrWhiteSpace([string]$values[$k]) -and $ids[$k]) { $values[$k] = $ids[$k] }
        }
        # Workspace on the kit that holds loose builds: name from the app, default "playtest"
        $values['Workspace'] = Get-WorkspaceName $values $buildPath $c
    }
    if ($pkey -eq 'Xbox') {
        $xids = Get-XboxIds $buildPath
        foreach ($k in 'PackageFamilyName','LaunchId') {
            if ([string]::IsNullOrWhiteSpace([string]$values[$k]) -and $xids[$k]) { $values[$k] = $xids[$k] }
        }
    }
    $values['Gp5'] = $resolved.Gp5

    $steps = New-Object System.Collections.ArrayList
    function Add-Step([string]$stepName,[string]$label,[bool]$required,[bool]$continueOnError,[bool]$stagger=$false) {
        $defs = @(Get-StepDefs $pkey $stepName)
        if ($defs.Count -eq 0) {
            if ($required) { throw "$pkey '$stepName' command is not configured in DeployConfig.json" }
            return
        }
        for ($n = 0; $n -lt $defs.Count; $n++) {
            $def = $defs[$n]
            $args2 = Expand-Template $def.Args $values "$pkey $stepName"
            $lbl = $(if ($defs.Count -gt 1) { "$label $($n+1)/$($defs.Count)" } else { $label })
            # only the first command of a group waits for its stagger slot
            [void]$steps.Add(@{ Type = 'Run'; Label = $lbl; Exe = $def.Exe; Args = $args2; ContinueOnError = $continueOnError; OkOutput = $def.OkOutput; Stagger = ($stagger -and $n -eq 0) })
        }
    }
    # For loose builds use the loose-specific command when the config has one
    function Pick([string]$looseName,[string]$normalName) {
        if ($mode -eq 'Loose' -and (Get-StepDef $pkey $looseName)) { return $looseName }
        return $normalName
    }

    if ($chkReboot.Checked) {
        Add-Step 'Reboot' 'Reboot' $true $false
        [void]$steps.Add(@{ Type = 'Wait'; Label = 'Wait for online'; GraceSec = [int]$script:cfg.Reboot.DownGraceSec; TimeoutSec = [int]$script:cfg.Reboot.OnlineTimeoutSec; SettleSec = [int]$script:cfg.Reboot.SettleSec })
    }
    if ($pkey -eq 'PS5' -and $chkConnect.Checked) {
        Add-Step 'Connect' 'Connect' $false $false
        $force = Get-StepDef 'PS5' 'ForceConnect'
        if ($chkForceOwn.Checked -and $force -and $steps.Count -gt 0) {
            $steps[$steps.Count - 1]['OnFailMatch'] = '(?i)another host has ownership|owned by another|ownership'
            $steps[$steps.Count - 1]['OnFailFlag'] = 'OwnedElsewhere'
            $steps[$steps.Count - 1]['AskFirst'] = $true
            $info = Get-StepDef 'PS5' 'TargetInfo'
            if ($info) { $steps[$steps.Count - 1]['InfoExe'] = $info.Exe; $steps[$steps.Count - 1]['InfoArgs'] = (Expand-Template $info.Args $values 'PS5 TargetInfo') }
            [void]$steps.Add(@{ Type = 'Run'; Label = 'Take ownership'; Exe = $force.Exe; Args = (Expand-Template $force.Args $values 'PS5 ForceConnect'); ContinueOnError = $false; RunIf = 'OwnedElsewhere' })
        }
    }
    if ($chkUninstall.Checked) { Add-Step (Pick 'UninstallLoose' 'Uninstall') 'Uninstall' $true $true }
    if ($mode -eq 'Loose') {
        $looseStep = $(if ($resolved.Gp5 -and (Get-StepDef $pkey 'DeployLooseGp5')) { 'DeployLooseGp5' } else { 'DeployLoose' })
        $check = Get-StepDef $pkey 'CheckWorkspace'
        if ($check) {
            $ws = [string]$values['Workspace']
            [void]$steps.Add(@{ Type = 'Run'; Label = 'Check workspace'; Exe = $check.Exe; Args = (Expand-Template $check.Args $values "$pkey CheckWorkspace"); ContinueOnError = $true
                ProbeVar = 'WorkspaceExists'; NotFoundOutput = $check.NotFoundOutput
                ProbeUnknown = "Could not confirm whether workspace '$ws' exists - trying to create it"
                ProbeYes = "Workspace '$ws' already exists on this kit - deploying into it (only changed files are copied, files not in this build are removed)"
                ProbeNo  = "Workspace '$ws' not found on this kit - creating it" })
        }
        $create = Get-StepDef $pkey 'CreateWorkspace'
        if ($create) {
            [void]$steps.Add(@{ Type = 'Run'; Label = 'Create workspace'; Exe = $create.Exe; Args = (Expand-Template $create.Args $values "$pkey CreateWorkspace"); ContinueOnError = $false
                OkOutput = $create.OkOutput; SkipIf = 'WorkspaceExists'; SkipMsg = 'workspace already exists' })
        }
        Add-Step $looseStep 'Deploy (loose)' $true $false $true
    }
    elseif ($pkgSel) {
        $def = Get-StepDef $pkey 'InstallPackage'
        if (-not $def) { throw "$pkey 'InstallPackage' command is not configured in DeployConfig.json" }
        $all = @()
        if ($pkgSel.Main) { $all += ,@($pkgSel.Main, 'Install main', $false) }
        $k = 0
        foreach ($d in $pkgSel.Dlcs) { $k++; $all += ,@($d, "Install DLC $k/$($pkgSel.Dlcs.Count)", $true) }
        $first = $true
        foreach ($item in $all) {
            $v2 = $values.Clone(); $v2['BuildPath'] = $item[0].Path
            # DLC failures do not stop the other DLCs; the kit ends as PARTIAL instead
            [void]$steps.Add(@{ Type = 'Run'; Label = "$($item[1]) ($($item[0].Label))"; Exe = $def.Exe; Args = (Expand-Template $def.Args $v2 "$pkey InstallPackage")
                ContinueOnError = $item[2]; OnFail = $(if ($item[2]) { 'DlcFailed' } else { $null }); FailName = $item[0].Label
                OkOutput = $def.OkOutput; Stagger = $first })
            $first = $false
        }
    }
    else { Add-Step 'InstallPackage' 'Install (package)' $true $false $true }
    if ($chkLaunch.Checked) {
        # launch parameters + launch ID of the build type picked for this platform (Launch game... on the tab).
        # Xbox package: the launch ID is read from the kit after the install (xbapp list)
        $ls = Get-ConsoleLaunchSetting $pkey
        [void](Add-ConsoleLaunchSteps $steps $pkey $values $mode $ls.Type $ls.Text $ls.Id 'Launch' $(if ($mode -eq 'Loose') { 'Workspace' } else { 'Package' }) ([string]$values['Workspace']))
    }

    return @{
        Row = $rowIndex; Name = [string]$c.Name; Platform = $pkey; IP = [string]$c.IP
        Steps = @($steps); DryRun = $chkDryRun.Checked; Mode = $mode; BuildPath = $buildPath
        StaggerSec = [int]$numStagger.Value
        Workspace = [string]$values['Workspace']
        Action = "Deploy $mode"; SuccessStatus = 'Deployed'
        Title = $(if ($pkgSel) { "Package deploy: " + $(if ($pkgSel.Main) { "main $($pkgSel.Main.Label)" } else { 'no main' }) + " + $($pkgSel.Dlcs.Count) DLC" + $(if ($pkgSel.Dlcs.Count) { ' (' + (($pkgSel.Dlcs | ForEach-Object { $_.Label }) -join ', ') + ')' } else { '' }) }
                  else { "$mode deploy of $buildPath" + $(if ($resolved.Gp5) { " (gp5: $([System.IO.Path]::GetFileName($resolved.Gp5)))" } else { '' }) })
        Warn = $(if ($pkgSel -and $pkgSel.Dlcs.Count -gt 0) { @{ Flag = 'DlcFailed'; Result = 'PARTIAL'; Status = 'Main OK, DLC failed'; Message = 'Some DLC did not install: {failed}' } } else { $null })
        LogFile = Join-Path $logDir ("Deploy_{0}_{1}_{2}.log" -f $script:RunStamp, ($c.Name -replace '[^\w\-]','_'), $pkey)
    }
}

# ---------------------------------------------------------------- power plans

function Normalize-Mac([string]$mac) {
    $m = ([string]$mac -replace '[^0-9A-Fa-f]','').ToUpperInvariant()
    if ($m.Length -eq 12) { return $m }
    return ''
}

function New-PowerPlan([object]$c,[int]$rowIndex,[string]$action) {
    $pkey = Get-PlatformKey ([string]$c.Platform)
    if (-not $pkey) { throw "Unsupported platform '$($c.Platform)'" }
    $values = @{ IP = [string]$c.IP; Name = [string]$c.Name; BuildPath = ''; MAC = [string]$c.MAC }
    $pv = $script:cfg.$pkey.Values
    if ($pv) { foreach ($prop in $pv.PSObject.Properties) { $values[$prop.Name] = [string]$prop.Value } }
    $pw = $script:cfg.Power
    $steps = New-Object System.Collections.ArrayList

    $stepName = @{ 'Restart' = 'Reboot'; 'Power Off' = 'PowerOff'; 'Power On' = 'PowerOn' }[$action]
    $warn = $null
    if ($action -eq 'Power Off' -and $pkey -eq 'Xbox') {
        # A kit with AlwaysOn=true powers itself straight back up after a shutdown
        $chk = Get-StepDef 'Xbox' 'CheckAlwaysOn'
        if ($chk) {
            [void]$steps.Add(@{ Type = 'Run'; Label = 'Check AlwaysOn'; Exe = $chk.Exe; Args = (Expand-Template $chk.Args $values 'Xbox CheckAlwaysOn'); ContinueOnError = $true
                ProbeVar = 'AlwaysOn'; ProbeMatch = '(?i)AlwaysOn\s*[:=]\s*true'; ReportTo = 'AlwaysOn'
                ProbeYes = 'AlwaysOn is true on this kit - it will power itself straight back on after the shutdown'
                ProbeNo  = 'AlwaysOn is false - the kit will stay off' })
            $dis = Get-StepDef 'Xbox' 'DisableAlwaysOn'
            if ($pw.XboxTurnOffAlwaysOn -eq $true -and $dis) {
                [void]$steps.Add(@{ Type = 'Run'; Label = 'Turn off AlwaysOn'; Exe = $dis.Exe; Args = (Expand-Template $dis.Args $values 'Xbox DisableAlwaysOn'); ContinueOnError = $false; RunIf = 'AlwaysOn'; SetFalse = 'AlwaysOn'; ReportTo = 'AlwaysOn' })
            } else {
                $warn = @{ Flag = 'AlwaysOn'; Result = 'BACK ON'; Status = 'On (AlwaysOn)'
                    Message = 'Shutdown sent, but AlwaysOn=true so the kit powers back on. To keep it off: set AlwaysOn=false on the kit, or "XboxTurnOffAlwaysOn": true in DeployConfig.json' }
            }
        }
    }
    $raw = $script:cfg.$pkey.Steps.$stepName
    if ($raw -and ([string]$raw.Exe).Trim().ToUpperInvariant() -eq 'WOL') {
        if ($c.MAC) { [void]$steps.Add(@{ Type = 'Wol'; Label = 'Wake-on-LAN'; Mac = [string]$c.MAC; Targets = @($pw.WolBroadcast) }) }
        else { [void]$steps.Add(@{ Type = 'Info'; Label = 'Wake'; Message = 'No MAC known - waking with directed pings only' }) }
    } else {
        $def = Get-StepDef $pkey $stepName
        if (-not $def) { throw "$pkey '$stepName' command is not configured in DeployConfig.json" }
        [void]$steps.Add(@{ Type = 'Run'; Label = $action; Exe = $def.Exe; Args = (Expand-Template $def.Args $values "$pkey $stepName"); ContinueOnError = $false; OkOutput = $def.OkOutput })
    }

    switch ($action) {
        'Restart'   { [void]$steps.Add(@{ Type = 'Wait'; Label = 'Wait for online'; GraceSec = [int]$script:cfg.Reboot.DownGraceSec; TimeoutSec = [int]$script:cfg.Reboot.OnlineTimeoutSec; SettleSec = 0 }); $ok = 'Online' }
        'Power On'  {
            $hint = $(if ($pkey -eq 'Xbox') { ' An Xbox that was fully powered off (Power Off button / xbreboot /S) cannot be woken remotely - switch it on at the console.' } else { '' })
            [void]$steps.Add(@{ Type = 'Wait'; Label = 'Wait for online'; GraceSec = 0; TimeoutSec = [int]$pw.OnTimeoutSec; SettleSec = 0; PingSec = 2; Hint = $hint }); $ok = 'Online'
        }
        'Power Off' {
            if ($pw.VerifyOffWithPing -eq $false) { $ok = 'Off (not verified)' }
            else { [void]$steps.Add(@{ Type = 'WaitOffline'; Label = 'Wait for off'; TimeoutSec = [int]$pw.OffTimeoutSec; SkipIf = 'AlwaysOn'; SkipMsg = 'AlwaysOn kit comes straight back on' }); $ok = 'Off' }
        }
    }

    return @{
        Row = $rowIndex; Name = [string]$c.Name; Platform = $pkey; IP = [string]$c.IP
        Steps = @($steps); DryRun = $chkDryRun.Checked; Mode = ''; BuildPath = ''
        Action = $action; Title = $action; SuccessStatus = $ok; Warn = $warn
        LogFile = Join-Path $logDir ("Power_{0}_{1}_{2}.log" -f $script:RunStamp, ($c.Name -replace '[^\w\-]','_'), $pkey)
    }
}

# ---------------------------------------------------------------- background worker

$Worker = {
    param($job, $sync)
    $row = $sync.Rows[$job.Row]

    function Log([string]$m) {
        $line = '[{0}] {1}: {2}' -f (Get-Date -Format 'HH:mm:ss'), $job.Name, $m
        $sync.Log.Enqueue($line)
        try { Add-Content -LiteralPath $job.LogFile -Value $line -Encoding UTF8 } catch {}
    }
    function FileOnly([string]$m) {
        try { Add-Content -LiteralPath $job.LogFile -Value ('[{0}]   {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 } catch {}
    }
    function Test-Ping([string]$ip) {
        try { return ((New-Object System.Net.NetworkInformation.Ping).Send($ip,1500).Status -eq 'Success') } catch { return $false }
    }
    function Sleep-Cancellable([int]$sec) {
        for ($i = 0; $i -lt $sec; $i++) {
            if ($sync.Cancel) { throw 'Cancelled by user' }
            Start-Sleep -Seconds 1
        }
    }
    function Wait-Online($s) {
        if ([int]$s.GraceSec -gt 0) {
            $row.Progress = "Waiting $($s.GraceSec)s for the kit to go down"
            Sleep-Cancellable ([int]$s.GraceSec)
        }
        $deadline = (Get-Date).AddSeconds([int]$s.TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if ($sync.Cancel) { throw 'Cancelled by user' }
            if (Test-Ping $job.IP) {
                $row.Status = 'Online'
                if ([int]$s.SettleSec -gt 0) {
                    $row.Progress = "Online - settling $($s.SettleSec)s"
                    Log "Online, settling $($s.SettleSec)s"
                    Sleep-Cancellable ([int]$s.SettleSec)
                } else { Log 'Online' }
                return
            }
            $row.Progress = 'Waiting for kit to come online...'
            Sleep-Cancellable $(if ([int]$s.PingSec -gt 0) { [int]$s.PingSec } else { 5 })
        }
        throw ("Kit did not come online within $($s.TimeoutSec)s." + [string]$s.Hint)
    }
    function Wait-Offline($s) {
        $deadline = (Get-Date).AddSeconds([int]$s.TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if ($sync.Cancel) { throw 'Cancelled by user' }
            if (-not (Test-Ping $job.IP)) { Log 'No longer responding to ping - off'; return }
            $row.Progress = 'Waiting for kit to power off...'
            Sleep-Cancellable 5
        }
        throw "Kit still responds to ping after $($s.TimeoutSec)s - it may not have powered off"
    }
    function Send-Wol($s) {
        $macBytes = [byte[]](($s.Mac -split '(..)' | Where-Object { $_ }) | ForEach-Object { [Convert]::ToByte($_,16) })
        $packet = [byte[]]((,0xFF * 6) + ($macBytes * 16))
        $udp = New-Object System.Net.Sockets.UdpClient
        try {
            $udp.EnableBroadcast = $true
            foreach ($t in $s.Targets) { for ($n = 0; $n -lt 3; $n++) { [void]$udp.Send($packet, $packet.Length, [string]$t, 9) } }
        } finally { $udp.Close() }
    }
    # Kits take turns: each one waits until StaggerSec has passed since the previous kit started its install.
    # The lock makes kits queue in order; the wait is cancellable.
    function Wait-StaggerSlot([int]$gap) {
        $row.Status = 'Queued (stagger)'
        [System.Threading.Monitor]::Enter($sync.StartLock)
        try {
            while ($true) {
                if ($sync.Cancel) { throw 'Cancelled by user' }
                $left = [double]($sync.LastStart.AddSeconds($gap) - (Get-Date)).TotalSeconds
                if ($left -le 0) { break }
                $row.Progress = "Staggered start - install begins in $([math]::Ceiling($left))s"
                Start-Sleep -Milliseconds 500
            }
            $sync.LastStart = Get-Date
        } finally { [System.Threading.Monitor]::Exit($sync.StartLock) }
        Log "Install slot granted (stagger ${gap}s)"
    }
    function Invoke-Step($s) {
        if (-not (Test-Path -LiteralPath $s.Exe)) { throw "Tool not found: $($s.Exe)" }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $s.Exe
        $psi.Arguments = $s.Args
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $row.Proc = $p
        $errTask = $p.StandardError.ReadToEndAsync()
        $script:LastOutput = New-Object System.Text.StringBuilder
        # Read output without blocking, so the grid shows elapsed time even while the tool is silent
        $started = Get-Date
        $last = ''
        $row.Progress = "0:00 | $($s.Label) started"
        $lineTask = $p.StandardOutput.ReadLineAsync()
        while ($true) {
            if ($lineTask.Wait(1000)) {
                $line = $lineTask.Result
                if ($null -eq $line) { break }
                $t = $line.Trim()
                if ($t) {
                    if ($t.Length -gt 140) { $t = $t.Substring(0,140) + '...' }
                    $last = $t
                    FileOnly $line
                    [void]$script:LastOutput.AppendLine($line)
                }
                $lineTask = $p.StandardOutput.ReadLineAsync()
            }
            $el = (Get-Date) - $started
            $clock = $(if ($el.TotalHours -ge 1) { '{0}:{1:mm\:ss}' -f [int][math]::Floor($el.TotalHours), $el } else { '{0:m\:ss}' -f $el })
            $row.Progress = $(if ($last) { "$clock | $last" } else { "$clock | running - no output from tool yet" })
        }
        $p.WaitForExit()
        $err = $errTask.Result
        if ($err) { [void]$script:LastOutput.AppendLine($err); foreach ($l in ($err -split "`r?`n")) { if ($l.Trim()) { FileOnly "ERR: $l"; $row.Progress = $l.Trim() } } }
        $code = $p.ExitCode
        $row.Proc = $null
        return $code
    }

    # Plain-language hints added to a failure, matched against what the tool printed
    # The most useful line the tool printed: last line mentioning an error, else the last line
    function Get-ToolMessage([string]$out) {
        $lines = @($out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^(SIE CONFIDENTIAL|Copyright|version\s*:)' })
        if ($lines.Count -eq 0) { return 'no output' }
        $err = @($lines | Where-Object { $_ -match '(?i)error|fail|unable|cannot|could not|denied|not found|timed? ?out|refused' })
        $m = $(if ($err.Count -gt 0) { $err[-1] } else { $lines[-1] })
        if ($m.Length -gt 220) { $m = $m.Substring(0,220) + '...' }
        return $m
    }
    function Get-FailureHint([string]$out,[string]$label='') {
        if ($out -match '(?i)another host has ownership|owned by another') { return ' - another PC owns this kit. Check who in Target Manager and ask them to release it, or tick "Take ownership if needed" in the PS5 tab (that takes it from them)' }
        if ($out -match '(?i)incorrectly formatted|unknown (option|argument|command)|No matching command|invalid (option|argument)') { return " - this SDK's tool does not accept the command as written in DeployConfig.json. Run `"$([System.IO.Path]::GetFileName([string]$s.Exe))`" /help and fix that command (Steps.$($label -replace '\s*\[.*$',''))" }
        if ($out -match '(?i)Invalid Target|not registered|No matching target') { return ' - the kit is not registered in Target Manager on this PC (PS5 tab: Add PS5 kits to Target Manager)' }
        if ($label -like 'Launch*' -or $label -eq 'Close game') {
            if ($out -match '(?i)already running') { return ' - the game is already running on this kit (use Close game first)' }
            if ($out -match '(?i)not found|could not be found|0x80070490|0x80073cf1') { return ' - the game (launch ID) is not installed on this kit - check the ID with Find on kit' }
        }
        if ($out -match '(?i)0x87e10008|network error') { return ' - network error: this PC cannot reach the kit' }
        if ($out -match '(?i)0x87e10009') { return ' - authentication failed: check the kit is paired with this PC (Xbox Manager)' }
        if ($out -match '(?i)0x80070005|access denied') { return ' - access denied by the kit' }
        if ($out -match '(?i)0x80070057') { return ' - invalid install state on the kit (uninstall the title and install again)' }
        if ($out -match '(?i)0x80070070') { return ' - the kit is out of storage space' }
        if ($label -eq 'Connect') { return ' - this PC could not connect to the kit. It may be owned by another PC (check Target Manager), not added to Target Manager on this PC, or switched off / unreachable' }
        if ($out -match '(?i)both' -and $out -match '(?i)storage') { return ' - the workspace exists on both internal and M.2 storage. Use a different workspace name, or add /storage:INTERNAL to the command in DeployConfig.json' }
        if ($out -match '(?i)timed? ?out|unreachable|no route|refused|lost connection') { return ' - lost contact with the kit. Check it is switched on and on the network, then retry' }
        if ($out -match '(?i)owner|ownership|another host|other host') { return ' - another PC owns this kit. Take ownership in Target Manager, or ask whoever owns it to release it' }
        if ($out -match '(?i)mount|in use|busy|locked|running') { return ' - the workspace or kit is busy (a game may be running from it). Close the game or use a different workspace name' }
        if ($out -match '(?i)space|full|insufficient|capacity') { return ' - the kit is out of storage space. Delete old workspaces or packages on the kit' }
        return ''
    }
    $state = @{}
    $started = Get-Date
    try {
        $row.Result = 'Running'
        Log ("START {0}{1}" -f $job.Title, $(if ($job.DryRun) { ' [DRY RUN]' } else { '' }))
        foreach ($s in $job.Steps) {
            if ($sync.Cancel) { throw 'Cancelled by user' }
            $row.Step = $s.Label
            if ($s.Type -eq 'Wait') {
                if ($job.DryRun) { Log 'WAIT  until kit is online (skipped in dry run)'; continue }
                Wait-Online $s
                continue
            }
            if ($s.Type -eq 'WaitOffline') {
                if ($s.SkipIf -and $state[$s.SkipIf]) { Log "$($s.Label): skipped - $($s.SkipMsg)"; continue }
                if ($job.DryRun) { Log 'WAIT  until kit is off (skipped in dry run)'; continue }
                Wait-Offline $s
                continue
            }
            if ($s.Type -eq 'Info') { Log $s.Message; $row.Status = 'Waking'; continue }
            if ($s.Type -eq 'Ping') {
                if ($job.DryRun) { Log 'PING  kit (skipped in dry run)'; continue }
                $row.Progress = 'Checking the kit is online'
                $alive = $false
                for ($n = 0; $n -lt 3 -and -not $alive; $n++) { $alive = Test-Ping $job.IP }
                if (-not $alive) { throw 'kit is offline - no reply to ping (switched off, asleep or not on the network)' }
                Log 'Kit is online'
                continue
            }
            if ($s.Type -eq 'Wol') {
                Log ('WOL   magic packet to MAC {0} via {1}' -f $s.Mac, ($s.Targets -join ', '))
                if ($job.DryRun) { $row.Progress = 'Dry run - not sent'; continue }
                $row.Status = 'Waking'
                Send-Wol $s
                Log 'Wake-on-LAN packet sent'
                continue
            }
            if ($s.SkipIf -and $state[$s.SkipIf]) { Log "$($s.Label): skipped - $($s.SkipMsg)"; continue }
            if ($s.RunIf -and -not $state[$s.RunIf]) { continue }
            if ($s.Stagger -and [int]$job.StaggerSec -gt 0) { Wait-StaggerSlot ([int]$job.StaggerSec) }
            # {{Name}} = a value an earlier step read from the kit (e.g. the Xbox launch ID)
            if ($s.Uses -and -not $job.DryRun) {
                $s = $s.Clone()
                foreach ($k in @($s.Uses)) {
                    if (-not $state[$k]) { throw "$($s.Label): $k was not found on the kit" }
                    $s.Args = $s.Args.Replace('{{' + $k + '}}', [string]$state[$k])
                }
            }
            Log ('RUN   {0}: "{1}" {2}' -f $s.Label, $s.Exe, $s.Args)
            if ($job.DryRun) { $row.Progress = 'Dry run - not executed'; continue }
            if ($s.CaptureVar) {
                # read a value from what the tool prints, e.g. the game's launch ID from xbapp list
                $code = Invoke-Step $s
                if ($sync.Cancel) { throw 'Cancelled by user' }
                $outText = $script:LastOutput.ToString()
                if ($code -ne 0) { throw ("$($s.Label) failed with exit code $code" + (Get-FailureHint $outText $s.Label) + " | tool said: " + (Get-ToolMessage $outText)) }
                # the name we expect (e.g. the PS5 tab's workspace) wins whenever the tool's output mentions it
                if ($s.CapturePrefer -and $outText.IndexOf([string]$s.CapturePrefer, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $state[$s.CaptureVar] = [string]$s.CapturePrefer; Log "$($s.CaptureVar) found on the kit: $($s.CapturePrefer)"; continue
                }
                $all = @([regex]::Matches($outText, $s.CaptureRegex) | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ } | Select-Object -Unique)
                if (-not $all.Count -and $s.CaptureLines) {
                    # plain list: one name per line (tool banner and "key: value" lines skipped)
                    $all = @($outText -split "`r?`n" | ForEach-Object { $_.Trim().TrimStart('-').Trim() } | Where-Object { $_ -and $_ -notmatch '(?i)^(SIE CONFIDENTIAL|Copyright|version\s*:|\[\]$)' -and $_ -notmatch ':' } | Select-Object -Unique)
                }
                if (-not $all.Count -and $s.CaptureFallback) { $all = @([regex]::Matches($outText, $s.CaptureFallback) | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ } | Select-Object -Unique) }
                if ($s.CapturePrefix) { $cand = @($all | Where-Object { $_.StartsWith([string]$s.CapturePrefix, [StringComparison]::OrdinalIgnoreCase) }); $want = "an app of package $($s.CapturePrefix.TrimEnd('!'))" }
                elseif ($s.CaptureFilter) { $cand = @($all | Where-Object { $_ -match $s.CaptureFilter }); $want = "an app matching '$($s.CaptureFilter)'" }
                elseif ($s.CaptureSoftFilter) { $soft = @($all | Where-Object { $_ -match $s.CaptureSoftFilter }); $cand = @(if ($all.Count -le 1 -or $soft.Count -eq 0) { $all } else { $soft }); $want = 'a workspace' }
                else { $cand = $all; $want = 'an app' }
                if ($s.CaptureWhat) {
                    $shownW = $(if ($all.Count) { $all -join ', ' } else { 'none' })
                    if ($cand.Count -eq 0) { throw "no $($s.CaptureWhat) on this kit - deploy the build first, or type the $($s.CaptureWhat) name in Launch game..." }
                    if ($cand.Count -gt 1) { throw "$($cand.Count) $($s.CaptureWhat)s on this kit ($shownW) and none is called '$($s.CapturePrefer)' - pick one with Find on kit in Launch game..." }
                }
                $shown = $(if ($all.Count) { (@($all | Select-Object -First 8) -join ', ') + $(if ($all.Count -gt 8) { ", ... ($($all.Count) in all)" } else { '' }) } else { 'none found' })
                if ($cand.Count -eq 0 -and $s.CaptureNoneFlag) { $state[$s.CaptureNoneFlag] = $true; Log $s.CaptureNoneMsg; continue }
                if ($cand.Count -eq 0) { throw "the game is not installed on this kit (looked for $want; installed apps: $shown)" }
                if ($cand.Count -gt 1 -and -not $s.CapturePrefix -and -not $s.CaptureFirst) { throw "$($cand.Count) matching games are installed ($($cand -join ', ')) - pick the build on the Xbox tab (or set Xbox.Values.LaunchId) so the tool knows which one to start" }
                $state[$s.CaptureVar] = $cand[0]
                Log ("$($s.CaptureVar) found on the kit: $($cand[0])" + $(if ($cand.Count -gt 1) { " (also there: $(@($cand | Select-Object -Skip 1) -join ', '))" } else { '' }))
                continue
            }
            if ($s.ProbeVar) {
                $code = Invoke-Step $s
                if ($sync.Cancel) { throw 'Cancelled by user' }
                $outText = $script:LastOutput.ToString()
                if ($s.ProbeMatch) {
                    # decided by what the tool printed, not its exit code
                    $state[$s.ProbeVar] = ($outText -match $s.ProbeMatch)
                    $state[$s.ProbeVar + '.Known'] = ($state[$s.ProbeVar] -or $code -eq 0)
                    if ($state[$s.ProbeVar]) { Log $s.ProbeYes }
                    elseif ($code -eq 0) { Log $s.ProbeNo }
                    else { Log ("Could not read the setting (tool said: " + (Get-ToolMessage $outText) + ') - continuing') }
                    if ($s.ReportTo) { $row[$s.ReportTo] = $(if (-not $state[$s.ProbeVar + '.Known']) { '?' } elseif ($state[$s.ProbeVar]) { 'true' } else { 'false' }) }
                    continue
                }
                $state[$s.ProbeVar] = ($code -eq 0)
                if ($code -eq 0) { Log $s.ProbeYes }
                elseif ($s.NotFoundOutput -and $outText -match $s.NotFoundOutput) { Log $s.ProbeNo }
                else { Log ("$($s.ProbeUnknown) (tool said: " + (Get-ToolMessage $outText) + ')') }
                continue
            }
            if ($s.Label -in 'Reboot','Restart') { $row.Status = 'Rebooting' }
            if ($s.Label -eq 'Power Off') { $row.Status = 'Powering off' }
            if ($s.Label -eq 'Power On') { $row.Status = 'Powering on' }
            if ($s.Label -like 'Deploy*' -or $s.Label -like 'Install*') { $row.Status = 'Deploying' }
            $code = Invoke-Step $s
            if ($sync.Cancel) { throw 'Cancelled by user' }
            if ($code -ne 0 -and $s.OkOutput -and ($script:LastOutput.ToString() -match $s.OkOutput)) {
                Log "$($s.Label) returned exit code $code, but its output matched '$($s.OkOutput)' - treating the command as accepted"
                $code = 0
            }
            if ($code -ne 0) {
                $said = Get-ToolMessage $script:LastOutput.ToString()
                if ($s.OnFailMatch -and $script:LastOutput.ToString() -match $s.OnFailMatch) {
                    $owner = 'another PC'
                    if ($s.InfoExe) {
                        # target info usually says who owns the kit; any owner/host/user line is shown as-is
                        [void](Invoke-Step @{ Exe = $s.InfoExe; Args = $s.InfoArgs; Label = 'Target info' })
                        $ol = @($script:LastOutput.ToString() -split "`r?`n" | ForEach-Object { $_.Trim() } |
                                Where-Object { $_ -match '(?i)^[^:]*(owner|owned by|in use by|host|user)[^:]*:\s*\S' -and $_ -notmatch '(?i)^\s*(target\s+)?host\s*name\s*:' })
                        $pick = @($ol | Where-Object { $_ -match '(?i)owner|owned by|in use by' }) + $ol
                        if ($pick.Count -gt 0) { $owner = ($pick[0] -replace '^[^:]*:\s*','').Trim() }
                    }
                    Log "$($s.Label): kit is owned by $owner"
                    if ($s.AskFirst) {
                        $id = [guid]::NewGuid().ToString()
                        $sync.Asks.Enqueue(@{ Id = $id; Name = $job.Name; IP = $job.IP; Owner = $owner })
                        $row.Status = 'Waiting for you'
                        $row.Progress = "In use by $owner - answer the prompt to take it over"
                        $deadline = (Get-Date).AddMinutes(15)
                        while (-not $sync.Answers.ContainsKey($id)) {
                            if ($sync.Cancel) { throw 'Cancelled by user' }
                            if ((Get-Date) -gt $deadline) { $sync.Answers[$id] = $false; Log 'No answer within 15 minutes - not taking ownership' }
                            Start-Sleep -Milliseconds 300
                        }
                        $yes = [bool]$sync.Answers[$id]; $sync.Answers.Remove($id)
                        if (-not $yes) { throw "kit is in use by $owner - you chose not to disconnect them" }
                        Log "You confirmed: disconnecting $owner and taking ownership"
                    }
                    $state[$s.OnFailFlag] = $true
                }
                elseif ($s.ContinueOnError) {
                    Log "$($s.Label) returned exit code $code - continuing (tool said: $said)"
                    if ($s.OnFail) { $state[$s.OnFail] = $true; $state['FailedNames'] = @($state['FailedNames']) + $s.FailName }
                }
                else { throw ("$($s.Label) failed with exit code $code" + (Get-FailureHint $script:LastOutput.ToString() $s.Label) + " | tool said: $said") }
            } else {
                Log "$($s.Label) OK"
                if ($s.SetFalse) { $state[$s.SetFalse] = $false; if ($s.ReportTo) { $row[$s.ReportTo] = 'false' } }
                if ($script:LastOutput.ToString() -match '(?i)reboot|restart') { Log "Note: the tool says a reboot may be needed for this to take effect" }
            }
        }
        if ($job.Expect -and -not $job.DryRun) {
            $want = ($job.Expect.Value -eq $true)
            if (-not $state[$job.Expect.Flag + '.Known']) { throw "could not read $($job.Expect.Flag) back to confirm the change" }
            if ($state[$job.Expect.Flag] -ne $want) { throw "$($job.Expect.Flag) is still $($state[$job.Expect.Flag].ToString().ToLower()) after the change - the setting did not stick" }
        }
        $mins = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
        if ($job.DryRun) { $row.Result = 'DRY RUN OK'; $row.Status = 'Not changed' }
        elseif ($job.Warn -and $state[$job.Warn.Flag]) {
            $wm = $job.Warn.Message.Replace('{failed}', ((@($state['FailedNames']) | Where-Object { $_ }) -join ', '))
            $row.Result = $job.Warn.Result; $row.Status = $job.Warn.Status; Log $wm
        }
        elseif ($job.StatusFrom) { $row.Result = 'SUCCESS'; $row.Status = "AlwaysOn: $($row[$job.StatusFrom])" }
        else { $row.Result = 'SUCCESS'; $row.Status = $job.SuccessStatus }
        $row.Step = 'Done'
        $row.Progress = "Finished in $mins min" + $(if ($row.Result -eq 'PARTIAL') { ' - DLC failed: ' + ((@($state['FailedNames']) | Where-Object { $_ }) -join ', ') } else { '' })
        Log "DONE in $mins min"
    } catch {
        $msg = $_.Exception.Message
        $row.Result = $(if ($msg -like 'Cancelled*') { 'CANCELLED' } else { 'FAILED' })
        $row.Status = $(if ($msg -like 'Kit still responds*') { 'Still on?' } elseif ($msg -like 'kit is offline*') { 'Offline' } else { 'Error' })
        $row.Progress = $msg
        Log "FAILED: $msg"
    }
}

# ---------------------------------------------------------------- run control

# The console buttons (check / deploy / power / tick) only apply to the Xbox and PS5 tabs
function Update-SharedButtons {
    $pc = ($tabs.SelectedTab -eq $tabPC)
    foreach ($b in @($btnStatus,$btnPreview,$btnDeploySel,$btnDeployIdle,$btnPowerOn,$btnPowerOff,$btnRestart,$btnSelectAll,$btnClearSel)) { $b.Enabled = (-not $script:Busy) -and (-not $pc) }
    $grpOpt.Enabled = (-not $script:Busy) -and (-not $pc)
    $chkRmOnly.Enabled = -not $pc
}

function Set-Busy([bool]$busy) {
    $script:Busy = $busy
    foreach ($b in @($btnStatus,$btnPreview,$btnDeploySel,$btnDeployIdle,$btnReload,$btnScan,$btnUseBuild,$btnClearCache,$btnPowerOn,$btnPowerOff,$btnRestart,$btnAoOn,$btnAoOff,$btnAoRead,
                     $btnXboxFolder,$btnXboxPkg,$btnPS5Folder,$btnMainBrowse,$btnMainClear,$btnDlcAdd,$btnDlcRemove,$btnDlcClear)) { $b.Enabled = -not $busy }
    $grpOpt.Enabled = -not $busy
    $rbPkg.Enabled = -not $busy; $rbLoose.Enabled = -not $busy
    $txtMain.ReadOnly = $busy; $lstDlc.Enabled = -not $busy
    $txtWorkspace.ReadOnly = $busy
    $chkConnect.Enabled = -not $busy
    $chkForceOwn.Enabled = (-not $busy) -and $chkConnect.Checked
    $txtXbox.ReadOnly = $busy
    $txtPS5.ReadOnly = $busy
    $btnCancel.Enabled = $busy
    Update-SharedButtons
}

function Start-Deploy([int[]]$indices) {
    if ($indices.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('No consoles selected.','HYD Build Deploy') | Out-Null; return }
    try { Load-Config } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Config error') | Out-Null; return }
    $script:RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    $plans = @(); $errors = @(); $warnings = @(); $notIdle = @()
    $usedPlatforms = @{}
    foreach ($i in $indices) {
        $c = $script:consoles[$i]
        try {
            $plans += ,(New-DeployPlan $c $i)
            $usedPlatforms[(Get-PlatformKey ([string]$c.Platform))] = $true
            if (([string]$c.Idle).ToLowerInvariant() -ne 'true') { $notIdle += $c.Name }
        } catch { $errors += "$($c.Name) ($($c.Platform), $($c.IP)): $($_.Exception.Message)" }
    }
    if ($errors.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show("Cannot start - fix these first:`n`n" + ($errors -join "`n"),'HYD Build Deploy',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    foreach ($pkey in $usedPlatforms.Keys) {
        if ($pkey -eq 'PS5' -and $rbPkg.Checked) { $warnings += @((Get-Ps5PackageProblems).Warnings); continue }
        $rb = Resolve-Build $pkey (Get-BuildPathFor $pkey)
        if ($rb.Note) { $warnings += "$pkey $($rb.Note)" }
        $warnings += Get-BuildWarnings $pkey $rb.Path
    }

    $msg = "Deploy to $($plans.Count) console(s)?`n`n" + (Format-TargetList $indices) + "`n`n"
    if ($usedPlatforms['Xbox']) { $msg += "Xbox: $((Resolve-Build 'Xbox' $txtXbox.Text.Trim()).Path)`n" }
    if ($usedPlatforms['PS5'])  {
        if ($rbPkg.Checked) {
            $ps = Get-Ps5PackageSelection
            $msg += "PS5 packages:`n      Main: " + $(if ($ps.Main) { "$($ps.Main.Label)   ($($ps.Main.Path))" } else { '(none - DLC only)' }) + "`n"
            if ($ps.Dlcs.Count) { foreach ($d in $ps.Dlcs) { $msg += "      DLC:  $($d.Label)   ($($d.Path))`n" } } else { $msg += "      DLC:  (none)`n" }
        } else {
            $msg += "PS5 loose folder: $((Resolve-Build 'PS5' $txtPS5.Text.Trim()).Path)`n"
        }
    }
    $msg += "`nReboot first: $($chkReboot.Checked)   Uninstall first: $($chkUninstall.Checked)   Launch after: $($chkLaunch.Checked)"
    if ($chkLaunch.Checked) {
        foreach ($pk in @('Xbox','PS5')) {
            if (-not $usedPlatforms[$pk]) { continue }
            $ls = Get-ConsoleLaunchSetting $pk; $la = Get-ConsoleLaunchArgs $ls.Text @{} $ls.Type
            $msg += "`n$pk launch: $($ls.Type) build, parameters: " + $(if ($la) { $la } else { '(none)' }) + $(if ($ls.Id) { ", ID $($ls.Id)" } else { '' })
        }
    }
    $msg += "`nParallel: $($numParallel.Value)   Stagger: $($numStagger.Value)s between install starts"
    # Many kits: copy the build to this PC once instead of streaming it from the NAS for every kit
    $cacheItems = @(); $cacheRoot = ''
    $limit = $(if ($null -ne $script:cfg.Cache.WhenMoreThanKits) { [int]$script:cfg.Cache.WhenMoreThanKits } else { 5 })
    if ($script:cfg.Cache.Enabled -ne $false -and $plans.Count -gt $limit) {
        if ($chkDryRun.Checked) { $msg += "`n`nCache: skipped in a dry run (a real run would copy the build to this PC first)." }
        else {
            $srcs = @(Get-CacheSources $usedPlatforms)
            if ($srcs.Count) {
                $cacheRoot = Get-CacheRoot
                $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                $status.Text = 'Measuring the build for the local cache...'; [System.Windows.Forms.Application]::DoEvents()
                try { foreach ($s in $srcs) { $it = New-CacheItem $s $cacheRoot; Measure-CacheItem $it; $cacheItems += $it } }
                catch { $cacheItems = @(); Append-UiLog "Cache: could not measure the build - $($_.Exception.Message)" }
                finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
                if ($cacheItems.Count) {
                    $tot = [double](($cacheItems | Measure-Object Size -Sum).Sum); $hv = [double](($cacheItems | Measure-Object Have -Sum).Sum)
                    $free = Get-FreeSpace $cacheRoot
                    if ($null -eq $free) { $free = Get-FreeSpace (Split-Path -Qualifier $cacheRoot -ErrorAction SilentlyContinue) }
                    if ($null -ne $free -and $free -lt ($tot - $hv) + 5GB) {
                        $a = [System.Windows.Forms.MessageBox]::Show("Not enough space to cache the build on this PC.`n`nBuild: $(Format-Size $tot)   Already cached: $(Format-Size $hv)   Free on $([System.IO.Path]::GetPathRoot($cacheRoot)): $(Format-Size $free)`n`nYes = deploy straight from the NAS instead (slower)`nNo = cancel (free some space or use Clear Cache)",'Build cache',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
                        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                        $cacheItems = @()
                    } else {
                        $msg += "`n`nCache: $($plans.Count) kits (more than $limit), so the build ($(Format-Size $tot)" + $(if ($hv -gt 0) { ", $(Format-Size $hv) already cached" } else { '' }) + ") is copied ONCE to`n      $cacheRoot`n      and every kit is deployed from there."
                    }
                }
            }
        }
    }
    if ($usedPlatforms['PS5'] -and $chkConnect.Checked -and $chkForceOwn.Checked) { $msg += "`n`nTake ownership is ON: if a PS5 kit is owned by another PC you will be asked before it is taken over." }
    $wsNames = @($plans | Where-Object { $_.Platform -eq 'PS5' -and $_.Mode -eq 'Loose' } | ForEach-Object { $_.Workspace } | Sort-Object -Unique)
    if ($wsNames.Count -gt 0) { $msg += "`nPS5 workspace: " + (($wsNames | ForEach-Object { '"' + $_ + '"' }) -join ', ') + "  (an existing workspace with this name is updated in place)" }
    if ($chkDryRun.Checked) { $msg += "`n`nDRY RUN - commands are logged, nothing is executed." }
    if ($notIdle.Count -gt 0) { $msg += "`n`nNOT marked idle (someone may be using these): " + ($notIdle -join ', ') }
    if ($warnings.Count -gt 0) { $msg += "`n`nWarnings:`n" + ($warnings -join "`n") }
    $answer = [System.Windows.Forms.MessageBox]::Show($msg,'Confirm Deploy',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    if ($cacheItems.Count) { Start-CacheThenDeploy $plans $cacheItems $cacheRoot; return }
    Start-RunPlans $plans ([int]$numParallel.Value) 'Deploy'
}

function Start-RunPlans($plans,[int]$parallel,[string]$label) {
    $sync.Cancel = $false
    $sync.StartLock = New-Object System.Object
    $sync.LastStart = [datetime]::MinValue
    $script:RunLabel = $label
    $script:Pool = [runspacefactory]::CreateRunspacePool(1, [math]::Max(1,$parallel))
    $script:Pool.Open()
    $script:Jobs = @()
    foreach ($plan in $plans) {
        $sync.Rows[$plan.Row] = [hashtable]::Synchronized(@{ Status = 'Queued'; Step = ''; Progress = 'Waiting for a free slot'; Result = 'Queued'; Proc = $null })
        $ps = [powershell]::Create()
        $ps.RunspacePool = $script:Pool
        [void]$ps.AddScript($Worker).AddArgument($plan).AddArgument($sync)
        $script:Jobs += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Plan = $plan; Logged = $false }
    }
    Append-UiLog ("==== {0} {1}: {2} console(s), parallel {3}{4} ====" -f $label, $script:RunStamp, @($plans).Count, $parallel, $(if ($chkDryRun.Checked) { ', DRY RUN' } else { '' }))
    Set-Busy $true
    $status.Text = "$label running on $(@($plans).Count) console(s)..."
    $timer.Start()
}

function Format-TargetList([int[]]$indices) {
    $lines = @($indices | Select-Object -First 12 | ForEach-Object { $c = $script:consoles[$_]; "  {0}  ({1})  {2}" -f $c.Name, $c.Platform, $c.IP })
    if ($indices.Count -gt 12) { $lines += "  ...and $($indices.Count - 12) more" }
    # ticked kits hidden by the Filter box are included - say so, so nobody is surprised
    $hidden = @($indices | Where-Object { $r = Get-GridRow $_; $r -and -not $r.Visible }).Count
    if ($hidden -gt 0) { $lines += "  ($hidden of these are hidden by the current filter)" }
    return ($lines -join "`n")
}

# Xbox AlwaysOn: Read, or set On/Off and read back to confirm
function New-AlwaysOnPlan([object]$c,[int]$rowIndex,[string]$action) {
    $values = @{ IP = [string]$c.IP; Name = [string]$c.Name }
    $chk = Get-StepDef 'Xbox' 'CheckAlwaysOn'
    if (-not $chk) { throw "Xbox 'CheckAlwaysOn' command is not configured in DeployConfig.json" }
    $read = @{ Type = 'Run'; Label = 'Read AlwaysOn'; Exe = $chk.Exe; Args = (Expand-Template $chk.Args $values 'Xbox CheckAlwaysOn'); ContinueOnError = $true
        ProbeVar = 'AlwaysOn'; ProbeMatch = '(?i)AlwaysOn\s*[:=]\s*true'; ReportTo = 'AlwaysOn'
        ProbeYes = 'AlwaysOn is true'; ProbeNo = 'AlwaysOn is false' }
    $steps = New-Object System.Collections.ArrayList
    $expect = $null
    if ($action -ne 'AlwaysOn Read') {
        $want = ($action -eq 'AlwaysOn On')
        $stepName = $(if ($want) { 'EnableAlwaysOn' } else { 'DisableAlwaysOn' })
        $def = Get-StepDef 'Xbox' $stepName
        if (-not $def) { throw "Xbox '$stepName' command is not configured in DeployConfig.json" }
        [void]$steps.Add(@{ Type = 'Run'; Label = $action; Exe = $def.Exe; Args = (Expand-Template $def.Args $values "Xbox $stepName"); ContinueOnError = $false })
        $expect = @{ Flag = 'AlwaysOn'; Value = $want }
    }
    [void]$steps.Add($read)
    return @{
        Row = $rowIndex; Name = [string]$c.Name; Platform = 'Xbox'; IP = [string]$c.IP
        Steps = @($steps); DryRun = $chkDryRun.Checked; Mode = ''; BuildPath = ''
        Action = $action; Title = $action; SuccessStatus = ''; StatusFrom = 'AlwaysOn'; Expect = $expect
        LogFile = Join-Path $logDir ("Power_{0}_{1}_Xbox.log" -f $script:RunStamp, ($c.Name -replace '[^\w\-]','_'))
    }
}

function Start-AlwaysOn([int[]]$indices,[string]$action) {
    if ($indices.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select one or more Xbox consoles first.','HYD Build Deploy') | Out-Null; return }
    try { Load-Config } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Config error') | Out-Null; return }
    $xb = @($indices | Where-Object { $script:consoles[$_].Platform -eq 'Xbox' })
    $skipped = $indices.Count - $xb.Count
    if ($xb.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('AlwaysOn is an Xbox setting - no Xbox consoles are selected.','HYD Build Deploy') | Out-Null; return }
    $script:RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $plans = @()
    try { foreach ($i in $xb) { $plans += ,(New-AlwaysOnPlan $script:consoles[$i] $i $action) } }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'HYD Build Deploy') | Out-Null; return }
    if ($skipped -gt 0) { Append-UiLog "AlwaysOn: $skipped PS5 kit(s) in the selection skipped (Xbox-only setting)" }
    if ($action -ne 'AlwaysOn Read') {
        $effect = $(if ($action -eq 'AlwaysOn On') { 'These kits will power themselves back on after any shutdown, so Power Off will not keep them off.' }
                    else { 'Power Off will really turn these kits off - they can then ONLY be switched on at the console (no remote power on).' })
        $msg = "Set AlwaysOn = $(if ($action -eq 'AlwaysOn On') { 'true' } else { 'false' }) on $($plans.Count) Xbox kit(s)?`n`n" + (Format-TargetList $xb) + "`n`n$effect"
        if ($chkDryRun.Checked) { $msg += "`n`nDRY RUN - commands are logged, nothing is executed." }
        $answer = [System.Windows.Forms.MessageBox]::Show($msg,"Confirm $action",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $par = [int]$script:cfg.Power.Parallel; if ($par -lt 1) { $par = 32 }
    Start-RunPlans $plans $par $action
}

function Start-Power([int[]]$indices,[string]$action) {
    if ($indices.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select one or more consoles first.','HYD Build Deploy') | Out-Null; return }
    try { Load-Config } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Config error') | Out-Null; return }
    $script:RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $plans = @(); $errors = @(); $notIdle = @()
    foreach ($i in $indices) {
        $c = $script:consoles[$i]
        try {
            $plans += ,(New-PowerPlan $c $i $action)
            if (([string]$c.Idle).ToLowerInvariant() -ne 'true') { $notIdle += "$($c.Name) ($($c.Platform))" }
        } catch { $errors += "$($c.Name) ($($c.Platform)): $($_.Exception.Message)" }
    }
    if ($errors.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show("Cannot start - fix these first:`n`n" + ($errors -join "`n"),'HYD Build Deploy',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    $msg = "$action $($plans.Count) console(s)?`n`n" + (Format-TargetList $indices)
    if ($action -ne 'Power On') {
        $msg += "`n`nAnything running on these kits will be closed and unsaved progress lost."
        if ($notIdle.Count -gt 0) {
            $shown = @($notIdle | Select-Object -First 15)
            $more = $(if ($notIdle.Count -gt 15) { "`n...and $($notIdle.Count - 15) more" } else { '' })
            $msg += "`n`nNOT marked idle (someone may be using these):`n" + ($shown -join "`n") + $more
        }
    }
    if ($chkDryRun.Checked) { $msg += "`n`nDRY RUN - commands are logged, nothing is executed." }
    $icon = $(if ($action -eq 'Power On') { [System.Windows.Forms.MessageBoxIcon]::Question } else { [System.Windows.Forms.MessageBoxIcon]::Warning })
    $answer = [System.Windows.Forms.MessageBox]::Show($msg,"Confirm $action",[System.Windows.Forms.MessageBoxButtons]::YesNo,$icon)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $par = [int]$script:cfg.Power.Parallel; if ($par -lt 1) { $par = 32 }
    Start-RunPlans $plans $par $action
}

function Stop-Deploy {
    $answer = [System.Windows.Forms.MessageBox]::Show("Cancel everything that is running?`n`nKits mid-deploy will be left with a partial build and must be redeployed. Power commands already sent cannot be undone.",'Confirm Cancel',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $sync.Cancel = $true
    Stop-CacheRun
    foreach ($key in @($sync.Rows.Keys)) {
        $p = $sync.Rows[$key].Proc
        if ($p -and -not $p.HasExited) {
            try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch {}
        }
    }
    $status.Text = 'Cancelling...'
}

# ---------------------------------------------------------------- Target Manager sync (PS5)
# Adds PS5 kits from the console list that Target Manager on this PC does not know yet.
# Runs in the background; checks prospero-ctrl's own help first and stops after repeated failures.
$TmWorker = {
    param($exe, $listArgs, $kits, $sync, $logFile, $maxFailures)
    function Log([string]$m) {
        $line = '[{0}] Target Manager: {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
        $sync.Log.Enqueue($line)
        try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch {}
    }
    function Run([string]$a, [int]$timeoutMs = 60000) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe; $psi.Arguments = $a; $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($timeoutMs)) { try { $p.Kill() } catch {}; return @{ Code = -1; Out = 'timed out' } }
        $p.WaitForExit()
        try { Add-Content -LiteralPath $logFile -Value ("  > $a  (exit $($p.ExitCode))`r`n" + $o.Result + $e.Result) -Encoding UTF8 } catch {}
        return @{ Code = $p.ExitCode; Out = ($o.Result + "`n" + $e.Result) }
    }
    function Said([string]$out) {
        $l = @($out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^(SIE CONFIDENTIAL|Copyright|version\s*:)' })
        if ($l.Count -eq 0) { return 'no output' }
        $err = @($l | Where-Object { $_ -match '(?i)error|fail|unable|cannot|could not|denied|timed? ?out|refused' })
        if ($err.Count -gt 0) { return $err[-1] } else { return $l[-1] }
    }
    try {
        if (-not (Test-Path -LiteralPath $exe)) { Log "prospero-ctrl not found ($exe) - skipped"; return }
        $help = Run 'help target'
        $usage = @($help.Out -split "`r?`n" | Where-Object { $_ -match '^\s*target\s+add\b' })
        if ($usage.Count -eq 0) { Log "this prospero-ctrl has no 'target add' command - skipped (see the log file for its 'help target' output)"; return }
        Log ("SDK usage: " + ($usage[0].Trim() -replace '\s{2,}',' '))
        $list = Run $listArgs
        if ($list.Code -ne 0) { Log ("could not read the target list - skipped (tool said: " + (Said $list.Out) + ")"); return }
        $missing = @($kits | Where-Object { $list.Out -notmatch ('(?<![\d.])' + [regex]::Escape($_.IP) + '(?![\d.])') })
        $have = $kits.Count - $missing.Count
        if ($missing.Count -eq 0) { Log "all $($kits.Count) PS5 kits are already in Target Manager"; return }
        Log "$have of $($kits.Count) PS5 kits already in Target Manager - adding $($missing.Count)"
        $added = 0; $failed = 0; $streak = 0; $offline = @()
        foreach ($k in $missing) {
            if ($sync.TmCancel) { Log 'stopped'; break }
            $r = Run $k.Args
            if ($r.Code -eq 0 -or $r.Out -match '(?i)already') { $added++; $streak = 0; Log "added $($k.Name) ($($k.IP))" }
            elseif ($r.Out -match '(?i)actively refused|connected to the network|unable to add the new target|timed? ?out|unreachable|no route|host is down') {
                # the command worked - the kit just did not answer (off / offline). Try again on the next sync.
                $offline += "$($k.Name) ($($k.IP))"; $streak = 0
                Log "skipped $($k.Name) ($($k.IP)) - kit not reachable (off or offline), will retry next sync"
            }
            else {
                $failed++; $streak++
                Log "could not add $($k.Name) ($($k.IP)): $(Said $r.Out)"
                if ($added -eq 0 -and $streak -ge $maxFailures) {
                    Log "stopped after $streak failures in a row and none added - check TargetAdd in DeployConfig.json against the SDK usage line above"
                    break
                }
            }
        }
        Log "done: $added added, $($offline.Count) not reachable (off/offline), $failed other failures, $have already present"
    } catch { Log "error: $($_.Exception.Message)" }
}

function Start-TargetManagerSync([bool]$manual) {
    if ($script:TmPS -and -not $script:TmHandle.IsCompleted) { if ($manual) { Append-UiLog 'Target Manager: a sync is already running' }; return }
    $add = Get-StepDef 'PS5' 'TargetAdd'
    $list = Get-StepDef 'PS5' 'TargetList'
    if (-not $add -or -not $list) { if ($manual) { Append-UiLog 'Target Manager: TargetAdd / TargetList are not configured in DeployConfig.json' }; return }
    $kits = @()
    for ($i = 0; $i -lt $script:consoles.Count; $i++) {
        $c = $script:consoles[$i]
        if ($c.Platform -ne 'PS5' -or ([string]$c.Enabled).ToLowerInvariant() -ne 'true') { continue }
        try { $kits += [pscustomobject]@{ Name = [string]$c.Name; IP = [string]$c.IP; Args = (Expand-Template $add.Args @{ IP = [string]$c.IP; Name = [string]$c.Name } 'PS5 TargetAdd') } }
        catch { Append-UiLog "Target Manager: $($_.Exception.Message)"; return }
    }
    if ($kits.Count -eq 0) { return }
    $sync.TmCancel = $false
    $logFile = Join-Path $logDir ("TargetManager_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    $maxF = $(if ($script:cfg.TargetManager.StopAfterFailures) { [int]$script:cfg.TargetManager.StopAfterFailures } else { 3 })
    Append-UiLog "Target Manager: checking $($kits.Count) PS5 kit(s) in the background..."
    $script:TmPS = [powershell]::Create()
    [void]$script:TmPS.AddScript($TmWorker).AddArgument($list.Exe).AddArgument($list.Args).AddArgument($kits).AddArgument($sync).AddArgument($logFile).AddArgument($maxF)
    $script:TmHandle = $script:TmPS.BeginInvoke()
    $btnTmSync.Enabled = $false
    $tmTimer.Start()
}

# drains the shared log while a sync runs (the main timer only runs during deploys)
$tmTimer = New-Object System.Windows.Forms.Timer
$tmTimer.Interval = 500
$tmTimer.Add_Tick({
    $line = $null
    while ($sync.Log.TryDequeue([ref]$line)) { Append-UiLog $line }
    if ($script:TmHandle -and $script:TmHandle.IsCompleted) {
        try { $script:TmPS.EndInvoke($script:TmHandle) | Out-Null } catch { Append-UiLog "Target Manager: $($_.Exception.Message)" }
        $script:TmPS.Dispose(); $script:TmPS = $null; $script:TmHandle = $null
        while ($sync.Log.TryDequeue([ref]$line)) { Append-UiLog $line }
        $btnTmSync.Enabled = $true
        $tmTimer.Stop()
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$timer.Add_Tick({
    $line = $null
    while ($sync.Log.TryDequeue([ref]$line)) { Append-UiLog $line }

    # A worker found a kit owned by another PC and needs a yes/no before taking it over
    if (-not $script:Asking -and $sync.Asks.Count -gt 0) {
        $ask = $null
        if ($sync.Asks.TryDequeue([ref]$ask)) {
            if ($sync.Cancel) { $sync.Answers[$ask.Id] = $false }
            else {
                $script:Asking = $true
                try {
                    $more = $sync.Asks.Count
                    $q = "$($ask.Name)'s PS5 ($($ask.IP)) is in use by:`n`n    $($ask.Owner)`n`n" +
                         "Are you sure you want to disconnect $($ask.Owner) and connect this PC to the console?`n`n" +
                         "They lose control of the kit immediately. No = skip this kit (other kits carry on)." +
                         $(if ($more -gt 0) { "`n`n($more more kit(s) waiting for an answer after this one)" } else { '' })
                    $res = [System.Windows.Forms.MessageBox]::Show($form, $q, 'Take over this PS5?', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
                    $sync.Answers[$ask.Id] = ($res -eq [System.Windows.Forms.DialogResult]::Yes)
                    Append-UiLog ("Take over {0} ({1}) from {2}: {3}" -f $ask.Name, $ask.IP, $ask.Owner, $(if ($sync.Answers[$ask.Id]) { 'YES' } else { 'no' }))
                } finally { $script:Asking = $false }
            }
        }
    }

    foreach ($key in @($sync.Rows.Keys)) {
        $r = $sync.Rows[$key]
        $gr = Get-GridRow ([int]$key)
        $gr.Cells['Status'].Value = $r.Status
        $gr.Cells['Step'].Value = $r.Step
        $gr.Cells['Progress'].Value = $r.Progress
        $gr.Cells['Result'].Value = $r.Result
        if ($r.AlwaysOn -and $gr.DataGridView.Columns.Contains('AlwaysOn')) { $gr.Cells['AlwaysOn'].Value = $r.AlwaysOn }
        switch ($r.Result) {
            'SUCCESS'    { $gr.Cells['Result'].Style.BackColor = [System.Drawing.Color]::FromArgb(198,239,206) }
            'DRY RUN OK' { $gr.Cells['Result'].Style.BackColor = [System.Drawing.Color]::FromArgb(221,235,247) }
            'FAILED'     { $gr.Cells['Result'].Style.BackColor = [System.Drawing.Color]::FromArgb(255,199,206) }
            'PARTIAL'    { $gr.Cells['Result'].Style.BackColor = [System.Drawing.Color]::FromArgb(255,235,156) }
            'BACK ON'    { $gr.Cells['Result'].Style.BackColor = [System.Drawing.Color]::FromArgb(255,235,156) }
            'CANCELLED'  { $gr.Cells['Result'].Style.BackColor = [System.Drawing.Color]::FromArgb(255,235,156) }
            default      { $gr.Cells['Result'].Style.BackColor = [System.Drawing.Color]::Empty }
        }
    }

    $running = 0
    foreach ($j in $script:Jobs) {
        if (-not $j.Handle.IsCompleted) { $running++; continue }
        if (-not $j.Logged) {
            try { $j.PS.EndInvoke($j.Handle) | Out-Null } catch { Append-UiLog "Worker error for $($j.Plan.Name): $($_.Exception.Message)" }
            $r = $sync.Rows[$j.Plan.Row]
            Write-Log $j.Plan.Name $j.Plan.Platform $j.Plan.IP $j.Plan.Action $r.Result ("{0} | {1}" -f $j.Plan.BuildPath, $r.Progress)
            $j.PS.Dispose()
            $j.Logged = $true
        }
    }
    if ($running -gt 0) {
        $done = $script:Jobs.Count - $running
        $status.Text = "$($script:RunLabel): $done of $($script:Jobs.Count) finished"
    } elseif ($script:Jobs.Count -gt 0) {
        $timer.Stop()
        $total = $script:Jobs.Count
        $ok = @($script:Jobs | Where-Object { $sync.Rows[$_.Plan.Row].Result -in 'SUCCESS','DRY RUN OK' }).Count
        $script:Pool.Close(); $script:Pool.Dispose(); $script:Pool = $null
        $script:Jobs = @()
        Set-Busy $false
        $status.Text = "$($script:RunLabel) finished: $ok of $total succeeded | logs folder has per-kit detail"
        Append-UiLog "==== $($script:RunLabel) finished: $ok of $total OK ===="
    }
})

# ---------------------------------------------------------------- consoles

# Reads every sheet of an .xlsx without Excel or extra modules. Works while the file is open in Excel.
function Read-XlsxRows([string]$path) {
    Add-Type -AssemblyName System.IO.Compression
    $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $zip = $null
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
        $readXml = {
            param([string]$entryName)
            $e = $zip.GetEntry($entryName)
            if (-not $e) { return $null }
            $sr = New-Object System.IO.StreamReader($e.Open())
            try { $x = New-Object System.Xml.XmlDocument; $x.LoadXml($sr.ReadToEnd()); return $x } finally { $sr.Dispose() }
        }
        $mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
        $relNs  = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'

        $shared = New-Object 'System.Collections.Generic.List[string]'
        $sst = & $readXml 'xl/sharedStrings.xml'
        if ($sst) {
            $ns = New-Object System.Xml.XmlNamespaceManager($sst.NameTable); $ns.AddNamespace('m',$mainNs)
            foreach ($si in $sst.SelectNodes('/m:sst/m:si',$ns)) {
                $shared.Add((($si.SelectNodes('.//m:t[not(ancestor::m:rPh)]',$ns) | ForEach-Object { $_.InnerText }) -join ''))
            }
        }

        $wb = & $readXml 'xl/workbook.xml'
        $rels = & $readXml 'xl/_rels/workbook.xml.rels'
        $targets = @{}
        foreach ($r in $rels.DocumentElement.ChildNodes) { if ($r.Id) { $targets[$r.Id] = $r.Target } }
        $wns = New-Object System.Xml.XmlNamespaceManager($wb.NameTable); $wns.AddNamespace('m',$mainNs)

        $out = New-Object System.Collections.ArrayList
        foreach ($sheet in $wb.SelectNodes('/m:workbook/m:sheets/m:sheet',$wns)) {
            $target = [string]$targets[$sheet.GetAttribute('id',$relNs)]
            if (-not $target) { continue }
            $entry = $(if ($target.StartsWith('/')) { $target.TrimStart('/') } else { 'xl/' + $target })
            $sx = & $readXml $entry
            if (-not $sx) { continue }
            $sns = New-Object System.Xml.XmlNamespaceManager($sx.NameTable); $sns.AddNamespace('m',$mainNs)
            foreach ($row in $sx.SelectNodes('/m:worksheet/m:sheetData/m:row',$sns)) {
                $cells = @{}
                foreach ($c in $row.SelectNodes('m:c',$sns)) {
                    $letters = ([string]$c.GetAttribute('r')) -replace '\d',''
                    $col = 0; foreach ($ch in $letters.ToCharArray()) { $col = $col * 26 + ([int][char]$ch - 64) }
                    $t = $c.GetAttribute('t')
                    $vNode = $c.SelectSingleNode('m:v',$sns)
                    $val = ''
                    if ($t -eq 's' -and $vNode) { $val = $shared[[int]$vNode.InnerText] }
                    elseif ($t -eq 'inlineStr') { $val = (($c.SelectNodes('.//m:t',$sns) | ForEach-Object { $_.InnerText }) -join '') }
                    elseif ($vNode) { $val = $vNode.InnerText }
                    $cells[$col] = [string]$val
                }
                [void]$out.Add([pscustomobject]@{ Sheet = $sheet.GetAttribute('name'); Row = [int]$row.GetAttribute('r'); Cells = $cells })
            }
        }
        return $out
    } finally {
        if ($zip) { $zip.Dispose() }
        $fs.Dispose()
    }
}

function Get-ConsoleListPath {
    $configured = [string]$script:cfg.ConsoleList
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if ([System.IO.Path]::IsPathRooted($configured)) { return $configured }
        return (Join-Path $base $configured)
    }
    $xlsx = Join-Path $base 'Console_IP_List.xlsx'
    if (Test-Path -LiteralPath $xlsx) { return $xlsx }
    return $csvPath
}

function Test-IPv4([string]$ip) {
    if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $false }
    foreach ($o in $ip.Split('.')) { if ([int]$o -gt 255) { return $false } }
    return $true
}

# Turns raw rows (from xlsx or csv) into validated consoles; returns warnings for anything skipped or guessed
function Convert-ConsoleRows($rawRows) {
    $result = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $seenIp = @{}
    foreach ($r in $rawRows) {
        $where = "$($r.Where)"
        $name = ([string]$r.Name).Trim()
        $ip = ([string]$r.IP).Trim()
        $rawPlatform = ([string]$r.Platform).Trim()
        if (-not $name -and -not $ip) { continue }
        if (-not $name) { [void]$warnings.Add("SKIPPED $where - no Name (IP '$ip')"); continue }
        if (-not (Test-IPv4 $ip)) { [void]$warnings.Add("SKIPPED $where $name - IP '$ip' is not a valid IP address"); continue }
        $pkey = Get-PlatformKey $rawPlatform
        if (-not $pkey) {
            $pkey = Get-PlatformKey ([string]$r.SheetName)
            if ($pkey) { [void]$warnings.Add("NOTE    $where $name - platform '$rawPlatform' unclear, using sheet name -> $pkey") }
            else { [void]$warnings.Add("SKIPPED $where $name - platform '$rawPlatform' not recognised (use Xbox or PS5)"); continue }
        }
        if ($seenIp.ContainsKey($ip)) { [void]$warnings.Add("SKIPPED $where $name - IP $ip already used by $($seenIp[$ip])"); continue }
        $seenIp[$ip] = "$name ($pkey)"
        $enabled = ([string]$r.Enabled).Trim(); if (-not $enabled) { $enabled = 'true' }
        $idle    = ([string]$r.Idle).Trim();    if (-not $idle)    { $idle = 'false' }
        $mac = Normalize-Mac ([string]$r.MAC)
        if (([string]$r.MAC).Trim() -and -not $mac) { [void]$warnings.Add("NOTE    $where $name - MAC '$($r.MAC)' is not valid, ignored") }
        [void]$result.Add([pscustomobject]@{ Name = $name; Platform = $pkey; IP = $ip; Enabled = $enabled.ToLowerInvariant(); Idle = $idle.ToLowerInvariant(); Notes = ([string]$r.Notes).Trim(); MAC = $mac })
    }
    return @{ Consoles = @($result); Warnings = @($warnings) }
}

function Read-ConsoleSource([string]$path) {
    $raw = New-Object System.Collections.ArrayList
    if ($path -match '\.xlsx$') {
        $rows = Read-XlsxRows $path
        $headerBySheet = @{}
        foreach ($row in $rows) {
            if (-not $headerBySheet.ContainsKey($row.Sheet)) {
                $map = @{}
                foreach ($k in $row.Cells.Keys) { $h = ([string]$row.Cells[$k]).Trim().ToLowerInvariant(); if ($h) { $map[$h] = $k } }
                if ($map.ContainsKey('name') -and $map.ContainsKey('ip')) { $headerBySheet[$row.Sheet] = $map }
                continue
            }
            $map = $headerBySheet[$row.Sheet]
            $get = { param($h) if ($map.ContainsKey($h)) { [string]$row.Cells[$map[$h]] } else { '' } }
            [void]$raw.Add([pscustomobject]@{
                Where = "[$($row.Sheet) row $($row.Row)]"; SheetName = $row.Sheet
                Name = & $get 'name'; Platform = & $get 'platform'; IP = & $get 'ip'
                Enabled = & $get 'enabled'; Idle = & $get 'idle'; Notes = & $get 'notes'; MAC = $(if ($map.ContainsKey('mac')) { & $get 'mac' } else { & $get 'mac address' })
            })
        }
        if ($headerBySheet.Count -eq 0) { throw "No sheet in $path has a header row with Name and IP columns." }
    } else {
        $n = 1
        foreach ($c in (Import-Csv -LiteralPath $path)) {
            $n++
            [void]$raw.Add([pscustomobject]@{ Where = "[CSV row $n]"; SheetName = ''; Name = $c.Name; Platform = $c.Platform; IP = $c.IP; Enabled = $c.Enabled; Idle = $c.Idle; Notes = $c.Notes; MAC = $c.MAC })
        }
    }
    return (Convert-ConsoleRows $raw)
}

$learnedMacPath = Join-Path $base 'Learned_MACs.csv'

function Get-LearnedMacs {
    $map = @{}
    if (Test-Path -LiteralPath $learnedMacPath) {
        try { foreach ($r in (Import-Csv -LiteralPath $learnedMacPath)) { if ($r.IP -and $r.MAC) { $map[[string]$r.IP] = $r } } } catch {}
    }
    return $map
}

function Get-ArpMac([string]$ip) {
    try {
        $out = & arp.exe -a $ip 2>$null
        foreach ($line in $out) {
            if ($line -match ('^\s*' + [regex]::Escape($ip) + '\s+([0-9a-fA-F]{2}([-:][0-9a-fA-F]{2}){5})\s')) {
                $m = Normalize-Mac $Matches[1]
                if ($m -and $m -ne '000000000000' -and $m -ne 'FFFFFFFFFFFF') { return $m }
            }
        }
    } catch {}
    return ''
}

function Load-Consoles {
    $script:ConsoleListPath = Get-ConsoleListPath
    if (-not (Test-Path -LiteralPath $script:ConsoleListPath)) { throw "Console list was not found: $($script:ConsoleListPath)" }
    $loaded = Read-ConsoleSource $script:ConsoleListPath
    $script:consoles = @($loaded.Consoles)
    $script:LoadWarnings = @($loaded.Warnings)
    $learned = Get-LearnedMacs
    foreach ($c in $script:consoles) {
        if (-not $c.MAC -and $learned.ContainsKey([string]$c.IP)) { $c.MAC = Normalize-Mac ([string]$learned[[string]$c.IP].MAC) }
    }
    $gridXbox.Rows.Clear(); $gridPS5.Rows.Clear()
    $sync.Rows.Clear()
    $script:GridRowOf = New-Object System.Collections.ArrayList
    foreach ($c in $script:consoles) {
        $g = Get-GridFor $c.Platform
        $n = $g.Rows.Add()
        $row = $g.Rows[$n]
        $row.Cells['Name'].Value = $c.Name; $row.Cells['IP'].Value = $c.IP
        $row.Cells['Enabled'].Value = $c.Enabled; $row.Cells['Idle'].Value = $c.Idle
        $row.Cells['Status'].Value = 'Not checked'; $row.Cells['Notes'].Value = $c.Notes
        $script:BulkTick = $true; $row.Cells['Sel'].Value = $false; $script:BulkTick = $false
        if ($g.Columns.Contains('AlwaysOn')) { $row.Cells['AlwaysOn'].Value = '?' }
        $row.Tag = $script:GridRowOf.Count     # console index - survives sorting
        [void]$script:GridRowOf.Add($row)
    }
    if (Get-Command Apply-Filter -ErrorAction SilentlyContinue) { Apply-Filter } else { Update-TabTitles }
    foreach ($w in $script:LoadWarnings) { Append-UiLog "Console list: $w" }
}

function Reload-All {
    Load-Config
    Load-Consoles
    Load-PcOffers
    $keepB = [string]$cmbStream.SelectedItem; $keepC = [string]$cmbConfig.SelectedItem
    $cmbStream.Items.Clear(); $cmbConfig.Items.Clear()
    $branches = @($script:cfg.BuildLibrary.Branches); if ($branches.Count -eq 0) { $branches = @($script:cfg.BuildLibrary.Streams) }
    foreach ($s in $branches) { [void]$cmbStream.Items.Add([string]$s) }
    foreach ($s in @($script:cfg.BuildLibrary.Configs)) { [void]$cmbConfig.Items.Add([string]$s) }
    $cmbStream.SelectedIndex = [math]::Max(0, $cmbStream.Items.IndexOf($keepB)); if ($cmbStream.Items.Count -eq 0) { $cmbStream.SelectedIndex = -1 }
    $cmbConfig.SelectedIndex = [math]::Max(0, $cmbConfig.Items.IndexOf($keepC)); if ($cmbConfig.Items.Count -eq 0) { $cmbConfig.SelectedIndex = -1 }
    if ($null -ne $script:cfg.BuildLibrary.PS5RmOnly) { $chkRmOnly.Checked = [bool]$script:cfg.BuildLibrary.PS5RmOnly }
    $script:LibCache = @{}
    if ($script:cfg.MaxParallel) { $numParallel.Value = [math]::Min(16,[math]::Max(1,[int]$script:cfg.MaxParallel)) }
    if ([string]$script:cfg.PS5.Values.Workspace) { $txtWorkspace.Text = [string]$script:cfg.PS5.Values.Workspace }
    Update-WorkspaceHint
    if ($null -ne $script:cfg.StaggerSec) { $numStagger.Value = [math]::Min(900,[math]::Max(0,[int]$script:cfg.StaggerSec)) }
    $skipped = @($script:LoadWarnings | Where-Object { $_ -like 'SKIPPED*' }).Count
    $xb = @($script:consoles | Where-Object { $_.Platform -eq 'Xbox' }).Count
    $ps = @($script:consoles | Where-Object { $_.Platform -eq 'PS5' }).Count
    $src = Split-Path -Leaf $script:ConsoleListPath
    $skipText = $(if ($skipped -gt 0) { " ($skipped skipped - see log)" } else { '' })
    $status.Text = "Loaded $xb Xbox + $ps PS5 from $src$skipText | $(Get-ToolSummary)"
    if (Get-Command Update-ConsoleLaunchLabels -ErrorAction SilentlyContinue) { Update-ConsoleLaunchLabels }
    $clipSecs = [int]$script:cfg.Capture.Xbox.ClipSeconds; if ($clipSecs -lt 6 -or $clipSecs -gt 300) { $clipSecs = 90 }
    $btnXbClip.Text = "Save last $clipSecs s"
    try { Update-PcMonitorList } catch {}
    try { Update-PcAudioList $true } catch {}
    if ($script:cfg.TargetManager.AutoAdd -eq $true) { Start-TargetManagerSync $false }
}

function Get-SelectedIndices { if ((Get-ActivePlatform) -eq 'PC') { return @() }; return @((Get-ActiveGrid).Rows | Where-Object { [bool]$_.Cells['Sel'].Value } | ForEach-Object { [int]$_.Tag } | Sort-Object -Unique) }
function Get-PlatformIndices([string]$pkey) {
    $out = @()
    for ($i = 0; $i -lt $script:consoles.Count; $i++) { if ($script:consoles[$i].Platform -eq $pkey) { $out += $i } }
    return $out
}
function Get-GridRow([int]$consoleIndex) { if ($consoleIndex -lt 0 -or $consoleIndex -ge $script:GridRowOf.Count) { return $null }; return $script:GridRowOf[$consoleIndex] }

# ---------------------------------------------------------------- events

function Update-WorkspaceHint {
    $n = $txtWorkspace.Text.Trim(); if (-not $n) { $n = 'playtest' }
    $pre = $(if ($script:cfg) { Get-WorkspacePrefix } else { 'sce_nolimit ' })
    if ($pre -and -not $n.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { $n = $pre + $n }
    $lblWsHint.Text = "On the kit: `"$n`""
}
$txtWorkspace.Add_TextChanged({ Update-WorkspaceHint })
# Re-check the build paths shortly after typing stops (scanning a NAS folder on every key press is slow)
$pathTimer = New-Object System.Windows.Forms.Timer
$pathTimer.Interval = 700
$pathTimer.Add_Tick({ $pathTimer.Stop(); Update-ModeLabels })
$txtXbox.Add_TextChanged({ $pathTimer.Stop(); $pathTimer.Start() })
$txtPS5.Add_TextChanged({ $pathTimer.Stop(); $pathTimer.Start() })
# ---- PS5 packages: buttons, Delete key, drag and drop
function Set-MainPackage([string]$p) {
    if (Test-LooksLikeDlc $p) {
        $lbl = Get-PkgLabel ([System.IO.Path]::GetFileName($p))
        $a = [System.Windows.Forms.MessageBox]::Show("'$lbl' looks like DLC (additional content), not the game.`n`nYes = add it to the DLC list instead`nNo = use it as the main package anyway",'Main or DLC?',[System.Windows.Forms.MessageBoxButtons]::YesNoCancel,[System.Windows.Forms.MessageBoxIcon]::Question)
        if ($a -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        if ($a -eq [System.Windows.Forms.DialogResult]::Yes) { [void](Add-DlcPaths @($p)); $rbPkg.Checked = $true; return }
    }
    for ($i = $script:DlcPaths.Count - 1; $i -ge 0; $i--) { if ($script:DlcPaths[$i] -ieq $p) { $script:DlcPaths.RemoveAt($i) } }
    $txtMain.Text = $p
    $rbPkg.Checked = $true
    Sync-DlcList
}
function Add-DlcFromUser([string[]]$files) {
    if (@($files).Count -eq 0) { return }
    $sk = @(Add-DlcPaths $files)
    $rbPkg.Checked = $true
    if ($sk.Count -gt 0) { Append-UiLog ('DLC not added: ' + ($sk -join '; ')) }
}
$txtMain.Add_TextChanged({ $pathTimer.Stop(); $pathTimer.Start() })
$rbPkg.Add_CheckedChanged({ Update-Ps5Info })
$chkConnect.Add_CheckedChanged({ $chkForceOwn.Enabled = $chkConnect.Checked; if (-not $chkConnect.Checked) { $chkForceOwn.Checked = $false } })
$btnMainBrowse.Add_Click({ $f = @(Pick-PkgFiles $false 'Pick the MAIN (game) package'); if ($f.Count -gt 0) { Set-MainPackage $f[0] } })
$btnMainClear.Add_Click({ $txtMain.Text = ''; Update-Ps5Info })
$btnDlcAdd.Add_Click({ Add-DlcFromUser @(Pick-PkgFiles $true 'Pick one or more DLC packages (Ctrl / Shift-click to select several)') })
$btnDlcRemove.Add_Click({ Remove-SelectedDlcs })
$btnDlcClear.Add_Click({ $script:DlcPaths.Clear(); Sync-DlcList })
$lstDlc.Add_KeyDown({ param($sender, $e) if ($e.KeyCode -eq 'Delete') { Remove-SelectedDlcs } })
$pkgDragEnter = { param($sender, $e) if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy } }
$lstDlc.Add_DragEnter($pkgDragEnter)
$txtMain.Add_DragEnter($pkgDragEnter)
$lstDlc.Add_DragDrop({ param($sender, $e) Add-DlcFromUser @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop) | Where-Object { $_ -match '\.pkg$' }) })
$txtMain.Add_DragDrop({ param($sender, $e) $f = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop) | Where-Object { $_ -match '\.pkg$' }); if ($f.Count -gt 0) { Set-MainPackage $f[0] } })
$btnXboxFolder.Add_Click({ Pick-Folder $txtXbox })
$btnPS5Folder.Add_Click({ Pick-Folder $txtPS5; if ($txtPS5.Text.Trim()) { $rbLoose.Checked = $true } })
$btnXboxPkg.Add_Click({ Pick-Package $txtXbox 'Xbox packages (*.xvc;*.msixvc)|*.xvc;*.msixvc|All files (*.*)|*.*' })

# ---- build library: scan / pick / use
# ---------------------------------------------------------------- PC: EA app override.cfg
# Each ticked offer gets these lines (offers without a zip only get the last two):
#   qa.Origin.<offer>.OverrideDownloadPath=file:\\server\...\Build.zip
#   qa.Origin.<offer>.ServerVersionOverride=<version>
#   qa.Origin.<offer>.OverrideUpToDateStatus=1
#   qa.Origin.<offer>.overrideUpToDateAfterInstall=1
# Every other line in the file (environment, SDK port, comments ...) is kept as it is.

function Read-OverrideFile([string]$path) {
    $r = @{ Exists = $false; Lines = @(); Eol = "`r`n"; Bom = $false; EndsWithEol = $true }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $r }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $r.Exists = $true
    $r.Bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes, $(if ($r.Bom) { 3 } else { 0 }), $bytes.Length - $(if ($r.Bom) { 3 } else { 0 }))
    if ($text -notmatch "`r`n" -and $text -match "`n") { $r.Eol = "`n" }
    $r.EndsWithEol = ($text.Length -eq 0) -or $text.EndsWith("`n")
    $body = $(if ($r.EndsWithEol -and $text.Length) { $text.Substring(0, $text.Length - $(if ($text.EndsWith("`r`n")) { 2 } else { 1 })) } else { $text })
    $r.Lines = $(if ($body.Length) { @($body -split "`r?`n") } else { @() })
    return $r
}

# Offer id of an active (not commented) override line, or ''
function Get-OverrideLineOffer([string]$line) {
    if ($line -match '^\s*qa\.Origin\.(OFR\.\d+\.\d+)\.\w+\s*=') { return $Matches[1] }
    return ''
}

# What the file currently sets for each offer: path (without file:), version, whether anything is set
function Get-OverrideState([string[]]$lines) {
    $st = @{}
    foreach ($l in $lines) {
        $id = Get-OverrideLineOffer $l
        if (-not $id) { continue }
        if (-not $st.ContainsKey($id)) { $st[$id] = @{ Path = ''; Version = ''; Set = $true } }
        if ($l -match '(?i)\.OverrideDownloadPath\s*=\s*(.*)$') { $st[$id].Path = ($Matches[1].Trim() -replace '(?i)^file:', '') }
        if ($l -match '(?i)\.ServerVersionOverride\s*=\s*(.*)$') { $st[$id].Version = $Matches[1].Trim() }
    }
    return $st
}

function Get-OfferLines([string]$id, [string]$path, [string]$version, [string]$prefix) {
    $k = "qa.Origin.$id"
    $out = @()
    if ($path) { $out += "$k.OverrideDownloadPath=$prefix$path" }
    if ($version) { $out += "$k.ServerVersionOverride=$version" }
    $out += "$k.OverrideUpToDateStatus=1"
    if ($path) { $out += "$k.overrideUpToDateAfterInstall=1" }
    return $out
}

# New file content: our offer lines first, then every existing line that is not an override for a managed offer
function Build-OverrideLines([string[]]$existing, [string[]]$managedIds, [object[]]$offers, [string]$prefix) {
    $out = New-Object System.Collections.ArrayList
    foreach ($o in $offers) { foreach ($l in (Get-OfferLines $o.Id $o.Path $o.Version $prefix)) { [void]$out.Add($l) } }
    foreach ($l in $existing) {
        $id = Get-OverrideLineOffer $l
        if ($id -and ($managedIds -contains $id)) { continue }
        [void]$out.Add($l)
    }
    return @($out)
}

# Backs up the current file, then writes the new lines with the file's own line endings / BOM
function Save-OverrideFile([string]$path, [string[]]$lines, $orig) {
    $backup = ''
    if ($orig.Exists) {
        $backup = "$path.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item -LiteralPath $path -Destination $backup -Force
    } else {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }
    $text = ($lines -join $orig.Eol) + $(if ($orig.EndsWithEol -and $lines.Count) { $orig.Eol } else { '' })
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($orig.Bom)))
    return $backup
}

# ---- PC tab logic: offers table <-> override.cfg
function Get-PcPrefix { $p = $script:cfg.PC.DownloadPathPrefix; if ($null -eq $p) { return 'file:' } else { return [string]$p } }
function Get-PcManagedIds { return @(@($script:cfg.PC.Offers) | ForEach-Object { [string]$_.Id }) }

# ---- PC: content to install (mirrors the EA app's install dialog)
# PC.Content maps each EA app item to the override offers it needs. An offer listed under several items
# (SAN1+SAN2 under Multiplayer and Single Player) is needed when ANY of those items is ticked.
$script:PcContentBoxes = @()

function Get-PcRow([string]$id) { foreach ($r in $gridPC.Rows) { if ([string]$r.Cells['Offer'].Value -eq $id) { return $r } }; return $null }
function Get-PcOfferName([string]$id) { $o = @($script:cfg.PC.Offers | Where-Object { $_.Id -eq $id })[0]; if ($o) { return "$($o.Name) ($($o.Zip))" } else { return $id } }
function Get-PcContentOfferIds { return @(@($script:cfg.PC.Content) | ForEach-Object { @($_.Offers) } | ForEach-Object { [string]$_ } | Sort-Object -Unique) }

# offer id -> names of the ticked items that need it
function Get-PcWantedOffers {
    $want = @{}
    foreach ($cb in $script:PcContentBoxes) {
        if (-not $cb.Checked) { continue }
        foreach ($id in @($cb.Tag.Offers)) { $id = [string]$id; if (-not $want.ContainsKey($id)) { $want[$id] = @() }; $want[$id] += [string]$cb.Tag.Name }
    }
    return $want
}

# Content ticks drive the Include column for every offer the content list knows about (others are left alone)
function Apply-PcContentSelection {
    $want = Get-PcWantedOffers
    foreach ($id in (Get-PcContentOfferIds)) {
        $r = Get-PcRow $id
        if ($r) { $r.Cells['Use'].Value = $want.ContainsKey($id) }
    }
    Update-PcContentInfo
}

# Problems with the chosen content: errors block writing, warnings are shown
function Get-PcContentProblems {
    $want = Get-PcWantedOffers
    $err = @(); $warn = @(); $errIds = @()
    foreach ($id in $want.Keys) {
        $r = Get-PcRow $id
        $who = ($want[$id] | Sort-Object -Unique) -join ' / '
        if (-not $r) { $err += "$who needs offer $id, which is not in PC.Offers"; continue }
        if (-not [bool]$r.Cells['Use'].Value) { $err += "$who needs $(Get-PcOfferName $id) - it is unticked"; continue }
        if ($r.Tag.Zip -and -not ([string]$r.Cells['Path'].Value).Trim()) { $err += "$who needs $(Get-PcOfferName $id) - no .zip picked (not in this build?)"; $errIds += $id }
    }
    foreach ($id in (Get-PcContentOfferIds)) {
        if ($want.ContainsKey($id)) { continue }
        $r = Get-PcRow $id
        if ($r -and [bool]$r.Cells['Use'].Value) { $warn += "$(Get-PcOfferName $id) is ticked, but no selected content needs it" }
    }
    return @{ Errors = $err; Warnings = $warn; ErrorIds = $errIds }
}

function Update-PcContentInfo {
    if (-not $lblPcContentInfo) { return }
    $p = Get-PcContentProblems
    if ($p.Errors.Count) { $lblPcContentInfo.Text = '! ' + $p.Errors[0]; $lblPcContentInfo.ForeColor = [System.Drawing.Color]::DarkRed }
    elseif ($p.Warnings.Count) { $lblPcContentInfo.Text = '! ' + $p.Warnings[0]; $lblPcContentInfo.ForeColor = [System.Drawing.Color]::DarkOrange }
    else { $lblPcContentInfo.Text = 'OK - every selected item has its override'; $lblPcContentInfo.ForeColor = [System.Drawing.Color]::DarkGreen }
}

# One tick box per EA app item; Base Game is required (always ticked)
function Build-PcContentBoxes {
    $keep = @{}; foreach ($cb in $script:PcContentBoxes) { $keep[[string]$cb.Tag.Name] = $cb.Checked }
    $flowPcContent.Controls.Clear()
    $script:PcContentBoxes = @()
    $l = New-Object System.Windows.Forms.Label; $l.Text = 'Content to install:'; $l.AutoSize = $true; $l.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 0)
    $flowPcContent.Controls.Add($l)
    foreach ($c in @($script:cfg.PC.Content)) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = [string]$c.Name + $(if ($c.Required) { ' (required)' } else { '' })
        $cb.AutoSize = $true; $cb.Tag = $c; $cb.Margin = New-Object System.Windows.Forms.Padding(0, 4, 14, 0)
        $cb.Checked = $(if ($c.Required) { $true } elseif ($keep.ContainsKey([string]$c.Name)) { $keep[[string]$c.Name] } else { $c.Default -ne $false })
        $cb.Enabled = -not $c.Required
        $cb.Add_CheckedChanged({ Apply-PcContentSelection })
        $flowPcContent.Controls.Add($cb)
        $script:PcContentBoxes += $cb
    }
    $b = New-Object System.Windows.Forms.Button; $b.Text = 'Install checklist'; $b.AutoSize = $true; $b.Margin = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
    $b.Add_Click({ Show-PcChecklist })
    $flowPcContent.Controls.Add($b)
    foreach ($def in @(,@('Open in EA app', { Open-PcGameInEaApp }))) {   # leading comma keeps a one-item list from being unwrapped
        $x = New-Object System.Windows.Forms.Button; $x.Text = $def[0]; $x.AutoSize = $true; $x.Margin = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
        $x.Add_Click($def[1]); $flowPcContent.Controls.Add($x)
    }
}

# Lines for the on-top checklist, in the EA app dialog's order
function Get-PcChecklistLines {
    $out = @()
    foreach ($cb in $script:PcContentBoxes) {
        $c = $cb.Tag
        if ($c.Required) { $out += ,@('ok', "$($c.Name)  (required - already ticked)"); continue }
        $out += ,@($(if ($cb.Checked) { 'tick' } else { 'untick' }), [string]$c.Name)
        if ($c.HdTextures) { $out += ,@('untick', "    $($c.HdTextures)   (no NAS build)") }
    }
    return $out
}

function Show-PcChecklist {
    if ($script:PcChecklist -and -not $script:PcChecklist.IsDisposed) { $script:PcChecklist.Close() }
    $lines = Get-PcChecklistLines
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'EA app install - tick exactly these'
    $f.TopMost = $true; $f.FormBorderStyle = 'FixedToolWindow'; $f.ShowInTaskbar = $false
    $f.Size = New-Object System.Drawing.Size(520, (110 + 26 * $lines.Count))
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(($wa.Right - $f.Width - 20), ($wa.Top + 80))
    $hdr = New-Object System.Windows.Forms.Label; $hdr.SetBounds(12, 10, 480, 36)
    $hdr.Text = "1. If the EA app says 'Game not installed', click GET THE GAME.`n2. In the install dialog, set each item like this:"
    $f.Controls.Add($hdr)
    $f.Height += 40
    $y = 52
    foreach ($ln in $lines) {
        $tag = New-Object System.Windows.Forms.Label; $tag.AutoSize = $false; $tag.SetBounds(12, $y, 120, 22)
        $tag.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        switch ($ln[0]) {
            'tick'   { $tag.Text = 'TICK';           $tag.ForeColor = [System.Drawing.Color]::DarkGreen }
            'untick' { $tag.Text = 'LEAVE UNTICKED'; $tag.ForeColor = [System.Drawing.Color]::DarkRed }
            default  { $tag.Text = 'ALREADY ON';     $tag.ForeColor = [System.Drawing.Color]::DimGray }
        }
        $txt = New-Object System.Windows.Forms.Label; $txt.AutoSize = $false; $txt.SetBounds(135, $y, 360, 22); $txt.Text = $ln[1]
        $f.Controls.Add($tag); $f.Controls.Add($txt)
        $y += 26
    }
    $foot = New-Object System.Windows.Forms.Label; $foot.SetBounds(12, $y + 4, 480, 22); $foot.ForeColor = [System.Drawing.Color]::DimGray
    $foot.Text = '3. Click INSTALL / UPDATE INSTALL in the EA app.'
    $f.Controls.Add($foot)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Done'; $ok.SetBounds(410, $y + 30, 80, 28); $ok.Add_Click({ $this.FindForm().Close() })
    $f.Controls.Add($ok)
    $script:PcChecklist = $f
    $f.Show()
}

function Load-PcOffers {
    if (-not $txtPcInstallDir.Text.Trim()) { $txtPcInstallDir.Text = $(if ($script:cfg.PC.DirectInstall.InstallDir) { [Environment]::ExpandEnvironmentVariables([string]$script:cfg.PC.DirectInstall.InstallDir) } else { 'C:\Program Files\EA Games\Battlefield 6' }) }
    if (-not $txtPcFile.Text.Trim()) { $txtPcFile.Text = $(if ($script:cfg.PC.OverrideFile) { [string]$script:cfg.PC.OverrideFile } else { 'C:\EADesktopDev\override.cfg' }) }
    $gridPC.Rows.Clear()
    foreach ($o in @($script:cfg.PC.Offers)) {
        $n = $gridPC.Rows.Add(); $r = $gridPC.Rows[$n]
        $r.Tag = $o
        $r.Cells['Use'].Value = ($o.Use -ne $false)
        $r.Cells['Offer'].Value = [string]$o.Id
        $r.Cells['Content'].Value = [string]$o.Name
        $r.Cells['Zip'].Value = $(if ($o.Zip) { [string]$o.Zip } else { '(no download)' })
        $r.Cells['Version'].Value = [string]$o.Version
        if (-not $o.Zip) { $r.Cells['Path'].ReadOnly = $true; $r.Cells['Path'].Style.BackColor = [System.Drawing.SystemColors]::Control; $r.Cells['Path'].Value = '(version + up-to-date only)' }
    }
    Refresh-PcFromFile
    Build-PcContentBoxes
    Apply-PcContentSelection
}

# Show what the file sets right now (paths / versions / which offers are set)
function Refresh-PcFromFile {
    $path = $txtPcFile.Text.Trim()
    $f = Read-OverrideFile $path
    $st = Get-OverrideState $f.Lines
    $n = 0
    foreach ($r in $gridPC.Rows) {
        $id = [string]$r.Cells['Offer'].Value
        if ($st.ContainsKey($id)) {
            $n++
            $r.Cells['InFile'].Value = 'set'
            if ($st[$id].Path -and $r.Tag.Zip) { $r.Cells['Path'].Value = $st[$id].Path }
            if ($st[$id].Version) { $r.Cells['Version'].Value = $st[$id].Version }
        } else { $r.Cells['InFile'].Value = 'not set' }
    }
    $lblPcInfo.Text = $(if (-not $f.Exists) { 'File not found - it will be created when you write the overrides' }
                        elseif ($n) { "The file currently overrides $n of $($gridPC.Rows.Count) offers" }
                        else { 'The file has no overrides (default)' })
}

# Ticked rows -> offers to write; errors block the write, warnings go into the confirm dialog
function Get-PcSelection {
    $offers = @(); $cp = Get-PcContentProblems; $err = @($cp.Errors); $warn = @($cp.Warnings)
    foreach ($r in $gridPC.Rows) {
        if (-not [bool]$r.Cells['Use'].Value) { continue }
        $o = $r.Tag; $name = "$($o.Name) ($($o.Id))"
        $ver = ([string]$r.Cells['Version'].Value).Trim()
        $path = ''
        if ($o.Zip) {
            $path = (([string]$r.Cells['Path'].Value).Trim().Trim('"')) -replace '(?i)^file:', ''
            if (-not $path) { if ($cp.ErrorIds -notcontains [string]$o.Id) { $err += "${name}: no .zip picked - use ... or untick it" }; continue }
            if ($path -notmatch '(?i)\.zip$') { $err += "${name}: the path must be the full path to the .zip file"; continue }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $warn += "${name}: file not found (check the NAS path): $path" }
            elseif ([System.IO.Path]::GetFileName($path) -ine [string]$o.Zip) { $warn += "${name}: expected $($o.Zip) but picked $([System.IO.Path]::GetFileName($path))" }
        }
        if ($ver -and $ver -notmatch '^\d+(\.\d+)+$') { $err += "${name}: server version '$ver' should look like 17.153.26.246"; continue }
        $offers += [pscustomobject]@{ Id = [string]$o.Id; Path = $path; Version = $ver; Name = [string]$o.Name }
    }
    return @{ Offers = $offers; Errors = $err; Warnings = $warn }
}

function Write-PcOverrides([bool]$remove) {
    try { Load-Config } catch {}
    $path = $txtPcFile.Text.Trim()
    if (-not $path) { [System.Windows.Forms.MessageBox]::Show('Set the EA app override file path first.','PC') | Out-Null; return }
    $sel = $(if ($remove) { @{ Offers = @(); Errors = @(); Warnings = @() } } else { Get-PcSelection })
    if ($sel.Errors.Count) { [System.Windows.Forms.MessageBox]::Show("Fix these first:`n`n" + ($sel.Errors -join "`n"),'PC overrides',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null; return }
    if (-not $remove -and $sel.Offers.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('No offers are ticked. Tick the main game and/or DLC to write, or use "Remove overrides".','PC overrides') | Out-Null; return }
    $orig = Read-OverrideFile $path
    $lines = Build-OverrideLines $orig.Lines (Get-PcManagedIds) $sel.Offers (Get-PcPrefix)
    $msg = $(if ($remove) { "Remove all overrides for these offers from`n$path ?`n`nThe file goes back to default; other settings are kept." }
             else { "Write overrides for $($sel.Offers.Count) offer(s) to`n$path ?`n`n" + (($sel.Offers | ForEach-Object { "  $($_.Name)   " + $(if ($_.Path) { [System.IO.Path]::GetFileName((Split-Path -Parent $_.Path)) + '\' + [System.IO.Path]::GetFileName($_.Path) } else { '(version only)' }) }) -join "`n") })
    if ($sel.Warnings.Count) { $msg += "`n`nWarnings:`n" + ($sel.Warnings -join "`n") }
    $msg += "`n`n" + $(if ($orig.Exists) { 'The current file is backed up first.' } else { 'The file does not exist yet and will be created.' }) + ' Restart the EA app afterwards so it picks up the change.'
    $a = [System.Windows.Forms.MessageBox]::Show($msg, $(if ($remove) { 'Remove PC overrides' } else { 'Write PC overrides' }), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $backup = Save-OverrideFile $path $lines $orig
        Append-UiLog ("PC: " + $(if ($remove) { 'overrides removed from' } else { "wrote $($sel.Offers.Count) offer(s) to" }) + " $path" + $(if ($backup) { "  (backup: $([System.IO.Path]::GetFileName($backup)))" } else { '' }))
        foreach ($l in $lines) { if (Get-OverrideLineOffer $l) { Append-UiLog "   $l" } }
        Refresh-PcFromFile
        $status.Text = $(if ($remove) { 'PC overrides removed - restart the EA app' } else { 'PC overrides written - restart the EA app to pick them up' })
    } catch [System.UnauthorizedAccessException] {
        [System.Windows.Forms.MessageBox]::Show("Windows refused access to $path.`n`nRun the tool as administrator, or check the folder's permissions.",'PC overrides',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not write the file:`n`n$($_.Exception.Message)",'PC overrides',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

$gridPC.Add_CurrentCellDirtyStateChanged({ if ($gridPC.IsCurrentCellDirty -and $gridPC.CurrentCell.OwningColumn.Name -eq 'Use') { [void]$gridPC.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) } })
$gridPC.Add_CellValueChanged({ param($sender, $e) if ($e.RowIndex -ge 0 -and ($gridPC.Columns[$e.ColumnIndex].Name -in 'Use','Path')) { Update-PcContentInfo } })
$gridPC.Add_CellContentClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $gridPC.Columns[$e.ColumnIndex].Name -ne 'Browse') { return }
    $r = $gridPC.Rows[$e.RowIndex]; $o = $r.Tag
    if (-not $o.Zip) { return }
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Zip files (*.zip)|*.zip|All files (*.*)|*.*'
    $d.Title = "Pick $($o.Zip) for $($o.Name)"
    $cur = ([string]$r.Cells['Path'].Value) -replace '(?i)^file:', ''
    if ($cur -and (Test-Path -LiteralPath (Split-Path -Parent $cur) -ErrorAction SilentlyContinue)) { $d.InitialDirectory = Split-Path -Parent $cur }
    if ($d.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $r.Cells['Path'].Value = $d.FileName
    $r.Cells['Use'].Value = $true
    if ([System.IO.Path]::GetFileName($d.FileName) -ine [string]$o.Zip) { Append-UiLog "PC: note - $($o.Name) expects $($o.Zip), you picked $([System.IO.Path]::GetFileName($d.FileName))" }
})
$btnPcWrite.Add_Click({ $gridPC.EndEdit() | Out-Null; Write-PcOverrides $false })
$btnPcRestore.Add_Click({ Write-PcOverrides $true })
$btnPcReread.Add_Click({ try { Load-Config } catch {}; Load-PcOffers; $status.Text = 'PC: override file re-read' })
$btnPcOpen.Add_Click({ $p = $txtPcFile.Text.Trim(); if (Test-Path -LiteralPath $p) { Start-Process notepad.exe -ArgumentList ('"' + $p + '"') } else { [System.Windows.Forms.MessageBox]::Show("File not found:`n$p",'PC') | Out-Null } })
$btnPcFileBrowse.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'EA app override (*.cfg)|*.cfg|All files (*.*)|*.*'
    $d.CheckFileExists = $false
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtPcFile.Text = $d.FileName; Refresh-PcFromFile }
})
$btnPcRestart.Add_Click({
    try { if (Restart-EaApp $true) { $status.Text = 'EA app restarted' } }
    catch { [System.Windows.Forms.MessageBox]::Show("Could not restart the EA app:`n$($_.Exception.Message)",'Restart EA app') | Out-Null }
})

# ---- PC: install / uninstall the game after overriding
# Pure helpers first (no UI), then the button handlers.

function Test-IsAdmin {
    try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}

# Splits a Windows command line into the program and its arguments ("C:\a b\x.exe" /s  or  C:\x.exe /s)
function Split-CommandLine([string]$cmd) {
    $c = $cmd.Trim()
    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 0) { return @{ Exe = $c.Substring(1, $end - 1); Args = $c.Substring($end + 1).Trim() } }
    }
    $m = [regex]::Match($c, '^(.+?\.exe)(\s+.*)?$', 'IgnoreCase')
    if ($m.Success) { return @{ Exe = $m.Groups[1].Value; Args = $m.Groups[2].Value.Trim() } }
    $sp = $c.IndexOf(' ')
    if ($sp -gt 0) { return @{ Exe = $c.Substring(0, $sp); Args = $c.Substring($sp + 1).Trim() } }
    return @{ Exe = $c; Args = '' }
}

# How to remove an installed entry silently: MSI product code -> msiexec /x {code} /qn,
# otherwise the entry's QuietUninstallString, otherwise its UninstallString (may show a window)
function Get-UninstallPlan($entry) {
    $guid = ''
    if ($entry.KeyName -match '^\{[0-9A-Fa-f\-]{36}\}$') { $guid = $entry.KeyName }
    elseif ([string]$entry.UninstallString -match '(?i)msiexec' -and [string]$entry.UninstallString -match '(\{[0-9A-Fa-f\-]{36}\})') { $guid = $Matches[1] }
    if ($guid -and ([string]$entry.UninstallString -match '(?i)msiexec' -or $entry.WindowsInstaller -eq 1)) {
        return @{ Exe = 'msiexec.exe'; Args = "/x $guid /qn"; Kind = 'MSI (silent)' }
    }
    if ($entry.QuietUninstallString) { $p = Split-CommandLine $entry.QuietUninstallString; $p.Kind = 'quiet uninstaller'; return $p }
    if ($entry.UninstallString) { $p = Split-CommandLine $entry.UninstallString; $p.Kind = 'uninstaller (may ask questions)'; return $p }
    return $null
}

# Refuses anything that is not clearly a game folder (roots, Windows, Program Files itself, user profile ...)
function Test-SafeDeleteFolder([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return 'no folder given' }
    $p = $path.Trim().TrimEnd('\','/')
    if ($p -match '^[A-Za-z]:$' -or $p -match '^\\\\[^\\]+\\[^\\]+$' -or $p -eq '' -or $p -eq '/') { return "refusing to delete a drive or share root ($path)" }
    $deny = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:PUBLIC,
              (Join-Path ([string]$env:ProgramFiles) 'Electronic Arts'), (Join-Path ([string]$env:ProgramFiles) 'EA Games'),
              (Join-Path ([string]$env:ProgramFiles) 'Electronic Arts\EA Desktop'), (Join-Path ([string]$env:ProgramFiles) 'Electronic Arts\EA Desktop\EA Desktop')) |
            Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\','/') }
    foreach ($d in $deny) { if ($p -ieq $d) { return "refusing to delete a system / shared folder ($path)" } }
    if (($p -split '[\\/]' | Where-Object { $_ }).Count -lt 3) { return "folder is too close to the drive root ($path)" }
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { return "folder not found ($path)" }
    return ''
}

function Find-InstalledGames([string]$pattern) {
    $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
    $out = @()
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        foreach ($k in @(Get-ChildItem $r -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DisplayName -or $p.DisplayName -notmatch $pattern) { continue }
            $out += [pscustomobject]@{ Name = [string]$p.DisplayName; Version = [string]$p.DisplayVersion; Publisher = [string]$p.Publisher
                InstallLocation = ([string]$p.InstallLocation).Trim('"'); UninstallString = [string]$p.UninstallString; QuietUninstallString = [string]$p.QuietUninstallString
                WindowsInstaller = $p.WindowsInstaller; KeyName = $k.PSChildName; Hive = $r }
        }
    }
    return $out
}

# Small picker when several installed entries match
function Select-FromList([string]$title, [string[]]$items) {
    if ($items.Count -eq 1) { return 0 }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $title; $f.Size = New-Object System.Drawing.Size(640, 300); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MinimizeBox = $false; $f.MaximizeBox = $false
    $lb = New-Object System.Windows.Forms.ListBox; $lb.SetBounds(10, 10, 605, 200); $lb.HorizontalScrollbar = $true
    foreach ($i in $items) { [void]$lb.Items.Add($i) }; $lb.SelectedIndex = 0; $f.Controls.Add($lb)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'OK'; $ok.SetBounds(440, 220, 80, 30); $ok.DialogResult = 'OK'; $f.Controls.Add($ok); $f.AcceptButton = $ok
    $no = New-Object System.Windows.Forms.Button; $no.Text = 'Cancel'; $no.SetBounds(530, 220, 80, 30); $no.DialogResult = 'Cancel'; $f.Controls.Add($no); $f.CancelButton = $no
    if ($f.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return -1 }
    return $lb.SelectedIndex
}

# Runs a program, elevated (UAC prompt) if this tool is not already admin; keeps the window responsive while it runs
function Invoke-PcCommand([string]$exe, [string]$cmdArgs, [string]$what, [bool]$elevate) {
    Append-UiLog "PC: $what -> `"$exe`" $cmdArgs"
    $sp = @{ FilePath = $exe; PassThru = $true; WindowStyle = 'Hidden' }
    if ($cmdArgs) { $sp.ArgumentList = $cmdArgs }
    if ($elevate -and -not (Test-IsAdmin)) { $sp.Verb = 'RunAs' }
    $p = Start-Process @sp
    while (-not $p.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 250 }
    Append-UiLog "PC: $what finished (exit code $($p.ExitCode))"
    return $p.ExitCode
}

function Stop-EaApp {
    foreach ($n in @($script:cfg.PC.KillProcesses)) {
        $ps = @(Get-Process -Name ([string]$n) -ErrorAction SilentlyContinue)
        if ($ps.Count) { $ps | Stop-Process -Force -ErrorAction SilentlyContinue; Append-UiLog "PC: stopped $n" }
    }
    $t = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $t -and @($script:cfg.PC.KillProcesses | ForEach-Object { Get-Process -Name ([string]$_) -ErrorAction SilentlyContinue }).Count) { Start-Sleep -Milliseconds 300; [System.Windows.Forms.Application]::DoEvents() }
}

function Get-PcGameEntry([bool]$quiet) {
    $pat = $(if ($script:cfg.PC.GameNamePattern) { [string]$script:cfg.PC.GameNamePattern } else { 'Battlefield' })
    $found = @(Find-InstalledGames $pat)
    if ($found.Count -eq 0) {
        $lblPcGame.Text = "Installed game: none found matching '$pat'"
        if (-not $quiet) { Append-UiLog "PC: no installed program matches '$pat' (Windows Apps & features list)" }
        return $null
    }
    $i = Select-FromList 'Which installed game?' @($found | ForEach-Object { "$($_.Name)   $($_.Version)   $($_.InstallLocation)" })
    if ($i -lt 0) { return $null }
    $g = $found[$i]
    $lblPcGame.Text = "Installed game: $($g.Name) $($g.Version)" + $(if ($g.InstallLocation) { "  at $($g.InstallLocation)" } else { '' })
    return $g
}

$btnPcFind.Add_Click({ try { Load-Config } catch {}; $g = Get-PcGameEntry $false; if ($g) { Append-UiLog "PC: found $($g.Name) $($g.Version) | folder: $($g.InstallLocation) | uninstall: $($g.UninstallString)" } })

function Open-PcGameInEaApp {
    try { Load-Config } catch {}
    $offer = $(if ($script:cfg.PC.InstallOffer) { [string]$script:cfg.PC.InstallOffer } else { [string]@($script:cfg.PC.Offers)[0].Id })
    $uri = ([string]$script:cfg.PC.InstallUri).Replace('{OfferId}', $offer).Replace('{TitleId}', [string]$script:cfg.PC.TitleId)
    if ($uri -match '\{TitleId\}|/$') { [System.Windows.Forms.MessageBox]::Show('PC.TitleId is empty in DeployConfig.json.','Install via EA app') | Out-Null; return }
    $st = Get-OverrideState (Read-OverrideFile $txtPcFile.Text.Trim()).Lines
    $msg = "Open Battlefield in the EA app?`n`n    $uri`n`nNot installed yet: the EA app says 'Game not installed' - click GET THE GAME to reach the install dialog.`nAlready installed: the game launches.`n`n"
    $msg += $(if ($st.ContainsKey($offer) -and $st[$offer].Path) { "Overrides are set - it should install from:`n    $($st[$offer].Path)" } else { "WARNING: the override file has no download path for $offer.`nThe EA app may download from the live CDN instead. Write overrides first." })
    $want = Get-PcWantedOffers
    $missing = @($want.Keys | Where-Object { -not ($st.ContainsKey($_)) } | ForEach-Object { "    $(Get-PcOfferName $_)  - needed by $((($want[$_]) | Sort-Object -Unique) -join ' / ')" })
    if ($missing.Count) { $msg += "`n`nWARNING - not written to the override file yet (would come from the CDN):`n" + ($missing -join "`n") + "`nClick 'Write overrides to file' first." }
    $msg += "`n`nIn the EA app's install dialog, tick: " + ((@($script:PcContentBoxes | Where-Object { $_.Checked } | ForEach-Object { [string]$_.Tag.Name })) -join ', ') + ' - and leave all HD Textures unticked. A checklist will stay on top of the EA app.'
    $msg += "`n`nIf the EA app was already open before you wrote the overrides, restart it first."
    if ([System.Windows.Forms.MessageBox]::Show($msg,'Open game in EA app',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try { Start-Process $uri; Append-UiLog "PC: opened $uri - if the EA app says 'Game not installed', click GET THE GAME"; $status.Text = "EA app opened - click GET THE GAME if it says 'Game not installed'"; Show-PcChecklist }
    catch { [System.Windows.Forms.MessageBox]::Show("Windows could not open $uri`n`n$($_.Exception.Message)`n`nIs the EA app installed? Check PC.InstallUri in DeployConfig.json.",'Install via EA app') | Out-Null }
}
$btnPcInstall.Add_Click({ Start-PcDirectInstall })

$btnPcUninstall.Add_Click({
    try { Load-Config } catch {}
    $g = Get-PcGameEntry $false
    if (-not $g) { [System.Windows.Forms.MessageBox]::Show("No installed game was found in Windows' installed programs.`n`nIf the files are still on disk, use 'Delete game files (fast)'.",'Uninstall') | Out-Null; return }
    $plan = Get-UninstallPlan $g
    if (-not $plan) { [System.Windows.Forms.MessageBox]::Show("$($g.Name) has no uninstall command registered.`nUse 'Delete game files (fast)' instead.",'Uninstall') | Out-Null; return }
    $msg = "Uninstall $($g.Name) $($g.Version)?`n`nMethod: $($plan.Kind)`n    `"$($plan.Exe)`" $($plan.Args)`n`nWindows will ask for administrator rights if needed."
    if ([System.Windows.Forms.MessageBox]::Show($msg,'Uninstall game',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $code = Invoke-PcCommand $plan.Exe $plan.Args "uninstall $($g.Name)" $true
        $status.Text = $(if ($code -eq 0 -or $code -eq 3010) { "Uninstalled $($g.Name)" + $(if ($code -eq 3010) { ' (restart Windows to finish)' } else { '' }) } else { "Uninstall finished with exit code $code - see log" })
        [void](Get-PcGameEntry $true)
    } catch { [System.Windows.Forms.MessageBox]::Show("Uninstall did not start:`n$($_.Exception.Message)",'Uninstall') | Out-Null }
})

$btnPcWipe.Add_Click({
    try { Load-Config } catch {}
    $g = Get-PcGameEntry $true
    $folder = $(if ($g -and $g.InstallLocation) { $g.InstallLocation } elseif ($txtPcInstallDir.Text.Trim() -and (Test-Path -LiteralPath $txtPcInstallDir.Text.Trim())) { $txtPcInstallDir.Text.Trim() } else { [Environment]::ExpandEnvironmentVariables([string]$script:cfg.PC.GameFolder) })
    if (-not $folder) {
        $folder = Select-Folder 'Pick the game folder to delete' '' 'Pick this folder'
        if (-not $folder) { return }
    }
    $bad = Test-SafeDeleteFolder $folder
    if ($bad) { [System.Windows.Forms.MessageBox]::Show("Not deleting: $bad",'Delete game files',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null; return }
    $procs = @($script:cfg.PC.KillProcesses) -join ', '
    $m1 = "DELETE this folder and everything in it?`n`n    $folder`n`nThe EA app ($procs) is closed first. This cannot be undone."
    if ([System.Windows.Forms.MessageBox]::Show($m1,'Delete game files (1 of 2)',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning,[System.Windows.Forms.MessageBoxDefaultButton]::Button2) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    if ([System.Windows.Forms.MessageBox]::Show("Last check - delete:`n`n    $folder ?",'Delete game files (2 of 2)',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning,[System.Windows.Forms.MessageBoxDefaultButton]::Button2) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $cache = [Environment]::ExpandEnvironmentVariables([string]$script:cfg.PC.ClearCacheFolder)
    $clearCache = $false
    if ($cache -and (Test-Path -LiteralPath $cache)) {
        $clearCache = ([System.Windows.Forms.MessageBox]::Show("Also clear the EA app cache so it forgets the game?`n`n    $cache",'Delete game files',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -eq [System.Windows.Forms.DialogResult]::Yes)
    }
    try {
        $status.Text = 'Closing the EA app...'; Stop-EaApp
        $status.Text = "Deleting $folder ..."
        [void](Invoke-PcCommand 'cmd.exe' "/c rd /s /q `"$folder`"" "delete $folder" $true)
        if ($clearCache) { [void](Invoke-PcCommand 'cmd.exe' "/c rd /s /q `"$cache`"" 'clear EA app cache' $false) }
        $left = Test-Path -LiteralPath $folder
        $status.Text = $(if ($left) { "Some files could not be deleted from $folder - see log (files in use? not admin?)" } else { "Deleted $folder" })
        if ($left) { Append-UiLog "PC: $folder still exists - a file may be in use, or the admin prompt was declined" }
        [void](Get-PcGameEntry $true)
    } catch { [System.Windows.Forms.MessageBox]::Show("Delete did not run:`n$($_.Exception.Message)",'Delete game files') | Out-Null }
})

function Restart-EaApp([bool]$ask) {
    $name = $(if ($script:cfg.PC.EAAppProcess) { [string]$script:cfg.PC.EAAppProcess } else { 'EADesktop' })
    $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    $exe = ($procs | Where-Object { $_.Path } | Select-Object -First 1).Path
    if (-not $exe) { $exe = [Environment]::ExpandEnvironmentVariables([string]$script:cfg.PC.EAAppExe) }
    if ($ask -and $procs.Count) {
        $a = [System.Windows.Forms.MessageBox]::Show("Close and reopen the EA app so it reads the new overrides?`n`nAny download or game running from the EA app will be stopped.",'Restart EA app',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
    }
    if ($procs.Count) {
        $procs | Stop-Process -Force -ErrorAction Stop
        $t = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $t -and @(Get-Process -Name $name -ErrorAction SilentlyContinue).Count) { Start-Sleep -Milliseconds 300; [System.Windows.Forms.Application]::DoEvents() }
    }
    if ($exe -and (Test-Path -LiteralPath $exe)) { Start-Process -FilePath $exe; Append-UiLog "PC: EA app started ($exe)"; return $true }
    Append-UiLog 'PC: EA app closed - could not find EADesktop.exe to start it again (PC.EAAppExe)'
    return $false
}

# ---- PC: copy a loose build (Files Final / Files Performance) from the NAS to a folder on this PC
# Runs robocopy in the background: multi-threaded, retries on network blips, and re-running it into
# the same folder resumes (files that are already complete are skipped). Nothing is ever deleted.
$script:PcCopy = $null
$pcCopyLastFile = Join-Path $base 'PcCopyLastFolder.txt'

$PcCopyWorker = {
    param($job, $st)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'robocopy.exe'
        $psi.Arguments = $job.Args
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $st.Proc = $p
        $errTask = $p.StandardError.ReadToEndAsync()
        while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
            try { Add-Content -LiteralPath $job.LogFile -Value $line -Encoding UTF8 } catch {}
            # with /BYTES each copied file is logged as "<status>  <size>  <path>"
            if ($line -match '^\s*(New File|Newer|Older|Changed|Tweaked|\*EXTRA File)?\s*(\d{1,15})\s+(\S.*)$' -and $line -notmatch '^\s*(Dirs|Files|Bytes|Times|Speed)\s*:') {
                if ($Matches[1] -ne '*EXTRA File') { $st.Done = [long]$st.Done + [long]$Matches[2]; $st.Files = [int]$st.Files + 1 }
            }
            if ($line -match '(?i)ERROR \d+ \(0x[0-9A-F]+\)') { $st.LastError = $line.Trim() }
        }
        $p.WaitForExit()
        [void]$errTask.Result
        $st.Exit = $p.ExitCode
    } catch { $st.LastError = $_.Exception.Message; $st.Exit = 16 }
    $st.Finished = $true
}

function Format-Size([double]$b) { if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) } }

# Free bytes on the drive that holds $path (or $null for shares / unknown)
function Get-FreeSpace([string]$path) {
    try { $root = [System.IO.Path]::GetPathRoot($path); if ($root -match '^[A-Za-z]:\\$') { return [double](New-Object System.IO.DriveInfo($root)).AvailableFreeSpace } } catch {}
    return $null
}

function Start-PcLooseCopy($b) {
    if ($script:PcCopy -and -not $script:PcCopy.St.Finished) { [System.Windows.Forms.MessageBox]::Show('A copy is already running. Wait for it, or click Cancel copy.','Copy build') | Out-Null; return }
    $src = $b.Entry.Folder
    if (-not (Test-Path -LiteralPath $src -PathType Container)) { [System.Windows.Forms.MessageBox]::Show("Build folder not found:`n$src",'Copy build') | Out-Null; return }

    # 1. where to copy - starts in the last folder used
    $last = ''
    try { $last = (Get-Content -LiteralPath $pcCopyLastFile -ErrorAction Stop | Select-Object -First 1).Trim() } catch {}
    $root = Select-Folder "Copy build CL $($b.Cl) (#$($b.Entry.Id)) into which folder? - a '$([System.IO.Path]::GetFileName($src.TrimEnd('\','/')))' folder is created inside it" $last 'Copy here'
    if (-not $root) { return }
    if ($root -like '\\*') {
        $a = [System.Windows.Forms.MessageBox]::Show("$root is a network location, not this PC. Copy there anyway?",'Copy build',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $dest = Join-Path $root ([System.IO.Path]::GetFileName($src.TrimEnd('\','/')))
    if ($dest.TrimEnd('\') -ieq $src.TrimEnd('\') -or $dest.StartsWith($src.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { [System.Windows.Forms.MessageBox]::Show('The destination is inside the build on the NAS - pick a folder on this PC.','Copy build') | Out-Null; return }

    # 2. size, free space, existing folder
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $status.Text = "Measuring the build on the NAS..."; [System.Windows.Forms.Application]::DoEvents()
    try { $m = Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    $total = [double]$m.Sum; $count = [long]$m.Count
    $have = 0.0
    if (Test-Path -LiteralPath $dest) { $have = [double](Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
    $free = Get-FreeSpace $root
    $need = [math]::Max([double]0, [double]($total - $have))
    if ($null -ne $free -and $free -lt $need + 2GB) {
        [System.Windows.Forms.MessageBox]::Show("Not enough space on $([System.IO.Path]::GetPathRoot($root)).`n`nBuild: $(Format-Size $total)`nAlready there: $(Format-Size $have)`nFree: $(Format-Size $free)`n`nFree up space or pick another drive.",'Copy build',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        $status.Text = 'Copy not started - not enough disk space'; return
    }
    $msg = "Copy build CL $($b.Cl) (#$($b.Entry.Id))`n`n  From: $src`n  To:   $dest`n`n  Size: $(Format-Size $total) in $count files" + $(if ($null -ne $free) { "`n  Free on $([System.IO.Path]::GetPathRoot($root)): $(Format-Size $free)" } else { '' })
    if ($have -gt 0) { $msg += "`n`nThe folder already exists ($(Format-Size $have) there). Files that are already complete are skipped, so this resumes / updates it. Nothing in it is deleted." }
    $msg += "`n`nThe copy runs in the background - you can keep using the tool."
    if ([System.Windows.Forms.MessageBox]::Show($msg,'Copy build',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try { Set-Content -LiteralPath $pcCopyLastFile -Value $root -Encoding UTF8 } catch {}

    # 3. the CL text file next to the build folder on the NAS is copied next to it on the PC too
    $parent = Split-Path -Parent $src
    $txt = @(Get-ChildItem -LiteralPath $parent -Filter "$($b.Entry.Id) - *.txt" -File -ErrorAction SilentlyContinue)
    foreach ($t in $txt) { try { Copy-Item -LiteralPath $t.FullName -Destination $root -Force } catch {} }

    $threads = $(if ([int]$script:cfg.PC.CopyThreads -gt 0) { [int]$script:cfg.PC.CopyThreads } else { 16 })
    $log = Join-Path $logDir ("PcCopy_{0}_{1}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $b.Entry.Id)
    $job = @{ Args = "`"$src`" `"$dest`" /E /Z /MT:$threads /R:3 /W:10 /BYTES /NP /NDL /NJH /XJ /FFT"; LogFile = $log }
    $st = [hashtable]::Synchronized(@{ Done = [long]0; Files = 0; Exit = $null; Finished = $false; Proc = $null; LastError = '' })
    $ps = [powershell]::Create()
    [void]$ps.AddScript($PcCopyWorker).AddArgument($job).AddArgument($st)
    $script:PcCopy = @{ PS = $ps; Handle = $ps.BeginInvoke(); St = $st; Total = $total; Have = $have; Count = $count; Src = $src; Dest = $dest; Started = (Get-Date); Log = $log; Cl = $b.Cl; Id = [string]$b.Entry.Id; Type = [string]$cmbConfig.SelectedItem; Branch = [string]$cmbStream.SelectedItem }
    Append-UiLog "PC copy: CL $($b.Cl) $src -> $dest ($(Format-Size $total), robocopy log: $([System.IO.Path]::GetFileName($log)))"
    $btnPcCopyCancel.Enabled = $true
    $lblPcCopy.ForeColor = [System.Drawing.SystemColors]::ControlText
    $pcCopyTimer.Start()
}

$pcCopyTimer = New-Object System.Windows.Forms.Timer
$pcCopyTimer.Interval = 1000
$pcCopyTimer.Add_Tick({
    $c = $script:PcCopy
    if (-not $c) { $pcCopyTimer.Stop(); return }
    $done = [double]$c.St.Done
    $el = (Get-Date) - $c.Started
    # bytes still to copy = total minus what was already there (skipped files are not logged)
    $todo = [math]::Max([double]1, [double]([double]$c.Total - [double]$c.Have))
    $pct = [int][math]::Min([double]100, [math]::Floor([double]100 * $done / $todo))
    $speed = $(if ($el.TotalSeconds -ge 3) { $done / $el.TotalSeconds } else { 0 })
    $eta = $(if ($speed -gt 0) { [TimeSpan]::FromSeconds([math]::Max([double]0, [double](($todo - $done) / $speed))) } else { $null })
    if (-not $c.St.Finished) {
        $lblPcCopy.Text = "Copying CL $($c.Cl): $pct%  ($(Format-Size $done) of $(Format-Size $todo), $(Format-Size $speed)/s" + $(if ($eta) { ", about $([int]$eta.TotalMinutes) min left" } else { '' }) + ")  -> $($c.Dest)"
        return
    }
    $pcCopyTimer.Stop()
    $btnPcCopyCancel.Enabled = $false
    try { $c.PS.EndInvoke($c.Handle) | Out-Null } catch {}
    $c.PS.Dispose()
    $code = [int]$c.St.Exit
    $mins = [math]::Round($el.TotalMinutes, 1)
    if ($c.Cancelled) {
        $lblPcCopy.Text = "Copy cancelled after $mins min - copy again to the same folder to resume"; $lblPcCopy.ForeColor = [System.Drawing.Color]::DarkOrange
        Append-UiLog "PC copy: cancelled ($(Format-Size $done) copied). Copying to the same folder again resumes."
    } elseif ($code -lt 8) {
        # robocopy: 0-7 = success (1 = files copied, 0 = already up to date, 2/3 = extra files present)
        $lblPcCopy.Text = "Copy finished in $mins min: $($c.Dest)"; $lblPcCopy.ForeColor = [System.Drawing.Color]::DarkGreen
        Append-UiLog "PC copy: DONE in $mins min - $($c.St.Files) file(s), $(Format-Size $done) copied to $($c.Dest) (robocopy code $code)"
        $status.Text = "Build CL $($c.Cl) copied to $($c.Dest)"
        Add-PcBuildHistory $c.Type $c.Branch ([string]$c.Cl) $c.Id $c.Dest
        $a = [System.Windows.Forms.MessageBox]::Show("Build CL $($c.Cl) ($($c.Type)) is copied to:`n`n$($c.Dest)`n`nYes = launch it now (Launch game window)`nNo = open the folder`nCancel = nothing",'Copy build',[System.Windows.Forms.MessageBoxButtons]::YesNoCancel,[System.Windows.Forms.MessageBoxIcon]::Information)
        if ($a -eq [System.Windows.Forms.DialogResult]::Yes) { $script:PcCopy = $null; try { Load-Config } catch {}; Show-PcLaunchDialog }
        elseif ($a -eq [System.Windows.Forms.DialogResult]::No) { Start-Process explorer.exe -ArgumentList ('"' + $c.Dest + '"') }
    } else {
        $lblPcCopy.Text = "Copy FAILED (robocopy code $code) - see log; copy again to resume"; $lblPcCopy.ForeColor = [System.Drawing.Color]::DarkRed
        Append-UiLog ("PC copy: FAILED with robocopy code $code" + $(if ($c.St.LastError) { " - $($c.St.LastError)" } else { '' }) + " | full log: $($c.Log)")
        [System.Windows.Forms.MessageBox]::Show("The copy did not finish (robocopy code $code).`n`n$($c.St.LastError)`n`nCommon causes: the NAS dropped, the disk is full, or access was denied. Copy again to the same folder to resume.",'Copy build',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
    $script:PcCopy = $null
})

function Stop-PcCopy([bool]$ask) {
    $c = $script:PcCopy
    if (-not $c -or $c.St.Finished) { return $true }
    if ($ask) {
        $a = [System.Windows.Forms.MessageBox]::Show("Stop the build copy?`n`nWhat is copied so far is kept - copying to the same folder again resumes.",'Cancel copy',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
    }
    $c.Cancelled = $true
    $p = $c.St.Proc
    if ($p -and -not $p.HasExited) { try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch {} }
    return $true
}
$btnPcCopyCancel.Add_Click({ [void](Stop-PcCopy $true) })
$btnPcCopyOpen.Add_Click({
    $p = $(if ($script:PcCopy) { $script:PcCopy.Dest } else { try { (Get-Content -LiteralPath $pcCopyLastFile -ErrorAction Stop | Select-Object -First 1).Trim() } catch { '' } })
    if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe -ArgumentList ('"' + $p + '"') } else { [System.Windows.Forms.MessageBox]::Show('No copied build yet.','Copy build') | Out-Null }
})

# ---------------------------------------------------------------- build cache (many kits)
# Deploying to many kits streams the build NAS -> this PC -> kit once per kit. Above
# Cache.WhenMoreThanKits kits the build is copied to a local cache ONCE, then every kit is
# deployed from the local copy. Re-using a cached build only copies files that changed.
# Layout: <cache root>\<8-char id>_<name>\...   (id = hash of the NAS path, so builds never collide)
$script:CacheRun = $null

function Test-NetworkPath([string]$p) {
    if ($p -like '\\*') { return $true }
    try { $root = [System.IO.Path]::GetPathRoot($p); if ($root -match '^[A-Za-z]:\\$') { return ((New-Object System.IO.DriveInfo($root)).DriveType -eq 'Network') } } catch {}
    return $false
}

function Get-CacheRoot {
    $f = [Environment]::ExpandEnvironmentVariables([string]$script:cfg.Cache.Folder)
    if ($f -and $f -ne 'auto') { return $f.TrimEnd('\') }
    # auto: the local (fixed) drive with the most free space
    $d = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | Sort-Object AvailableFreeSpace -Descending | Select-Object -First 1)
    if ($d.Count) { return (Join-Path $d[0].Name 'HYDBuildCache') }
    return (Join-Path $env:LOCALAPPDATA 'HYDBuildCache')
}

function Get-CacheId([string]$src) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $h = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($src.ToLowerInvariant().TrimEnd('\','/')))
    return (-join ($h[0..3] | ForEach-Object { $_.ToString('x2') }))
}

# One cache entry per NAS source (a package file or a loose folder)
function New-CacheItem([string]$src, [string]$root) {
    $s = $src.TrimEnd('\','/')
    $isFile = Test-Path -LiteralPath $s -PathType Leaf
    $name = $(if ($isFile) { Split-Path -Leaf (Split-Path -Parent $s) } else { Split-Path -Leaf $s })
    $dir = Join-Path $root ("{0}_{1}" -f (Get-CacheId $s), ($name -replace '[^\w\-\. ]', '_'))
    if ($isFile) {
        $file = [System.IO.Path]::GetFileName($s)
        return [pscustomobject]@{ Src = $s; Dir = $dir; Local = (Join-Path $dir $file); IsFile = $true
            Args = "`"$(Split-Path -Parent $s)`" `"$dir`" `"$file`" /J /R:3 /W:10 /BYTES /NP /NJH /NDL /FFT"; Size = 0.0; Have = 0.0 }
    }
    return [pscustomobject]@{ Src = $s; Dir = $dir; Local = $dir; IsFile = $false
        Args = "`"$s`" `"$dir`" /E /MT:16 /R:3 /W:10 /BYTES /NP /NJH /NDL /XJ /FFT"; Size = 0.0; Have = 0.0 }
}

# The NAS files / folders this deploy reads, for the platforms being deployed
function Get-CacheSources($usedPlatforms) {
    $src = @()
    if ($usedPlatforms['Xbox']) { $src += (Resolve-Build 'Xbox' $txtXbox.Text.Trim()).Path }
    if ($usedPlatforms['PS5']) {
        if ($rbPkg.Checked) { $ps = Get-Ps5PackageSelection; if ($ps.Main) { $src += $ps.Main.Path }; foreach ($d in $ps.Dlcs) { $src += $d.Path } }
        else { $src += (Resolve-Build 'PS5' $txtPS5.Text.Trim()).Path }
    }
    return @($src | Where-Object { $_ -and (Test-NetworkPath $_) } | Sort-Object -Unique)
}

function Measure-CacheItem($it) {
    if ($it.IsFile) {
        $it.Size = [double](Get-Item -LiteralPath $it.Src).Length
        if (Test-Path -LiteralPath $it.Local) { $l = Get-Item -LiteralPath $it.Local; if ($l.Length -eq $it.Size) { $it.Have = $it.Size } }
    } else {
        $it.Size = [double](Get-ChildItem -LiteralPath $it.Src -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if (Test-Path -LiteralPath $it.Dir) { $it.Have = [double](Get-ChildItem -LiteralPath $it.Dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
    }
}

# Point every deploy command at the local copy instead of the NAS. Returns the number of commands changed.
function Set-PlansToCache($plans, $items) {
    $n = 0
    $ordered = @($items | Sort-Object { $_.Src.Length } -Descending)
    foreach ($plan in $plans) {
        foreach ($st in $plan.Steps) {
            if (-not $st.Args) { continue }
            $a = [string]$st.Args
            foreach ($it in $ordered) { $a = $a.Replace($it.Src, $it.Local) }
            if ($a -ne $st.Args) { $st['Args'] = $a; $n++ }
        }
        foreach ($it in $ordered) { $plan['BuildPath'] = ([string]$plan.BuildPath).Replace($it.Src, $it.Local); $plan['Title'] = ([string]$plan.Title).Replace($it.Src, $it.Local) }
    }
    return $n
}

# Which cache folders to delete: keep the folders of the last KeepBuilds runs (this run included)
function Get-CacheCleanup([string]$root, [string[]]$currentDirs, [int]$keep) {
    $idxFile = Join-Path $root 'cache_index.json'
    $runs = @()
    try { $runs = @((Get-Content -LiteralPath $idxFile -Raw -ErrorAction Stop | ConvertFrom-Json) | ForEach-Object { ,@($_.Dirs) }) } catch {}
    $mine = @($currentDirs | ForEach-Object { Split-Path -Leaf $_ })
    $runs = @($runs | Where-Object { (Compare-Object @($_) $mine -SyncWindow 0).Count -ne 0 })   # same build again = move it to the front
    $runs = @(,$mine) + $runs
    $runs = @($runs | Select-Object -First ([math]::Max(1, $keep)))
    $allowed = @{}; foreach ($r in $runs) { foreach ($d in @($r)) { $allowed[[string]$d] = $true } }
    $delete = @()
    if (Test-Path -LiteralPath $root) {
        $delete = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -match '^[0-9a-f]{8}_' -and -not $allowed.ContainsKey($_.Name) } | ForEach-Object { $_.FullName })
    }
    return @{ Delete = $delete; Index = @($runs | ForEach-Object { [pscustomobject]@{ Dirs = @($_) } }); IndexFile = $idxFile }
}

function Get-FolderSize([string]$p) { return [double](Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }

$CacheWorker = {
    param($items, $st)
    foreach ($it in $items) {
        if ($st.Cancel) { break }
        $st.Current = $it.Src
        try {
            New-Item -ItemType Directory -Force -Path $it.Dir | Out-Null
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'robocopy.exe'; $psi.Arguments = $it.Args
            $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $st.Proc = $p
            $errTask = $p.StandardError.ReadToEndAsync()
            while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
                try { Add-Content -LiteralPath $st.LogFile -Value $line -Encoding UTF8 } catch {}
                if ($line -match '^\s*(New File|Newer|Older|Changed|Tweaked)?\s*(\d{1,15})\s+(\S.*)$' -and $line -notmatch '^\s*(Dirs|Files|Bytes|Times|Speed)\s*:') { $st.Done = [double]$st.Done + [double]$Matches[2] }
                if ($line -match '(?i)ERROR \d+ \(0x[0-9A-F]+\)') { $st.LastError = $line.Trim() }
            }
            $p.WaitForExit(); [void]$errTask.Result
            if ($st.Cancel) { break }
            if ($p.ExitCode -ge 8) { $st.Exit = $p.ExitCode; break }
            # a file whose size did not change is skipped and not logged: count it as done
            if ($it.IsFile) { $st.Done = [double]$st.Done + [double]$it.Have }
        } catch { $st.LastError = $_.Exception.Message; $st.Exit = 16; break }
    }
    if ($st.Cancel) { $st.Exit = -1 } elseif ($null -eq $st.Exit) { $st.Exit = 0 }
    $st.Finished = $true
}

function Start-CacheThenDeploy($plans, $items, [string]$root) {
    # 1. make room: remove cache folders of older builds
    $cl = Get-CacheCleanup $root @($items | ForEach-Object { $_.Dir }) ([int]$script:cfg.Cache.KeepBuilds)
    foreach ($d in $cl.Delete) {
        try { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop; Append-UiLog "Cache: removed old build $([System.IO.Path]::GetFileName($d))" }
        catch { Append-UiLog "Cache: could not remove $d - $($_.Exception.Message)" }
    }
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    try { $cl.Index | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cl.IndexFile -Encoding UTF8 } catch {}

    # 2. kits show they are waiting for the cache
    $sync.Cancel = $false
    foreach ($plan in $plans) { $sync.Rows[$plan.Row] = [hashtable]::Synchronized(@{ Status = 'Queued'; Step = 'Cache build'; Progress = 'Waiting: build is being copied to this PC'; Result = 'Queued'; Proc = $null }) }
    $total = [double](($items | Measure-Object Size -Sum).Sum); $have = [double](($items | Measure-Object Have -Sum).Sum)
    $log = Join-Path $logDir ("Cache_{0}.log" -f $script:RunStamp)
    $st = [hashtable]::Synchronized(@{ Done = [double]0; Current = ''; Exit = $null; Finished = $false; Cancel = $false; Proc = $null; LastError = ''; LogFile = $log })
    $ps = [powershell]::Create()
    [void]$ps.AddScript($CacheWorker).AddArgument(@($items)).AddArgument($st)
    $script:CacheRun = @{ PS = $ps; Handle = $ps.BeginInvoke(); St = $st; Plans = $plans; Items = $items; Total = $total; Have = $have; Started = (Get-Date); Root = $root; Log = $log }
    Append-UiLog ("==== Cache {0}: copying the build to {1} once for {2} kits ({3}, {4} already cached) ====" -f $script:RunStamp, $root, @($plans).Count, (Format-Size $total), (Format-Size $have))
    foreach ($it in $items) { Append-UiLog "   $($it.Src)  ->  $($it.Local)" }
    Set-Busy $true
    $timer.Start()
    $cacheTimer.Start()
}

$cacheTimer = New-Object System.Windows.Forms.Timer
$cacheTimer.Interval = 1000
$cacheTimer.Add_Tick({
    $c = $script:CacheRun
    if (-not $c) { $cacheTimer.Stop(); return }
    $done = [double]$c.St.Done
    $el = (Get-Date) - $c.Started
    $pct = [int][math]::Min([double]100, [math]::Floor([double]100 * $done / [math]::Max([double]1, $c.Total)))
    $speed = $(if ($el.TotalSeconds -ge 3) { $done / $el.TotalSeconds } else { [double]0 })
    if (-not $c.St.Finished) {
        $txt = "Caching build on this PC: $pct% ($(Format-Size $done) of $(Format-Size $c.Total)" + $(if ($speed -gt 0) { ", $(Format-Size $speed)/s" } else { '' }) + ') - deploy starts when done'
        foreach ($plan in $c.Plans) { $r = $sync.Rows[$plan.Row]; if ($r) { $r.Progress = $txt } }
        $status.Text = $txt
        return
    }
    $cacheTimer.Stop()
    try { $c.PS.EndInvoke($c.Handle) | Out-Null } catch {}
    $c.PS.Dispose()
    $script:CacheRun = $null
    $code = [int]$c.St.Exit
    if ($code -ne 0) {
        $why = $(if ($code -eq -1) { 'cancelled' } else { "copy failed (robocopy code $code) " + $c.St.LastError })
        Append-UiLog "Cache: $why - nothing was deployed. Full log: $($c.Log)"
        $timer.Stop()
        foreach ($plan in $c.Plans) {
            $gr = Get-GridRow $plan.Row
            $gr.Cells['Status'].Value = 'Not changed'; $gr.Cells['Step'].Value = 'Cache build'
            $gr.Cells['Progress'].Value = "Cache $why - kit not touched"
            $gr.Cells['Result'].Value = $(if ($code -eq -1) { 'CANCELLED' } else { 'FAILED' })
            $gr.Cells['Result'].Style.BackColor = $(if ($code -eq -1) { [System.Drawing.Color]::FromArgb(255,235,156) } else { [System.Drawing.Color]::FromArgb(255,199,206) })
            $sync.Rows.Remove($plan.Row)
        }
        Set-Busy $false
        $status.Text = "Cache $why - no kit was touched"
        return
    }
    foreach ($it in $c.Items) { try { (Get-Item -LiteralPath $it.Dir).LastWriteTime = Get-Date } catch {} }
    $n = Set-PlansToCache $c.Plans $c.Items
    Append-UiLog ("Cache: ready in {0} min - {1} deploy command(s) now read from {2}" -f [math]::Round(((Get-Date) - $c.Started).TotalMinutes, 1), $n, $c.Root)
    Start-RunPlans $c.Plans ([int]$numParallel.Value) 'Deploy'
})

function Stop-CacheRun {
    $c = $script:CacheRun
    if (-not $c -or $c.St.Finished) { return }
    $c.St.Cancel = $true
    $p = $c.St.Proc
    if ($p -and -not $p.HasExited) { try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch {} }
}

$btnClearCache.Add_Click({
    try { Load-Config } catch {}
    $root = Get-CacheRoot
    $dirs = @(); if (Test-Path -LiteralPath $root) { $dirs = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -match '^[0-9a-f]{8}_' }) }
    if (-not $dirs.Count) { [System.Windows.Forms.MessageBox]::Show("The build cache is empty.`n`n$root",'Clear Cache') | Out-Null; return }
    $size = [double]0; foreach ($d in $dirs) { $size += Get-FolderSize $d.FullName }
    $a = [System.Windows.Forms.MessageBox]::Show("Delete $($dirs.Count) cached build folder(s), $(Format-Size $size), from`n$root ?`n`nThe builds stay on the NAS; the next big deploy copies them again.",'Clear Cache',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    foreach ($d in $dirs) { try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop } catch { Append-UiLog "Cache: could not remove $($d.FullName) - $($_.Exception.Message)" } }
    Remove-Item -LiteralPath (Join-Path $root 'cache_index.json') -Force -ErrorAction SilentlyContinue
    Append-UiLog "Cache: cleared $(Format-Size $size) from $root"
    $status.Text = "Build cache cleared ($(Format-Size $size))"
})

# ---- PC: direct install (replaces the EA app automation)
# Extracts the ticked content's ZIPs straight into the install folder, runs Touchup.exe and writes the
# HKLM registry keys, so Windows and the EA app treat the game as installed. Program Files and HKLM
# need administrator rights, so the work runs in HYD_PC_DirectInstall.ps1 started elevated (one UAC
# prompt); the tool reads its progress from a status file and stays responsive.
$script:PcInstall = $null

# Size of everything in a ZIP, read with Windows' tar.exe. (The .NET ZIP reader in Windows PowerShell 5.1
# misreads the big Zip64 EA ZIPs: 6,916 GB instead of 84.7 GB.)
function Get-ZipUncompressedSize([string]$path) {
    $tar = $(if ($env:HYD_TAR) { $env:HYD_TAR } else { Join-Path ([string]$env:WINDIR) 'System32\tar.exe' })
    if (-not (Test-Path -LiteralPath $tar)) { throw "Windows tar.exe was not found ($tar) - it is part of Windows 10 (1803) and later" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $tar; $psi.Arguments = "-tvf `"$path`""
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "tar could not read $([System.IO.Path]::GetFileName($path)): $($errTask.Result.Trim())" }
    $t = [double]0
    foreach ($line in ($out -split "`r?`n")) { if ($line -match '^-\S*\s+\d+\s+\S+\s+\S+\s+(\d+)\s') { $t += [double]$Matches[1] } }
    return $t
}

function Get-PowerShellExe {
    # always the 64-bit PowerShell, so the registry keys land where the EA app reads them
    $sys = $(if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' })
    return (Join-Path $env:WINDIR "$sys\WindowsPowerShell\v1.0\powershell.exe")
}

function Start-PcDirectInstall {
    if ($script:PcInstall) { [System.Windows.Forms.MessageBox]::Show('An install is already running.','Install game') | Out-Null; return }
    try { Load-Config } catch {}
    [void]$gridPC.EndEdit()
    $di = $script:cfg.PC.DirectInstall
    $helper = Join-Path $base 'HYD_PC_DirectInstall.ps1'
    if (-not (Test-Path -LiteralPath $helper)) { [System.Windows.Forms.MessageBox]::Show("HYD_PC_DirectInstall.ps1 is missing from the tool folder:`n$base`n`nCopy it from the zip.",'Install game') | Out-Null; return }

    # 1. what to install: the ticked content's ZIPs, main game first
    $sel = Get-PcSelection
    $err = @($sel.Errors)
    $zips = @($sel.Offers | Where-Object { $_.Path })
    foreach ($o in $zips) { if (-not (Test-Path -LiteralPath $o.Path -PathType Leaf)) { $err += "$($o.Name): file not found - $($o.Path)" } }
    if (-not $zips.Count) { $err += 'No ZIPs to install - pick a build (Use This Build) and tick the content' }
    if ($err.Count) { [System.Windows.Forms.MessageBox]::Show("Fix these first:`n`n" + ($err -join "`n"),'Install game',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null; return }
    $mainIds = @(@($script:cfg.PC.Content) | Where-Object { $_.Required } | ForEach-Object { @($_.Offers) } | ForEach-Object { [string]$_ })
    $zips = @(@($zips | Where-Object { $mainIds -contains $_.Id }) + @($zips | Where-Object { $mainIds -notcontains $_.Id }))

    # 2. where: the install folder must be a real game folder, never a drive / Program Files itself
    $dest = $txtPcInstallDir.Text.Trim().TrimEnd('\')
    if (-not $dest) { [System.Windows.Forms.MessageBox]::Show('Set the install folder first.','Install game') | Out-Null; return }
    $exists = Test-Path -LiteralPath $dest -PathType Container
    $bad = $(if ($exists) { Test-SafeDeleteFolder $dest } elseif (@($dest -split '[\\/]' | Where-Object { $_ }).Count -lt 3) { "folder is too close to the drive root ($dest)" } else { '' })
    if ($bad) { [System.Windows.Forms.MessageBox]::Show("Not installing there: $bad",'Install game',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null; return }

    # 3. sizes and free space (the old build is deleted first, so its space counts as free)
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $status.Text = 'Reading the ZIP sizes on the NAS...'; [System.Windows.Forms.Application]::DoEvents()
    try {
        $total = [double]0
        foreach ($o in $zips) { $o | Add-Member -NotePropertyName Unzipped -NotePropertyValue (Get-ZipUncompressedSize $o.Path) -Force; $total += $o.Unzipped }
        $old = $(if ($exists) { Get-FolderSize $dest } else { [double]0 })
    } catch {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        [System.Windows.Forms.MessageBox]::Show("Could not read the ZIPs:`n$($_.Exception.Message)",'Install game') | Out-Null; return
    } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    $free = Get-FreeSpace $dest
    if ($null -ne $free -and $free + $old -lt $total + 5GB) {
        [System.Windows.Forms.MessageBox]::Show("Not enough space on $([System.IO.Path]::GetPathRoot($dest)).`n`nGame after extraction: $(Format-Size $total)`nFree: $(Format-Size $free)" + $(if ($old) { " (+ $(Format-Size $old) from the old build)" } else { '' }),'Install game',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null; return
    }

    # 4. confirm
    $clean = ($di.CleanInstall -ne $false)
    $msg = "Install the game into:`n    $dest`n`nZIPs (extracted in this order):`n" + (($zips | ForEach-Object { "    $($_.Name)   $([System.IO.Path]::GetFileName($_.Path))   ($(Format-Size $_.Unzipped))" }) -join "`n")
    $msg += "`n`nSize after extraction: $(Format-Size $total)" + $(if ($null -ne $free) { "   Free: $(Format-Size $free)" } else { '' })
    if ($exists -and $old -gt 0 -and $clean) { $msg += "`n`nCLEAN INSTALL: everything already in this folder ($(Format-Size $old)) is DELETED first." }
    $msg += "`n`nThen: Touchup.exe (if the build has one), the registry keys that mark the game as installed, and the overrides in override.cfg."
    $msg += "`n`nWindows will ask for administrator permission (Program Files and the registry need it)."
    $icon = $(if ($exists -and $old -gt 0) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Question })
    if ([System.Windows.Forms.MessageBox]::Show($msg,'Install game',[System.Windows.Forms.MessageBoxButtons]::YesNo,$icon,[System.Windows.Forms.MessageBoxDefaultButton]::Button2) -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    # 5. job file -> elevated helper
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $job = [ordered]@{
        InstallDir = $dest; Clean = $clean
        Zips = @($zips | ForEach-Object { [ordered]@{ Name = $_.Name; Path = $_.Path } })
        Touchup = $di.Touchup; Registry = @($di.Registry)
        StatusFile = (Join-Path $logDir "PcInstall_$stamp.status.json"); LogFile = (Join-Path $logDir "PcInstall_$stamp.log"); CancelFile = (Join-Path $logDir "PcInstall_$stamp.cancel")
    }
    $jobFile = Join-Path $logDir "PcInstall_$stamp.job.json"
    $job | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jobFile -Encoding UTF8
    try {
        $proc = Start-Process -FilePath (Get-PowerShellExe) -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$helper`" -JobFile `"$jobFile`""
    } catch {
        Append-UiLog "PC install: not started - administrator permission was not given ($($_.Exception.Message))"
        [System.Windows.Forms.MessageBox]::Show("The install did not start: administrator permission is needed to install into Program Files and write the registry.",'Install game') | Out-Null
        return
    }
    $script:PcInstall = @{ Proc = $proc; Job = $job; Offers = @($sel.Offers); Started = (Get-Date); Total = $total; LogPos = 0 }
    Append-UiLog "==== PC install $stamp -> $dest ($($zips.Count) ZIP(s), $(Format-Size $total)) ===="
    $btnPcInstall.Enabled = $false; $btnPcInstallCancel.Enabled = $true
    $lblPcInstall.ForeColor = [System.Drawing.SystemColors]::ControlText
    $lblPcInstall.Text = 'Starting (waiting for administrator permission)...'
    $pcInstallTimer.Start()
}

# Reads a file the install helper may be writing at the same moment (shared access, never locks it)
function Read-SharedText([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try { $sr = New-Object System.IO.StreamReader($fs); return $sr.ReadToEnd() } finally { $fs.Dispose() }
}

$pcInstallTimer = New-Object System.Windows.Forms.Timer
$pcInstallTimer.Interval = 800
$pcInstallTimer.Add_Tick({
    $c = $script:PcInstall
    if (-not $c) { $pcInstallTimer.Stop(); return }
    # helper's log -> log pane
    try {
        if (Test-Path -LiteralPath $c.Job.LogFile) {
            $lines = @(((Read-SharedText $c.Job.LogFile) -split "`r?`n") | Where-Object { $_ })
            for ($i = $c.LogPos; $i -lt $lines.Count; $i++) { Append-UiLog ("PC install: " + ($lines[$i] -replace '^\[[\d:]+\]\s*', '')) }
            $c.LogPos = $lines.Count
        }
    } catch {}
    $s = $null
    try { $txt = Read-SharedText $c.Job.StatusFile; if ($txt) { $s = $txt | ConvertFrom-Json } } catch {}   # half-written = read again next tick
    $exited = $c.Proc.HasExited
    if ($s -and -not $s.Finished) {
        $el = (Get-Date) - $c.Started
        $tot = [math]::Max([double]1, [double]$s.Total)
        $pct = [int][math]::Min([double]100, [math]::Floor([double]100 * [double]$s.Done / $tot))
        $speed = $(if ($el.TotalSeconds -ge 3) { [double]$s.Done / $el.TotalSeconds } else { [double]0 })
        $lblPcInstall.Text = $(if ([string]$s.Stage -like 'Extracting*') { "$($s.Stage): $pct% ($(Format-Size $s.Done) of $(Format-Size $s.Total)" + $(if ($speed -gt 0) { ", $(Format-Size $speed)/s" } else { '' }) + ')' } else { [string]$s.Stage + '...' })
        $status.Text = "PC install: $($lblPcInstall.Text)"
    }
    if (-not $exited -and -not ($s -and $s.Finished)) { return }
    if (-not $exited) { return }   # status says finished - wait for the process to close
    $pcInstallTimer.Stop()
    $script:PcInstall = $null
    $btnPcInstall.Enabled = $true; $btnPcInstallCancel.Enabled = $false
    $mins = [math]::Round(((Get-Date) - $c.Started).TotalMinutes, 1)
    if (-not $s -or -not $s.Finished) {
        # the final status could not be written - the helper's own log says how it ended
        $lg = ''; try { $lg = [string](Read-SharedText $c.Job.LogFile) } catch {}
        if ($lg -match 'Install finished') { $s = [pscustomobject]@{ Finished = $true; Ok = $true; Stage = 'Done'; Error = ''; Warnings = @() } }
        elseif ($lg -match 'STOPPED: (.+)') { $s = [pscustomobject]@{ Finished = $true; Ok = $false; Stage = 'see log'; Error = $Matches[1].Trim(); Warnings = @() } }
    }
    if (-not $s -or -not $s.Finished) {
        $lblPcInstall.Text = 'Install helper stopped unexpectedly - see log'; $lblPcInstall.ForeColor = [System.Drawing.Color]::DarkRed
        Append-UiLog "PC install: the helper stopped without reporting (exit code $($c.Proc.ExitCode)). Log: $($c.Job.LogFile)"
        return
    }
    if (-not $s.Ok) {
        $cancel = ([string]$s.Error -like 'Cancelled*')
        $lblPcInstall.Text = $(if ($cancel) { "Install cancelled after $mins min" } else { "Install FAILED: $($s.Error)" })
        $lblPcInstall.ForeColor = $(if ($cancel) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::DarkRed })
        [System.Windows.Forms.MessageBox]::Show($(if ($cancel) { "The install was cancelled during: $($s.Stage)." } else { "The install stopped during: $($s.Stage)`n`n$($s.Error)" }) + "`n`nThe folder may hold a partial build - run Install game again (it starts clean).",'Install game',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    # success: write our overrides (only the offer lines change, backup first)
    $ovr = ''
    try {
        $f = $txtPcFile.Text.Trim()
        $orig = Read-OverrideFile $f
        $bk = Save-OverrideFile $f (Build-OverrideLines $orig.Lines (Get-PcManagedIds) $c.Offers (Get-PcPrefix)) $orig
        Refresh-PcFromFile
        $ovr = "Overrides written to $f"
        Append-UiLog ("PC install: overrides written for $(@($c.Offers).Count) offer(s)" + $(if ($bk) { " (backup $([System.IO.Path]::GetFileName($bk)))" } else { '' }))
    } catch { $ovr = "Overrides NOT written: $($_.Exception.Message)"; Append-UiLog "PC install: $ovr" }
    $warn = @($s.Warnings | Where-Object { $_ })
    $lblPcInstall.Text = "Installed in $mins min: $($c.Job.InstallDir)" + $(if ($warn.Count) { "  ($($warn.Count) warning(s) - see log)" } else { '' })
    $lblPcInstall.ForeColor = $(if ($warn.Count) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::DarkGreen })
    $status.Text = 'PC install finished'
    try {
        # remember the install so the Launch game window can show which build it is
        $mainZip = @($c.Offers | Where-Object { $_.Path } | Select-Object -First 1)
        $bid = $(if ($mainZip.Count) { [System.IO.Path]::GetFileName((Split-Path -Parent ([string]$mainZip[0].Path))) } else { '' })
        $bcl = ''; foreach ($lb in @($script:LibBuilds)) { if ($lb.Kind -eq 'PCPkg' -and @($lb.Entries | Where-Object { [string]$_.Id -eq $bid }).Count) { $bcl = [string]$lb.Cl } }
        $itype = ''; foreach ($lp in @(Get-PcLaunchProfiles)) { if (-not $itype -and $lp.Folder -eq 'Install') { $itype = $lp.Type } }
        Add-PcBuildHistory $itype ([string]$cmbStream.SelectedItem) $bcl $bid ([string]$c.Job.InstallDir)
    } catch {}
    $m = "Battlefield is installed in:`n    $($c.Job.InstallDir)`n`n$ovr" + $(if ($warn.Count) { "`n`nWarnings:`n" + ($warn -join "`n") } else { '' })
    $m += "`n`nRestart the EA app now so it picks up the install?"
    $a = [System.Windows.Forms.MessageBox]::Show($m,'Install game',[System.Windows.Forms.MessageBoxButtons]::YesNo,$(if ($warn.Count) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information }))
    if ($a -eq [System.Windows.Forms.DialogResult]::Yes) { try { [void](Restart-EaApp $false) } catch { Append-UiLog "PC: could not restart the EA app - $($_.Exception.Message)" } }
})

function Stop-PcInstall([bool]$ask) {
    $c = $script:PcInstall
    if (-not $c) { return $true }
    if ($ask) {
        $a = [System.Windows.Forms.MessageBox]::Show("Stop the install?`n`nThe folder will hold a partial build; running Install game again starts clean.",'Cancel install',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
    }
    try { New-Item -ItemType File -Force -Path $c.Job.CancelFile | Out-Null } catch {}
    $lblPcInstall.Text = 'Cancelling...'
    return $true
}

# ---- PC: launch window - one launch profile per build type (Combine Retail / Files Final / Files Performance)
# Every type keeps its own build folder, game exe and launch parameters, plus named parameter presets.
# Defaults per type come from PC.Launch.Profiles in DeployConfig.json; what you use is remembered in PcLaunch.json.
# PcBuilds.json lists the builds this tool put on this PC (loose copies + direct installs) so the window can offer them.
$pcLaunchFile = Join-Path $base 'PcLaunch.json'
$pcBuildsFile = Join-Path $base 'PcBuilds.json'

function Get-PcBuildHistory {
    $h = @()
    try { $h = @(Get-Content -LiteralPath $pcBuildsFile -Raw -ErrorAction Stop | ConvertFrom-Json | ForEach-Object { $_ }) } catch {}
    return @($h | Where-Object { $_ -and $_.Path })
}

function Add-PcBuildHistory([string]$type,[string]$branch,[string]$cl,[string]$id,[string]$path) {
    if (-not $path) { return }
    $h = @(Get-PcBuildHistory | Where-Object { ([string]$_.Path).TrimEnd('\','/') -ine $path.TrimEnd('\','/') })
    $h = @([pscustomobject]@{ Type = $type; Branch = $branch; Cl = $cl; Id = $id; Path = $path.TrimEnd('\','/'); When = (Get-Date).ToString('s') }) + $h
    if ($h.Count -gt 40) { $h = $h[0..39] }
    try { ConvertTo-Json -InputObject $h -Depth 4 | Set-Content -LiteralPath $pcBuildsFile -Encoding UTF8 } catch {}
}

function Find-PcBuildInHistory([string]$path) {
    if (-not $path) { return $null }
    foreach ($e in @(Get-PcBuildHistory)) { if (([string]$e.Path).TrimEnd('\','/') -ieq $path.TrimEnd('\','/')) { return $e } }
    return $null
}

# Launch profiles from the config; one per build config if none are set up.
# Folder = 'Install' (the install folder on this tab) or 'Copied' (a loose build copied with Use This Build).
function Get-PcLaunchProfiles {
    $list = @()
    foreach ($p in @($script:cfg.PC.Launch.Profiles)) {
        if ($p -and $p.Type) { $list += ,([pscustomobject]@{ Type = [string]$p.Type; Folder = $(if ([string]$p.Folder -ieq 'Install') { 'Install' } else { 'Copied' }); Exe = [string]$p.Exe; Args = [string]$p.Args }) }
    }
    if (-not $list.Count) {
        $pk = @($script:cfg.BuildLibrary.PackageConfigs)
        foreach ($c in @($script:cfg.BuildLibrary.Configs)) { if ($c) { $list += ,([pscustomobject]@{ Type = [string]$c; Folder = $(if ($pk -contains $c) { 'Install' } else { 'Copied' }); Exe = ''; Args = '' }) } }
    }
    if (-not $list.Count) { $list += ,([pscustomobject]@{ Type = 'Installed game'; Folder = 'Install'; Exe = ''; Args = '' }) }
    return $list
}

function Read-PcLaunchState([string]$file = $pcLaunchFile) {
    $st = @{ LastType = ''; Types = @{}; Old = $null }
    $raw = $null; try { $raw = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
    if (-not $raw) { return $st }
    if ($raw.PSObject.Properties['Types']) {
        $st.LastType = [string]$raw.LastType
        if ($raw.Types) {
            foreach ($p in $raw.Types.PSObject.Properties) {
                $v = $p.Value
                $sv = $v.Saved; $sv = $(if ($sv -is [datetime]) { $sv.ToString('s') } else { [string]$sv })
                $t = @{ Folder = [string]$v.Folder; Exe = [string]$v.Exe; Args = [string]$v.Args; Id = [string]$v.Id; Ws = [string]$v.Ws; Saved = $sv; Presets = New-Object System.Collections.ArrayList }
                foreach ($q in @($v.Presets)) { if ($q -and $q.Name) { [void]$t.Presets.Add(@{ Name = [string]$q.Name; Args = [string]$q.Args }) } }
                $st.Types[[string]$p.Name] = $t
            }
        }
    } elseif ($raw.PSObject.Properties['Exe']) {
        # PcLaunch.json from v4.2 (one exe + parameters) - used for the installed game's type
        $st.Old = @{ Exe = [string]$raw.Exe; Args = [string]$raw.Args }
    }
    return $st
}

function Save-PcLaunchState($st,[string]$file = $pcLaunchFile) {
    $types = [ordered]@{}
    foreach ($k in @($st.Types.Keys | Sort-Object)) {
        $t = $st.Types[$k]
        $types[$k] = [ordered]@{ Folder = [string]$t.Folder; Exe = [string]$t.Exe; Args = [string]$t.Args; Id = [string]$t.Id; Ws = [string]$t.Ws; Saved = [string]$t.Saved; Presets = @($t.Presets | ForEach-Object { [ordered]@{ Name = [string]$_.Name; Args = [string]$_.Args } }) }
    }
    try { ([ordered]@{ LastType = [string]$st.LastType; Types = $types } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $file -Encoding UTF8 } catch { Append-UiLog "Launch: could not save $([System.IO.Path]::GetFileName($file)) - $($_.Exception.Message)" }
}

# Game exes in a build folder (2 levels deep), PC.Launch.PreferExe names first, then biggest first. Paths are relative to the folder.
function Find-PcGameExes([string]$dir) {
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    $skip = [string]$script:cfg.PC.Launch.SkipExe
    if (-not $skip) { $skip = '(?i)touchup|cleanup|unins|setup|installer|crash|report|redist|vc_|dxsetup|activation|anticheat' }
    $pref = @($script:cfg.PC.Launch.PreferExe | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $root = $dir.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    $ranked = @(Get-ChildItem -LiteralPath $dir -Filter '*.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $skip } | ForEach-Object {
        $r = 999; for ($i = 0; $i -lt $pref.Count; $i++) { if ($_.Name -ieq $pref[$i]) { $r = $i; break } }
        [pscustomobject]@{ Rank = $r; Size = [long]$_.Length; Path = $(if ($_.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $_.FullName.Substring($root.Length) } else { $_.FullName }) }
    })
    return @($ranked | Sort-Object @{ Expression = 'Rank'; Ascending = $true }, @{ Expression = 'Size'; Descending = $true } | ForEach-Object { $_.Path })
}

function Resolve-PcExe([string]$folder,[string]$exe) {
    $exe = $exe.Trim().Trim('"')
    if (-not $exe) { return '' }
    if ([System.IO.Path]::IsPathRooted($exe)) { return $exe }
    if ($folder) { try { return [System.IO.Path]::Combine($folder, $exe) } catch { return $exe } }
    return $exe
}

# Launch parameters: one per line is fine (lines are joined with spaces); {Folder} {Exe} {Cl} {BuildId} {Type} are filled in
function Get-PcLaunchArgs([string]$text,[string]$folder,[string]$exe,[string]$type) {
    $a = (@(($text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }) -join ' ')
    $h = Find-PcBuildInHistory $folder
    $map = @{ Folder = $folder.TrimEnd('\','/'); Exe = $exe; Type = $type; Cl = $(if ($h) { [string]$h.Cl } else { '' }); BuildId = $(if ($h) { [string]$h.Id } else { '' }) }
    foreach ($k in $map.Keys) { $a = $a.Replace('{' + $k + '}', [string]$map[$k]) }
    return $a
}

# Folders to offer for a type: the install folder, or the copied builds of that type (newest first) and older copies in the last copy folder
function Get-PcLaunchFolders($prof,[string]$installDir) {
    $out = New-Object System.Collections.ArrayList
    $add = { param($p) if ($p -and (Test-Path -LiteralPath $p -PathType Container) -and -not (@($out) | Where-Object { $_.TrimEnd('\','/') -ieq $p.TrimEnd('\','/') })) { [void]$out.Add($p) } }
    $hist = @(Get-PcBuildHistory)
    if ($prof.Folder -eq 'Install') {
        & $add $installDir
        & $add ([string]$script:cfg.PC.DirectInstall.InstallDir)
        foreach ($e in $hist) { if ([string]$e.Type -eq $prof.Type) { & $add ([string]$e.Path) } }
        & $add ([string]$script:cfg.PC.GameFolder)
    } else {
        foreach ($e in $hist) { if ([string]$e.Type -eq $prof.Type) { & $add ([string]$e.Path) } }
        $last = ''; try { $last = (Get-Content -LiteralPath $pcCopyLastFile -ErrorAction Stop | Select-Object -First 1).Trim() } catch {}
        if ($last -and (Test-Path -LiteralPath $last -PathType Container)) {
            $known = @($hist | ForEach-Object { ([string]$_.Path).TrimEnd('\','/') })
            foreach ($d in @(Get-ChildItem -LiteralPath $last -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
                if ($known -notcontains $d.FullName.TrimEnd('\','/')) { & $add $d.FullName }
            }
        }
    }
    return @($out)
}

function Show-PcLaunchDialog {
    $profiles = @(Get-PcLaunchProfiles)
    $state = Read-PcLaunchState
    $installDir = $txtPcInstallDir.Text.Trim()
    $ctx = @{ Type = ''; Loading = $false; Go = $false; Prof = $null }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Launch game'; $f.ClientSize = New-Object System.Drawing.Size(776, 430); $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $gray = [System.Drawing.Color]::DimGray
    $mk = { param($text, $x, $y, $w, $h) $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.SetBounds($x, $y, $w, $h); $f.Controls.Add($l); $l }

    [void](& $mk 'Build type:' 12 18 110 20)
    $cbType = New-Object System.Windows.Forms.ComboBox; $cbType.DropDownStyle = 'DropDownList'; $cbType.SetBounds(125, 15, 250, 24); $f.Controls.Add($cbType)
    foreach ($p in $profiles) { [void]$cbType.Items.Add($p.Type) }
    $lblTypeHint = & $mk '' 385 18 380 20; $lblTypeHint.ForeColor = $gray

    [void](& $mk 'Build folder:' 12 51 110 20)
    $cbFolder = New-Object System.Windows.Forms.ComboBox; $cbFolder.DropDownStyle = 'DropDown'; $cbFolder.SetBounds(125, 48, 545, 24); $f.Controls.Add($cbFolder)
    $btnFolder = New-Object System.Windows.Forms.Button; $btnFolder.Text = 'Browse...'; $btnFolder.SetBounds(676, 46, 90, 28); $f.Controls.Add($btnFolder)
    $lblFolderInfo = & $mk '' 125 75 641 18; $lblFolderInfo.ForeColor = $gray

    [void](& $mk 'Game exe:' 12 101 110 20)
    $cbExe = New-Object System.Windows.Forms.ComboBox; $cbExe.DropDownStyle = 'DropDown'; $cbExe.SetBounds(125, 98, 545, 24); $f.Controls.Add($cbExe)
    $btnExe = New-Object System.Windows.Forms.Button; $btnExe.Text = 'Browse...'; $btnExe.SetBounds(676, 96, 90, 28); $f.Controls.Add($btnExe)

    [void](& $mk 'Preset:' 12 139 110 20)
    $cbPreset = New-Object System.Windows.Forms.ComboBox; $cbPreset.DropDownStyle = 'DropDownList'; $cbPreset.SetBounds(125, 136, 300, 24); $f.Controls.Add($cbPreset)
    $btnPresetSave = New-Object System.Windows.Forms.Button; $btnPresetSave.Text = 'Save as preset...'; $btnPresetSave.SetBounds(432, 134, 125, 28); $f.Controls.Add($btnPresetSave)
    $btnPresetDel = New-Object System.Windows.Forms.Button; $btnPresetDel.Text = 'Delete preset'; $btnPresetDel.SetBounds(563, 134, 107, 28); $f.Controls.Add($btnPresetDel)

    $lblArgs = & $mk 'Launch parameters:' 12 172 500 18
    $tp = New-Object System.Windows.Forms.TextBox; $tp.Multiline = $true; $tp.ScrollBars = 'Vertical'; $tp.WordWrap = $true; $tp.AcceptsReturn = $true
    $tp.Font = New-Object System.Drawing.Font('Consolas', 9); $tp.SetBounds(12, 192, 754, 96); $f.Controls.Add($tp)
    $lblArgHint = & $mk 'One parameter per line is fine (lines are joined with spaces; lines starting with # are skipped). {Folder} {Exe} {Cl} {BuildId} {Type} are filled in.' 12 292 590 32
    $lblArgHint.ForeColor = $gray
    $btnDefault = New-Object System.Windows.Forms.Button; $btnDefault.Text = 'Config default'; $btnDefault.SetBounds(636, 292, 130, 26); $f.Controls.Add($btnDefault)

    [void](& $mk 'Command line:' 12 336 100 20)
    $txtCmd = New-Object System.Windows.Forms.TextBox; $txtCmd.ReadOnly = $true; $txtCmd.SetBounds(115, 333, 651, 24); $f.Controls.Add($txtCmd)

    $btnOpen = New-Object System.Windows.Forms.Button; $btnOpen.Text = 'Open folder'; $btnOpen.SetBounds(12, 388, 100, 30); $f.Controls.Add($btnOpen)
    $btnGo = New-Object System.Windows.Forms.Button; $btnGo.Text = 'Launch'; $btnGo.SetBounds(586, 388, 85, 30); $f.Controls.Add($btnGo)
    $btnNo = New-Object System.Windows.Forms.Button; $btnNo.Text = 'Cancel'; $btnNo.SetBounds(681, 388, 85, 30); $btnNo.DialogResult = 'Cancel'; $f.Controls.Add($btnNo); $f.CancelButton = $btnNo

    # --- helpers working on the window (they run while the window is open, so they see its controls)
    $updatePreview = {
        if ($ctx.Loading) { return }
        $folder = $cbFolder.Text.Trim().Trim('"')
        $exe = Resolve-PcExe $folder $cbExe.Text
        $a = Get-PcLaunchArgs $tp.Text $folder $exe $ctx.Type
        $txtCmd.Text = $(if ($exe) { '"' + $exe + '"' + $(if ($a) { ' ' + $a } else { '' }) } else { '' })
        $info = ''
        if (-not $folder) { $info = $(if ($ctx.Prof.Folder -eq 'Install') { 'Pick the folder the game is installed in.' } else { 'Pick a copied build folder (Use This Build on a Files Final / Files Performance build copies one here).' }) }
        elseif (-not (Test-Path -LiteralPath $folder -PathType Container)) { $info = 'Folder not found.' }
        else {
            $h = Find-PcBuildInHistory $folder
            if ($h) {
                $when = ''; try { $when = ([datetime]$h.When).ToString('dd MMM HH:mm') } catch {}
                $info = (@($(if ($h.Cl) { "CL $($h.Cl)" }), $(if ($h.Id) { "#$($h.Id)" }), $(if ($h.Branch) { [string]$h.Branch }), [string]$h.Type) | Where-Object { $_ }) -join '  '
                $info += $(if ($ctx.Prof.Folder -eq 'Install') { "  - installed $when" } else { "  - copied $when" })
                if ($h.Type -and [string]$h.Type -ne $ctx.Type) { $info += "   (this is a $($h.Type) build)" }
            } else { $info = 'Not a build this tool copied/installed - fine if you know it is the right one.' }
        }
        $lblFolderInfo.Text = $info
    }
    $fillExes = {
        param([string]$folder)
        # (the folder is passed in from SelectedIndexChanged, where the combo's Text can still be the old one)
        if (-not $folder) { $folder = $cbFolder.Text }
        $folder = $folder.Trim().Trim('"')
        $keep = $cbExe.Text.Trim()
        $cbExe.Items.Clear()
        foreach ($x in @(Find-PcGameExes $folder)) { [void]$cbExe.Items.Add($x) }
        # keep what was picked if it is in this folder too, otherwise the profile exe, otherwise the best match
        if ($keep -and (Test-Path -LiteralPath (Resolve-PcExe $folder $keep) -PathType Leaf)) { $cbExe.Text = $keep }
        elseif ($ctx.Prof.Exe -and (Test-Path -LiteralPath (Resolve-PcExe $folder $ctx.Prof.Exe) -PathType Leaf)) { $cbExe.Text = $ctx.Prof.Exe }
        elseif ($cbExe.Items.Count) { $cbExe.Text = [string]$cbExe.Items[0] }
        elseif (-not $keep) { $cbExe.Text = '' }
    }
    $fillPresets = {
        param([string]$select)
        $cbPreset.Items.Clear(); [void]$cbPreset.Items.Add('(none)')
        $t = $state.Types[$ctx.Type]
        if ($t) { foreach ($q in $t.Presets) { [void]$cbPreset.Items.Add($q.Name) } }
        $i = $(if ($select) { $cbPreset.Items.IndexOf($select) } else { -1 })
        $cbPreset.SelectedIndex = [math]::Max(0, $i)
        $btnPresetDel.Enabled = ($cbPreset.SelectedIndex -gt 0)
    }
    $savePresets = {
        # presets are saved straight away, without the other (not yet launched) changes in the window
        $disk = Read-PcLaunchState
        if ($disk.Old) { foreach ($p in $profiles) { if ($p.Folder -eq 'Install' -and -not $disk.Types[$p.Type]) { $disk.Types[$p.Type] = @{ Folder = ''; Exe = $disk.Old.Exe; Args = $disk.Old.Args; Saved = ''; Presets = New-Object System.Collections.ArrayList } } } }
        $d = $disk.Types[$ctx.Type]
        if (-not $d) { $m = $state.Types[$ctx.Type]; $d = @{ Folder = $m.Folder; Exe = $m.Exe; Args = $m.Args; Saved = ''; Presets = $null }; $disk.Types[$ctx.Type] = $d }
        $d.Presets = $state.Types[$ctx.Type].Presets
        $disk.LastType = $(if ($disk.LastType) { $disk.LastType } else { $ctx.Type })
        Save-PcLaunchState $disk
    }
    $commit = {
        # remember the window's values for the type that is showing
        if (-not $ctx.Type) { return }
        $t = $state.Types[$ctx.Type]
        if (-not $t) { $t = @{ Folder = ''; Exe = ''; Args = ''; Saved = ''; Presets = New-Object System.Collections.ArrayList }; $state.Types[$ctx.Type] = $t }
        $folder = $cbFolder.Text.Trim().Trim('"')
        $exe = $cbExe.Text.Trim().Trim('"')
        $root = $folder.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
        if ($folder -and $exe.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $exe = $exe.Substring($root.Length) }
        $t.Folder = $folder; $t.Exe = $exe; $t.Args = $tp.Text
    }
    $loadType = {
        param([string]$type)
        $ctx.Loading = $true
        $ctx.Type = $type
        $prof = $null; foreach ($p in $profiles) { if ($p.Type -eq $type) { $prof = $p } }
        $ctx.Prof = $prof
        $t = $state.Types[$type]
        $lblTypeHint.Text = $(if ($prof.Folder -eq 'Install') { 'Runs the installed game (install folder on the PC tab)' } else { 'Runs a loose build copied to this PC' })
        $lblArgs.Text = "Launch parameters for $($type):"
        $folders = @(Get-PcLaunchFolders $prof $installDir)
        $cbFolder.Items.Clear(); foreach ($x in $folders) { [void]$cbFolder.Items.Add($x) }
        # folder: the newest copy of this type if it arrived after the last launch, else the remembered one, else the first offered
        $folder = ''
        if ($prof.Folder -eq 'Copied') {
            $newest = $null; foreach ($e in @(Get-PcBuildHistory)) { if ([string]$e.Type -eq $type -and (Test-Path -LiteralPath ([string]$e.Path) -PathType Container)) { $newest = $e; break } }
            $saved = [datetime]::MinValue; if ($t -and $t.Saved) { try { $saved = [datetime]$t.Saved } catch {} }
            if ($newest) { try { if ([datetime]$newest.When -gt $saved) { $folder = [string]$newest.Path } } catch {} }
        }
        if (-not $folder -and $t -and $t.Folder -and (Test-Path -LiteralPath $t.Folder -PathType Container)) { $folder = $t.Folder }
        if (-not $folder -and $prof.Folder -eq 'Install') { $folder = $installDir }
        if (-not $folder -and $folders.Count) { $folder = $folders[0] }
        $cbFolder.Text = $folder
        # exe: remembered for this type, then the profile's, then (installed game) the v4.2 / GameExe setting
        $exe = ''
        if ($t -and $t.Exe) { $exe = $t.Exe }
        elseif ($prof.Exe) { $exe = $prof.Exe }
        elseif ($prof.Folder -eq 'Install' -and $state.Old -and $state.Old.Exe) { $exe = $state.Old.Exe }
        elseif ($prof.Folder -eq 'Install' -and $script:cfg.PC.GameExe) { $exe = [string]$script:cfg.PC.GameExe }
        $cbExe.Text = $exe
        & $fillExes
        # parameters: remembered for this type, else the config default (v4.2 parameters for the installed game)
        $tp.Text = $(if ($t) { [string]$t.Args } elseif ($prof.Folder -eq 'Install' -and $state.Old -and $state.Old.Args) { [string]$state.Old.Args } else { [string]$prof.Args })
        & $fillPresets ''
        $btnDefault.Enabled = [bool]$prof.Args
        $ctx.Loading = $false
        & $updatePreview
    }

    # --- events
    $cbType.Add_SelectedIndexChanged({ if ($ctx.Loading) { return }; & $commit; & $loadType ([string]$cbType.SelectedItem) })
    $cbFolder.Add_SelectedIndexChanged({ if ($ctx.Loading) { return }; & $fillExes ([string]$cbFolder.SelectedItem); & $updatePreview })
    $cbFolder.Add_Leave({ if ($ctx.Loading) { return }; & $fillExes; & $updatePreview })
    $cbFolder.Add_TextChanged({ & $updatePreview })
    $cbExe.Add_TextChanged({ & $updatePreview })
    $tp.Add_TextChanged({ & $updatePreview })
    $btnFolder.Add_Click({
        $p = Select-Folder "Build folder for $($ctx.Type)" $cbFolder.Text.Trim().Trim('"') 'Use this folder'
        if ($p) { $cbFolder.Text = $p; & $fillExes $p; & $updatePreview }
    })
    $btnExe.Add_Click({
        $d = New-Object System.Windows.Forms.OpenFileDialog; $d.Filter = 'Programs (*.exe)|*.exe'
        $folder = $cbFolder.Text.Trim().Trim('"')
        if ($folder -and (Test-Path -LiteralPath $folder)) { $d.InitialDirectory = $folder }
        if ($d.ShowDialog($f) -eq 'OK') {
            $root = $folder.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
            $cbExe.Text = $(if ($folder -and $d.FileName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $d.FileName.Substring($root.Length) } else { $d.FileName })
        }
    })
    $cbPreset.Add_SelectedIndexChanged({
        $btnPresetDel.Enabled = ($cbPreset.SelectedIndex -gt 0)
        if ($ctx.Loading -or $cbPreset.SelectedIndex -le 0) { return }
        $t = $state.Types[$ctx.Type]
        foreach ($q in $t.Presets) { if ($q.Name -eq [string]$cbPreset.SelectedItem) { $tp.Text = $q.Args } }
    })
    $btnPresetSave.Add_Click({
        Add-Type -AssemblyName Microsoft.VisualBasic
        $cur = $(if ($cbPreset.SelectedIndex -gt 0) { [string]$cbPreset.SelectedItem } else { '' })
        $name = [Microsoft.VisualBasic.Interaction]::InputBox("Name for these $($ctx.Type) launch parameters:", 'Save preset', $cur).Trim()
        if (-not $name) { return }
        if ($name -eq '(none)') { [System.Windows.Forms.MessageBox]::Show('Pick another name.','Save preset') | Out-Null; return }
        & $commit
        $t = $state.Types[$ctx.Type]
        $hit = $null; foreach ($q in $t.Presets) { if ($q.Name -ieq $name) { $hit = $q } }
        if ($hit) {
            if ([System.Windows.Forms.MessageBox]::Show("Replace the preset '$($hit.Name)'?",'Save preset',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $hit.Args = $tp.Text; $name = $hit.Name
        } else { [void]$t.Presets.Add(@{ Name = $name; Args = $tp.Text }) }
        & $savePresets
        $ctx.Loading = $true; & $fillPresets $name; $ctx.Loading = $false
    })
    $btnPresetDel.Add_Click({
        if ($cbPreset.SelectedIndex -le 0) { return }
        $name = [string]$cbPreset.SelectedItem
        if ([System.Windows.Forms.MessageBox]::Show("Delete the preset '$name'?",'Delete preset',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        & $commit
        $t = $state.Types[$ctx.Type]
        $gone = @($t.Presets | Where-Object { $_.Name -eq $name }); foreach ($q in $gone) { $t.Presets.Remove($q) }
        & $savePresets
        $ctx.Loading = $true; & $fillPresets ''; $ctx.Loading = $false
    })
    $btnDefault.Add_Click({ $tp.Text = [string]$ctx.Prof.Args })
    $btnOpen.Add_Click({ $p = $cbFolder.Text.Trim().Trim('"'); if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe -ArgumentList ('"' + $p + '"') } })
    $btnGo.Add_Click({
        $folder = $cbFolder.Text.Trim().Trim('"')
        $exe = Resolve-PcExe $folder $cbExe.Text
        if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { [System.Windows.Forms.MessageBox]::Show("Game exe not found:`n$exe",'Launch game',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null; return }
        $ctx.Go = $true
        $f.Close()
    })

    # start on the build type picked in the header (Config), else the last one launched
    $start = ''
    $hdr = [string]$cmbConfig.SelectedItem
    foreach ($p in $profiles) { if ($p.Type -eq $hdr) { $start = $p.Type } }
    if (-not $start) { foreach ($p in $profiles) { if ($p.Type -eq $state.LastType) { $start = $p.Type } } }
    if (-not $start) { $start = $profiles[0].Type }
    $ctx.Loading = $true; $cbType.SelectedItem = $start; $ctx.Loading = $false
    & $loadType $start

    [void]$f.ShowDialog($form)
    if (-not $ctx.Go) { return }   # Cancel: nothing is remembered (saved presets stay)

    # --- launch
    & $commit
    $state.LastType = $ctx.Type
    $state.Types[$ctx.Type].Saved = (Get-Date).ToString('s')
    Save-PcLaunchState $state
    $folder = $cbFolder.Text.Trim().Trim('"')
    $exe = Resolve-PcExe $folder $cbExe.Text
    $argsTxt = Get-PcLaunchArgs $tp.Text $folder $exe $ctx.Type
    $pname = [System.IO.Path]::GetFileNameWithoutExtension($exe)
    $running = @(Get-Process -Name $pname -ErrorAction SilentlyContinue)
    if ($running.Count) {
        $a = [System.Windows.Forms.MessageBox]::Show("$pname is already running.`n`nYes = close it and launch again`nNo = launch another copy`nCancel = do nothing",'Launch game',[System.Windows.Forms.MessageBoxButtons]::YesNoCancel,[System.Windows.Forms.MessageBoxIcon]::Question)
        if ($a -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        if ($a -eq [System.Windows.Forms.DialogResult]::Yes) {
            foreach ($p in $running) { try { $p.Kill() } catch {} }
            $until = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $until -and @(Get-Process -Name $pname -ErrorAction SilentlyContinue).Count) { Start-Sleep -Milliseconds 300; [System.Windows.Forms.Application]::DoEvents() }
            Append-UiLog "PC: closed the running $pname"
        }
    }
    try {
        $sp = @{ FilePath = $exe; WorkingDirectory = (Split-Path -Parent $exe) }
        if ($argsTxt) { $sp.ArgumentList = $argsTxt }
        Start-Process @sp
        $h = Find-PcBuildInHistory $folder
        Append-UiLog ("PC: launched [$($ctx.Type)]" + $(if ($h -and $h.Cl) { " CL $($h.Cl)" } else { '' }) + " `"$exe`" $argsTxt")
        $status.Text = "Game launched ($($ctx.Type))"
    } catch { [System.Windows.Forms.MessageBox]::Show("Could not launch:`n$($_.Exception.Message)",'Launch game',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null }
}

# ---- Xbox / PS5: launch the game (same idea as the PC Launch game window, launch logic as in XBDEPLOY)
# XboxLaunch.json / PS5Launch.json remember, per build type: launch parameters, presets and an optional launch ID
# (Xbox AUMID / PS5 Title ID), plus the build type in use. Used by "Launch game..." on the tab and by "Launch after
# deploy". Xbox launch = "xbapp launch /X:<kit> <launch ID> <parameters>" with the parameters passed as ONE argument
# (Xbox.Launch.QuoteArgs), a ping first, and "xbapp terminate" for Close game. Defaults: <Platform>.Launch in the config.
function Get-ConsoleLaunchFile([string]$pkey) { return (Join-Path $base "$($pkey)Launch.json") }

function Get-ConsoleLaunchProfiles([string]$pkey) {
    $list = @()
    # From = where the build type runs from on the kit: Package (installed package) or Workspace (loose build
    # pushed to the deploy workspace). Not set = Package for BuildLibrary.PackageConfigs, else Workspace.
    $pk = @($script:cfg.BuildLibrary.PackageConfigs | ForEach-Object { [string]$_ })
    $getFrom = { param($t, $f) if ([string]$f -match '^(?i)(package|workspace)$') { (Get-Culture).TextInfo.ToTitleCase(([string]$f).ToLower()) } elseif ($pk -contains $t) { 'Package' } else { 'Workspace' } }
    foreach ($p in @($script:cfg.$pkey.Launch.Profiles)) { if ($p -and $p.Type) { $list += ,([pscustomobject]@{ Type = [string]$p.Type; Args = [string]$p.Args; Id = [string]$p.LaunchId; From = (& $getFrom ([string]$p.Type) $p.From) }) } }
    if (-not $list.Count) { foreach ($c in @($script:cfg.BuildLibrary.Configs)) { if ($c) { $list += ,([pscustomobject]@{ Type = [string]$c; Args = ''; Id = ''; From = (& $getFrom ([string]$c) '') }) } } }
    if (-not $list.Count) { $list += ,([pscustomobject]@{ Type = 'Default'; Args = ''; Id = ''; From = 'Package' }) }
    return $list
}

# The build type, parameter text and launch ID in use for a platform right now
function Get-ConsoleLaunchSetting([string]$pkey) {
    $profiles = @(Get-ConsoleLaunchProfiles $pkey)
    $st = Read-PcLaunchState (Get-ConsoleLaunchFile $pkey)
    $type = ''
    foreach ($p in $profiles) { if ($p.Type -eq $st.LastType) { $type = $p.Type } }
    if (-not $type) { foreach ($p in $profiles) { if ($p.Type -eq [string]$cmbConfig.SelectedItem) { $type = $p.Type } } }
    if (-not $type) { $type = $profiles[0].Type }
    $prof = $null; foreach ($p in $profiles) { if ($p.Type -eq $type) { $prof = $p } }
    $t = $st.Types[$type]
    return @{ Type = $type; Text = $(if ($t) { [string]$t.Args } else { [string]$prof.Args }); Id = $(if ($t) { [string]$t.Id } else { [string]$prof.Id }); Ws = $(if ($t) { [string]$t.Ws } else { '' }); Default = [string]$prof.Args }
}

# Parameter text -> one line: lines joined with spaces, # lines skipped, {placeholders} from the kit/build filled in
function Get-ConsoleLaunchArgs([string]$text,[hashtable]$values,[string]$type) {
    $a = (@(($text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }) -join ' ')
    $map = @{ Type = $type }
    foreach ($k in $values.Keys) { if ($k -ne 'LaunchArgs') { $map[$k] = [string]$values[$k] } }
    foreach ($k in $map.Keys) { if ($map[$k]) { $a = $a.Replace('{' + $k + '}', $map[$k]) } }
    return $a
}

# One command-line argument, quoted the way PowerShell passes a string to a program
# ("-a -b" -> "\"-a -b\"" style quoting; no quotes when there is no space or quote in it)
function ConvertTo-NativeArg([string]$s) {
    if ($s -eq '' -or $s -notmatch '[\s"]') { return $s }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"'); $bs = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq [char]'\') { $bs++; continue }
        if ($ch -eq [char]'"') { [void]$sb.Append('\' * (2 * $bs + 1)); [void]$sb.Append('"') }
        else { [void]$sb.Append('\' * $bs); [void]$sb.Append($ch) }
        $bs = 0
    }
    [void]$sb.Append('\' * (2 * $bs)); [void]$sb.Append('"')
    return $sb.ToString()
}

# Launch command with parameters: {LaunchArgs} in the config command, or added at the end when the command has none
function Expand-LaunchCommand($def,[hashtable]$values,[string]$context) {
    $a = Expand-Template $def.Args $values $context
    if ($values['LaunchArgs'] -and $def.Args -notmatch '\{LaunchArgs\}') { $a = $a.TrimEnd() + ' ' + $values['LaunchArgs'] }
    return $a
}

# Remember the build type for a platform (Use This Build calls this with the header's Config)
function Set-ConsoleLaunchType([string]$pkey,[string]$type) {
    if (-not $type -or @(Get-ConsoleLaunchProfiles $pkey | Where-Object { $_.Type -eq $type }).Count -eq 0) { return }
    $f = Get-ConsoleLaunchFile $pkey
    $st = Read-PcLaunchState $f
    if ($st.LastType -eq $type) { return }
    $st.LastType = $type
    Save-PcLaunchState $st $f
    Update-ConsoleLaunchLabels
}

function Update-ConsoleLaunchLabels {
    foreach ($x in @(@('Xbox', $lblXbLaunch), @('PS5', $lblPs5Launch))) {
        try {
            $s = Get-ConsoleLaunchSetting $x[0]
            $one = Get-ConsoleLaunchArgs $s.Text @{} $s.Type
            $x[1].Text = "Build type: $($s.Type)   Parameters: " + $(if ($one) { $one } else { '(none)' }) + $(if ($s.Id) { "   ID: $($s.Id)" } else { '' })
        } catch { $x[1].Text = '' }
    }
}

function Get-XboxAppIdRegex {
    $rx = [string]$script:cfg.Xbox.Launch.AppIdRegex
    if (-not $rx) { $rx = '([A-Za-z0-9][A-Za-z0-9.\-]*_[0-9a-z]{13}![A-Za-z0-9._\-]+)' }
    return $rx
}
function Get-XboxFindApp {
    $find = [string]$script:cfg.Xbox.Launch.FindApp
    if (-not $find) { $find = '(?i)glacier|battlefield' }
    return $find
}

# Xbox package builds do not carry their launch ID (only loose builds have MicrosoftGame.config),
# so the tool asks the kit: "xbapp list" (Steps.ListApps) and picks the app of this package, or
# the one app matching Xbox.Launch.FindApp when no build is picked. Returns the step, or $null.
function New-XboxLaunchIdLookup([hashtable]$values) {
    $list = Get-StepDef 'Xbox' 'ListApps'
    if (-not $list) { return $null }
    $pfn = [string]$values['PackageFamilyName']
    $values['LaunchId'] = '{{LaunchId}}'
    return @{ Type = 'Run'; Label = 'Find game on kit'; Exe = $list.Exe; Args = (Expand-Template $list.Args $values 'Xbox ListApps'); ContinueOnError = $false
              CaptureVar = 'LaunchId'; CaptureRegex = (Get-XboxAppIdRegex); CapturePrefix = $(if ($pfn) { $pfn + '!' } else { '' }); CaptureFilter = (Get-XboxFindApp) }
}

# PS5 Close game without a Title ID: "prospero-ctrl application list" (Steps.ListApps) shows what is running
# ("[]" = nothing); the first entry's TitleId (or Name) is what gets killed - same as BF Deploy.
function New-Ps5RunningAppLookup([hashtable]$values) {
    $list = Get-StepDef 'PS5' 'ListApps'
    if (-not $list) { return $null }
    $values['TitleId'] = '{{TitleId}}'
    return @{ Type = 'Run'; Label = 'Find running game'; Exe = $list.Exe; Args = (Expand-Template $list.Args $values 'PS5 ListApps'); ContinueOnError = $false
              CaptureVar = 'TitleId'; CaptureRegex = '(?im)TitleId:\s*(\S+)'; CaptureFallback = '(?im)Name:\s*(.+?)\s*$'; CaptureFirst = $true
              CaptureNoneFlag = 'NothingRunning'; CaptureNoneMsg = 'Nothing is running on this kit - nothing to close' }
}

# PS5: workspace names in "prospero-ctrl workspace list" output (Name: lines, else one name per line)
function Get-Ps5WorkspaceRegex {
    $rx = [string]$script:cfg.PS5.Launch.WorkspaceListRegex
    if (-not $rx) { $rx = '(?im)^\s*-?\s*(?:Name|Workspace(?:\s*Name)?)\s*:\s*(.+?)\s*$' }
    return $rx
}
function Get-Ps5WorkspaceNames([string]$out) {
    $n = @([regex]::Matches($out, (Get-Ps5WorkspaceRegex)) | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $n.Count) { $n = @($out -split "`r?`n" | ForEach-Object { $_.Trim().TrimStart('-').Trim() } | Where-Object { $_ -and $_ -notmatch '(?i)^(SIE CONFIDENTIAL|Copyright|version\s*:|\[\]$)' -and $_ -notmatch ':' } | Select-Object -Unique) }
    return $n
}
function Get-Ps5KitWorkspaces($c) {
    $def = Get-StepDef 'PS5' 'ListWorkspaces'
    if (-not $def) { throw "PS5 'ListWorkspaces' command is not configured in DeployConfig.json" }
    $r = Invoke-ToolOutput $def.Exe (Expand-Template $def.Args @{ IP = [string]$c.IP; Name = [string]$c.Name } 'PS5 ListWorkspaces') 30
    if ($r.Code -ne 0) { throw "workspace list failed (exit code $($r.Code)): " + (@($r.Out -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1) }
    return @(Get-Ps5WorkspaceNames $r.Out)
}
# Launch from the workspace with no name typed: read the kit's workspaces ("workspace list") right before launching -
# the PS5 tab's name if the kit has it, else the kit's only (sce_nolimit) workspace
function New-Ps5WorkspaceLookup([hashtable]$values) {
    $list = Get-StepDef 'PS5' 'ListWorkspaces'
    if (-not $list -or $script:cfg.PS5.Launch.ReadWorkspace -eq $false) { return $null }
    $prefer = [string]$values['Workspace']
    $values['Workspace'] = '{{Workspace}}'
    return @{ Type = 'Run'; Label = 'Find workspace on kit'; Exe = $list.Exe; Args = (Expand-Template $list.Args $values 'PS5 ListWorkspaces'); ContinueOnError = $false
              CaptureVar = 'Workspace'; CaptureRegex = (Get-Ps5WorkspaceRegex); CaptureLines = $true; CapturePrefer = $prefer
              CaptureSoftFilter = '(?i)^' + [regex]::Escape((Get-WorkspacePrefix).Trim()); CaptureWhat = 'workspace' }
}

# PS5: the Title ID the tool uses when none is typed, and where it comes from (shown in Launch game...)
function Get-Ps5AutoTitleId {
    if ([string]$script:cfg.PS5.Values.TitleId) { return @{ Id = [string]$script:cfg.PS5.Values.TitleId; From = 'PS5.Values.TitleId in the config' } }
    if ($rbPkg.Checked) {
        $ps = Get-Ps5PackageSelection
        $pp = $(if ($ps.Main) { $ps.Main.Path } elseif ($ps.Dlcs.Count) { $ps.Dlcs[0].Path } else { '' })
        if ($pp) { $i = (Get-Ps5Ids $pp).TitleId; if ($i) { return @{ Id = $i; From = 'the package picked on the PS5 tab' } } }
    } else {
        $lp = $txtPS5.Text.Trim()
        if ($lp) { $i = (Get-Ps5Ids $lp).TitleId; if ($i) { return @{ Id = $i; From = 'the loose build picked on the PS5 tab' } } }
    }
    if ([string]$script:cfg.PS5.Launch.TitleId) { return @{ Id = [string]$script:cfg.PS5.Launch.TitleId; From = 'the default (PS5.Launch.TitleId)' } }
    return @{ Id = ''; From = '' }
}

# Adds the launch (or close-game) command for one kit to $steps. $values = the kit/build values.
# $id = launch ID typed in the Launch game window (wins over the build and the config).
function Add-ConsoleLaunchSteps($steps,[string]$pkey,[hashtable]$values,[string]$mode,[string]$type,[string]$text,[string]$id,[string]$what = 'Launch',[string]$from = '',[string]$ws = '') {
    $v = $values.Clone()
    $idKey = $(if ($pkey -eq 'PS5') { 'TitleId' } else { 'LaunchId' })
    if ($id) { $v[$idKey] = $id.Trim() }
    # PS5 (as in BF Deploy): Close game kills the typed Title ID, else whatever "application list" shows running
    if ($pkey -eq 'PS5' -and $what -eq 'Close' -and -not $id) { $v['TitleId'] = [string]$script:cfg.PS5.Values.TitleId }
    if ($what -eq 'Close') { $stepName = 'Terminate' }
    elseif ($pkey -eq 'PS5') {
        # PS5: the BUILD TYPE decides - Package types start the installed package (Steps.Launch),
        # Workspace types (Files Final / Performance) start the game from the deploy workspace (Steps.LaunchWorkspace)
        if (-not $from) { foreach ($p in @(Get-ConsoleLaunchProfiles 'PS5')) { if ($p.Type -eq $type) { $from = $p.From } } }
        $stepName = $(if ($from -eq 'Workspace' -and (Get-StepDef 'PS5' 'LaunchWorkspace')) { 'LaunchWorkspace' } else { 'Launch' })
    }
    else { $stepName = $(if ($mode -eq 'Loose' -and (Get-StepDef $pkey 'LaunchLoose')) { 'LaunchLoose' } else { 'Launch' }) }
    $def = Get-StepDef $pkey $stepName
    if (-not $def) { throw "$pkey '$stepName' command is not configured in DeployConfig.json" }
    # PS5 with no Title ID from the window, the config or a picked build: the game's own Title ID (PS5.Launch.TitleId)
    if ($pkey -eq 'PS5' -and $what -ne 'Close' -and [string]::IsNullOrWhiteSpace([string]$v['TitleId']) -and $script:cfg.PS5.Launch.TitleId) {
        $v['TitleId'] = [string]$script:cfg.PS5.Launch.TitleId
    }
    $lookup = $null
    if ($def.Args -match "\{$idKey\}" -and [string]::IsNullOrWhiteSpace([string]$v[$idKey])) {
        if ($pkey -eq 'Xbox') { $lookup = New-XboxLaunchIdLookup $v }
        if ($pkey -eq 'PS5' -and $what -eq 'Close') { $lookup = New-Ps5RunningAppLookup $v }
        if (-not $lookup) {
            throw $(if ($pkey -eq 'PS5') { 'no Title ID - type it in Launch game..., pick the build on the PS5 tab, or set PS5.Launch.TitleId in the config' }
                    else { 'no launch ID - type it in Launch game... (or Find on kit), pick the loose build on the Xbox tab, or set Xbox.Values.LaunchId' })
        }
    }
    # PS5 workspace launch: a workspace typed / picked in the window, else read from each kit
    $wsLookup = $null
    if ($pkey -eq 'PS5' -and $stepName -eq 'LaunchWorkspace') {
        if ($ws) { $v['Workspace'] = $ws.Trim() } else { $wsLookup = New-Ps5WorkspaceLookup $v }
    }
    $v['LaunchArgs'] = ''
    if ($what -ne 'Close') {
        $v['LaunchArgs'] = Get-ConsoleLaunchArgs $text $v $type
        # XBDEPLOY / BF Deploy pass the parameters to xbapp / prospero-run as ONE argument (quoted when it has spaces)
        if ($script:cfg.$pkey.Launch.QuoteArgs -ne $false) { $v['LaunchArgs'] = ConvertTo-NativeArg $v['LaunchArgs'] }
        # PS5 application start: "/args <parameters>" must be the last thing on the line
        $pre = [string]$script:cfg.$pkey.Launch.ArgsPrefix
        if ($pre -and $v['LaunchArgs']) { $v['LaunchArgs'] = $pre.Trim() + ' ' + $v['LaunchArgs'] }
    }
    if ($lookup) { [void]$steps.Add($lookup) }
    if ($wsLookup) { [void]$steps.Add($wsLookup) }
    $uses = @(@($lookup, $wsLookup) | Where-Object { $_ } | ForEach-Object { $_.CaptureVar })
    $label = $(if ($what -eq 'Close') { 'Close game' } else { "Launch [$type]" })
    $ok = $(if ($what -eq 'Close') { $(if ($def.OkOutput) { $def.OkOutput } else { '(?i)not running' }) } else { $def.OkOutput })
    [void]$steps.Add(@{ Type = 'Run'; Label = $label; Exe = $def.Exe; Args = (Expand-LaunchCommand $def $v "$pkey $stepName"); ContinueOnError = $false; OkOutput = $ok
                        Uses = $(if ($uses.Count) { $uses } else { $null }); SkipIf = $(if ($lookup -and $lookup.CaptureNoneFlag) { $lookup.CaptureNoneFlag } else { $null }); SkipMsg = 'nothing to close' })
    return [string]$v['LaunchArgs']
}

# Plan that only launches (or closes) the game on one kit: ping first, PS5 connects when "Connect before deploy" is ticked
function New-LaunchPlan([object]$c,[int]$rowIndex,[string]$type,[string]$text,[string]$id = '',[string]$what = 'Launch',[string]$ws = '') {
    $pkey = Get-PlatformKey ([string]$c.Platform)
    if (-not $pkey) { throw "Unsupported platform '$($c.Platform)'" }
    # the build picked on the tab tells the tool the title's IDs (Title ID / launch ID)
    if ($pkey -eq 'PS5' -and $rbPkg.Checked) {
        $ps = Get-Ps5PackageSelection
        $buildPath = $(if ($ps.Main) { $ps.Main.Path } elseif ($ps.Dlcs.Count) { $ps.Dlcs[0].Path } else { '' }); $mode = 'Package'
    } else {
        $rb = Resolve-Build $pkey (Get-BuildPathFor $pkey); $buildPath = [string]$rb.Path; $mode = [string]$rb.Mode
    }
    $values = @{ IP = [string]$c.IP; Name = [string]$c.Name; BuildPath = $buildPath; LaunchArgs = '' }
    $pv = $script:cfg.$pkey.Values
    if ($pv) { foreach ($prop in $pv.PSObject.Properties) { $values[$prop.Name] = [string]$prop.Value } }
    if ($pkey -eq 'PS5') {
        $ids = Get-Ps5Ids $buildPath
        foreach ($k in 'TitleId','ContentId') { if ([string]::IsNullOrWhiteSpace([string]$values[$k]) -and $ids[$k]) { $values[$k] = $ids[$k] } }
        # workspace on the kit (PS5 tab name, e.g. "sce_nolimit playtest") - also when no build is picked
        try { $values['Workspace'] = Get-WorkspaceName $values $(if ($buildPath) { $buildPath } else { 'build' }) $c } catch {}
    } else {
        $xids = Get-XboxIds $buildPath
        foreach ($k in 'PackageFamilyName','LaunchId') { if ([string]::IsNullOrWhiteSpace([string]$values[$k]) -and $xids[$k]) { $values[$k] = $xids[$k] } }
    }
    $steps = New-Object System.Collections.ArrayList
    [void]$steps.Add(@{ Type = 'Ping'; Label = 'Check kit is online' })
    if ($pkey -eq 'PS5' -and $chkConnect.Checked) {
        $con = Get-StepDef 'PS5' 'Connect'
        if ($con) { [void]$steps.Add(@{ Type = 'Run'; Label = 'Connect'; Exe = $con.Exe; Args = (Expand-Template $con.Args $values 'PS5 Connect'); ContinueOnError = $false; OkOutput = $con.OkOutput }) }
    }
    $la = Add-ConsoleLaunchSteps $steps $pkey $values $mode $type $text $id $what '' $ws
    $close = ($what -eq 'Close')
    return @{
        Row = $rowIndex; Name = [string]$c.Name; Platform = $pkey; IP = [string]$c.IP
        Steps = @($steps); DryRun = $chkDryRun.Checked; Mode = $mode; BuildPath = $buildPath
        Action = $(if ($close) { 'Close game' } else { 'Launch' }); SuccessStatus = $(if ($close) { 'Game closed' } else { 'Launched' })
        Warn = $(if ($close) { @{ Flag = 'NothingRunning'; Result = 'SUCCESS'; Status = 'Nothing running'; Message = 'Nothing was running on this kit' } } else { $null })
        Title = $(if ($close) { 'Close game' } else { "Launch $type build" + $(if ($la) { " with: $la" } else { ' (no parameters)' }) })
        LogFile = Join-Path $logDir ("Launch_{0}_{1}_{2}.log" -f $script:RunStamp, ($c.Name -replace '[^\w\-]','_'), $pkey)
    }
}

function Start-ConsoleLaunch([string]$pkey,[int[]]$indices,[string]$type,[string]$text,[string]$id = '',[string]$what = 'Launch',[string]$ws = '') {
    $close = ($what -eq 'Close')
    $title = $(if ($close) { 'Close game' } else { 'Launch game' })
    $indices = @($indices | Where-Object { (Get-PlatformKey ([string]$script:consoles[$_].Platform)) -eq $pkey })
    if ($indices.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Tick one or more $pkey kits first.",$title) | Out-Null; return }
    $script:RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $plans = @(); $errors = @(); $notIdle = @()
    foreach ($i in $indices) {
        $c = $script:consoles[$i]
        try {
            $plans += ,(New-LaunchPlan $c $i $type $text $id $what $ws)
            if (([string]$c.Idle).ToLowerInvariant() -ne 'true') { $notIdle += $c.Name }
        } catch { $errors += "$($c.Name) ($($c.IP)): $($_.Exception.Message)" }
    }
    if ($errors.Count) { [System.Windows.Forms.MessageBox]::Show("Cannot start - fix these first:`n`n" + ($errors -join "`n"),$title,[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null; return }
    $last = $plans[0].Steps[$plans[0].Steps.Count - 1]
    $cmd = "`"$([System.IO.Path]::GetFileName($last.Exe))`" $($last.Args.Replace('{{LaunchId}}', '<game found on the kit with xbapp list>').Replace('{{TitleId}}', '<whatever is running>').Replace('{{Workspace}}', '<workspace read from each kit>'))"
    $msg = $(if ($close) { "Close the game on $($plans.Count) $pkey kit(s)?" } else { "Launch the $type build on $($plans.Count) $pkey kit(s)?" })
    $msg += "`n`n" + (Format-TargetList $indices) + "`n`nCommand (first kit):`n  $cmd"
    $msg += $(if ($close) { "`n`nUnsaved progress in the game is lost." } else { "`n`nA game already running on these kits may be closed." })
    if ($notIdle.Count) { $msg += "`n`nNOT marked idle (someone may be using these): " + ($notIdle -join ', ') }
    if ($chkDryRun.Checked) { $msg += "`n`nDRY RUN - commands are logged, nothing is executed." }
    if ([System.Windows.Forms.MessageBox]::Show($msg,$title,[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $par = [int]$script:cfg.Power.Parallel; if ($par -lt 1) { $par = 32 }
    Start-RunPlans $plans $par $(if ($close) { 'Close game' } else { 'Launch' })
}

# Runs a tool and returns its exit code + output (used by Find on kit; waits at most $timeoutSec)
function Invoke-ToolOutput([string]$exe,[string]$argText,[int]$timeoutSec = 30) {
    if (-not (Test-Path -LiteralPath $exe)) { throw "Tool not found: $exe" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = $argText
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutSec * 1000)) { try { $p.Kill() } catch {}; throw "no answer within $timeoutSec s" }
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Out = ($o.Result + "`n" + $e.Result) }
}

# Xbox: the apps installed on a kit (launch IDs), Battlefield ones (FindApp) first
function Get-XboxKitApps($c) {
    $def = Get-StepDef 'Xbox' 'ListApps'
    if (-not $def) { throw "Xbox 'ListApps' command is not configured in DeployConfig.json" }
    $r = Invoke-ToolOutput $def.Exe (Expand-Template $def.Args @{ IP = [string]$c.IP; Name = [string]$c.Name } 'Xbox ListApps') 30
    if ($r.Code -ne 0) { throw "xbapp list failed (exit code $($r.Code)): " + (@($r.Out -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1) }
    $all = @([regex]::Matches($r.Out, (Get-XboxAppIdRegex)) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $find = Get-XboxFindApp
    return @(@($all | Where-Object { $_ -match $find }) + @($all | Where-Object { $_ -notmatch $find }))
}

function Show-ConsoleLaunchDialog([string]$pkey) {
    $profiles = @(Get-ConsoleLaunchProfiles $pkey)
    $file = Get-ConsoleLaunchFile $pkey
    $state = Read-PcLaunchState $file
    $ticked = @(Get-SelectedIndices | Where-Object { (Get-PlatformKey ([string]$script:consoles[$_].Platform)) -eq $pkey })
    $ctx = @{ Type = ''; Loading = $false; Go = ''; Prof = $null }
    $isXbox = ($pkey -eq 'Xbox')
    $dy = $(if ($isXbox) { 0 } else { 48 })   # PS5 has an extra Workspace row

    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Launch game - $pkey"; $f.ClientSize = New-Object System.Drawing.Size(776, (446 + $dy)); $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $gray = [System.Drawing.Color]::DimGray
    $mk = { param($text, $x, $y, $w, $h) $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.SetBounds($x, $y, $w, $h); $f.Controls.Add($l); $l }

    [void](& $mk 'Build type:' 12 18 110 20)
    $cbType = New-Object System.Windows.Forms.ComboBox; $cbType.DropDownStyle = 'DropDownList'; $cbType.SetBounds(125, 15, 250, 24); $f.Controls.Add($cbType)
    foreach ($p in $profiles) { [void]$cbType.Items.Add($p.Type) }
    $lblTypeHint = & $mk 'Also used by "Launch after deploy". Use This Build sets it from the Config.' 385 18 385 20; $lblTypeHint.ForeColor = $gray

    [void](& $mk $(if ($isXbox) { 'Launch ID:' } else { 'Title ID:' }) 12 54 110 20)
    $cbId = New-Object System.Windows.Forms.ComboBox; $cbId.DropDownStyle = 'DropDown'; $cbId.SetBounds(125, 51, 432, 24); $f.Controls.Add($cbId)
    $btnFind = New-Object System.Windows.Forms.Button; $btnFind.Text = 'Find on kit'; $btnFind.SetBounds(563, 49, 107, 28); $f.Controls.Add($btnFind)
    $btnFind.Visible = $isXbox
    $lblIdHint = & $mk $(if ($isXbox) { 'Empty = from the loose build, else looked up on each kit (xbapp list). Find on kit lists what the first ticked kit has.' } else { '' }) 125 77 641 18
    # PS5: the box stays empty = automatic; the line under it says which Title ID that is, and the list offers it
    $ps5Auto = $(if (-not $isXbox) { Get-Ps5AutoTitleId } else { $null })
    if ($ps5Auto) {
        $known = @(@($ps5Auto.Id, [string]$script:cfg.PS5.Launch.TitleId) + @($state.Types.Values | ForEach-Object { [string]$_.Id }) | Where-Object { $_ } | Select-Object -Unique)
        foreach ($k in $known) { [void]$cbId.Items.Add($k) }
    }
    $updateIdHint = {
        if ($isXbox) { return }
        $typed = $cbId.Text.Trim()
        $where = $(if ($ctx.Prof.From -eq 'Workspace') { 'Runs from the workspace on the kit' } else { 'Runs the installed package' })
        $lblTypeHint.Text = "$where (also Launch after deploy)"
        $lblIdHint.Text = $(if ($typed) { "Using the typed Title ID $typed for $($ctx.Type)." }
                            elseif ($ps5Auto.Id) { "Empty = automatic: $($ps5Auto.Id) (from $($ps5Auto.From)). Type or pick another to override." }
                            else { 'No Title ID known - type it, pick the build on the PS5 tab, or set PS5.Launch.TitleId.' })
    }
    $lblIdHint.ForeColor = $gray

    # PS5: which workspace the Workspace build types (Files Final / Performance) start from
    $lblWs = & $mk 'Workspace:' 12 102 110 20
    $cbWs = New-Object System.Windows.Forms.ComboBox; $cbWs.DropDownStyle = 'DropDown'; $cbWs.SetBounds(125, 99, 432, 24); $f.Controls.Add($cbWs)
    $btnFindWs = New-Object System.Windows.Forms.Button; $btnFindWs.Text = 'Find on kit'; $btnFindWs.SetBounds(563, 97, 107, 28); $f.Controls.Add($btnFindWs)
    $lblWsHint = & $mk '' 125 125 641 18; $lblWsHint.ForeColor = $gray
    foreach ($x in @($lblWs, $cbWs, $btnFindWs, $lblWsHint)) { $x.Visible = -not $isXbox }
    $tabWs = $(if (-not $isXbox) { try { Get-WorkspaceName @{} $(if ($txtPS5.Text.Trim()) { $txtPS5.Text.Trim() } else { 'build' }) ([pscustomobject]@{ Name = 'kit' }) } catch { '' } } else { '' })
    $updateWsHint = {
        if ($isXbox) { return }
        $useWs = ($ctx.Prof.From -eq 'Workspace')
        $cbWs.Enabled = $useWs; $btnFindWs.Enabled = $useWs
        $typed = $cbWs.Text.Trim()
        $lblWsHint.Text = $(if (-not $useWs) { "Not used - $($ctx.Type) runs the installed package." }
                            elseif ($typed) { "Using workspace `"$typed`" on every kit." }
                            else { "Empty = read from each kit (workspace list): `"$tabWs`" if the kit has it, else the kit's only workspace." })
    }

    [void](& $mk 'Preset:' 12 (102 + $dy) 110 20)
    $cbPreset = New-Object System.Windows.Forms.ComboBox; $cbPreset.DropDownStyle = 'DropDownList'; $cbPreset.SetBounds(125, (99 + $dy), 300, 24); $f.Controls.Add($cbPreset)
    $btnPresetSave = New-Object System.Windows.Forms.Button; $btnPresetSave.Text = 'Save as preset...'; $btnPresetSave.SetBounds(432, (97 + $dy), 125, 28); $f.Controls.Add($btnPresetSave)
    $btnPresetDel = New-Object System.Windows.Forms.Button; $btnPresetDel.Text = 'Delete preset'; $btnPresetDel.SetBounds(563, (97 + $dy), 107, 28); $f.Controls.Add($btnPresetDel)

    $lblArgs = & $mk 'Launch parameters:' 12 (136 + $dy) 500 18
    $tp = New-Object System.Windows.Forms.TextBox; $tp.Multiline = $true; $tp.ScrollBars = 'Vertical'; $tp.WordWrap = $true; $tp.AcceptsReturn = $true
    $tp.Font = New-Object System.Drawing.Font('Consolas', 9); $tp.SetBounds(12, (156 + $dy), 754, 100); $f.Controls.Add($tp)
    $lblArgHint = & $mk 'One parameter per line is fine (lines are joined with spaces; lines starting with # are skipped). {Type} {Name} {IP} {TitleId} {Workspace} ... are filled in.' 12 (260 + $dy) 590 32
    $lblArgHint.ForeColor = $gray
    $btnDefault = New-Object System.Windows.Forms.Button; $btnDefault.Text = 'Config default'; $btnDefault.SetBounds(636, (260 + $dy), 130, 26); $f.Controls.Add($btnDefault)

    [void](& $mk 'Command line:' 12 (304 + $dy) 100 20)
    $txtCmd = New-Object System.Windows.Forms.TextBox; $txtCmd.ReadOnly = $true; $txtCmd.SetBounds(115, (301 + $dy), 651, 24); $f.Controls.Add($txtCmd)
    $lblKits = & $mk '' 115 (329 + $dy) 651 36; $lblKits.ForeColor = $gray

    $btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = 'Save (for Launch after deploy)'; $btnSave.SetBounds(12, (404 + $dy), 210, 30); $f.Controls.Add($btnSave)
    $btnClose = New-Object System.Windows.Forms.Button; $btnClose.SetBounds(228, (404 + $dy), 175, 30); $f.Controls.Add($btnClose)
    $btnClose.Text = $(if ($ticked.Count) { "Close game on $($ticked.Count) kit(s)" } else { 'Close game' })
    $btnClose.Enabled = ($ticked.Count -gt 0) -and -not $script:Busy -and [bool](Get-StepDef $pkey 'Terminate')
    $btnGo = New-Object System.Windows.Forms.Button; $btnGo.SetBounds(476, (404 + $dy), 195, 30); $f.Controls.Add($btnGo)
    $btnGo.Text = $(if ($ticked.Count) { "Launch on $($ticked.Count) ticked kit(s)" } else { 'Launch (no kits ticked)' })
    $btnGo.Enabled = ($ticked.Count -gt 0) -and -not $script:Busy
    $btnNo = New-Object System.Windows.Forms.Button; $btnNo.Text = 'Cancel'; $btnNo.SetBounds(681, (404 + $dy), 85, 30); $btnNo.DialogResult = 'Cancel'; $f.Controls.Add($btnNo); $f.CancelButton = $btnNo

    $names = @($ticked | Select-Object -First 6 | ForEach-Object { $script:consoles[$_].Name })
    $lblKits.Text = $(if ($ticked.Count) { "Ticked: " + ($names -join ', ') + $(if ($ticked.Count -gt 6) { " and $($ticked.Count - 6) more" } else { '' }) } else { "No $pkey kits ticked - tick kits in the list to launch now, or just Save the parameters for Launch after deploy." })
    if ($script:Busy) { $lblKits.Text += '   (something is running - wait for it to finish to launch)' }
    if (-not (Get-StepDef $pkey 'Terminate')) { $lblKits.Text += "   (Close game: no $pkey Steps.Terminate command in the config)" }

    $updatePreview = {
        if ($ctx.Loading) { return }
        $c = $(if ($ticked.Count) { $script:consoles[$ticked[0]] } else { [pscustomobject]@{ Name = 'kit'; IP = '<kit IP>'; Platform = $pkey; Idle = 'true' } })
        try {
            $plan = New-LaunchPlan $c -1 $ctx.Type $tp.Text $cbId.Text.Trim() 'Launch' $cbWs.Text.Trim()
            $s = $plan.Steps[$plan.Steps.Count - 1]
            $txtCmd.Text = "$([System.IO.Path]::GetFileName($s.Exe)) $($s.Args)".Replace('{{LaunchId}}', '<game found on the kit>').Replace('{{TitleId}}', '<whatever is running>').Replace('{{Workspace}}', '<workspace read from the kit>')
        } catch { $txtCmd.Text = "(cannot launch yet: $($_.Exception.Message))" }
    }
    $fillPresets = {
        param([string]$select)
        $cbPreset.Items.Clear(); [void]$cbPreset.Items.Add('(none)')
        $t = $state.Types[$ctx.Type]
        if ($t) { foreach ($q in $t.Presets) { [void]$cbPreset.Items.Add($q.Name) } }
        $i = $(if ($select) { $cbPreset.Items.IndexOf($select) } else { -1 })
        $cbPreset.SelectedIndex = [math]::Max(0, $i)
        $btnPresetDel.Enabled = ($cbPreset.SelectedIndex -gt 0)
    }
    $commit = {
        param([bool]$force)
        if (-not $ctx.Type) { return }
        $t = $state.Types[$ctx.Type]
        if (-not $t) {
            # an untouched type keeps following the config defaults
            if (-not $force -and $tp.Text -eq [string]$ctx.Prof.Args -and $cbId.Text.Trim() -eq [string]$ctx.Prof.Id -and -not $cbWs.Text.Trim()) { return }
            $t = @{ Folder = ''; Exe = ''; Args = ''; Id = ''; Ws = ''; Saved = ''; Presets = New-Object System.Collections.ArrayList }; $state.Types[$ctx.Type] = $t
        }
        $t.Args = $tp.Text
        $t.Id = $cbId.Text.Trim()
        $t.Ws = $cbWs.Text.Trim()
    }
    $savePresets = {
        $disk = Read-PcLaunchState $file
        $d = $disk.Types[$ctx.Type]
        if (-not $d) { $m = $state.Types[$ctx.Type]; $d = @{ Folder = ''; Exe = ''; Args = $m.Args; Id = $m.Id; Ws = $m.Ws; Saved = ''; Presets = $null }; $disk.Types[$ctx.Type] = $d }
        $d.Presets = $state.Types[$ctx.Type].Presets
        Save-PcLaunchState $disk $file
    }
    $loadType = {
        param([string]$type)
        $ctx.Loading = $true
        $ctx.Type = $type
        $prof = $null; foreach ($p in $profiles) { if ($p.Type -eq $type) { $prof = $p } }
        $ctx.Prof = $prof
        $t = $state.Types[$type]
        $lblArgs.Text = "$pkey launch parameters for $($type):"
        $tp.Text = $(if ($t) { [string]$t.Args } else { [string]$prof.Args })
        $cbId.Text = $(if ($t) { [string]$t.Id } else { [string]$prof.Id })
        $cbWs.Text = $(if ($t) { [string]$t.Ws } else { '' })
        & $fillPresets ''
        & $updateIdHint
        & $updateWsHint
        $btnDefault.Enabled = [bool]$prof.Args
        $ctx.Loading = $false
        & $updatePreview
    }

    $cbType.Add_SelectedIndexChanged({ if ($ctx.Loading) { return }; & $commit; & $loadType ([string]$cbType.SelectedItem) })
    $tp.Add_TextChanged({ & $updatePreview })
    $cbId.Add_TextChanged({ & $updatePreview; & $updateIdHint })
    $cbWs.Add_TextChanged({ & $updatePreview; & $updateWsHint })
    $cbWs.Add_SelectedIndexChanged({ if ($cbWs.SelectedIndex -ge 0) { $cbWs.Text = [string]$cbWs.SelectedItem }; & $updatePreview; & $updateWsHint })
    $btnFindWs.Add_Click({
        if (-not $ticked.Count) { [System.Windows.Forms.MessageBox]::Show('Tick a kit in the PS5 list first - Find on kit asks the first ticked kit which workspaces it has.','Find on kit') | Out-Null; return }
        $c = $script:consoles[$ticked[0]]
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lblWsHint.Text = "Asking $($c.Name) ($($c.IP)) for its workspaces..."; [System.Windows.Forms.Application]::DoEvents()
        try { $wss = @(Get-Ps5KitWorkspaces $c) }
        catch { $lblWsHint.Text = "Find on kit: $($_.Exception.Message)"; return }
        finally { $f.Cursor = [System.Windows.Forms.Cursors]::Default }
        $cbWs.Items.Clear(); foreach ($w in $wss) { [void]$cbWs.Items.Add($w) }
        $hit = @($wss | Where-Object { $_ -ieq $tabWs })
        if ($hit.Count) { $cbWs.Text = $hit[0] } elseif ($wss.Count -eq 1) { $cbWs.Text = $wss[0] }
        $lblWsHint.Text = "$($c.Name): $($wss.Count) workspace(s)" + $(if ($wss.Count) { ': ' + ($wss -join ', ') } else { ' - deploy the build first' }) + $(if ($wss.Count -gt 1 -and -not $hit.Count) { ' - pick one' } else { '' })
        Append-UiLog ("PS5: workspaces on $($c.Name): " + $(if ($wss.Count) { $wss -join ', ' } else { 'none' }))
    })
    $cbId.Add_SelectedIndexChanged({ if ($cbId.SelectedIndex -ge 0) { $cbId.Text = [string]$cbId.SelectedItem }; & $updatePreview })
    $btnFind.Add_Click({
        if (-not $ticked.Count) { [System.Windows.Forms.MessageBox]::Show('Tick a kit in the Xbox list first - Find on kit asks the first ticked kit which games it has.','Find on kit') | Out-Null; return }
        $c = $script:consoles[$ticked[0]]
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lblIdHint.Text = "Asking $($c.Name) ($($c.IP)) for its installed apps..."; [System.Windows.Forms.Application]::DoEvents()
        try { $apps = @(Get-XboxKitApps $c) }
        catch { $lblIdHint.Text = "Find on kit: $($_.Exception.Message)"; return }
        finally { $f.Cursor = [System.Windows.Forms.Cursors]::Default }
        $cbId.Items.Clear(); foreach ($a in $apps) { [void]$cbId.Items.Add($a) }
        $find = Get-XboxFindApp
        $bf = @($apps | Where-Object { $_ -match $find })
        if ($bf.Count) { $cbId.Text = $bf[0] }
        $lblIdHint.Text = "$($c.Name): $($apps.Count) app(s), $($bf.Count) Battlefield" + $(if ($bf.Count -gt 1) { ' - pick the right one in the list' } elseif ($bf.Count -eq 0) { ' - is the game installed on this kit?' } else { '' })
        Append-UiLog ("Xbox: apps on $($c.Name): " + $(if ($apps.Count) { $apps -join ', ' } else { 'none' }))
    })
    $cbPreset.Add_SelectedIndexChanged({
        $btnPresetDel.Enabled = ($cbPreset.SelectedIndex -gt 0)
        if ($ctx.Loading -or $cbPreset.SelectedIndex -le 0) { return }
        foreach ($q in $state.Types[$ctx.Type].Presets) { if ($q.Name -eq [string]$cbPreset.SelectedItem) { $tp.Text = $q.Args } }
    })
    $btnPresetSave.Add_Click({
        Add-Type -AssemblyName Microsoft.VisualBasic
        $cur = $(if ($cbPreset.SelectedIndex -gt 0) { [string]$cbPreset.SelectedItem } else { '' })
        $name = [Microsoft.VisualBasic.Interaction]::InputBox("Name for these $pkey $($ctx.Type) launch parameters:", 'Save preset', $cur).Trim()
        if (-not $name) { return }
        if ($name -eq '(none)') { [System.Windows.Forms.MessageBox]::Show('Pick another name.','Save preset') | Out-Null; return }
        & $commit $true
        $t = $state.Types[$ctx.Type]
        $hit = $null; foreach ($q in $t.Presets) { if ($q.Name -ieq $name) { $hit = $q } }
        if ($hit) {
            if ([System.Windows.Forms.MessageBox]::Show("Replace the preset '$($hit.Name)'?",'Save preset',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $hit.Args = $tp.Text; $name = $hit.Name
        } else { [void]$t.Presets.Add(@{ Name = $name; Args = $tp.Text }) }
        & $savePresets
        $ctx.Loading = $true; & $fillPresets $name; $ctx.Loading = $false
    })
    $btnPresetDel.Add_Click({
        if ($cbPreset.SelectedIndex -le 0) { return }
        $name = [string]$cbPreset.SelectedItem
        if ([System.Windows.Forms.MessageBox]::Show("Delete the preset '$name'?",'Delete preset',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        & $commit $true
        $t = $state.Types[$ctx.Type]
        $gone = @($t.Presets | Where-Object { $_.Name -eq $name }); foreach ($q in $gone) { $t.Presets.Remove($q) }
        & $savePresets
        $ctx.Loading = $true; & $fillPresets ''; $ctx.Loading = $false
    })
    $btnDefault.Add_Click({ $tp.Text = [string]$ctx.Prof.Args })
    $btnSave.Add_Click({ $ctx.Go = 'Save'; $f.Close() })
    $tryPlan = {
        param([string]$what)
        $c = $script:consoles[$ticked[0]]
        try { [void](New-LaunchPlan $c -1 $ctx.Type $tp.Text $cbId.Text.Trim() $what $cbWs.Text.Trim()); return $true }
        catch { [System.Windows.Forms.MessageBox]::Show("Cannot start on $($c.Name):`n$($_.Exception.Message)",'Launch game',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null; return $false }
    }
    $btnGo.Add_Click({ if ($ticked.Count -and (& $tryPlan 'Launch')) { $ctx.Go = 'Launch'; $f.Close() } })
    $btnClose.Add_Click({ if ($ticked.Count -and (& $tryPlan 'Close')) { $ctx.Go = 'Close'; $f.Close() } })

    $start = Get-ConsoleLaunchSetting $pkey
    $ctx.Loading = $true; $cbType.SelectedItem = $start.Type; $ctx.Loading = $false
    & $loadType $start.Type

    [void]$f.ShowDialog($form)
    if (-not $ctx.Go) { return }   # Cancel: nothing is remembered (saved presets stay)
    & $commit
    $state.LastType = $ctx.Type
    if ($state.Types[$ctx.Type]) { $state.Types[$ctx.Type].Saved = (Get-Date).ToString('s') }
    Save-PcLaunchState $state $file
    Update-ConsoleLaunchLabels
    $id = $cbId.Text.Trim()
    if ($ctx.Go -ne 'Close') { Append-UiLog ("$($pkey): launch build type $($ctx.Type), parameters: " + $(if (($a = Get-ConsoleLaunchArgs $tp.Text @{} $ctx.Type)) { $a } else { '(none)' }) + $(if ($id) { ", ID $id" } else { '' })) }
    if ($ctx.Go -eq 'Launch') { Start-ConsoleLaunch $pkey $ticked $ctx.Type $tp.Text $id 'Launch' $cbWs.Text.Trim() }
    if ($ctx.Go -eq 'Close') { Start-ConsoleLaunch $pkey $ticked $ctx.Type $tp.Text $id 'Close' }
}

$btnXbLaunch.Add_Click({ try { Load-Config } catch {}; try { Show-ConsoleLaunchDialog 'Xbox' } catch { [System.Windows.Forms.MessageBox]::Show("Launch window error:`n$($_.Exception.Message)",'Launch game') | Out-Null } })
$btnPs5Launch.Add_Click({ try { Load-Config } catch {}; try { Show-ConsoleLaunchDialog 'PS5' } catch { [System.Windows.Forms.MessageBox]::Show("Launch window error:`n$($_.Exception.Message)",'Launch game') | Out-Null } })

# ---- Xbox / PS5: screenshots, clips and video recording on the ticked kits, with the SDKs' own capture tools
#   Xbox: xbcapture (screenshot, /C = the last N seconds, /V = live video for N seconds)
#   PS5:  prospero-ctrl target screenshot / target video
# The picture comes over the network to this PC - no capture card. Screenshots and clips run like any other
# kit action (parallel, one row per kit). Recordings are long-running tool processes; Stop recording sends
# them Ctrl+C (HYD_CtrlC.ps1) so the file is closed properly, and kills them only if they do not stop.
$script:Recs = New-Object System.Collections.ArrayList

function Get-CaptureFolder {
    $root = [string]$script:cfg.Capture.Folder
    if (-not $root) { $root = Join-Path $base 'Captures' }
    $root = [Environment]::ExpandEnvironmentVariables($root)
    $d = Join-Path $root (Get-Date -Format 'yyyy-MM-dd')
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    return $d
}
function Get-CaptureFileName($c,[string]$ext,[string]$tag = '') { return ('{0}_{1}{2}{3}' -f ([string]$c.Name -replace '[^\w\-]','_'), (Get-Date -Format 'HHmmss'), $tag, $ext) }
function Get-TickedFor([string]$pkey) { return @(Get-SelectedIndices | Where-Object { (Get-PlatformKey ([string]$script:consoles[$_].Platform)) -eq $pkey }) }
function Get-CaptureOptions([string]$pkey,[string]$name) { $v = $script:cfg.Capture.$pkey.$name; if ($null -eq $v) { $v = $script:cfg.Capture.$name }; return [string]$v }
function Set-CaptureRow([int]$i,[string]$st,[string]$step,[string]$prog,[string]$res) {
    if ($i -lt 0) {
        # this PC: shown on the PC tab's screen capture line
        $lblPcRec.Text = "${st}: $prog"
        $lblPcRec.ForeColor = $(switch -regex ($res) { '^(SAVED|REPAIRED)$' { [System.Drawing.Color]::DarkGreen } 'FAILED' { [System.Drawing.Color]::DarkRed } 'CHECK FILE' { [System.Drawing.Color]::DarkOrange } default { [System.Drawing.SystemColors]::ControlText } })
        return
    }
    $gr = Get-GridRow $i
    if (-not $gr) { return }
    $gr.Cells['Status'].Value = $st; $gr.Cells['Step'].Value = $step; $gr.Cells['Progress'].Value = $prog; $gr.Cells['Result'].Value = $res
    $gr.Cells['Result'].Style.BackColor = $(switch -regex ($res) { '^(SAVED|REPAIRED)$' { [System.Drawing.Color]::FromArgb(198,239,206) } 'FAILED' { [System.Drawing.Color]::FromArgb(255,199,206) } 'CHECK FILE' { [System.Drawing.Color]::FromArgb(255,235,156) } default { [System.Drawing.Color]::Empty } })
}
function Update-CaptureButtons {
    foreach ($x in @(@('Xbox', $btnXbRecStop), @('PS5', $btnPs5RecStop), @('PC', $btnPcRecStop))) {
        if (-not $x[1]) { continue }
        $n = @($script:Recs | Where-Object { $_.Platform -eq $x[0] }).Count
        $x[1].Enabled = ($n -gt 0)
        $x[1].Text = $(if ($n) { "Stop recording ($n)" } else { 'Stop recording' })
    }
}

# --- screenshots (and Xbox "save the last N seconds" clips): one plan per kit through the normal worker
function Start-KitCaptures([string]$pkey,[int[]]$indices,[string]$what = 'Screenshot') {
    $title = $(if ($what -eq 'Clip') { 'Save clip' } else { 'Screenshot' })
    if ($indices.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Tick one or more $pkey kits first.",$title) | Out-Null; return }
    if ($script:Busy) { [System.Windows.Forms.MessageBox]::Show("Something is running - wait for it to finish, then try again.",$title) | Out-Null; return }
    $def = Get-StepDef $pkey $what
    if (-not $def) { [System.Windows.Forms.MessageBox]::Show("$pkey '$what' command is not configured in DeployConfig.json",$title) | Out-Null; return }
    $folder = Get-CaptureFolder
    if ($what -eq 'Clip') {
        $secs = [int]$script:cfg.Capture.Xbox.ClipSeconds; if ($secs -lt 6 -or $secs -gt 300) { $secs = 90 }
        $ext = '.mp4'; $tag = "_last${secs}s"
    } else {
        $secs = 0; $ext = '.' + $(if ((Get-CaptureOptions $pkey 'ScreenshotFormat')) { (Get-CaptureOptions $pkey 'ScreenshotFormat').TrimStart('.') } else { 'png' }); $tag = ''
    }
    $script:RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $plans = @()
    foreach ($i in $indices) {
        $c = $script:consoles[$i]
        if ($script:Recs | Where-Object { $_.Index -eq $i }) { Append-UiLog "${title}: $($c.Name) is recording - skipped"; continue }
        $file = Join-Path $folder (Get-CaptureFileName $c $ext $tag)
        $values = @{ IP = [string]$c.IP; Name = [string]$c.Name; File = $file; Seconds = [string]$secs; Options = (Get-CaptureOptions $pkey $(if ($what -eq 'Clip') { 'VideoOptions' } else { 'ScreenshotOptions' })) }
        $plans += ,@{
            Row = $i; Name = [string]$c.Name; Platform = $pkey; IP = [string]$c.IP
            Steps = @(@{ Type = 'Ping'; Label = 'Check kit is online' },
                      @{ Type = 'Run'; Label = $title; Exe = $def.Exe; Args = (Expand-Template $def.Args $values "$pkey $what"); ContinueOnError = $false; OkOutput = $def.OkOutput })
            DryRun = $chkDryRun.Checked; Mode = ''; BuildPath = $file; Action = $title; Title = "$title to $file"
            SuccessStatus = $(if ($what -eq 'Clip') { "Last ${secs}s saved" } else { 'Screenshot saved' })
            LogFile = Join-Path $logDir ("Capture_{0}_{1}_{2}.log" -f $script:RunStamp, ($c.Name -replace '[^\w\-]','_'), $pkey)
        }
    }
    if (-not $plans.Count) { return }
    Append-UiLog ("$title of $($plans.Count) $pkey kit(s)" + $(if ($what -eq 'Clip') { " (last $secs s)" } else { '' }) + " -> $folder")
    $par = [int]$script:cfg.Power.Parallel; if ($par -lt 1) { $par = 32 }
    Start-RunPlans $plans $par $title
}

# --- recording
# The GDK bin folder (xbcapture, XtfConsoleControl.dll ...): Xbox.ToolDir, else the GDK install
function Get-XboxGdkBin {
    $d = [Environment]::ExpandEnvironmentVariables([string]$script:cfg.Xbox.ToolDir)
    if ($d -and (Test-Path -LiteralPath $d)) { return $d.TrimEnd('\','/') }
    $root = $(if ($env:GameDK) { $env:GameDK.TrimEnd('\') } else { Join-Path ${env:ProgramFiles(x86)} 'Microsoft GDK' })
    return (Join-Path $root 'bin')
}

function Start-KitRecording([string]$pkey,[int[]]$indices) {
    if ($indices.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Tick one or more $pkey kits first.",'Record video') | Out-Null; return }
    $isXbox = ($pkey -eq 'Xbox')
    if ($isXbox) {
        # Xbox: the GDK's own live capture (as Xbox Manager's red button) through HYD_XboxRecord.ps1 - Stop recording
        # ends it with a stop signal and the capture finishes the file itself
        $helper = Join-Path $base 'HYD_XboxRecord.ps1'
        $gdkBin = Get-XboxGdkBin
        $why = $(if (-not (Test-Path -LiteralPath $helper)) { 'HYD_XboxRecord.ps1 is missing from the tool folder.' }
                 elseif (-not (Test-Path -LiteralPath (Join-Path $gdkBin 'XtfConsoleControl.dll'))) { "XtfConsoleControl.dll was not found in $gdkBin`n`nInstall the GDK, or set Xbox.ToolDir in DeployConfig.json to its bin folder." }
                 else { '' })
        if ($why) { [System.Windows.Forms.MessageBox]::Show("Cannot record Xbox video:`n`n$why",'Record video') | Out-Null; return }
    } else {
        $def = Get-StepDef $pkey 'Video'
        if (-not $def) { [System.Windows.Forms.MessageBox]::Show("$pkey 'Video' command is not configured in DeployConfig.json",'Record video') | Out-Null; return }
    }
    $busyKits = @($indices | Where-Object { $i = $_; $script:Recs | Where-Object { $_.Index -eq $i } })
    $todo = @($indices | Where-Object { $busyKits -notcontains $_ })
    if (-not $todo.Count) { [System.Windows.Forms.MessageBox]::Show('The ticked kits are already recording.','Record video') | Out-Null; return }
    $cap = $script:cfg.Capture
    $maxMin = $(if ($isXbox) { 360 } else { 600 })   # the GDK live capture records at most 21600 s

    # options window
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Record video - $pkey"; $f.ClientSize = New-Object System.Drawing.Size(460, 236); $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $mk = { param($t, $x, $y, $w) $l = New-Object System.Windows.Forms.Label; $l.Text = $t; $l.SetBounds($x, $y, $w, 20); $f.Controls.Add($l); $l }
    [void](& $mk 'Stop after (minutes):' 12 19 140)
    $num = New-Object System.Windows.Forms.NumericUpDown; $num.SetBounds(160, 16, 70, 24); $num.Minimum = 0; $num.Maximum = $maxMin
    $num.Value = $(if ($null -ne $cap.MaxMinutes) { [math]::Min($maxMin, [math]::Max(0, [int]$cap.MaxMinutes)) } else { 30 }); $f.Controls.Add($num)
    $l0 = & $mk $(if ($isXbox) { '0 = until Stop recording (6 h at most)' } else { '0 = until Stop recording' }) 240 19 210; $l0.ForeColor = [System.Drawing.Color]::DimGray
    [void](& $mk 'Resolution:' 12 55 140)
    $cbRes = New-Object System.Windows.Forms.ComboBox; $cbRes.DropDownStyle = 'DropDownList'; $cbRes.SetBounds(160, 52, 100, 24); $f.Controls.Add($cbRes)
    foreach ($r in '720p','1080p','1440p','2160p') { [void]$cbRes.Items.Add($r) }
    $cbRes.SelectedItem = $(if ($cap.Resolution -and $cbRes.Items.Contains([string]$cap.Resolution)) { [string]$cap.Resolution } else { '1080p' })
    [void](& $mk 'Frame rate:' 12 91 140)
    $cbFps = New-Object System.Windows.Forms.ComboBox; $cbFps.DropDownStyle = 'DropDownList'; $cbFps.SetBounds(160, 88, 100, 24); $f.Controls.Add($cbFps)
    foreach ($r in '60','30') { [void]$cbFps.Items.Add($r) }
    $cbFps.SelectedItem = $(if ([string]$cap.FrameRate -eq '30') { '30' } else { '60' })
    if ($isXbox) {
        # the GDK capture has no quality settings - the kit records at its own capture settings
        $cbRes.Enabled = $false; $cbFps.Enabled = $false
        $lq = & $mk 'set by the kit' 270 55 170; $lq.ForeColor = [System.Drawing.Color]::DimGray
    }
    $names = @($todo | Select-Object -First 5 | ForEach-Object { $script:consoles[$_].Name })
    $lk = & $mk ("Kits: " + ($names -join ', ') + $(if ($todo.Count -gt 5) { " and $($todo.Count - 5) more" } else { '' })) 12 126 436
    $lf = & $mk "Saved to: $(Join-Path ([Environment]::ExpandEnvironmentVariables($(if ($cap.Folder) { [string]$cap.Folder } else { Join-Path $base 'Captures' }))) (Get-Date -Format 'yyyy-MM-dd'))" 12 148 436
    $lf.ForeColor = [System.Drawing.Color]::DimGray; $lf.AutoEllipsis = $true
    if ($busyKits.Count) { $lk.Text += "   ($($busyKits.Count) already recording - skipped)" }
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = "Record $($todo.Count) kit(s)"; $ok.SetBounds(236, 192, 120, 30); $ok.DialogResult = 'OK'; $f.Controls.Add($ok); $f.AcceptButton = $ok
    $no = New-Object System.Windows.Forms.Button; $no.Text = 'Cancel'; $no.SetBounds(364, 192, 84, 30); $no.DialogResult = 'Cancel'; $f.Controls.Add($no); $f.CancelButton = $no
    if ($f.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $mins = [int]$num.Value
    # PS5: /length:<n>m (nothing = until Ctrl+C). Xbox: seconds for the GDK capture (6..21600, always given)
    $length = $(if ($isXbox) { '' } elseif ($mins -gt 0) { "/length:${mins}m" } else { '' })
    $xbSecs = $(if ($mins -gt 0) { [math]::Max(6, $mins * 60) } else { 21600 })
    $folder = Get-CaptureFolder
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $started = 0
    foreach ($i in $todo) {
        $c = $script:consoles[$i]
        $alive = $false
        try { $alive = ((New-Object System.Net.NetworkInformation.Ping).Send([string]$c.IP, 1500).Status -eq 'Success') } catch {}
        if (-not $alive) { Set-CaptureRow $i 'Offline' 'Record video' 'kit is offline - no reply to ping' 'FAILED'; Append-UiLog "Record: $($c.Name) is offline - not recorded"; continue }
        $file = Join-Path $folder (Get-CaptureFileName $c '.mp4')
        for ($n = 2; (Test-Path -LiteralPath $file) -and $n -lt 100; $n++) { $file = Join-Path $folder (Get-CaptureFileName $c '.mp4' "_$n") }   # never reuse an existing file
        $values = @{ IP = [string]$c.IP; Name = [string]$c.Name; File = $file; Resolution = [string]$cbRes.SelectedItem; FrameRate = [string]$cbFps.SelectedItem
                     Length = $length; Options = (Get-CaptureOptions $pkey 'VideoOptions') }
        $stopName = $null
        if ($isXbox) {
            $stopName = 'HYD_XboxRecStop_' + [guid]::NewGuid().ToString('N')
            $exe = Get-PowerShellExe
            $argText = "-NoProfile -ExecutionPolicy Bypass -File `"$helper`" -IP `"$($c.IP)`" -File `"$file`" -Seconds $xbSecs -StopEvent $stopName -Bin `"$gdkBin`" -ParentPid $PID"
        } else {
            try { $argText = Expand-Template $def.Args $values "$pkey Video" } catch { Append-UiLog "Record: $($_.Exception.Message)"; return }
            $exe = $def.Exe
        }
        if ($chkDryRun.Checked) { Append-UiLog "DRY RUN record $($c.Name): `"$exe`" $argText"; continue }
        if (-not (Test-Path -LiteralPath $exe)) { Append-UiLog "Record: tool not found: $exe"; return }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe; $psi.Arguments = $argText
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        try { $p = [System.Diagnostics.Process]::Start($psi) } catch { Set-CaptureRow $i 'Error' 'Record video' $_.Exception.Message 'FAILED'; continue }
        [void]$script:Recs.Add(@{ Index = $i; Platform = $pkey; Name = [string]$c.Name; IP = [string]$c.IP; Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync()
                                  File = $file; Started = (Get-Date); Minutes = $mins; StopAsked = $null; Args = $argText; StopEvent = $stopName; Log = (Join-Path $logDir ("Capture_{0}_{1}_{2}.log" -f $stamp, ($c.Name -replace '[^\w\-]','_'), $pkey)) })
        if ($sync.Rows.ContainsKey($i)) { $sync.Rows.Remove($i) }   # an old deploy row must not overwrite the recording status
        Set-CaptureRow $i 'Recording' 'Record video' "0:00 -> $([System.IO.Path]::GetFileName($file))" 'Running'
        Append-UiLog ("Record: $($c.Name) -> $file  (" + $(if ($mins) { "stops after $mins min" } else { 'until Stop recording' }) + $(if ($isXbox) { '' } else { ", $($cbRes.SelectedItem) $($cbFps.SelectedItem) fps" }) + ")")
        $started++
    }
    if ($started) { $status.Text = "Recording $($script:Recs.Count) kit(s)"; $recTimer.Start() }
    Update-CaptureButtons
}

# Xbox (GDK capture helper): set its named stop event - the capture then finishes the file itself
function Send-StopEvent($r) {
    try { $ev = [System.Threading.EventWaitHandle]::OpenExisting([string]$r.StopEvent); [void]$ev.Set(); $ev.Dispose(); $r.EventSent = Get-Date; return $true }
    catch { return $false }   # not created yet (the helper is still starting) - the timer tries again
}

# Ctrl+C to recordings (the clean way to end them), via a small helper that attaches to each one's console
function Send-CtrlC([int[]]$ids) {
    $helper = Join-Path $base 'HYD_CtrlC.ps1'
    if (-not $ids.Count -or -not (Test-Path -LiteralPath $helper)) { return $false }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-PowerShellExe)
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$helper`" -Ids $($ids -join ',')"
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $h = [System.Diagnostics.Process]::Start($psi)
        [void]$h.WaitForExit(15000)
        return ($h.HasExited -and $h.ExitCode -eq 0)
    } catch { Append-UiLog "Stop recording: could not send Ctrl+C - $($_.Exception.Message)"; return $false }
}

function Stop-KitRecording([string]$pkey,[bool]$all) {
    $mine = @($script:Recs | Where-Object { $all -or $_.Platform -eq $pkey })
    if (-not $mine.Count) { return }
    $ticked = $(if ($all -or $pkey -eq 'PC') { @() } else { @(Get-TickedFor $pkey) })
    $targets = @($mine | Where-Object { $all -or -not $ticked.Count -or $ticked -contains $_.Index } | Where-Object { -not $_.StopAsked })
    if (-not $targets.Count) {
        if ($ticked.Count) { [System.Windows.Forms.MessageBox]::Show("None of the ticked kits is recording.`n`nUntick all kits to stop every $pkey recording.",'Stop recording') | Out-Null }
        return
    }
    foreach ($r in $targets) { $r.StopAsked = Get-Date; Set-CaptureRow $r.Index 'Stopping' 'Record video' 'finishing the file...' 'Running' }
    Append-UiLog "Stop recording: $(@($targets | ForEach-Object { $_.Name }) -join ', ')"
    # ffmpeg (this PC) stops on "q"; Xbox (GDK capture) on its stop event; PS5 (prospero-ctrl) on Ctrl+C
    foreach ($r in @($targets | Where-Object { $_.Stdin })) { try { if (-not $r.Proc.HasExited) { $r.Proc.StandardInput.WriteLine('q'); $r.Proc.StandardInput.Flush() } } catch {} }
    foreach ($r in @($targets | Where-Object { $_.StopEvent })) { if (-not $r.Proc.HasExited) { [void](Send-StopEvent $r) } }
    $targets = @($targets | Where-Object { -not $_.StopEvent })
    $cc = @($targets | Where-Object { -not $_.Stdin })
    if ($cc.Count -and -not (Send-CtrlC @($cc | Where-Object { -not $_.Proc.HasExited } | ForEach-Object { $_.Proc.Id }))) {
        Append-UiLog 'Stop recording: Ctrl+C could not be sent (HYD_CtrlC.ps1 missing from the tool folder, or blocked) - the recording tool is stopped hard'
        foreach ($r in $cc) { try { if (-not $r.Proc.HasExited) { $r.Proc.Kill(); $r.Killed = $true } } catch {} }
    }
}

$recTimer = New-Object System.Windows.Forms.Timer
$recTimer.Interval = 1000
# An .mp4 is playable only when its index ("moov") was written - that happens when the recording tool
# finishes the file. A recording that was cut off has all the video but no index.
function Test-Mp4Complete([string]$path) {
    if ([System.IO.Path]::GetExtension($path) -ne '.mp4') { return $true }
    $fs = $null
    try { $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite') } catch { return $true }
    try {
        $n = $fs.Length; $o = [long]0; $h = New-Object byte[] 16
        while ($o + 8 -le $n) {
            [void]$fs.Seek($o, 'Begin'); if ($fs.Read($h, 0, 16) -lt 8) { break }
            $size = ([long]$h[0] -shl 24) -bor ([long]$h[1] -shl 16) -bor ([long]$h[2] -shl 8) -bor [long]$h[3]
            $type = [System.Text.Encoding]::ASCII.GetString($h, 4, 4)
            if ($o -eq 0 -and $type -ne 'ftyp') { return $true }   # not an MP4 file: nothing to judge
            if ($size -eq 1) { $size = [long]0; for ($i = 8; $i -lt 16; $i++) { $size = ($size -shl 8) -bor [long]$h[$i] } }
            elseif ($size -eq 0) { $size = $n - $o }
            if ($type -eq 'moov') { return $true }
            if ($size -lt 8) { break }
            $o += $size
        }
        return $false
    } catch { return $true } finally { $fs.Close() }
}

$recTimer.Add_Tick({
    $stopWait = $(if ([int]$script:cfg.Capture.StopTimeoutSec -gt 0) { [int]$script:cfg.Capture.StopTimeoutSec } else { 20 })
    foreach ($r in @($script:Recs)) {
        $el = (Get-Date) - $r.Started
        $clock = $(if ($el.TotalHours -ge 1) { '{0}:{1:mm\:ss}' -f [int][math]::Floor($el.TotalHours), $el } else { '{0:m\:ss}' -f $el })

        # ---- a recording still running
        if (-not $r.Proc.HasExited) {
            if ($r.StopAsked -and $r.StopEvent -and -not $r.EventSent) { [void](Send-StopEvent $r) }
            $hardWait = $stopWait + $(if ($r.StopEvent) { 15 } else { 0 })
            if ($r.StopAsked -and ((Get-Date) - $r.StopAsked).TotalSeconds -gt $hardWait) {
                try { $r.Proc.Kill() } catch {}
                $r.Killed = $true
                Append-UiLog "Stop recording: $($r.Name) did not stop within $hardWait s - stopped hard"
            } elseif (-not $r.StopAsked) {
                $size = 0.0; try { if (Test-Path -LiteralPath $r.File) { $size = [double](Get-Item -LiteralPath $r.File).Length } } catch {}
                $txt = "$clock" + $(if ($size -gt 0) { " | $(Format-Size $size)" } else { '' }) + " -> $([System.IO.Path]::GetFileName($r.File))"
                if ($r.Index -lt 0) { $lblPcRec.Text = "Recording: $txt" }
                else { $gr = Get-GridRow $r.Index; if ($gr) { $gr.Cells['Status'].Value = 'Recording'; $gr.Cells['Progress'].Value = $txt } }
            }
            continue
        }

        # ---- finished (time limit reached, stopped, or failed)
        if ($r.Loop) {
            try { $r.Loop.Stop() } catch {}
            if ($r.Loop.Error) { Append-UiLog "Record: $($r.Name) - sound: $($r.Loop.Error)" }
        }
        $out = ''; try { $out = [string]$r.Out.Result + "`n" + [string]$r.Err.Result } catch {}
        $code = $r.Proc.ExitCode
        $how = $(if ($r.Killed) { 'stopped hard' } elseif ($r.StopAsked) { 'stopped' } else { 'ended by itself' })
        try { Set-Content -LiteralPath $r.Log -Value ("`"$($r.Proc.StartInfo.FileName)`" $($r.Args)`r`nexit code $code ($how)`r`n$out") -Encoding UTF8 } catch {}
        $size = 0.0; try { if (Test-Path -LiteralPath $r.File) { $size = [double](Get-Item -LiteralPath $r.File).Length } } catch {}
        $last = @($out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '(?i)^(SIE CONFIDENTIAL|Copyright|version\s*:)' } | Select-Object -Last 1)
        if ($size -gt 0 -and -not (Test-Mp4Complete $r.File)) {
            # the recording tool ended before it finished the file (no index) - it will not play
            Set-CaptureRow $r.Index 'Recorded' 'Done' "$how after $clock - the file was not finished (will not play) - $($r.File)" 'CHECK FILE'
            Append-UiLog "Record: $($r.Name) - $how after $clock; the file was not finished (it will not play): $($r.File)"
            Write-Log $r.Name $r.Platform $r.IP 'Record video' 'CHECK FILE' 'file not finished'
        } elseif ($size -gt 0 -and ($code -eq 0 -or $r.StopAsked) -and -not $r.Killed) {
            Set-CaptureRow $r.Index 'Recorded' 'Done' "$clock, $(Format-Size $size) -> $($r.File)" 'SAVED'
            Append-UiLog "Record: $($r.Name) saved $clock, $(Format-Size $size): $($r.File)"
            Write-Log $r.Name $r.Platform $r.IP 'Record video' 'SAVED' $r.File
        } elseif ($size -gt 0) {
            Set-CaptureRow $r.Index 'Recorded' 'Done' "stopped hard after $clock - $($r.File)" 'CHECK FILE'
            Write-Log $r.Name $r.Platform $r.IP 'Record video' 'CHECK FILE' $r.File
        } else {
            $res = @($out -split "`r?`n" | Where-Object { $_ -like 'RESULT|FAIL|*' } | Select-Object -Last 1)
            $msg = $(if ($res.Count) { ($res[0] -split '\|', 3)[2] } elseif ($last.Count) { $last[0] } elseif ($r.StopAsked) { "stopped after $clock - the tool wrote no file" } else { "no file written (exit code $code)" })
            $hint = $(if ($r.Platform -eq 'PC' -and $r.Loop -and $r.Loop.Error) { " - sound: $($r.Loop.Error)" }
                      elseif ($r.Platform -eq 'PC') { '' }
                      elseif ($out -match '(?i)another host|ownership|owned') { ' - another PC owns this kit' }
                      elseif ($out -match '(?i)stream') { ' - the kit is already streaming to another PC (/force-stop-stream in Capture.PS5.VideoOptions ends that)' }
                      elseif ($out -match '0x8C11040D') { ' - no game is running on the kit' }
                      else { '' })
            Set-CaptureRow $r.Index 'Error' 'Record video' ($msg + $hint) 'FAILED'
            Append-UiLog "Record: $($r.Name) FAILED - $msg$hint | log: $($r.Log)"
            Write-Log $r.Name $r.Platform $r.IP 'Record video' 'FAILED' $msg
        }
        $script:Recs.Remove($r)
    }
    if (-not $script:Recs.Count) { $recTimer.Stop(); $status.Text = 'Recordings finished' }
    Update-CaptureButtons
})

foreach ($x in @(@('Xbox', $btnXbShot, $btnXbClip, $btnXbRec, $btnXbRecStop, $btnXbCaptures), @('PS5', $btnPs5Shot, $null, $btnPs5Rec, $btnPs5RecStop, $btnPs5Captures))) {
    $k = $x[0]
    $x[1].Tag = $k; $x[3].Tag = $k; $x[4].Tag = $k
    $x[1].Add_Click({ try { Load-Config } catch {}; Start-KitCaptures $this.Tag (Get-TickedFor $this.Tag) 'Screenshot' })
    $x[3].Add_Click({ try { Load-Config } catch {}; try { Start-KitRecording $this.Tag (Get-TickedFor $this.Tag) } catch { [System.Windows.Forms.MessageBox]::Show("Record video error:`n$($_.Exception.Message)",'Record video') | Out-Null } })
    $x[4].Add_Click({ Stop-KitRecording $this.Tag $false })
    $x[5].Add_Click({ try { Load-Config } catch {}; $d = Split-Path -Parent (Get-CaptureFolder); Start-Process explorer.exe -ArgumentList ('"' + $d + '"') })
}
$btnXbClip.Add_Click({ try { Load-Config } catch {}; Start-KitCaptures 'Xbox' (Get-TickedFor 'Xbox') 'Clip' })

# ---- PC: screenshot and MP4 recording of one monitor of this PC (ffmpeg)
# ffmpeg 6.0+ reads the screen with Desktop Duplication (ddagrab) - the same way Windows' own recorder does, so
# full-screen games are captured - and encodes on the graphics card when it can (NVIDIA / AMD / Intel), else on
# the CPU. Stop recording sends "q" to ffmpeg, which closes the MP4 properly. Without ddagrab (old ffmpeg) it
# falls back to gdigrab, which may show black for some full-screen games.
$hydMonitorSource = @'
using System;
using System.Runtime.InteropServices;
public static class HydDisplay {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra; public int dmFields;
        public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight; public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Ansi)] public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    // real pixels of a display (not scaled by Windows display scaling): x, y, width, height, refresh rate
    public static int[] Mode(string device) {
        DEVMODE m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(device, -1, ref m)) return null;
        return new int[] { m.dmPositionX, m.dmPositionY, m.dmPelsWidth, m.dmPelsHeight, m.dmDisplayFrequency };
    }
}
'@
$script:PcCap = @{ Ffmpeg = $null; DdaChecked = $false; Dda = $false; Encoder = $null; OutputMap = $null }
$pcMonitorFile = Join-Path $base 'PcCaptureMonitor.txt'
$pcAudioFile = Join-Path $base 'PcCaptureAudio.txt'
$script:PcAudioNames = @(''); $script:PcAudioListed = $false; $script:PcAudioFilling = $false

# Monitors of this PC, numbered like Windows' Display settings (DISPLAY1, DISPLAY2, ...), with real pixel sizes
function Get-PcMonitors {
    try { if (-not ('HydDisplay' -as [type])) { Add-Type -TypeDefinition $hydMonitorSource -ErrorAction Stop } } catch {}
    $list = @()
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $dev = ([string]$s.DeviceName).Trim([char]0).Trim()
        $num = $(if ($dev -match '(\d+)$') { [int]$Matches[1] } else { 99 })
        $m = $null; try { $m = [HydDisplay]::Mode($dev) } catch {}
        $x = $(if ($m) { $m[0] } else { $s.Bounds.X }); $y = $(if ($m) { $m[1] } else { $s.Bounds.Y })
        $w = $(if ($m) { $m[2] } else { $s.Bounds.Width }); $h = $(if ($m) { $m[3] } else { $s.Bounds.Height }); $hz = $(if ($m) { $m[4] } else { 0 })
        $list += [pscustomobject]@{ Device = $dev; Number = $num; X = $x; Y = $y; Width = $w; Height = $h; Hz = $hz; Primary = [bool]$s.Primary
                                    Label = ("Display $num - ${w}x${h}" + $(if ($hz -gt 1) { " $hz Hz" } else { '' }) + $(if ($s.Primary) { ' (main)' } else { '' })) }
    }
    return @($list | Sort-Object Number)
}

$script:PcMons = @()
function Update-PcMonitorList {
    $keep = $(if ($cmbPcMonitor.SelectedIndex -ge 0 -and $cmbPcMonitor.SelectedIndex -lt $script:PcMons.Count) { [string]$script:PcMons[$cmbPcMonitor.SelectedIndex].Device } else { '' })
    if (-not $keep) { try { $keep = (Get-Content -LiteralPath $pcMonitorFile -ErrorAction Stop | Select-Object -First 1).Trim() } catch {} }
    $mons = @(Get-PcMonitors)
    $script:PcMons = $mons
    $cmbPcMonitor.Items.Clear()
    foreach ($m in $mons) { [void]$cmbPcMonitor.Items.Add($m.Label) }
    $pick = 0
    for ($i = 0; $i -lt $mons.Count; $i++) { if ($mons[$i].Device -eq $keep) { $pick = $i } }
    if (-not $keep) { for ($i = 0; $i -lt $mons.Count; $i++) { if ($mons[$i].Primary) { $pick = $i } } }
    if ($mons.Count) { $cmbPcMonitor.SelectedIndex = $pick }
}

function Find-Ffmpeg {
    $c = @()
    if ([string]$script:cfg.Capture.PC.Ffmpeg) { $c += [Environment]::ExpandEnvironmentVariables([string]$script:cfg.Capture.PC.Ffmpeg) }
    $c += (Join-Path $base 'ffmpeg.exe'); $c += (Join-Path $base 'ffmpeg\bin\ffmpeg.exe'); $c += (Join-Path $base 'ffmpeg\ffmpeg.exe')
    foreach ($p in $c) { if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p } }
    $g = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.Source }
    return $null
}

# Sound for PC recordings: what plays on a Windows OUTPUT device (speakers / headphones - the game, voice chat,
# everything you hear), captured with WASAPI loopback and fed to ffmpeg over a local TCP port (127.0.0.1 only).
$hydAudioSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Diagnostics;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace HydAudio {
    [StructLayout(LayoutKind.Sequential)] public struct PROPERTYKEY { public Guid fmtid; public int pid; }
    [StructLayout(LayoutKind.Sequential)] public struct PROPVARIANT { public ushort vt; public ushort r1; public ushort r2; public ushort r3; public IntPtr p; public IntPtr p2; }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceCollection {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }
    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PROPERTYKEY key);
        [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
    }
    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioClient {
        [PreserveSig] int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
        [PreserveSig] int GetBufferSize(out uint frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint padding);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr handle);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }
    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioCaptureClient {
        [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out int flags, out ulong devicePosition, out ulong qpcPosition);
        [PreserveSig] int ReleaseBuffer(uint frames);
        [PreserveSig] int GetNextPacketSize(out uint frames);
    }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] public class MMDeviceEnumeratorCom { }

    public class OutputDevice { public string Id; public string Name; public bool IsDefault; }
    public class MixFormat { public int Rate; public int Channels; public int Bits; public int BlockAlign; public bool IsFloat; public string FfmpegFormat; }

    // Windows sound OUTPUT devices (speakers, headphones ...) and their "loopback": exactly what is played on them
    public static class Loopback {
        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT pv);
        const int eRender = 0, eConsole = 0, DEVICE_STATE_ACTIVE = 1, CLSCTX_ALL = 23;

        public static void Check(int hr, string what) { if (hr < 0) throw new Exception(what + " failed (0x" + hr.ToString("X8") + ")"); }
        public static IMMDeviceEnumerator Enumerator() { return (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom()); }

        static string Name(IMMDevice d) {
            IPropertyStore ps;
            if (d.OpenPropertyStore(0, out ps) != 0 || ps == null) return "";
            try {
                var key = new PROPERTYKEY(); key.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"); key.pid = 14;
                PROPVARIANT v;
                if (ps.GetValue(ref key, out v) != 0) return "";
                string s = (v.vt == 31 && v.p != IntPtr.Zero) ? Marshal.PtrToStringUni(v.p) : "";
                PropVariantClear(ref v);
                return s;
            } finally { Marshal.ReleaseComObject(ps); }
        }

        public static List<OutputDevice> List() {
            var list = new List<OutputDevice>();
            var en = Enumerator();
            try {
                string defId = null; IMMDevice def;
                if (en.GetDefaultAudioEndpoint(eRender, eConsole, out def) == 0 && def != null) { def.GetId(out defId); Marshal.ReleaseComObject(def); }
                IMMDeviceCollection col;
                Check(en.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, out col), "Listing the sound outputs");
                try {
                    uint n; col.GetCount(out n);
                    for (uint i = 0; i < n; i++) {
                        IMMDevice d;
                        if (col.Item(i, out d) != 0 || d == null) continue;
                        var o = new OutputDevice(); d.GetId(out o.Id); o.Name = Name(d); o.IsDefault = (o.Id != null && o.Id == defId);
                        if (string.IsNullOrEmpty(o.Name)) o.Name = o.Id;
                        list.Add(o); Marshal.ReleaseComObject(d);
                    }
                } finally { Marshal.ReleaseComObject(col); }
            } finally { Marshal.ReleaseComObject(en); }
            return list;
        }

        // the output with this name (as shown in Windows); empty name = the default output
        public static IMMDevice Find(IMMDeviceEnumerator en, string name) {
            IMMDevice d;
            if (string.IsNullOrEmpty(name)) { Check(en.GetDefaultAudioEndpoint(eRender, eConsole, out d), "Finding the default sound output"); return d; }
            IMMDeviceCollection col;
            Check(en.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, out col), "Listing the sound outputs");
            try {
                uint n; col.GetCount(out n);
                for (uint i = 0; i < n; i++) {
                    if (col.Item(i, out d) != 0 || d == null) continue;
                    if (string.Equals(Name(d), name, StringComparison.OrdinalIgnoreCase)) return d;
                    Marshal.ReleaseComObject(d);
                }
            } finally { Marshal.ReleaseComObject(col); }
            throw new Exception("the sound output '" + name + "' is not connected or is disabled");
        }

        public static MixFormat Parse(IntPtr f) {
            var m = new MixFormat();
            int tag = (ushort)Marshal.ReadInt16(f, 0);
            m.Channels = Marshal.ReadInt16(f, 2); m.Rate = Marshal.ReadInt32(f, 4); m.BlockAlign = Marshal.ReadInt16(f, 12); m.Bits = Marshal.ReadInt16(f, 14);
            if (tag == 0xFFFE) m.IsFloat = (Marshal.ReadInt32(f, 24) == 3); else m.IsFloat = (tag == 3);
            if (m.IsFloat && m.Bits == 32) m.FfmpegFormat = "f32le";
            else if (!m.IsFloat && m.Bits == 16) m.FfmpegFormat = "s16le";
            else if (!m.IsFloat && m.Bits == 24) m.FfmpegFormat = "s24le";
            else if (!m.IsFloat && m.Bits == 32) m.FfmpegFormat = "s32le";
            else throw new Exception("unsupported sound format (" + m.Bits + " bit" + (m.IsFloat ? " float" : "") + ")");
            return m;
        }

        // the format Windows mixes this output in (what the loopback delivers)
        public static MixFormat GetFormat(string name) {
            var en = Enumerator(); IMMDevice dev = null; object o = null; IntPtr f = IntPtr.Zero;
            try {
                dev = Find(en, name);
                Guid iid = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
                Check(dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o), "Opening the sound output");
                Check(((IAudioClient)o).GetMixFormat(out f), "Reading the sound format");
                return Parse(f);
            } finally {
                if (f != IntPtr.Zero) Marshal.FreeCoTaskMem(f);
                if (o != null) Marshal.ReleaseComObject(o);
                if (dev != null) Marshal.ReleaseComObject(dev);
                Marshal.ReleaseComObject(en);
            }
        }
    }

    // Records the loopback of one output and serves it as raw sound on a local TCP port that ffmpeg reads
    // ("tcp://127.0.0.1:<Port>"). The port is open before ffmpeg starts (Start), so ffmpeg always finds it.
    // Windows delivers nothing while nothing is playing - those gaps are filled with silence so sound and video stay in step.
    public class LoopbackRecorder {
        public string DeviceName = ""; public int Port;
        public volatile bool StopNow; public volatile bool Running; public volatile bool Connected;
        public string Error = ""; public long FramesWritten; public long SilenceFrames;
        Thread t; TcpListener listener;

        public void Start() {
            listener = new TcpListener(IPAddress.Loopback, 0);   // this PC only, any free port
            listener.Start(1);
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            t = new Thread(Run); t.IsBackground = true; t.Start();   // its own (MTA) thread: all sound COM work happens there
        }
        public void Stop() { StopNow = true; if (t != null) t.Join(5000); }

        void Run() {
            TcpClient conn = null; NetworkStream pipe = null; IMMDeviceEnumerator en = null; IMMDevice dev = null; IAudioClient client = null; IAudioCaptureClient cap = null; IntPtr fmt = IntPtr.Zero;
            try {
                var wait = Stopwatch.StartNew();
                while (!listener.Pending()) {
                    if (StopNow) return;
                    if (wait.Elapsed.TotalSeconds > 60) { Error = "ffmpeg did not open the sound input"; return; }
                    Thread.Sleep(50);
                }
                conn = listener.AcceptTcpClient();
                conn.NoDelay = true; conn.SendBufferSize = 1 << 20;
                pipe = conn.GetStream();
                Connected = true;

                en = Loopback.Enumerator();
                dev = Loopback.Find(en, DeviceName);
                Guid iid = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"); object o;
                Loopback.Check(dev.Activate(ref iid, 23, IntPtr.Zero, out o), "Opening the sound output");
                client = (IAudioClient)o;
                Loopback.Check(client.GetMixFormat(out fmt), "Reading the sound format");
                MixFormat mf = Loopback.Parse(fmt);
                Loopback.Check(client.Initialize(0, 0x00020000, 10000000, 0, fmt, IntPtr.Zero), "Starting the sound capture");   // shared, LOOPBACK, 1 s buffer
                Guid cid = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"); object co;
                Loopback.Check(client.GetService(ref cid, out co), "Starting the sound capture");
                cap = (IAudioCaptureClient)co;
                Loopback.Check(client.Start(), "Starting the sound capture");
                Running = true;

                var clock = Stopwatch.StartNew();
                byte[] buf = new byte[mf.BlockAlign * mf.Rate];
                byte[] zeros = new byte[mf.BlockAlign * (mf.Rate / 10)];
                long margin = mf.Rate / 10, keep = mf.Rate / 50;
                while (!StopNow) {
                    uint next;
                    Loopback.Check(cap.GetNextPacketSize(out next), "Reading sound");
                    while (next > 0) {
                        IntPtr data; uint frames; int flags; ulong dp, qp;
                        Loopback.Check(cap.GetBuffer(out data, out frames, out flags, out dp, out qp), "Reading sound");
                        int bytes = (int)frames * mf.BlockAlign;
                        if (bytes > buf.Length) buf = new byte[bytes];
                        if ((flags & 2) != 0) Array.Clear(buf, 0, bytes); else Marshal.Copy(data, buf, 0, bytes);   // 2 = silent packet
                        cap.ReleaseBuffer(frames);
                        pipe.Write(buf, 0, bytes); FramesWritten += frames;
                        Loopback.Check(cap.GetNextPacketSize(out next), "Reading sound");
                    }
                    long due = (long)(clock.Elapsed.TotalSeconds * mf.Rate);
                    if (due - FramesWritten > margin) {
                        long fill = due - FramesWritten - keep;
                        while (fill > 0) {
                            int fr = (int)Math.Min(fill, zeros.Length / mf.BlockAlign);
                            pipe.Write(zeros, 0, fr * mf.BlockAlign); FramesWritten += fr; SilenceFrames += fr; fill -= fr;
                        }
                    }
                    Thread.Sleep(10);
                }
            }
            catch (IOException) { }       // ffmpeg closed the sound input: the recording has ended
            catch (SocketException) { }
            catch (Exception e) { Error = e.Message; }
            finally {
                Running = false;
                try { if (client != null) client.Stop(); } catch { }
                if (fmt != IntPtr.Zero) Marshal.FreeCoTaskMem(fmt);
                try { if (cap != null) Marshal.ReleaseComObject(cap); } catch { }
                try { if (client != null) Marshal.ReleaseComObject(client); } catch { }
                try { if (dev != null) Marshal.ReleaseComObject(dev); } catch { }
                try { if (en != null) Marshal.ReleaseComObject(en); } catch { }
                try { if (pipe != null) pipe.Dispose(); } catch { }
                try { if (conn != null) conn.Close(); } catch { }
                try { listener.Stop(); } catch { }
            }
        }
    }
}
'@

function Initialize-HydAudio {
    if ('HydAudio.LoopbackRecorder' -as [type]) { return }
    if ($PSVersionTable.PSEdition -eq 'Core') { Add-Type -TypeDefinition $hydAudioSource -Language CSharp -IgnoreWarnings -ErrorAction Stop }
    else { Add-Type -TypeDefinition $hydAudioSource -Language CSharp -IgnoreWarnings -ErrorAction Stop }
}

# Windows sound outputs (as named in Windows Sound settings). Ok = $false when they cannot be read.
function Get-PcOutputDevices {
    try { Initialize-HydAudio; $l = @([HydAudio.Loopback]::List()) } catch { return @{ Ok = $false; Devices = @(); Default = ''; Error = $_.Exception.Message } }
    return @{ Ok = $true; Devices = @($l | ForEach-Object { $_.Name }); Default = [string](@($l | Where-Object { $_.IsDefault } | ForEach-Object { $_.Name }) | Select-Object -First 1) }
}

# Sound format of an output (what its loopback delivers) - ffmpeg is told this for the raw input
function Get-PcSoundFormat([string]$name) { Initialize-HydAudio; return [HydAudio.Loopback]::GetFormat($name) }

# Starts the loopback recorder: its port (.Port) is open when this returns; it waits for ffmpeg to connect
function Start-PcSoundCapture([string]$name) {
    Initialize-HydAudio
    $rec = New-Object HydAudio.LoopbackRecorder
    $rec.DeviceName = $name
    $rec.Start()
    return $rec
}

# The Sound list: "No sound" + the Windows sound outputs. The pick is remembered (PcCaptureAudio.txt; empty = no sound).
# $probe = read the outputs from Windows (otherwise only the remembered one is shown)
function Update-PcAudioList([bool]$probe) {
    $keep = $null
    if ($cmbPcAudio.SelectedIndex -ge 0 -and $cmbPcAudio.SelectedIndex -lt $script:PcAudioNames.Count) { $keep = [string]$script:PcAudioNames[$cmbPcAudio.SelectedIndex] }
    if ($null -eq $keep) {
        if (Test-Path -LiteralPath $pcAudioFile) { $keep = ''; try { $keep = [string](Get-Content -LiteralPath $pcAudioFile -Raw -ErrorAction Stop) } catch {}; $keep = $keep.Trim() }
        else { $keep = ([string]$script:cfg.Capture.PC.AudioDevice).Trim() }
    }
    $names = @(); $missing = $false; $def = ''
    if ($probe) {
        $res = Get-PcOutputDevices
        if ($res.Ok) { $names = @($res.Devices); $def = [string]$res.Default; $script:PcAudioListed = $true }
        else { $lblPcRec.Text = "Could not read the sound outputs: $($res.Error)"; $lblPcRec.ForeColor = [System.Drawing.Color]::DarkOrange }
    }
    if ($keep -and $names -notcontains $keep) { $names = @($keep) + $names; $missing = [bool]$script:PcAudioListed }
    $script:PcAudioFilling = $true
    try {
        $cmbPcAudio.Items.Clear(); $script:PcAudioNames = @('')
        [void]$cmbPcAudio.Items.Add('No sound')
        foreach ($n in $names) { [void]$cmbPcAudio.Items.Add($(if ($missing -and $n -eq $keep) { "$n (not found)" } elseif ($def -and $n -eq $def) { "$n (default)" } else { $n })); $script:PcAudioNames += $n }
        $i = [array]::IndexOf([string[]]$script:PcAudioNames, [string]$keep)
        $cmbPcAudio.SelectedIndex = [math]::Max(0, $i)
    } finally { $script:PcAudioFilling = $false }
}

function Save-PcAudioPick { try { Set-Content -LiteralPath $pcAudioFile -Value (Get-PcAudioPicked) -Encoding UTF8 } catch {} }

# The output whose sound is recorded ('' = no sound)
function Get-PcAudioPicked {
    if ($cmbPcAudio -and $cmbPcAudio.Items.Count -gt 0) {
        $i = $cmbPcAudio.SelectedIndex
        if ($i -gt 0 -and $i -lt $script:PcAudioNames.Count) { return [string]$script:PcAudioNames[$i] }
        return ''
    }
    return ([string]$script:cfg.Capture.PC.AudioDevice).Trim()
}

# Finds ffmpeg, checks it can use Desktop Duplication, picks the encoder and works out which ffmpeg output
# number shows which monitor (by its size). Done once; asks with a message box when ffmpeg is missing.
function Initialize-PcCapture {
    $ff = Find-Ffmpeg
    if (-not $ff) {
        [System.Windows.Forms.MessageBox]::Show("PC screen capture needs ffmpeg.exe (free, one file, no install).`n`n1. Download a Windows build of ffmpeg 6.0 or newer, e.g. 'ffmpeg-release-essentials.zip' from gyan.dev or a build from github.com/BtbN/FFmpeg-Builds.`n2. Copy ffmpeg.exe (from its bin folder) into the tool folder:`n   $base`n   or set Capture.PC.Ffmpeg in DeployConfig.json to its full path.",'PC screen capture',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return $false
    }
    if ($script:PcCap.Ffmpeg -eq $ff -and $script:PcCap.Encoder) { return $true }
    $script:PcCap.Ffmpeg = $ff
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $status.Text = 'Checking ffmpeg for screen capture...'; [System.Windows.Forms.Application]::DoEvents()
    try {
        $method = [string]$script:cfg.Capture.PC.Method
        $flt = ''; try { $flt = (Invoke-ToolOutput $ff '-hide_banner -filters' 20).Out } catch {}
        $script:PcCap.Dda = ($method -ne 'gdigrab') -and ($flt -match '(?m)\sddagrab\s')
        # encoder: the configured one, else the first that really works on this PC (graphics card first)
        $want = [string]$script:cfg.Capture.PC.Encoder
        $cands = $(if ($want -and $want -ne 'auto') { @($want) } else { @('h264_nvenc', 'h264_amf', 'h264_qsv', 'libx264') })
        $script:PcCap.Encoder = $null
        foreach ($enc in $cands) {
            if ($enc -eq 'libx264') { $script:PcCap.Encoder = $enc; break }
            $pf = $(if ($enc -eq 'h264_nvenc') { 'yuv420p' } else { 'nv12' })
            try { $r = Invoke-ToolOutput $ff "-hide_banner -loglevel error -f lavfi -i color=c=black:s=1280x720:r=30 -frames:v 5 -pix_fmt $pf -c:v $enc -f null -" 20 } catch { continue }
            if ($r.Code -eq 0) { $script:PcCap.Encoder = $enc; break }
        }
        if (-not $script:PcCap.Encoder) { $script:PcCap.Encoder = 'libx264' }
        # Desktop Duplication numbers the screens itself: match each of its outputs to a monitor by size
        $script:PcCap.OutputMap = @{}
        if ($script:PcCap.Dda) {
            $mons = @(Get-PcMonitors)
            $sizes = @{}
            for ($n = 0; $n -lt [math]::Max(1, $mons.Count); $n++) {
                try {
                    $r = Invoke-ToolOutput $ff "-hide_banner -filter_complex ddagrab=output_idx=${n}:framerate=1,hwdownload,format=bgra -frames:v 1 -f null -" 20
                    if ($r.Out -match 'Video:[^\r\n]*?(\d{3,5})x(\d{3,5})') { $sizes[$n] = "$($Matches[1])x$($Matches[2])" }
                } catch {}
            }
            $used = @{}
            foreach ($m in $mons) {
                $key = "$($m.Width)x$($m.Height)"
                $hits = @($sizes.Keys | Where-Object { $sizes[$_] -eq $key -and -not $used.ContainsKey($_) } | Sort-Object)
                if ($hits.Count) { $script:PcCap.OutputMap[$m.Device] = $hits[0]; $used[$hits[0]] = $true }
            }
        }
        Append-UiLog ("PC capture: $ff | " + $(if ($script:PcCap.Dda) { 'Desktop Duplication (ddagrab)' } else { 'GDI capture (gdigrab - full-screen games may record black; use ffmpeg 6.0+)' }) + " | encoder $($script:PcCap.Encoder)")
    } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default; $status.Text = 'Ready' }
    return $true
}

# ffmpeg input part for one monitor: Desktop Duplication output, or GDI with the monitor's position and size
function Get-PcCaptureInput($mon,[int]$fps,[bool]$mouse) {
    $idx = $null
    if ($script:PcCap.Dda) {
        $idx = $script:PcCap.OutputMap[$mon.Device]
        # not matched: if Desktop Duplication saw other screens, this one is on another graphics card -> GDI;
        # if the size check found nothing at all, go by Windows' numbering
        if ($null -eq $idx -and -not $script:PcCap.OutputMap.Count) { $idx = [math]::Max(0, $mon.Number - 1) }
    }
    if ($null -ne $idx) {
        return @{ Kind = 'dda'; Filter = "ddagrab=output_idx=${idx}:framerate=${fps}:draw_mouse=$(if ($mouse) { 1 } else { 0 }),hwdownload,format=bgra" }
    }
    return @{ Kind = 'gdi'; Input = "-f gdigrab -framerate $fps -draw_mouse $(if ($mouse) { 1 } else { 0 }) -offset_x $($mon.X) -offset_y $($mon.Y) -video_size $($mon.Width)x$($mon.Height) -i desktop" }
}

function Get-PcEncoderArgs {
    switch ($script:PcCap.Encoder) {
        'h264_nvenc' { return '-c:v h264_nvenc -preset p4 -cq 23 -pix_fmt yuv420p' }
        'h264_amf'   { return '-c:v h264_amf -quality balanced -rc cqp -qp_i 22 -qp_p 22 -pix_fmt nv12' }
        'h264_qsv'   { return '-c:v h264_qsv -global_quality 23 -pix_fmt nv12' }
        default      { return '-c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p' }
    }
}

# Full ffmpeg command line for a screenshot (frames = 1, .png) or a recording (.mp4)
# $audio = $null (no sound) or @{ Url; Fmt; Rate; Ch } from Start-PcRecording
function Get-PcCaptureArgs($mon,[string]$file,[bool]$shot,[int]$fps,[string]$size,[bool]$mouse,[int]$seconds,$audio = $null) {
    $in = Get-PcCaptureInput $mon $(if ($shot) { 5 } else { $fps }) $mouse
    $scale = $(switch ($size) { '1080p' { ',scale=-2:1080' } '720p' { ',scale=-2:720' } default { '' } })
    if ($shot) { $audio = $null }
    $audioIn = $(if ($audio) { "-f $($audio.Fmt) -ar $($audio.Rate) -ac $($audio.Ch) -i `"$($audio.Url)`" " } else { '' })
    $a = '-hide_banner -loglevel warning -nostats -y '
    if ($in.Kind -eq 'gdi') {
        $a += $in.Input + ' '
        if ($audio) { $a += $audioIn }
        $a += "-filter_complex `"[0:v]null$scale[v]`" -map `"[v]`" "
        if ($audio) { $a += '-map 1:a ' }
    } else {
        if ($audio) { $a += $audioIn }
        $a += "-filter_complex `"$($in.Filter)$scale[v]`" -map `"[v]`" "
        if ($audio) { $a += '-map 0:a ' }
    }
    if ($shot) { return $a + "-frames:v 1 `"$file`"" }
    $a += (Get-PcEncoderArgs) + ' '
    if ($audio) { $a += '-c:a aac -b:a 160k -ac 2 ' }
    if ($seconds -gt 0) { $a += "-t $seconds " }
    return $a + "-movflags +faststart `"$file`""
}

function Get-PcCaptureName([string]$ext) {
    $pc = $(if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName }) -replace '[^\w\-]','_'
    $name = 'PC_{0}_{1}{2}' -f $pc, (Get-Date -Format 'HHmmss'), $ext
    $dir = $null; try { $dir = Get-CaptureFolder } catch {}
    for ($n = 2; $dir -and (Test-Path -LiteralPath (Join-Path $dir $name)) -and $n -lt 100; $n++) { $name = 'PC_{0}_{1}_{2}{3}' -f $pc, (Get-Date -Format 'HHmmss'), $n, $ext }   # never reuse an existing file
    return $name
}
function Get-PcMonitorPicked {
    if ($cmbPcMonitor.SelectedIndex -lt 0 -or $cmbPcMonitor.SelectedIndex -ge $script:PcMons.Count) { Update-PcMonitorList }
    $m = $(if ($cmbPcMonitor.SelectedIndex -ge 0 -and $cmbPcMonitor.SelectedIndex -lt $script:PcMons.Count) { $script:PcMons[$cmbPcMonitor.SelectedIndex] } else { $null })
    if ($m) { try { Set-Content -LiteralPath $pcMonitorFile -Value $m.Device -Encoding UTF8 } catch {} }
    return $m
}

function Start-PcScreenshot {
    if (-not (Initialize-PcCapture)) { return }
    $mon = Get-PcMonitorPicked
    if (-not $mon) { [System.Windows.Forms.MessageBox]::Show('No monitor found.','Screenshot') | Out-Null; return }
    $file = Join-Path (Get-CaptureFolder) (Get-PcCaptureName '.png')
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { $r = Invoke-ToolOutput $script:PcCap.Ffmpeg (Get-PcCaptureArgs $mon $file $true 0 'native' $false 0) 30 }
    catch { $r = @{ Code = -1; Out = $_.Exception.Message } }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    if ($r.Code -eq 0 -and (Test-Path -LiteralPath $file)) {
        $lblPcRec.Text = "Screenshot of $($mon.Label): $file"; $lblPcRec.ForeColor = [System.Drawing.Color]::DarkGreen
        Append-UiLog "PC screenshot ($($mon.Label)): $file"
    } else {
        $last = @($r.Out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Last 1)
        $lblPcRec.Text = "Screenshot FAILED: $(if ($last.Count) { $last[0] } else { 'no file written' })"; $lblPcRec.ForeColor = [System.Drawing.Color]::DarkRed
        Append-UiLog "PC screenshot FAILED: $($r.Out)"
    }
}

function Start-PcRecording {
    if (@($script:Recs | Where-Object { $_.Platform -eq 'PC' }).Count) { [System.Windows.Forms.MessageBox]::Show('This PC is already recording - Stop recording first.','Record PC screen') | Out-Null; return }
    if (-not (Initialize-PcCapture)) { return }
    $mon = Get-PcMonitorPicked
    if (-not $mon) { [System.Windows.Forms.MessageBox]::Show('No monitor found.','Record PC screen') | Out-Null; return }
    $cap = $script:cfg.Capture

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Record PC screen'; $f.ClientSize = New-Object System.Drawing.Size(470, 292); $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $mk = { param($t, $x, $y, $w) $l = New-Object System.Windows.Forms.Label; $l.Text = $t; $l.SetBounds($x, $y, $w, 20); $f.Controls.Add($l); $l }
    [void](& $mk 'Monitor:' 12 19 140)
    $cbMon = New-Object System.Windows.Forms.ComboBox; $cbMon.DropDownStyle = 'DropDownList'; $cbMon.SetBounds(160, 16, 296, 24); $f.Controls.Add($cbMon)
    foreach ($m in $script:PcMons) { [void]$cbMon.Items.Add($m.Label) }
    $cbMon.SelectedIndex = [math]::Max(0, [math]::Min($script:PcMons.Count - 1, $cmbPcMonitor.SelectedIndex))
    [void](& $mk 'Stop after (minutes):' 12 55 140)
    $num = New-Object System.Windows.Forms.NumericUpDown; $num.SetBounds(160, 52, 70, 24); $num.Minimum = 0; $num.Maximum = 600
    $num.Value = $(if ($null -ne $cap.MaxMinutes) { [math]::Min(600, [math]::Max(0, [int]$cap.MaxMinutes)) } else { 30 }); $f.Controls.Add($num)
    $l0 = & $mk '0 = until Stop recording' 240 55 216; $l0.ForeColor = [System.Drawing.Color]::DimGray
    [void](& $mk 'Size:' 12 91 140)
    $cbSize = New-Object System.Windows.Forms.ComboBox; $cbSize.DropDownStyle = 'DropDownList'; $cbSize.SetBounds(160, 88, 100, 24); $f.Controls.Add($cbSize)
    foreach ($r in 'Native','1080p','720p') { [void]$cbSize.Items.Add($r) }
    $cbSize.SelectedItem = $(if ([string]$cap.PC.Size -and $cbSize.Items.Contains([string]$cap.PC.Size)) { [string]$cap.PC.Size } else { 'Native' })
    [void](& $mk 'Frame rate:' 12 127 140)
    $cbFps = New-Object System.Windows.Forms.ComboBox; $cbFps.DropDownStyle = 'DropDownList'; $cbFps.SetBounds(160, 124, 100, 24); $f.Controls.Add($cbFps)
    foreach ($r in '60','30') { [void]$cbFps.Items.Add($r) }
    $cbFps.SelectedItem = $(if ([string]$cap.FrameRate -eq '30') { '30' } else { '60' })
    $chkMouse = New-Object System.Windows.Forms.CheckBox; $chkMouse.Text = 'Show mouse pointer'; $chkMouse.SetBounds(276, 125, 180, 22); $chkMouse.Checked = [bool]$cap.PC.ShowMouse; $f.Controls.Add($chkMouse)
    [void](& $mk 'Sound:' 12 163 140)
    if (-not $script:PcAudioListed) { try { Update-PcAudioList $true } catch {} }
    $cbSnd = New-Object System.Windows.Forms.ComboBox; $cbSnd.DropDownStyle = 'DropDownList'; $cbSnd.SetBounds(160, 160, 296, 24); $f.Controls.Add($cbSnd)
    foreach ($it in $cmbPcAudio.Items) { [void]$cbSnd.Items.Add($it) }
    if ($cbSnd.Items.Count -eq 0) { [void]$cbSnd.Items.Add('No sound') }
    $cbSnd.SelectedIndex = [math]::Max(0, [math]::Min($cbSnd.Items.Count - 1, $cmbPcAudio.SelectedIndex))
    $ls = & $mk "Sound = everything played on that output (game, chat ...).   Encoder: $($script:PcCap.Encoder)" 12 194 446; $ls.ForeColor = [System.Drawing.Color]::DimGray
    $lf = & $mk "Saved to: $(Get-CaptureFolder)" 12 216 446; $lf.ForeColor = [System.Drawing.Color]::DimGray; $lf.AutoEllipsis = $true
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Record'; $ok.SetBounds(282, 250, 90, 30); $ok.DialogResult = 'OK'; $f.Controls.Add($ok); $f.AcceptButton = $ok
    $no = New-Object System.Windows.Forms.Button; $no.Text = 'Cancel'; $no.SetBounds(378, 250, 80, 30); $no.DialogResult = 'Cancel'; $f.Controls.Add($no); $f.CancelButton = $no
    if ($f.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $mon = $script:PcMons[$cbMon.SelectedIndex]
    $cmbPcMonitor.SelectedIndex = $cbMon.SelectedIndex
    try { Set-Content -LiteralPath $pcMonitorFile -Value $mon.Device -Encoding UTF8 } catch {}
    if ($cbSnd.SelectedIndex -ge 0 -and $cbSnd.SelectedIndex -lt $cmbPcAudio.Items.Count) { $cmbPcAudio.SelectedIndex = $cbSnd.SelectedIndex; Save-PcAudioPick }
    $sound = Get-PcAudioPicked
    $mins = [int]$num.Value
    $file = Join-Path (Get-CaptureFolder) (Get-PcCaptureName '.mp4')
    $spec = $null; $loop = $null
    if ($sound) {
        try {
            $mf = Get-PcSoundFormat $sound
            $loop = Start-PcSoundCapture $sound
            $spec = @{ Url = "tcp://127.0.0.1:$($loop.Port)"; Fmt = [string]$mf.FfmpegFormat; Rate = [int]$mf.Rate; Ch = [int]$mf.Channels }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Cannot record the sound of '$sound':`n`n$($_.Exception.Message)`n`nPick another output under Sound, or No sound.",'Record PC screen') | Out-Null
            return
        }
    }
    $argText = Get-PcCaptureArgs $mon $file $false ([int]$cbFps.SelectedItem) ([string]$cbSize.SelectedItem) $chkMouse.Checked ($mins * 60) $spec
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PcCap.Ffmpeg; $psi.Arguments = $argText
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    try { $p = [System.Diagnostics.Process]::Start($psi) } catch { if ($loop) { $loop.Stop() }; Set-CaptureRow -1 'Error' 'Record' $_.Exception.Message 'FAILED'; return }
    [void]$script:Recs.Add(@{ Index = -1; Platform = 'PC'; Name = "PC ($($mon.Label))"; IP = $env:COMPUTERNAME; Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync()
                              File = $file; Started = (Get-Date); Minutes = $mins; StopAsked = $null; Args = $argText; Stdin = $true; Loop = $loop
                              Log = (Join-Path $logDir ("Capture_{0}_PC.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))) })
    Set-CaptureRow -1 'Recording' 'Record' "0:00 -> $([System.IO.Path]::GetFileName($file))" 'Running'
    Append-UiLog ("PC record: $($mon.Label) -> $file  (" + $(if ($mins) { "stops after $mins min" } else { 'until Stop recording' }) + ", $($cbSize.SelectedItem), $($cbFps.SelectedItem) fps, $($script:PcCap.Encoder), sound: $(if ($sound) { $sound } else { 'none' }))")
    $recTimer.Start()
    Update-CaptureButtons
}

$cmbPcMonitor.Add_DropDown({ try { Update-PcMonitorList } catch {} })
$cmbPcAudio.Add_DropDown({ try { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; Update-PcAudioList $true } catch {} finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default } })
$cmbPcAudio.Add_SelectedIndexChanged({ if (-not $script:PcAudioFilling) { Save-PcAudioPick } })
$btnPcShot.Add_Click({ try { Load-Config } catch {}; try { Start-PcScreenshot } catch { [System.Windows.Forms.MessageBox]::Show("Screenshot error:`n$($_.Exception.Message)",'Screenshot') | Out-Null } })
$btnPcRec.Add_Click({ try { Load-Config } catch {}; try { Start-PcRecording } catch { [System.Windows.Forms.MessageBox]::Show("Record error:`n$($_.Exception.Message)",'Record PC screen') | Out-Null } })
$btnPcRecStop.Add_Click({ Stop-KitRecording 'PC' $false })
$btnPcCaptures.Add_Click({ try { Load-Config } catch {}; $d = Split-Path -Parent (Get-CaptureFolder); Start-Process explorer.exe -ArgumentList ('"' + $d + '"') })

$btnPcInstallBrowse.Add_Click({ $p = Select-Folder 'Install the game into which folder?' $txtPcInstallDir.Text.Trim() 'Use this folder'; if ($p) { $txtPcInstallDir.Text = $p } })
$btnPcInstallCancel.Add_Click({ [void](Stop-PcInstall $true) })
$btnPcLaunch.Add_Click({ try { Load-Config } catch {}; try { Show-PcLaunchDialog } catch { [System.Windows.Forms.MessageBox]::Show("Launch window error:`n$($_.Exception.Message)",'Launch game') | Out-Null } })

$script:LibArmed = $false   # the NAS is only touched after the first Scan click
$btnScan.Add_Click({ try { Load-Config } catch {}; $script:LibArmed = $true; Scan-Library $true })
foreach ($c in @($cmbStream, $cmbConfig)) { $c.Add_SelectedIndexChanged({ if ($script:LibArmed) { Scan-Library } }) }
$chkRmOnly.Add_CheckedChanged({ if ($script:LibArmed) { Scan-Library } })
$tabs.Add_SelectedIndexChanged({ if ($script:LibArmed) { Scan-Library } })
$cmbBuild.Add_SelectedIndexChanged({
    $i = $cmbBuild.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:LibBuilds.Count) { return }
    $b = $script:LibBuilds[$i]
    $status.Text = $(if ($b.Kind -eq 'PS5Pkg') {
        "CL $($b.Cl): " + $(if ($b.Main) { "Main #$($b.Main.Id)" } else { 'no Main' }) + $(if ($b.Dlcs.Count) { ', ' + (($b.Dlcs | ForEach-Object { "$($_.Role) #$($_.Id)" }) -join ', ') } else { '' })
    } elseif ($b.Kind -eq 'PCPkg') { "CL $($b.Cl): folders " + (($b.Entries | ForEach-Object { '#' + $_.Id }) -join ', ')
    } else { "CL $($b.Cl): $($b.Entry.Name)" })
})
$btnUseBuild.Add_Click({
    $i = $cmbBuild.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:LibBuilds.Count) { [System.Windows.Forms.MessageBox]::Show('Click Scan, then pick a build from the Build list.','Build library') | Out-Null; return }
    $b = $script:LibBuilds[$i]; $pkey = Get-ActivePlatform
    if ($pkey -eq 'PC' -and $b.Kind -eq 'Loose') { Start-PcLooseCopy $b; return }
    try {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $status.Text = 'Finding the build files...'; [System.Windows.Forms.Application]::DoEvents()
        $probs = @(Use-LibraryBuild $b $pkey)
    } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    Append-UiLog "Build library: using $pkey $($b.Label)"
    if ($pkey -ne 'PC') { Set-ConsoleLaunchType $pkey ([string]$cmbConfig.SelectedItem) }
    if ($b.Kind -eq 'PS5Pkg') {
        if ($txtMain.Text) { Append-UiLog "   Main: $($txtMain.Text)" }
        foreach ($p in $script:DlcPaths) { Append-UiLog "   DLC:  $p" }
    } elseif ($b.Kind -eq 'PCPkg') {
        foreach ($r in $gridPC.Rows) { if ([bool]$r.Cells['Use'].Value -and $r.Tag.Zip) { Append-UiLog "   $($r.Tag.Name): $($r.Cells['Path'].Value)" } }
        Append-UiLog '   Next: check the versions, then Write overrides to file'
    } else { Append-UiLog ("   Path: " + $(if ($pkey -eq 'Xbox') { $txtXbox.Text } else { $txtPS5.Text })) }
    foreach ($p in $probs) { Append-UiLog "   PROBLEM: $p" }
    $status.Text = $(if ($probs.Count) { "Build applied with $($probs.Count) problem(s) - see log" } else { "Build CL $($b.Cl) ready in the $pkey tab - tick kits and Deploy" })
    if ($probs.Count) { [System.Windows.Forms.MessageBox]::Show("Some files were not found:`n`n" + ($probs -join "`n"),'Build library',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null }
})

$btnStatus.Add_Click({
    # Pinging can wake kits that are asleep / in rest mode, so only ping what the user picked
    $targets = @(Get-SelectedIndices)
    if ($targets.Count -eq 0) {
        $pk = Get-ActivePlatform
        $all = @(Get-PlatformIndices $pk)
        $a = [System.Windows.Forms.MessageBox]::Show("No kits selected.`n`nPing ALL $($all.Count) $pk kits? Kits that are asleep or in rest mode with network wake enabled may turn on.",'Check Status',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $targets = $all
    }
    $btnStatus.Enabled = $false
    $status.Text = "Pinging $($targets.Count) console(s)..."
    $pending = @()
    foreach ($i in $targets) {
        (Get-GridRow $i).Cells['Status'].Value = 'Checking...'
        $pending += [pscustomobject]@{ Index = $i; Task = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync([string]$script:consoles[$i].IP, 1500) }
    }
    $deadline = (Get-Date).AddSeconds(10)
    while ((@($pending | Where-Object { -not $_.Task.IsCompleted }).Count -gt 0) -and ((Get-Date) -lt $deadline)) {
        [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50
    }
    $online = 0; $newMacs = 0; $noMac = 0
    $learned = Get-LearnedMacs
    foreach ($p in $pending) {
        $ok = $false
        try { $ok = ($p.Task.IsCompleted -and -not $p.Task.IsFaulted -and $p.Task.Result.Status -eq 'Success') } catch {}
        (Get-GridRow $p.Index).Cells['Status'].Value = $(if ($ok) { 'Online' } else { 'Offline / No Ping' })
        if (-not $ok) { continue }
        $online++
        $c = $script:consoles[$p.Index]
        $mac = Get-ArpMac ([string]$c.IP)
        if (-not $mac) { $noMac++; continue }
        if ($c.MAC -ne $mac) {
            $c.MAC = $mac
            $learned[[string]$c.IP] = [pscustomobject]@{ IP = $c.IP; MAC = $mac; Name = $c.Name; Platform = $c.Platform; LearnedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
            $newMacs++
            Append-UiLog ("MAC learned: {0} ({1}) {2} -> {3}" -f $c.Name, $c.Platform, $c.IP, ($mac -replace '(..)(?!$)','$1-'))
        }
    }
    if ($newMacs -gt 0) {
        try { $learned.Values | Sort-Object Platform, Name | Export-Csv -LiteralPath $learnedMacPath -NoTypeInformation -Encoding UTF8 }
        catch { Append-UiLog "Could not save Learned_MACs.csv: $($_.Exception.Message)" }
    }
    if ($noMac -gt 0 -and $newMacs -eq 0) {
        Append-UiLog "No MAC found for $noMac online kit(s) - this PC is probably on a different subnet from them, so Wake-on-LAN is unavailable; Power On will use directed pings."
    }
    $btnStatus.Enabled = $true
    $status.Text = "Status check complete: $online of $($pending.Count) online" + $(if ($newMacs -gt 0) { " | $newMacs MAC(s) learned for Power On" } else { '' })
})

$btnPreview.Add_Click({
    try { Load-Config } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Config error') | Out-Null; return }
    $indices = Get-SelectedIndices
    if ($indices.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select one or more consoles to preview.','HYD Build Deploy') | Out-Null; return }
    Append-UiLog '---- Command preview (nothing executed) ----'
    foreach ($i in $indices) {
        $c = $script:consoles[$i]
        try {
            $plan = New-DeployPlan $c $i
            Append-UiLog ("{0} [{1} {2}] {3} build" -f $c.Name, $plan.Platform, $c.IP, $plan.Mode)
            foreach ($s in $plan.Steps) {
                if ($s.Type -eq 'Wait') { Append-UiLog "    (wait for kit to come back online)" }
                else { Append-UiLog ('    "{0}" {1}' -f $s.Exe, $s.Args) }
            }
            foreach ($w in (Get-BuildWarnings $plan.Platform $plan.BuildPath)) { Append-UiLog "    WARNING: $w" }
        } catch { Append-UiLog ("{0}: CANNOT RUN - {1}" -f $c.Name, $_.Exception.Message) }
    }
})

$btnDeploySel.Add_Click({ Start-Deploy (Get-SelectedIndices) })
$btnDeployIdle.Add_Click({
    $indices = @()
    foreach ($i in (Get-PlatformIndices (Get-ActivePlatform))) {
        $c = $script:consoles[$i]
        if ((([string]$c.Enabled).ToLowerInvariant() -eq 'true') -and (([string]$c.Idle).ToLowerInvariant() -eq 'true')) { $indices += $i }
    }
    if ($indices.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No $(Get-ActivePlatform) consoles are marked Enabled=true and Idle=true.`n`nAdd an Idle column to the console list and set it to true for shared/free kits.",'HYD Build Deploy') | Out-Null
        return
    }
    Start-Deploy $indices
})
$btnCancel.Add_Click({ Stop-Deploy })
$btnPowerOn.Add_Click({ Start-Power (Get-SelectedIndices) 'Power On' })
$btnPowerOff.Add_Click({ Start-Power (Get-SelectedIndices) 'Power Off' })
$btnRestart.Add_Click({ Start-Power (Get-SelectedIndices) 'Restart' })
$btnAoOn.Add_Click({ Start-AlwaysOn (Get-SelectedIndices) 'AlwaysOn On' })
$btnAoOff.Add_Click({ Start-AlwaysOn (Get-SelectedIndices) 'AlwaysOn Off' })
$btnAoRead.Add_Click({ Start-AlwaysOn (Get-SelectedIndices) 'AlwaysOn Read' })
$btnTmSync.Add_Click({ try { Load-Config; Start-TargetManagerSync $true } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Config error') | Out-Null } })

$btnSelectAll.Add_Click({
    $g = Get-ActiveGrid; $n = 0; [void]$g.EndEdit()
    $script:BulkTick = $true
    try { foreach ($row in $g.Rows) { if ($row.Visible) { $row.Cells['Sel'].Value = $true; $n++ } } } finally { $script:BulkTick = $false }
    Update-TabTitles; $status.Text = "Ticked $n shown $(Get-ActivePlatform) console(s)"
})
$btnClearSel.Add_Click({
    $g = Get-ActiveGrid; [void]$g.EndEdit()
    $script:BulkTick = $true
    try { foreach ($row in $g.Rows) { $row.Cells['Sel'].Value = $false } } finally { $script:BulkTick = $false }
    Update-TabTitles; $status.Text = 'All ticks cleared in this tab'
})

$btnOpenCsv.Add_Click({
    $p = Get-ConsoleListPath
    if (-not (Test-Path -LiteralPath $p)) { return }
    if ($p -match '\.csv$') { Start-Process notepad.exe -ArgumentList ('"' + $p + '"') } else { Start-Process -FilePath $p }
})
# ---- Find = filter. Hidden rows keep their ticks; buttons act on every ticked kit in the tab.
function Test-ConsoleMatch($c, [string]$q) {
    if (-not $q) { return $true }
    foreach ($v in @($c.Name, $c.IP, $c.Notes)) { if (([string]$v).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }
    return $false
}
function Apply-Filter {
    $q = $txtFind.Text.Trim()
    $shown = @{}
    foreach ($pk in 'Xbox','PS5') {
        $g = Get-GridFor $pk
        $g.CurrentCell = $null
        $n = 0
        foreach ($i in (Get-PlatformIndices $pk)) {
            $m = Test-ConsoleMatch $script:consoles[$i] $q
            $r = Get-GridRow $i
            if ($r.Visible -ne $m) { $r.Visible = $m }
            if ($m) { $n++ }
        }
        $shown[$pk] = $n
    }
    # nothing here but something on the other tab -> show that tab
    $act = Get-ActivePlatform; $other = $(if ($act -eq 'PS5') { 'Xbox' } else { 'PS5' })
    if ($q -and $shown[$act] -eq 0 -and $shown[$other] -gt 0) { $tabs.SelectedTab = $(if ($other -eq 'PS5') { $tabPS5 } else { $tabXbox }) }
    Update-TabTitles
    $status.Text = $(if ($q) { "Filter '$q': $($shown['Xbox']) Xbox, $($shown['PS5']) PS5 shown" } else { 'Filter cleared - all consoles shown' })
}
function Update-TabTitles {
    foreach ($pk in 'Xbox','PS5') {
        $g = Get-GridFor $pk
        $all = $g.Rows.Count; $shown = 0; $ticked = 0; $hiddenTicked = 0
        foreach ($r in $g.Rows) {
            if ($r.Visible) { $shown++ }
            if ([bool]$r.Cells['Sel'].Value) { $ticked++; if (-not $r.Visible) { $hiddenTicked++ } }
        }
        $count = $(if ($shown -ne $all) { "$shown of $all" } else { "$all" })
        $tick = $(if ($ticked) { ", $ticked ticked" + $(if ($hiddenTicked) { " ($hiddenTicked hidden)" } else { '' }) } else { '' })
        $name = $(if ($pk -eq 'PS5') { 'PS5' } else { 'Xbox Series X|S' })
        $tp = $(if ($pk -eq 'PS5') { $tabPS5 } else { $tabXbox })
        $tp.Text = "  $name ($count$tick)  "
    }
}
$filterTimer = New-Object System.Windows.Forms.Timer
$filterTimer.Interval = 300
$filterTimer.Add_Tick({ $filterTimer.Stop(); Apply-Filter })
$txtFind.Add_TextChanged({ $filterTimer.Stop(); $filterTimer.Start() })
$txtFind.Add_KeyDown({ param($sender,$e) if ($e.KeyCode -eq 'Enter') { $filterTimer.Stop(); Apply-Filter; $e.SuppressKeyPress = $true } elseif ($e.KeyCode -eq 'Escape') { $txtFind.Text = ''; $e.SuppressKeyPress = $true } })
$btnFind.Add_Click({ $txtFind.Text = ''; $filterTimer.Stop(); Apply-Filter })
$btnOpenCfg.Add_Click({ if (Test-Path $configPath) { Start-Process notepad.exe -ArgumentList ('"' + $configPath + '"') } })
$btnOpenLogs.Add_Click({ Start-Process explorer.exe -ArgumentList ('"' + $logDir + '"') })
$btnReload.Add_Click({ try { Reload-All } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Load error') | Out-Null } })
$btnClose.Add_Click({ $form.Close() })

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:PcInstall) {
        $a = [System.Windows.Forms.MessageBox]::Show("The PC install is still running. Cancel it and exit?",'Exit',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
        [void](Stop-PcInstall $false)
    }
    if ($script:PcCopy -and -not $script:PcCopy.St.Finished) {
        $a = [System.Windows.Forms.MessageBox]::Show("A build copy is still running. Stop it and exit?`n`nCopying to the same folder again later resumes it.",'Exit',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
        [void](Stop-PcCopy $false)
    }
    $live = @($script:Recs)
    if ($live.Count) {
        $a = [System.Windows.Forms.MessageBox]::Show("$($live.Count) recording(s) are still running. Stop them and exit?`n`nWhat was recorded so far is kept.",'Exit',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
        Stop-KitRecording '' $true
        $until = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $until -and @($live | Where-Object { -not $_.Proc.HasExited }).Count) {
            foreach ($r in @($live | Where-Object { $_.StopEvent -and -not $_.EventSent -and -not $_.Proc.HasExited })) { [void](Send-StopEvent $r) }
            Start-Sleep -Milliseconds 300; [System.Windows.Forms.Application]::DoEvents()
        }
        foreach ($r in $live) { try { if (-not $r.Proc.HasExited) { $r.Proc.Kill(); [void]$r.Proc.WaitForExit(3000) } } catch {} }
    }
    $sync.TmCancel = $true
    if ($script:CacheRun -and -not $script:CacheRun.St.Finished) {
        $a = [System.Windows.Forms.MessageBox]::Show("The build is still being cached for a deploy. Stop and exit?`n`nNo kit has been touched yet.",'Exit',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
        Stop-CacheRun
    }
    if ($script:Jobs.Count -gt 0) {
        $a = [System.Windows.Forms.MessageBox]::Show("Operations are still running. Exit anyway?`n`nRunning deploy tools will be stopped and kits left with partial builds.",'Exit',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
        $sync.Cancel = $true
        foreach ($key in @($sync.Rows.Keys)) {
            $p = $sync.Rows[$key].Proc
            if ($p -and -not $p.HasExited) { try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch {} }
        }
    }
})

try { Reload-All } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Startup error') | Out-Null }
[void]$form.ShowDialog()
