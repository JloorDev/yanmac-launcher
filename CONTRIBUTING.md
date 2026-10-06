# Contributing to YanMac Launcher

Thanks for wanting to help! / ¡Gracias por querer ayudar!

## Ways to help

- **Test on your Mac** and report what happens (macOS version, chip, graphics profile used). Attach the session log from the launcher's Console if you can.
- **Report bugs** by opening an issue. Screenshots or short GIFs help a lot.
- **Ideas for the in-game text rendering issue** (see *Known issues* in the README) are especially welcome.
- **Translations:** the interface strings live in `source/Localizable.xcstrings`.
- **Code:** pull requests are welcome.

## Building

1. Requires macOS 14+ and Xcode 15+.
2. Open `YanMacLauncher.xcodeproj`, choose the **YanMac Launcher** scheme with **My Mac**, and press ⌘R.

## Pull requests

1. Fork the repo and create a branch from `main` (e.g. `fix/settings-buttons`).
2. Keep changes focused: one fix or feature per PR.
3. Build and run the app before opening the PR, and say in the description what you tested.
4. UI text must work in both Spanish and English (use `L10n.t(...)`).

## Code layout

- `source/ContentView.swift`: all SwiftUI views.
- `source/GameManager/`: game logic split by area (setup, download, play, mods, backups, diagnostics...).
- `source/Models/`: small data types (graphics profiles, language/appearance, mod entries).

## License

By contributing you agree that your work is released under the project's MIT license.

---

# Contribuir (resumen en español)

Puedes ayudar probando en tu Mac, reportando errores (con capturas y el registro de la Consola), proponiendo ideas para el problema del texto, traduciendo `Localizable.xcstrings` o enviando Pull Requests. Compila con Xcode 15+ en macOS 14+, crea una rama desde `main`, mantén los cambios pequeños y prueba la app antes de abrir el PR. Todo texto de la interfaz debe estar en español e inglés.
