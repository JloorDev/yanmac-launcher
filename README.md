# YanMac Launcher

A native macOS launcher for **Yandere Simulator**, built with SwiftUI. It installs and manages [WINE](https://www.winehq.org)/[Apple's Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/) for you, downloads and updates the game, manages mods and backups, and launches it — so you don't have to touch the Terminal.

> **Disclaimer:** This project is **not affiliated with, endorsed by, or associated with YandereDev** or the official Yandere Simulator project in any way. It's an independent, fan-made tool that automates running the Windows game on macOS via WINE. Yandere Simulator itself is downloaded from its [official source](https://yanderesimulator.com) — this launcher doesn't bundle, modify, or redistribute the game.

## What it does

- **Sets up WINE/GPTK automatically** — detects or installs Homebrew, WINE, and the dependencies needed to run Windows games on macOS.
- **Downloads and installs the game** with a real progress bar (not just a spinner), and checks the downloaded file's integrity before extracting it.
- **Checks for game updates** periodically and on demand, comparing the remote file against what you last installed.
- **Installs the required Windows fonts** automatically, so in-game text (dialogue, HUD) renders correctly — no manual steps.
- **Applies a Unity 6 compatibility patch** (`version.dll`) next to the game executable automatically.
- **Manages mods**: import `.zip` mods or folders, enable/disable them individually, and restore the vanilla game state.
- **Backs up save data and the whole game folder** with one click.
- **Diagnoses crashes**: if the game closes unexpectedly, it reads the WINE/Metal logs and gives you a plain-language guess at what went wrong (missing DLL, Direct3D issue, Rosetta mismatch, disk space, etc.).
- **Detects a frozen game** (no log activity for a while) and offers a safe "Force Quit" instead of making you guess.
- **Single-instance guard** — won't let you open two copies at once, which could corrupt your WINE prefix or game folder.
- **Graceful quit** — warns you if you try to close the launcher while the game is running or something is installing/downloading, and cleans up any leftover WINE processes when it exits.
- Light/dark theme, English/Spanish interface, play-time stats, and a one-click diagnostic report you can paste when asking for help.

## Requirements

- macOS 14.0 or later, Apple Silicon recommended (Game Porting Toolkit is built for Apple Silicon).
- [Homebrew](https://brew.sh) — the launcher can install this part of the chain for you, but Homebrew itself needs to already be on your Mac.
- Xcode 15+ if you're building from source.

## Building from source

1. Clone the repo:
   ```bash
   git clone https://github.com/<your-username>/YanMacLauncher.git
   cd YanMacLauncher
   ```
2. Open `YanMac Launcher.xcodeproj` in Xcode.
3. Select the **YanMac Launcher** scheme with **My Mac** as the destination.
4. Build and run (⌘R).

The app is macOS-only — if your project ever shows iOS/visionOS as supported destinations, remove them (Target → General → Supported Destinations), since this app uses `Process`, `AppKit`, and WINE, none of which exist on those platforms.

## Project structure

```
YanMacLauncher/
├── GameManager/          # Core app logic (split by responsibility)
│   ├── GameManager.swift          # State, settings, init
│   ├── GameManager+Setup.swift    # WINE/Homebrew install flow
│   ├── GameManager+Download.swift # Game download, extraction, updates
│   ├── GameManager+Play.swift     # Launching the game, crash/freeze detection
│   ├── GameManager+Mods.swift     # Mod import/management
│   ├── GameManager+Backups.swift  # Save & game folder backups
│   ├── GameManager+Maintenance.swift
│   ├── GameManager+Diagnostics.swift
│   ├── GameManager+Notifications.swift
│   ├── GameManager+QuickActions.swift
│   └── GameManager+Utilities.swift
├── Models/                # Small value types (enums, structs)
├── AppDelegate.swift       # App lifecycle: single instance, quit confirmation
├── YansimLauncherApp.swift # App entry point
├── ContentView.swift       # All SwiftUI views
└── Localizable.xcstrings   # English/Spanish strings
```

## Known limitations

- Game Porting Toolkit support is best on Apple Silicon; results on Intel Macs may vary.
- Performance and compatibility depend entirely on WINE/GPTK's own translation of Direct3D to Metal — some visual glitches or crashes are outside what this launcher can fix, though its diagnostics try to point you in the right direction.

## License

_Not yet licensed — add a `LICENSE` file (e.g. MIT) before relying on this being open source in the legal sense. Until then, all rights are reserved by default._
