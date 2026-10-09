# HYD PS5 + Xbox Build Deploy

A Windows desktop tool (PowerShell + WinForms) for deploying, launching and capturing game builds on
Xbox Series X|S and PS5 dev kits, and on the local PC, from one window.

## Features

- **Build library** – scan the build share by branch / config and pick a build by CL.
- **Deploy** – install packages or push loose builds to many kits at once, with dry run and command preview.
- **Launch** – start the game on kits or PC with saved launch parameters per build type.
- **Kit management** – power on / off / restart, Xbox AlwaysOn, PS5 Target Manager sync.
- **Capture** – screenshots and video from kits (Xbox: GDK live capture, stops cleanly; PS5: `prospero-ctrl`),
  plus PC screen recording to MP4 with monitor and sound-output selection.
- **PC tab** – EA app download overrides and direct install for PC builds.

## Requirements

| Needed for | Requirement |
|---|---|
| Everything | Windows 10 / 11 (64-bit), Windows PowerShell 5.1 (built in) |
| Xbox tab | Microsoft GDK installed (`C:\Program Files (x86)\Microsoft GDK\bin`) |
| PS5 tab | PS5 SDK Target Manager / `prospero-ctrl` (`...\SCE\Prospero\Tools\Target Manager Server\bin`) |
| Kits | Network access to the kits; Xbox Wake-on-LAN needs the same subnet |
| Build library | Read access to the build share |
| PC tab | EA app (for overrides / install) |
| PC screen capture | `ffmpeg.exe` 6.0+ in the tool folder – download [ffmpeg-release-essentials.zip](https://www.gyan.dev/ffmpeg/builds/) and copy `bin\ffmpeg.exe` |

No Excel, modules or installs are needed – the console list `.xlsx` is read directly.

## Quick start

1. Copy the folder to a local drive (not a network share).
2. Fill in `Console_IP_List.xlsx` (columns: Name, Platform, IP; optional Enabled, Idle, Notes, MAC).
3. Run `START_HYD_BUILD_DEPLOY.cmd` (use `START_HYD_BUILD_DEPLOY_debug.cmd` to see errors).
4. Pick a tab, pick a build, tick a kit, try **Dry run** + **Preview Commands** first.

## Files

| File | Purpose |
|---|---|
| `HYD_Build_Deploy_GUI.ps1` | The tool |
| `DeployConfig.json` | All settings: tool paths, commands, build share, launch profiles, capture |
| `HYD_XboxRecord.ps1` | Xbox video recording helper (GDK live capture) |
| `HYD_CtrlC.ps1` | Stops PS5 recordings cleanly |
| `HYD_PC_DirectInstall.ps1` | PC direct install helper |
| `Console_IP_List.xlsx` / `Consoles.csv` | Kit list (CSV is used if there is no `.xlsx`) |
| `README_FIRST.txt` | Full user guide and version history |

Runtime files (`logs\`, `Captures\`, `*Launch.json`, `PcBuilds.json`, `Pc*.txt`, `Learned_MACs.csv`)
and `ffmpeg.exe` are created / placed next to the tool and are ignored by `.gitignore`.
