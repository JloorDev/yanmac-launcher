import Foundation
import Combine
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

extension GameManager {
    // MARK: - Accesos rápidos a carpetas

    /// Abre en Finder la carpeta donde está el .exe del juego (donde
    /// también viven sus archivos internos, capturas, etc.).
    func openGameFolder() {
        #if canImport(AppKit)
        if let exe = gameExePath {
            NSWorkspace.shared.open(URL(fileURLWithPath: exe).deletingLastPathComponent())
        } else {
            NSWorkspace.shared.open(Self.gameDir)
        }
        #endif
    }

    /// Yandere Simulator no tiene una carpeta de capturas fija y documentada,
    /// así que buscamos una carpeta llamada "Screenshots" junto al juego; si
    /// no existe todavía, abrimos la carpeta del juego de todas formas para
    /// no dejar el botón sin hacer nada.
    func openScreenshotsFolder() {
        #if canImport(AppKit)
        guard let exe = gameExePath else { return }
        let gameFolder = URL(fileURLWithPath: exe).deletingLastPathComponent()
        let candidate = gameFolder.appendingPathComponent("Screenshots")
        if FileManager.default.fileExists(atPath: candidate.path) {
            NSWorkspace.shared.open(candidate)
        } else {
            NSWorkspace.shared.open(gameFolder)
        }
        #endif
    }

}
