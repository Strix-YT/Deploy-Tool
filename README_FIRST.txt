HYD PS5 + Xbox Build Deploy GUI v4.16.2

START
1. Extract the ZIP to a local folder (not a network share).
2. Double-click START_HYD_BUILD_DEPLOY.cmd (no console window - only the tool opens).
   If it does not start, an error box says why. For full details double-click
   START_HYD_BUILD_DEPLOY_debug.cmd instead - it keeps the console window open.
3. Pick the Xbox, PS5 or PC tab.
4. Pick a build: Branch + Config at the top -> Scan -> pick the CL -> Use This Build.
   (Or Xbox: Folder... / Package...; PS5: Main Browse / Add DLC(s) / loose Browse.)
5. Tick ONE known-good kit, tick "Dry run", click Preview Commands, then Deploy Selected.
6. Untick Dry run and do a real deploy to that one kit before using multiple kits.
See VERSION HISTORY at the end of this file for what changed in each version.

BUILD LIBRARY (top strip) - pick builds from the NAS instead of typing paths
  Builds live in  \\eahy-nas01.ad.ea.com\BF\<Branch>\<Config>\<Platform>\
     Branch:   CH1-Content Dev, CH1-QOL, CH1-Release, CH1-Stage
     Config:   Combine Retail (packages), Files Final / Files Performance (loose)
     Platform: XBSX or PS5 - taken from the tab you are on
  1. Open the Xbox or PS5 tab, pick Branch and Config, click Scan.
  2. The Build list shows the newest builds first, by CL, e.g.
        CL 29715907-29672681    RM Main + 4 DLC    #14759269    05 Oct 14:20
  3. Pick one and click Use This Build. The tab is filled in for you:
        PS5 Combine Retail -> Main = RM Main .pkg, DLC list = RM DLC1..DLC4 .pkg (from their
                              own folders; the "remastered" .pkg is used when a folder has two)
        Xbox Combine Retail -> the .xvc package
        Files Final / Performance -> the loose folder (where eboot.bin / MicrosoftGame.config is)
  How builds are recognised:
     - the build number is the start of the folder name (14759150)
     - the CL is the "digits-digits" group at the end of the folder name or of the matching
       .txt file (beside the folder or inside it), e.g. 29715907-29672681
     - PS5 packages: the name ends with "RM Main" / "RM DLC1" ... ; folders with the same CL
       are grouped into one build. If a part was rebuilt, the newest folder is used.
  RM only (ticked by default): PS5 package list shows only RM builds. Untick to see the others.
  After the first Scan, changing Branch / Config / tab / RM only re-scans automatically.
  The NAS is not touched until you click Scan. Settings: BuildLibrary in DeployConfig.json
  (root, branch list, config list, which configs are packages, MaxBuilds).

WINDOW LAYOUT
  Top:     Build library - Branch / Config / Build / Scan / Use This Build / RM only
  Tabs:    "PC (EA app)"     - EA app override.cfg for the PC main game + DLC (see PC TAB)
           "Xbox Series X|S" - Xbox build, Xbox kits, AlwaysOn On/Off/Read
           "PS5"             - Install packages / Deploy loose folder switch, Packages box
                               (Main + DLC list), Loose build box (folder + workspace),
                               Connect before deploy, Add PS5 kits to Target Manager, PS5 kits
  Bottom:  deploy options, Check / Preview / Deploy / Power buttons, Filter, log.
           These ALWAYS act on the TICKED kits in the tab you are looking at.

PC TAB - EA APP OVERRIDES (this PC only, no kits)
  Installs a PC Combine Retail build through the EA app by writing download overrides to
     C:\EADesktopDev\override.cfg      (PC.OverrideFile in DeployConfig.json)
  The table has one row per offer:
     Main game  BattlefieldGameData.zip      SAN1 (Single Player)  BF6_SAN1_DLC.zip
     SAN1+SAN2 (MP / SP)  BF6_SAN1_SAN2_DLC.zip  SAN2 (Multiplayer)  BF6_SAN2_DLC.zip
     MARKER (REDSEC) (OFR.50.0005605)  BF6_MARKER_DLC.zip     Offer 0005756  (no download: version + up-to-date only)
  1. PC tab -> Branch + Combine Retail -> Scan -> pick the CL -> Use This Build.
     Every zip is found in its numbered folder and the full path (incl. .zip) is filled in.
     Offers whose zip is not in that build are unticked. You can also use ... per row.
  2. Check the Server version column, then Write overrides to file.
     Each ticked offer gets:  OverrideDownloadPath=file:<full path to .zip>
                              ServerVersionOverride=<version>
                              OverrideUpToDateStatus=1
                              overrideUpToDateAfterInstall=1
     Only these offers' qa.Origin.OFR lines are replaced; every other line is kept.
     A backup (override.cfg.bak_<date>) is saved next to the file first.
  3. Restart EA app (button) so it reads the file.
  Remove overrides (default) takes the offer lines out again.
  "In file now" shows what the file currently sets; Re-read file refreshes it.
  The file: prefix can be changed with PC.DownloadPathPrefix ("" = no prefix).
  Offers, zip names and versions live in PC.Offers in DeployConfig.json.
  The deploy / power / tick buttons at the bottom do nothing on this tab.

  PC LOOSE BUILDS (Files Final / Files Performance) - COPY TO THIS PC
  PC tab -> Branch + Files Final (or Files Performance) -> Scan -> pick the CL -> Use This Build.
  The tool asks which folder to copy into (it remembers the last one) and creates
  <that folder>\<build number>, e.g. D:\Builds\14759150. The CL .txt file is copied beside it.
  Before starting it shows the size, checks free disk space and asks to confirm.
  The copy runs in the background with robocopy (16 files at a time, retries on network
  drops); the "Loose build copy" line shows %, speed and time left. Cancel copy keeps what
  is copied. Copying to the same folder again RESUMES - finished files are skipped and
  nothing on the PC is ever deleted. Full robocopy log: logs\PcCopy_<time>_<build>.log
  When the copy finishes: Yes = open Launch game on that build, No = open the folder.
  Every finished copy is remembered (PcBuilds.json) so Launch game can offer it.

  CONTENT TO INSTALL (row above the table) - matches the EA app's install dialog
     Base Game (required)          -> OFR.50.0005511  BattlefieldGameData.zip
     Battlefield 6 Multiplayer     -> SAN2 (0005606)  + SAN1+SAN2 (0005607)
     Battlefield 6 Single Player   -> SAN1 (0005608)  + SAN1+SAN2 (0005607)
     Battlefield REDSEC            -> MARKER (0005605)
     HD Textures items             -> no NAS build: always leave them unticked in the EA app
  Ticking content ticks the offers it needs (SAN1+SAN2 is needed if MP or SP is ticked).
  Writing is blocked if a selected item's zip is missing from the build. The line under the
  row says OK, or what is missing. Mapping lives in PC.Content in DeployConfig.json.
  The ticked content also decides which ZIPs Install game (direct) extracts.
  "Install checklist" shows what to tick if you ever install through the EA app by hand.

  INSTALL / UNINSTALL (second button row on the PC tab)
  Install game (direct) - installs WITHOUT the EA app downloading anything:
       1. checks every ticked content item has its ZIP (Use This Build fills them in)
       2. shows the ZIPs, the size after extraction and the free space, and asks to confirm
       3. ONE Windows administrator prompt (Program Files and HKLM need it), then in the
          background: empties the install folder (clean install), extracts the ZIPs - main
          game first, then each DLC - runs __Installer\Touchup.exe if the build has one, and
          writes the registry keys that mark the game as installed:
             HKLM\SOFTWARE\Electronic Arts\EA Games\Battlefield                [Install Dir]
             HKLM\SOFTWARE\WOW6432Node\Electronic Arts\EA Games\Battlefield   [Install Dir]
             HKLM\SOFTWARE\WOW6432Node\Electronic Arts\EA Games\Battlefield 6 [Install Dir]
             HKLM\SOFTWARE\WOW6432Node\Origin Games\16426154                   [InstallDir] [Installed]=true
       4. writes the overrides (same as Write overrides to file) and offers to restart the EA app.
       Install folder row on the PC tab (default C:\Program Files\EA Games\Battlefield 6,
       PC.DirectInstall.InstallDir). Progress, % and speed show next to it; Cancel install stops.
       ZIPs are read and extracted with Windows' own tar.exe (Windows 10 1803 or later), and
       every extracted file is checked against the size the ZIP lists before Touchup runs.
       A Touchup.exe problem is a warning (files and registry are still done).
       Log of each install: logs\PcInstall_<time>.log.  Needs HYD_PC_DirectInstall.ps1 in the
       tool folder. Touchup arguments and registry keys are in PC.DirectInstall in the config.
  Launch game... - starts the game with launch parameters. ONE PROFILE PER BUILD TYPE:
       Build type      Combine Retail / Files Final / Files Performance. Starts on the type
                       picked in the header's Config, else the last one launched.
       Build folder    Combine Retail = the install folder on this tab.
                       Files Final / Performance = the builds this tool copied for that type,
                       newest first (the newest copy is picked automatically when it is newer
                       than your last launch), plus older folders in the last copy folder.
                       The grey line under it shows the CL / build number / branch.
       Game exe        found in the build folder (bf6.exe, bf.exe, Battlefield6.exe,
                       Battlefield.exe, Game.exe first, then the biggest exe; Touchup, crash
                       reporters, installers etc. are skipped). Pick another or Browse.
       Launch parameters   free text, one per line is fine (lines are joined with spaces,
                       lines starting with # are skipped). Filled in for you:
                         {Folder} build folder   {Exe} game exe   {Type} build type
                         {Cl} / {BuildId} CL and build number of a copied/installed build
       Preset          named parameter sets per type, e.g. "Perf capture", "Windowed MP".
                       Save as preset... / Delete preset. Picking one fills the parameters.
       Config default  puts back the type's default parameters from DeployConfig.json.
       Command line    shows exactly what will run.
       Each type remembers its own folder, exe and parameters when you click Launch
       (PcLaunch.json; Cancel forgets changes, presets are saved straight away). If the game
       is already running it asks: close it and launch again / launch another copy / cancel.
       Default parameters, exe names and the types themselves: PC.Launch in DeployConfig.json
       (Folder "Install" or "Copied"). Note: if a retail exe hands over to the EA app to start,
       parameters may not reach the game - loose builds start directly.
  Open in EA app (small button) - opens  origin://launchgame/16426154  (PC.InstallUri, PC.TitleId).
       This LAUNCHES an installed game; it does not start an install by itself. If the game is
       not installed the EA app says "Game not installed" - click GET THE GAME to reach the
       install dialog, then tick items as the checklist window says. Warns if overrides are
       missing. Restart the EA app first if it was open before you wrote the overrides.
  Find installed game - looks in Windows' installed programs for a name matching
       PC.GameNamePattern ("Battlefield") and shows its version and folder.
  Uninstall (Windows entry) - runs that entry's own uninstall: msiexec /x {code} /qn for MSI
       installs, else its quiet uninstaller, else its normal uninstaller. Windows asks for
       admin rights if needed.
  Delete game files (fast) - closes EADesktop + EABackgroundService, then deletes the game's
       install folder (from the Windows entry, else PC.GameFolder, else you pick it). Asks twice.
       Optional: also clears %LOCALAPPDATA%\Electronic Arts\EA Desktop\cache.
       Never deletes drive roots, the NAS, Program Files, EA Games itself or user folders.

TICKING KITS
  Every row has a tick box. Click a row (or its box) to tick / untick it.
  Shift-click ticks every shown row between your last click and this one. Space ticks the
  highlighted row. Ticked rows are tinted green.
  Select All ticks every row currently SHOWN. Clear Selection unticks everything in the tab.
  The tab title shows the count, e.g.  PS5 (3 of 83, 2 ticked).

FILTER
  Type in Filter: the list shows only kits whose name, IP or notes contain the text.
  Clear Filter (or Esc) shows everything again. If nothing matches on the visible tab but
  something does on the other one, the tool switches tabs.
  Ticks are kept while filtering, so you can filter "leela", tick, filter "rugved", tick,
  then deploy to both. Hidden ticked kits are still deployed to - the tab title says
  "(1 hidden)" and the confirm dialog says how many targets are hidden by the filter.

PS5 OWNERSHIP
  Only one PC can control a PS5 kit. If another PC owns it, Connect fails with
  "another host has ownership" and the kit is not touched.
  "Take ownership if needed (asks first)" (PS5 tab, off by default): the tool still tries
  a normal connect first. Only if another PC owns the kit, it reads who owns it
  (target info) and asks you:
     "Are you sure you want to disconnect <owner> and connect this PC to the console?"
  Yes = target connect /force, then the deploy continues.  No = that kit stops, the
  others carry on. While it waits, the kit shows "Waiting for you". No answer within
  15 minutes counts as No. Several owned kits are asked one after another. The other PC loses control of the kit - only use it on kits you are
  allowed to take. Offline kits are never forced. The confirm dialog warns when it is on.

PS5 PACKAGE BUILDS - MAIN + DLC (each file can be in a different folder)
  Top of the PS5 tab:  (o) Install packages   ( ) Deploy loose folder
  It switches by itself when you use the Packages box or the Loose build box.
  Packages box:
    Main  - Browse... picks the game package (one file). Clear empties it.
            Empty Main = install DLC onto a game that is already on the kit.
            If the file is named like DLC (CONTENTPACK..., DLC...), the tool asks whether
            you meant to add it as DLC instead.
    DLC   - Add DLC(s)... picks one or more .pkg files (Ctrl / Shift-click to select several).
            Click it again to add DLC from another folder. Remove / Delete key removes the
            selected rows, Clear empties the list. You can also drag .pkg files onto the
            Main box or the DLC list.
    Duplicates and the main package are not added twice (the log says what was skipped).
  The line under the boxes says exactly what will install. Orange = warning (e.g. a DLC
  for a different Title ID than the main package). Red = error (file not found).
  Install order: main, then each DLC in list order. If the main fails the kit stops (FAILED).
  If a DLC fails the other DLC still install and the kit shows PARTIAL (yellow), naming it.
  "Uninstall existing first" is blocked for DLC-only installs (it would remove the game).

BUILD CACHE (deploying to many kits at once)
  Kits cannot read the NAS, so every deploy streams the build NAS -> this PC -> kit. With many
  kits that pulls the same build from the NAS again for every kit.
  When MORE THAN 5 kits are ticked (Cache.WhenMoreThanKits), the tool first copies the build
  from the NAS to this PC ONCE, then deploys every kit from the local copy:
     Xbox package or loose folder, PS5 main + DLC packages, PS5 loose folder.
  The confirm dialog says when this happens, the size, and where it goes. Every kit shows
  "Caching build on this PC: 42%..." and the deploy starts by itself when the copy is done.
  Cancel Running during caching stops it - no kit is touched.
  Where: HYDBuildCache on the local drive with the most free space (Cache.Folder).
  Not enough space -> it asks whether to deploy straight from the NAS instead.
  Deploying the same build again later re-uses the cache (only changed files are copied).
  The last 2 builds are kept (Cache.KeepBuilds); older ones are deleted automatically.
  Clear Cache (bottom row) empties it. Turn the feature off with Cache.Enabled = false.
  Log of each cache copy: logs\Cache_<run>.log

WHAT A DEPLOY DOES (per console, in this order)
  Reboot (optional) -> wait until it pings again + settle time
  PS5 connect (optional, NOT forced - will not kick another owner)
  Uninstall existing (optional, failures are ignored)
  Deploy loose folder  OR  install package (chosen automatically from the path)
  Launch (optional)
Kits run in parallel up to the "Parallel" value. Lower it if the network chokes.
"Stagger (s)" spaces out the INSTALL step: each kit waits until that many seconds have passed
since the previous kit started installing (reboots still happen together). 0 = no stagger.

PROGRESS column: "elapsed | last line the tool printed". Some tools (e.g. workspace push)
  print nothing until they finish - the clock still runs so you can see it is alive.

BUTTONS
  Check Selected    - pings only the selected kits. Pinging can WAKE kits that are asleep or
                      in rest mode, so avoid pinging the whole floor (it asks first if nothing
                      is selected).
  Preview Commands  - shows the exact command lines for the selected kits, runs nothing
  Deploy Selected   - deploys to the ticked rows
  Deploy All Idle   - deploys to rows where Enabled=true AND Idle=true
  Cancel Running    - stops all running deploys (kits mid-copy need a redeploy)
  Clear Cache       - deletes the local build cache (see BUILD CACHE)

CONFIG (DeployConfig.json - Open Config button)
  Every command is a template, so SDK syntax changes never need a code change.
  Placeholders: {IP} {Name} {BuildPath} + anything under that platform's "Values".
  Empty "Exe" = step disabled.
  Xbox Launch needs Values.LaunchId (AUMID, e.g. Name_publisherhash!AppId).
  Xbox Uninstall needs Values.PackageFamilyName.

  WHAT GETS DEPLOYED (picked automatically from the path you choose)
     Package file (.pkg / .xvc / .msixvc)        -> package install
     Folder with exactly one package inside      -> that package (label shows "Package (in folder)")
     Xbox folder with MicrosoftGame.config       -> loose: xbapp deploy
     PS5 folder with eboot.bin + a .gp5 file     -> loose: workspace deploy <ws> <file.gp5>
     PS5 folder with eboot.bin, no .gp5          -> loose: workspace push <ws> <folder> / /diff:QUICK /sync
       (repeat deploys only copy files that changed; /sync removes files deleted from the build)
     Anything else stops with a message saying what is wrong with the folder.

  IDs are read from the build - nothing to type in:
     PS5  Title ID / Content ID: package file name or sce_sys\param.json
     PS5  workspace name: "PS5 workspace" box in the app, default "playtest".
          Every name gets the prefix "sce_nolimit " (with a space; PS5.WorkspacePrefix in the
          config), so "playtest" is "sce_nolimit playtest" on the kit. The app shows the final
          name. Type the name WITHOUT spaces - the tool adds the prefix.
          Placeholders: {TitleId} {Build} {Stream} {Config} {Name}, e.g. bf_{Stream}_{Build}
          Before a loose deploy the tool checks the kit (workspace info):
            exists     -> logged, deploys INTO it (only changed files copied, extra files removed)
            not found  -> creates it, then deploys
          Changing the name starts a new workspace (full copy); the old one stays on the kit
          until you delete it (tick "Uninstall existing first" with the old name).
     Xbox Package Family Name: package file name, or MicrosoftGame.config for loose builds
     Xbox launch ID: MicrosoftGame.config for loose builds. PACKAGE builds don't carry it, so
          before launching the tool asks the kit (xbapp list) and takes the app of that package.
          With no build picked it takes the ONE installed app matching Xbox.Launch.FindApp
          ("glacier|battlefield") and stops if several match. Setting Xbox.Values.LaunchId
          (PackageFamilyName!AppId) skips the lookup.

  "Uninstall existing first": PS5 package -> package uninstall; PS5 loose -> workspace destroy;
     Xbox -> xbapp uninstall.

  !! PS5 LOOSE IS NEW - test on one kit first. The commands come straight from the
     prospero-ctrl 13.0 help, but have not been run on a kit yet. If "Launch after deploy"
     does not start a workspace build, change PS5.Steps.LaunchWorkspace in DeployConfig.json
     (e.g. add /workspaceOverlay:{Workspace} when a base package is installed).

  Xbox commands use the public GDK xbapp syntax (deploy / install / launch / uninstall).
  Confirm with a dry run on a single kit first.

LAUNCH GAME ON XBOX / PS5 (Launch game... button at the bottom of each console tab)
  Same idea as the PC Launch game window: ONE SET OF LAUNCH PARAMETERS PER BUILD TYPE
  (Combine Retail / Files Final / Files Performance), separate for Xbox and PS5.
  The grey line next to the button shows the build type and parameters in use, e.g.
     Build type: Files Final   Parameters: -windowed -name {Name}
  The window:
     Launch ID      Xbox: the app to start (AUMID, e.g. EA.Glacier_xxxxxxxxxxxxx!Game) - the
                    same "launch title ID" you typed in XBDEPLOY. Find on kit asks the first
                    ticked kit (xbapp list) and fills the list, Battlefield apps first.
                    Empty = from the loose build, else looked up on each kit at launch.
                    PS5: Title ID. Typed = always starts with prospero-run and that ID.
                    Empty = automatic - the line under the box says which ID that is and
                    where it comes from (picked package / loose build, else PS5.Launch.TitleId
                    = PPSA19534). The drop-down offers the known IDs.
                    Remembered per build type.
     Build type     which type's parameters to use. Use This Build sets it from the header's
                    Config automatically (pick a Files Performance build -> Files Performance
                    parameters), so normally you never change it by hand.
     Preset         named parameter sets per type - Save as preset... / Delete preset.
     Launch parameters   one per line is fine (joined with spaces; # lines are skipped).
                    Filled in per kit: {Name} {IP} {Type} {TitleId} {LaunchId} {Workspace}
                    {BuildPath} and any other value of that platform in the config.
     Config default puts back the type's default from DeployConfig.json.
     Command line   the exact command for the first ticked kit.
     Launch on N ticked kit(s)  launches now on the ticked kits of that tab (asks first;
                    PS5 connects first when "Connect before deploy" is ticked). The kits'
                    Status shows Launched / FAILED; log: logs\Launch_<time>_<kit>_<platform>.log
     Close game on N kit(s)  xbapp terminate on the ticked kits (same as XBDEPLOY's Kill).
                    PS5 (as in BF Deploy): prospero-ctrl application kill <Title ID typed
                    here>, or - when empty - whatever "application list" shows running
                    (its TitleId, else its Name). Nothing running = "Nothing running" (OK).
     Save (for Launch after deploy)  just remembers the type + parameters + ID.
  Each kit is pinged first (no reply = Offline, nothing sent). Xbox (like XBDEPLOY): the
  parameters reach xbapp as ONE argument, quoted when they contain spaces
  (Xbox.Launch.QuoteArgs). PS5: "/args" then each parameter as its own argument. Failures say why: game not installed,
  already running, network error, not paired, access denied, invalid install state.
  "Launch after deploy" uses the same type + parameters; the Confirm Deploy box shows them.
  What to launch: Xbox - the launch ID from a loose build, else it is looked up on each kit
  with xbapp list (the picked package's app, or the one Battlefield app installed when no
  build is picked; the command line shows <game found on the kit>). PS5 - the Title ID of
  the build picked on the tab, or PS5.Values.TitleId in the config.
  Where the parameters go: {LaunchArgs} in Steps.Launch / LaunchWorkspace (PS5). Xbox:
     xbapp launch /X:<ip> <launch ID> <parameters>
  PS5 (from the SDK help):
     launch:      prospero-ctrl application start <TitleId> /target:<ip> /args <parameters>
                  /args is only added when there are parameters, and is always last. Each
                  word is its own argument to the game - put quotes around a value that has
                  spaces, e.g.  -level "MP Test".
     WHICH BUILD STARTS IS DECIDED BY THE BUILD TYPE (PS5.Launch.Profiles "From"):
       Combine Retail      -> the installed package (Steps.Launch)
       Files Final / Perf  -> the build in a workspace on the kit (Steps.LaunchWorkspace):
                  application start <TitleId> "/workspaceOverlay:<workspace>" ...
     WORKSPACE NAME (Workspace row in the PS5 Launch game window):
       empty  = read from each kit right before launching (prospero-ctrl workspace list):
                the PS5 tab's name (e.g. "sce_nolimit playtest") if the kit has it, else the
                kit's only sce_nolimit workspace. Several and none matching -> that kit stops
                and lists them.
       Find on kit = lists the workspaces on the first ticked kit to pick from.
       typed / picked = used on every kit; remembered per build type.
     Launch after deploy starts what was just deployed (loose -> workspace, package -> package).
     close game:  prospero-ctrl application kill <TitleId> /target:<ip>
  With no parameters the commands are exactly as before.
  Defaults per type: Xbox.Launch.Profiles / PS5.Launch.Profiles in DeployConfig.json.
  Remembered in XboxLaunch.json / PS5Launch.json (Cancel forgets changes; presets are saved
  straight away).

SCREENSHOTS AND VIDEO (bottom row of the Xbox and PS5 tabs - acts on the ticked kits)
  Uses the SDKs' own capture: Xbox = xbcapture (screenshot, Save last) and the GDK live capture
  (Record), PS5 = prospero-ctrl target screenshot / video.
  The picture comes over the network, no capture card needed. Files go to
     Captures\<date>\<kit>_<time>.png / .mp4   (Capture.Folder in the config to move it)
  Screenshot      one .png per ticked kit.
  Save last 90 s  (Xbox) saves the LAST 90 seconds of gameplay, like the console's "record that"
                  - press it right after a bug. Length: Capture.Xbox.ClipSeconds (6-300).
                  Needs a game running on the kit.
  Record...       asks: stop after N minutes (0 = until Stop recording; Xbox 6 h at most),
                  and on PS5 resolution 720p-2160p and 30/60 fps (Xbox records at the kit's
                  own settings). Each kit records in the background; its row shows Recording,
                  the time and the file size. You can keep deploying meanwhile.
  Stop recording  stops the recordings of the ticked kits (no kits ticked = all on that tab).
                  Xbox: records with the GDK's own live capture - the same as Xbox Manager's red
                  RECORD button (needs HYD_XboxRecord.ps1 in the tool folder and the GDK in
                  Xbox.ToolDir). Stop recording tells it to stop and it FINISHES the .mp4 itself:
                  plays everywhere, full sound. If the tool is closed mid-recording, the
                  recording is stopped the same clean way.
                  PS5: Ctrl+C, the same as pressing Ctrl+C in the tool's window (needs
                  HYD_CtrlC.ps1 in the tool folder). PS5 keeps the video recorded so far.
                  Anything still running 20 s later (Xbox: 35 s) is stopped hard.
  Captures        opens the captures folder.
  Results: SAVED (file written), FAILED (with the tool's message), CHECK FILE (the recording was
           stopped hard before the file was finished - it will not play).
  PS5 streams about 10 Mbit/s per kit by default; Capture.PS5.VideoOptions can add
  /bandwidth:<kbps>, /no-connect (do not take ownership while recording) or
  /force-stop-stream. Xbox: Capture.Xbox.ScreenshotOptions /G = game image only, /H = HDR.
  Closing the tool stops recordings first.

PC SCREEN CAPTURE (PC tab, "Screen capture:" row - records THIS PC's screen)
  Needs ffmpeg 6.0 or newer (free). One-time setup:
     1. Download a Windows build: https://www.gyan.dev/ffmpeg/builds/ ("ffmpeg-release-essentials.zip")
        or https://github.com/BtbN/FFmpeg-Builds/releases ("ffmpeg-master-latest-win64-gpl.zip").
     2. Copy bin\ffmpeg.exe into this tool's folder (or a folder "ffmpeg\bin" next to it),
        or set Capture.PC.Ffmpeg in DeployConfig.json to its full path. On PATH also works.
  Monitor list   all screens, numbered like Windows Display settings ("Display 2 - 1920x1080
                 144 Hz"). The pick is remembered. Not sure which is which? Take a Screenshot.
                 Plugged a monitor in or out: Reload List + Config refreshes the list.
  Sound list     next to the monitor: "No sound" or one of this PC's sound OUTPUTS (speakers,
                 headphones ... as named in Windows Sound settings; "(default)" = the Windows
                 default). The recording gets exactly what plays on that output - the game,
                 voice chat, notification sounds - as AAC in the .mp4. Nothing to set up in
                 Windows. Opening the list reads the outputs again, so a headset plugged in
                 later shows up. The pick is remembered; the Record window has the same list.
                 A remembered output that is gone shows "(not found)".
  Screenshot     one .png of the picked monitor.
  Record...      asks: monitor, stop after N minutes (0 = until Stop recording), size
                 (Native / 1080p / 720p), frame rate (30 / 60) and Show mouse. Saves .mp4 (H.264).
  Stop recording stops the PC recording; the .mp4 is finished properly (plays everywhere).
  Captures       opens the captures folder. Files: Captures\<date>\PC_<computer>_<time>.png / .mp4
  The encoder is picked automatically, fastest first: NVIDIA (h264_nvenc), AMD (h264_amf),
  Intel (h264_qsv), then the CPU (libx264). The log pane shows which one is used.
  Capture uses Desktop Duplication (ddagrab) - captures full-screen games and is light on the
  CPU. Older ffmpeg without ddagrab falls back to gdigrab (works, slower; exclusive
  full-screen games may record black - use borderless window).
  Pick the output the game plays on (usually the default). Quiet stretches are recorded as
  silence, so sound and picture stay in step. Microphones are not offered.
  Config (Capture.PC): Ffmpeg, Method (auto / ddagrab / gdigrab), Encoder (auto or an ffmpeg
  encoder name), Size, ShowMouse, AudioDevice (output name: the Sound pick before one is made in the
  tool; afterwards PcCaptureAudio.txt). Capture.FrameRate / MaxMinutes apply too.

POWER (bottom row - acts on the selected kits)
  Power On   PS5: prospero-ctrl power on.  Xbox: Wake-on-LAN (needs a MAC column, see below).
  Power Off  asks for confirmation, then waits until the kit stops answering ping -> Status "Off".
  Restart    asks for confirmation, then waits until the kit is back online -> Status "Online".
  Kits not marked Idle are listed in the confirmation so you do not power off someone mid-test.
  Dry run applies here too. Cancel Running stops the waiting, not a command already sent.

  !! VERIFY ON ONE KIT FIRST - these defaults are not confirmed against your SDK versions:
     Xbox Power Off: xbreboot /S /X:{IP}  - CONFIRMED. xbreboot exits with code 1 after a
       successful shutdown (it cannot reconnect to an off console). "OkOutput" in the config
       treats that as OK when the output says "Shutting down"; the ping check then confirms Off.
       Xbox Power Off first checks the kit's AlwaysOn setting (xbconfig AlwaysOn).
       AlwaysOn=true -> the kit powers itself back on; Result shows BACK ON (yellow).
       To make it stay off: set AlwaysOn=false on the kit, or Power.XboxTurnOffAlwaysOn = true
       in DeployConfig.json (the tool then switches it off before shutting down - the kit
       can then only be turned on at the console).
     PS5 Power On / Off: prospero-ctrl power on|off /target:{IP}
     Change them under Steps.PowerOn / Steps.PowerOff in DeployConfig.json if needed.

  Xbox Power On:
     No MAC needed. The tool pings the kit every 2s (directed traffic wakes kits that are in
     sleep / instant-on with network wake) and also sends Wake-on-LAN when it knows the MAC.
     An Xbox switched off with Power Off (xbreboot /S) is fully off and can NOT be woken
     remotely - use Restart instead if you need it back without walking to the desk.
  MAC addresses are learned automatically: Check Selected reads them from this PC's ARP
     cache for kits that answer and saves them in Learned_MACs.csv. That only works when this
     PC is on the same subnet as the kit. A MAC column in the Excel file always wins.

XBOX ALWAYSON (Xbox tab: On / Off / Read - acts on the selected Xbox kits)
  On   - AlwaysOn=true: kit powers itself back on after a shutdown.
  Off  - AlwaysOn=false: Power Off really turns it off (then it can only be switched on at the console).
  Read - shows the current value; nothing is changed.
  After On/Off the value is read back to confirm it changed. The AlwaysOn column shows the
  last known value ("?" = not read yet). Xbox Power Off also updates it.

TARGET MANAGER (PS5)
  When the console list loads (and with the PS5 tab's "Add PS5 kits to Target Manager" button), every
  enabled PS5 kit that Target Manager on this PC does not have yet is added in the background.
  It first checks "prospero-ctrl help target" for a "target add" command, compares against
  "target list". Kits that do not answer (off / offline) are skipped and retried on the
  next sync; it only stops early (after 3 other failures in a row) if the command itself
  looks wrong.
  Adding a kit does NOT take ownership of it. Turn off with TargetManager.AutoAdd = false.
  Details: logs\TargetManager_<date>.log

CONSOLE LIST (Excel or CSV)
  The tool reads Console_IP_List.xlsx from this folder. If there is none, it uses Consoles.csv.
  To use a shared copy instead, set "ConsoleList" in DeployConfig.json to its path.
  Excel: every tab is read. A tab needs a header row with at least Name and IP.
    Columns (any order, any case):  Name | Platform | IP | Enabled | Idle | Notes | MAC
    Platform: Xbox / XBOX / XBSX / Series X  -> Xbox     PS5 / PS5 Pro -> PS5
              If Platform is unclear (e.g. "PS"), the tab name (XBOX / PS5) is used.
    Enabled blank = true.  Idle blank = false (so Deploy All Idle never hits personal kits).
  Rows with a bad IP, unknown platform or duplicate IP are SKIPPED and listed in the log pane.
  You can edit the Excel file while the tool is open; click Reload List + Config to pick up changes.
  Filter box: type a name, IP or note to show only matching kits (see FILTER above).

LOGS (Open Logs button)
  logs\Deploy_<run>_<kit>_<platform>.log  - full tool output per kit per deploy
  logs\Power_<run>_<kit>_<platform>.log   - same for power on / off / restart
  logs\ConsoleLog_<date>.csv   - one summary line per kit per run (same file as reboot tool)

==========================================================================================
VERSION HISTORY  (newest first)
==========================================================================================

v4.16.2
  FIXED  PC Record with a sound output still failed with "Error opening input files: Invalid
         argument": newer ffmpeg (7/8) no longer accepts -thread_queue_size on an input. Removed.

v4.16.1
  FIXED  PC Record with a sound output failed: "Error opening input files: Invalid argument" (ffmpeg
         could not open the sound pipe). The sound now goes to ffmpeg over a local connection on
         this PC (127.0.0.1 only), opened before ffmpeg starts.

v4.16
  CHANGED PC tab Sound list: lists the sound OUTPUTS (speakers / headphones) and records what plays
         on the picked one (Windows loopback, fed to ffmpeg locally) - game sound without
         Stereo Mix or a virtual cable. Microphones / DirectShow inputs are no longer listed.

v4.15
  REMOVED Repair video (button, automatic repair, HYD_RepairVideo.ps1, Capture.RepairBroken) and
         the xbcapture /V way of recording Xbox (Capture.Xbox.Method / StopWith / KeyWaitSec,
         Xbox Steps.Video). Xbox Record always uses the GDK live capture; if it cannot (helper or
         GDK missing) it says so instead of recording another way.

v4.14
  FIXED  Xbox Record + Stop recording: the file was cut off and its repaired sound was bad /
         laggy. Xbox now records with the GDK's own live capture (XtfCaptureLiveVideo, as Xbox
         Manager's red button) and Stop recording signals it to stop - the file is finished
         properly, full quality, no repair. New file HYD_XboxRecord.ps1. Config:
         Capture.Xbox.Method (xtf / xbcapture). Capture files are never reused (_2 when two
         start in the same second).

v4.13
  ADDED  PC tab: Sound list next to the monitor list (and in the Record window) - record a
         microphone, Stereo Mix or a virtual cable with the screen. Remembered; a missing device
         gives a clear FAILED message. The status text moved to its own line under the row.

v4.12.1
  FIXED  Repair failed on every PC with "SOURCE_CODE_ERROR ... AddTypeCommand": Windows PowerShell
         5.1 treats the C# compiler's warnings as errors. Fixed; if the repair code ever does not
         compile, the message now says which line and why (not the last line of the error).
  CHANGED A repaired recording replaces the broken file - no "unrepaired" copies are kept.
  CHANGED Xbox Stop recording sends Ctrl+C straight away (the key press was ignored by xbcapture
         and only added 10 s). Capture.Xbox.StopWith = "key" brings it back.

v4.12
  FIXED  Xbox Record + Stop recording left an .mp4 that would not play: Ctrl+C ends xbcapture
         before it writes the file's index. Stop now presses a key in xbcapture first (Ctrl+C
         only if that does not end it), and any recording that ends unfinished is repaired
         automatically (REPAIRED; replaces the broken file). New Repair video... button on
         the Xbox and PS5 tabs for older files. New file HYD_RepairVideo.ps1 (needs ffmpeg.exe).
         Config: Capture.RepairBroken, Capture.Xbox.StopWith / KeyWaitSec.

v4.11
  ADDED  PC tab "Screen capture" row: pick a monitor, Screenshot (.png), Record... (.mp4 H.264,
         Native / 1080p / 720p, 30 / 60 fps, stop after N minutes or on Stop recording),
         Stop recording, Captures. Uses ffmpeg (download once, see PC SCREEN CAPTURE); GPU
         encoder picked automatically. Config: Capture.PC.

v4.10
  ADDED  Xbox Screenshot, Save last 90 s, Record..., Stop recording and Captures buttons
         (xbcapture: screenshot, /C = the last N seconds, /V = live video). Capture settings per
         platform in the config (Capture.Xbox / Capture.PS5); Xbox Steps.Screenshot / Clip / Video.

v4.9
  ADDED  PS5 Screenshot, Record..., Stop recording and Captures buttons (prospero-ctrl target
         screenshot / target video). Recordings run in the background per kit, stop after a set
         time or on Stop recording (sent as Ctrl+C by the new HYD_CtrlC.ps1 so the file is
         closed properly). New Capture section and PS5 Steps.Screenshot / Steps.Video in the config.

v4.8
  ADDED  PS5 workspace name read from the kit: with the new Workspace box in Launch game empty,
         each kit's workspaces are listed (prospero-ctrl workspace list, Steps.ListWorkspaces)
         just before launching and the right one is used. Find on kit lists them to pick from.
         PS5.Launch.ReadWorkspace / WorkspaceListRegex in the config.

v4.7
  CHANGED PS5: the build type decides what starts. Files Final / Files Performance start the
         build in the deploy workspace (application start ... /workspaceOverlay:<workspace>),
         Combine Retail starts the installed package - before, both started the package.
         Set per type with PS5.Launch.Profiles "From" (Package / Workspace).
  FIXED  PS5 Title ID box always looked empty: empty means automatic, and the line under it now
         shows the Title ID that will be used and where it comes from; the drop-down lists it.
  REMOVED PS5.Launch.UseWorkspaceOverlay / Steps.LaunchLooseOverlay / Steps.LaunchLoose (replaced
         by the build type setting and Steps.LaunchWorkspace).

v4.6.3
  CHANGED PS5 launch parameters follow the SDK help for application start: "/args" followed by
         the parameters, as the last thing on the line, each parameter its own argument.
         Nothing is added when there are no parameters.
  ADDED  PS5.Launch.UseWorkspaceOverlay: loose builds can start the installed title with the
         deploy workspace overlaid (/workspaceOverlay), via Steps.LaunchLooseOverlay.

v4.6.2
  FIXED  PS5 launch failed with "Command line argument incorrectly formatted" (exit 255): the
         BF Deploy form "prospero-run <kit IP> <TitleId>" is not accepted by the SDK. PS5
         launch now uses prospero-ctrl application start <TitleId> /target:<kit IP> for both
         package and loose builds.
  ADDED  When a tool rejects a command's format, the message says to run it with /help and
         which Steps entry in DeployConfig.json to fix.

v4.6.1
  FIXED  PS5 Launch game said "cannot launch yet: no Title ID" when no build was picked on the
         PS5 tab. It now uses the game's Title ID from PS5.Launch.TitleId (PPSA19534) in that
         case; a picked package's Title ID or one typed in the window still wins.

v4.6
  CHANGED PS5 launch uses the BF Deploy commands: prospero-run <kit> <TitleId> <parameters> for
         packages (or a typed Title ID), prospero-ctrl workspace run <kit> <workspace>
         <parameters> for loose builds; parameters passed as one argument; ping first.
  ADDED  PS5 Close game: application kill of the typed Title ID, or of whatever
         "application list" shows running; "Nothing running" when the list is empty.
  ADDED  Clear message when a PS5 kit is not registered in Target Manager on this PC.

v4.5
  CHANGED Xbox launch works like XBDEPLOY: parameters go to xbapp as one argument, every kit is
         pinged first (Offline instead of a long timeout), clearer messages for not installed /
         already running / network / pairing / access denied / invalid install state.
  ADDED  Launch ID box in Launch game (Xbox AUMID / PS5 Title ID), remembered per build type,
         with Find on kit (lists the apps on the first ticked kit, Battlefield first).
  ADDED  Close game on the ticked kits (xbapp terminate, Steps.Terminate).
  ADDED  Launch after deploy and the confirm box use the saved launch ID too.

v4.4.1
  FIXED  Xbox Launch game said "cannot launch yet: no launch ID" for package builds (and when no
         build was picked). The tool now reads the launch ID from the kit itself (xbapp list,
         new Steps.ListApps) right before launching - also for Launch after deploy. It picks the
         app of the picked package, or the one installed app matching Xbox.Launch.FindApp, and
         says clearly if the game is not installed or several builds match.

v4.4
  ADDED  Launch game... on the Xbox and PS5 tabs: launch parameters per build type (Combine
         Retail / Files Final / Files Performance) with presets, a config default and a command
         preview; launches on the ticked kits (PS5 connects first).
  ADDED  Launch after deploy uses the same parameters (shown in Confirm Deploy and in Preview
         Commands). Use This Build switches the build type to match the Config.
  ADDED  {LaunchArgs} in the Xbox / PS5 Launch and LaunchLoose commands, Xbox.Launch and
         PS5.Launch in DeployConfig.json. Parameters are added at the end of an older
         Launch command that has no {LaunchArgs}; no parameters = same command as before.

v4.3
  ADDED  Launch game... has a profile per build type (Combine Retail / Files Final / Files
         Performance), each with its own build folder, game exe and launch parameters.
  ADDED  Parameter presets per build type (Save as preset... / Delete preset), a Config
         default button, a command line preview and {Folder} {Exe} {Cl} {BuildId} {Type}
         placeholders. Parameters can be written one per line; # lines are comments.
  ADDED  Copied loose builds and direct installs are remembered (PcBuilds.json), so Launch
         game offers them with their CL and picks the newest copy of the type.
  ADDED  When a loose copy finishes you can go straight to Launch game.
  ADDED  Asks before launching if the game is already running (close it / launch another).
  ADDED  PC.Launch section in DeployConfig.json (PreferExe, SkipExe, Profiles with default
         Exe + Args per type). The v4.2 PcLaunch.json is used for Combine Retail.

v4.2.4
  FIXED  Install stopped after extracting the main game with "3 file(s) ... missing or the wrong
         size, e.g. Support/EA Help/Servicio tÕcnico.rtf". The files were fine: tar.exe prints
         accented letters in names in another encoding, so the check looked for the wrong name.
         Files whose names contain such letters are now found on disk with those letters as
         wildcards and the exact size; every other file is still checked by exact name and size.

v4.2.3
  FIXED  Install stopped with "Cannot create a file when that file already exists" during
         extraction: the tool reading the progress file at the same moment the install helper
         replaced it made Windows refuse the write. Progress and log files are now written and
         read with shared access, writes retry, and a failed progress write never stops an
         install. If the last progress update is lost, the result is read from the install log.

v4.2.2
  FIXED  "Not enough space: game after extraction 7,139 GB" - the .NET ZIP reader in Windows
         PowerShell 5.1 misreads the big (Zip64) EA ZIPs: small .toc/.digest files read as
         4 GB each (84.7 GB ZIP reported as 6,916 GB). Extracting with it would have produced
         bad files. Size check and extraction now use Windows' tar.exe, which reads them
         correctly, and every extracted file is checked against its expected size.
  CHANGED Unsafe ZIP paths are caught while reading the ZIPs, before the old build is deleted.

v4.2.1
  FIXED  Startup error "Cannot convert argument value, with value: p, for add_Click" - a
         one-button list on the PC tab was unwrapped by PowerShell after v4.2 removed the
         "Save EA app screen" button.

v4.2  - PC direct install (from the Python tool)
  ADDED  "Install game (direct)": extracts the ticked content ZIPs into the install folder
         (main game first), runs Touchup.exe, writes the HKLM registry keys, then writes the
         overrides. Runs elevated in HYD_PC_DirectInstall.ps1 with one admin prompt; progress,
         Cancel, free-space check, clean install of the folder, unsafe ZIP paths refused.
  ADDED  Install folder row on the PC tab (default C:\Program Files\EA Games\Battlefield 6).
  ADDED  "Launch game..." window: exe + launch parameters, remembered in PcLaunch.json.
  CHANGED Delete game files (fast) uses the install folder when Windows has no entry for the game.
  REMOVED "Install game (automatic)" (EA app window automation), "Save EA app screen" and
          PC.AutoInstall - replaced by the direct install.
  NOTE   Differences from the Python tool: it asks for admin rights (the Python tool's registry
         writes silently failed without them), extracts in a fixed order, treats Touchup
         problems as warnings, and keeps override.cfg in the current format instead of
         rewriting the whole file.

v4.1.1
  CHANGED START_HYD_BUILD_DEPLOY.cmd starts the tool without the blank console window.
          Startup errors are shown in a message box instead.
  ADDED  START_HYD_BUILD_DEPLOY_debug.cmd - the old launcher (console stays open) for
         troubleshooting.

v4.1  - Build cache for big deploys
  ADDED  When more than 5 kits are ticked, the build is copied from the NAS to this PC ONCE
         and every kit is deployed from the local copy (instead of streaming it from the NAS
         for every kit). Covers Xbox package / loose, PS5 main + DLC packages, PS5 loose.
  ADDED  Cache progress shown on every kit row; deploy starts by itself when the copy is done.
  ADDED  Free-space check (offers to deploy straight from the NAS if there is no room).
  ADDED  Keeps the last 2 cached builds, deletes older ones automatically. Clear Cache button.
  ADDED  Config: Cache.Enabled, Cache.WhenMoreThanKits, Cache.Folder ("auto"), Cache.KeepBuilds.
  FIXED  (found in testing) Cancel during caching was reported as a failed copy.

v4.0.2
  FIXED  Crash "Cannot convert argument val2 ... to type System.Int32" when copying a large
         (over 2 GB) PC build - size maths now uses 64-bit numbers.

v4.0.1
  CHANGED Every folder prompt now uses the Explorer-style Windows picker (address bar, Quick
          access, Network) instead of the old tree dialog. Old dialog kept as a fallback.

v4.0  - PC loose builds
  ADDED  PC tab: Files Final / Files Performance builds are copied to a folder you choose
         (Use This Build asks where; remembers the last folder; creates <folder>\<build number>
         and copies the CL .txt beside it).
  ADDED  Size + free-space check and confirmation before copying.
  ADDED  Background copy with robocopy (16 files at a time, retries on network drops),
         progress / speed / time left, Cancel copy, Open folder. Copying again resumes.
  ADDED  Config: PC.CopyThreads.

v3.9  - Automatic PC install
  ADDED  "Install game (automatic)": restarts the EA app if it started before the overrides
         were written, opens the game, presses GET THE GAME, sets every content tick box
         (HD Textures off), reads them back and only then presses Install. Stops before
         Install if anything does not match and opens the checklist.
  ADDED  "Save EA app screen" - writes every control name in the EA app to a text file
         (used to fix button names). Steps / names live in PC.AutoInstall in the config.

v3.8.2
  CHANGED Install button renamed "Open game in EA app": origin://launchgame only launches an
          installed game; if not installed, the EA app says "Game not installed" and you click
          GET THE GAME. Prompt and checklist explain this.

v3.8.1
  CHANGED EA app link uses the title ID 16426154 (PC.TitleId).

v3.8  - PC content selection
  ADDED  "Content to install" row matching the EA app dialog: Base Game (required),
         Battlefield 6 Multiplayer, Single Player, REDSEC.
  ADDED  Mapping: Base -> 0005511, MP -> SAN2 + SAN1+SAN2, SP -> SAN1 + SAN1+SAN2,
         REDSEC -> MARKER. SAN1+SAN2 is needed when MP OR SP is ticked.
  ADDED  Writing is blocked if a selected item's zip is missing; on-top checklist window
         (TICK / LEAVE UNTICKED for every item, HD Textures always off).

v3.7  - PC install / uninstall
  ADDED  Open game in EA app, Find installed game (Windows installed-programs entry),
         Uninstall (Windows entry: msiexec /x for MSI installs, else the quiet uninstaller),
         Delete game files (fast): closes EA app + background service, deletes the real
         install folder after two confirmations, optional EA app cache clear. Refuses drive
         roots, the NAS, Program Files, user folders.

v3.6.1
  CHANGED MARKER (REDSEC) DLC moved to OFR.50.0005605; 0005756 is version-only.

v3.6  - PC (EA app) tab
  ADDED  Writes / removes EA app download overrides in C:\EADesktopDev\override.cfg for the main
         game and each DLC (OverrideDownloadPath with full .zip path, ServerVersionOverride,
         OverrideUpToDateStatus, overrideUpToDateAfterInstall). Only those lines change; a
         backup is made first. "In file now" column. Fill paths from a Combine Retail build.
         Restart EA app button.

v3.5.1
  CHANGED Branch name CH1-Content-dev -> "CH1-Content Dev" (new NAS path).

v3.5  - Build library (NAS scan)
  ADDED  Branch / Config / Build lists + Scan + Use This Build + RM only.
         Root \\eahy-nas01.ad.ea.com\BF\<Branch>\<Config>\<Platform>. CL read from folder /
         .txt names. PS5 Combine Retail: RM Main + RM DLC1..4 grouped by CL, "remastered" .pkg
         preferred. Loose builds: the folder that holds eboot.bin / MicrosoftGame.config.
  REMOVED Use Latest Build (replaced by the library).

v3.4  - Tick boxes + filter
  ADDED  Tick box on every row (click row, Shift-click range, Space). All buttons act on
         TICKED kits. Ticked rows tinted green; tab titles show "x of y, n ticked".
  CHANGED Find -> live Filter (name / IP / notes); ticks survive filtering; confirm dialog
          says how many targets are hidden by the filter.

v3.3
  ADDED  Before taking over a PS5 owned by another PC, the tool asks "Are you sure you want to
         disconnect <owner> and connect this PC to the console?" (No is default; 15 min timeout = No).

v3.2
  ADDED  "Take ownership if needed" (PS5 tab, off by default): normal connect first, only
         forces (target connect /force) when another PC owns the kit.
  FIXED  Target Manager sync stopped after 3 unreachable kits; offline kits are now skipped
         and retried on the next sync.

v3.1
  CHANGED PS5 packages: separate Main box + DLC list, each file from any folder.
          Add DLC(s) picks several at once; drag and drop; Remove / Clear.
  ADDED  Asks when a DLC-named file is picked as Main; warns on Title ID mismatch.
  ADDED  "Install packages / Deploy loose folder" switch on the PS5 tab.

v3.0  - Tabs
  CHANGED Window split into Xbox and PS5 tabs (shared options / buttons / log at the bottom).
  ADDED  PS5 main + DLC selection; DLC failure -> PARTIAL result (yellow), main failure stops.
  REMOVED Select PS5 Only / Select Xbox Only (replaced by tabs).

v2.7
  ADDED  Xbox AlwaysOn On / Off / Read buttons with read-back check; AlwaysOn column.

v2.6
  ADDED  Xbox Power Off checks AlwaysOn first; AlwaysOn kits show BACK ON instead of
         "Still on?". Optional PC.XboxTurnOffAlwaysOn.

v2.5
  ADDED  PS5 kits from the console list are added to Target Manager automatically
         (target list / target add) + manual button. Logs to TargetManager_<date>.log.

v2.4
  FIXED  A failed PS5 connect carried on and was misreported as "workspace not found".
         Connect failure now stops that kit; "not found" must be confirmed by the tool's output.
  ADDED  Every failure quotes prospero-ctrl's own message plus a plain-language hint.

v2.3
  CHANGED Every workspace name gets the prefix "sce_nolimit " (default "sce_nolimit playtest");
          names are quoted in all workspace commands.

v2.2
  ADDED  PS5 workspace name box (default playtest) with {TitleId} {Build} {Stream} {Config}
         {Name} placeholders. Existing workspace is detected and deployed into; otherwise created.

v2.1
  FIXED  Progress column stuck on "Waiting for a free slot" while a silent step ran.
         Progress now shows a running clock + the tool's last line.

v2.0  - Loose builds
  ADDED  PS5 loose deploy: workspace create + push (/diff:QUICK /sync), or workspace deploy
         when the folder has a .gp5. Xbox Package Family Name / launch ID read from the build.
  ADDED  A folder holding exactly one package is installed as that package.

v1.9
  ADDED  Stagger (s): minimum gap between kits starting their install.
  FIXED  (found in testing) overflow that would have failed every kit at its first install.

v1.8
  ADDED  PS5 package install / uninstall / launch (prospero-ctrl 13.0). Title ID and Content
         ID read from the package name or sce_sys\param.json.

v1.7
  FIXED  SERIOUS: after sorting the grid, actions went to the wrong console (rows were matched
         by position). Rows are now tied to their kit. Confirm dialogs list name / platform / IP.

v1.6
  ADDED  Xbox Power On without a MAC (directed pings) + MACs learned automatically
         (Learned_MACs.csv). Clear message that a fully powered-off Xbox needs the power button.

v1.5
  CHANGED Check Status -> Check Selected (pinging the whole floor woke sleeping kits).
  ADDED  Power.VerifyOffWithPing option.

v1.4
  FIXED  Xbox Power Off reported FAILED although the kit shut down (xbreboot exits 1 after a
         successful shutdown). OkOutput "Shutting down" now counts as success.

v1.3
  ADDED  Power On / Power Off / Restart with confirmations, online / offline checks,
         Wake-on-LAN (MAC column), power logs.

v1.2
  ADDED  Console list from Excel (Console_IP_List.xlsx, every tab, no Excel needed, file can be
         open). Platform names cleaned up; bad IP / duplicate / unknown platform rows skipped
         and listed. ConsoleList path in config. Fast parallel status check. Find box.
         Log file names include the platform.

v1.1
  FIXED  Startup crash "\xEF\xBB\xBFAdd-Type is not recognized" (file marker was written as text).

v1.0  - First release
  ADDED  PowerShell + WinForms app in the style of the HYD reboot tool (double-click .cmd).
         Xbox + PS5 deploy from a folder (loose) or package; optional reboot, PS5 connect,
         uninstall, launch. Parallel deploys with live progress, cancel, Preview Commands,
         Dry run, per-kit logs + daily ConsoleLog CSV. Commands are templates in DeployConfig.json.
  NOTE   Found a bug in the old reboot tool: "Reboot All Idle" ignored Idle (fix: wrap each
         function call in parentheses).
