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
    // MARK: - Copia de seguridad de partidas

    /// Busca las partidas guardadas dentro del WINEPREFIX (no sabemos el
    /// nombre exacto de la carpeta que usa Yandere Simulator, así que
    /// buscamos cualquier carpeta cuyo nombre contenga "yandere" dentro de
    /// AppData/LocalLow y AppData/Local, que es donde Unity guarda partidas
    /// normalmente) y copia lo que encuentre a una carpeta con fecha y hora
    /// dentro de Backups.
    func backupSaves() {
        guard !isBusy, !isBackingUp else { return }
        isBackingUp = true
        backupMessage = nil
        log("Buscando partidas guardadas para respaldar...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let userFolder = Self.winePrefixPath
                .appendingPathComponent("drive_c/users")
                .appendingPathComponent(NSUserName())
            let searchRoots = [
                userFolder.appendingPathComponent("AppData/LocalLow"),
                userFolder.appendingPathComponent("AppData/Local"),
            ]

            var foundFolders: [URL] = []
            for root in searchRoots {
                guard let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
                for item in contents where item.lastPathComponent.lowercased().contains("yandere") {
                    foundFolders.append(item)
                }
            }

            guard !foundFolders.isEmpty else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isBackingUp = false
                    self.backupMessage = "No encontré ninguna carpeta de partidas guardadas todavía. Juega un poco primero y guarda una partida, luego intenta de nuevo."
                    self.log("✘ No se encontró ninguna carpeta con partidas guardadas para respaldar.")
                }
                return
            }

            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let destRoot = Self.backupsDir.appendingPathComponent(stamp)
            try? fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

            var copiedCount = 0
            for folder in foundFolders {
                let dest = destRoot.appendingPathComponent(folder.lastPathComponent)
                do {
                    try fm.copyItem(at: folder, to: dest)
                    copiedCount += 1
                } catch {
                    DispatchQueue.main.async {
                        self?.log("✘ No pude copiar \(folder.path): \(error.localizedDescription)")
                    }
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isBackingUp = false
                if copiedCount > 0 {
                    self.backupMessage = "✔ Copia de seguridad guardada."
                    self.log("✔ Copia de seguridad de \(copiedCount) carpeta(s) guardada en \(destRoot.path)")
                    self.notify("Copia de seguridad lista", "Se guardaron \(copiedCount) carpeta(s) de partidas.")
                } else {
                    self.backupMessage = "Encontré carpetas de partidas pero no pude copiarlas."
                }
            }
        }
    }

    /// Abre en Finder la carpeta donde se guardan las copias de seguridad.
    // MARK: - Organizar la carpeta del juego

    /// Comprime TODA la carpeta del juego tal cual está ahora mismo (juego
    /// base + mods instalados + cualquier otra cosa) en un .zip dentro de
    /// Backups, como red de seguridad antes de mover nada. Si algo queda
    /// mal después, este .zip tiene exactamente cómo estaba todo antes.
    func backupGameFolder(completion: ((Bool) -> Void)? = nil) {
        guard let gameFolder = gameFolderURL, !isBusy, !isBackingUpGameFolder else {
            completion?(false)
            return
        }
        isBackingUpGameFolder = true
        gameFolderBackupMessage = nil
        log("Haciendo copia de seguridad completa de la carpeta del juego antes de organizar...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: Self.backupsDir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let zipURL = Self.backupsDir.appendingPathComponent("Carpeta del juego - \(stamp).zip")
            let success = Self.zipFolder(at: gameFolder, to: zipURL)

            DispatchQueue.main.async {
                guard let self else { return }
                self.isBackingUpGameFolder = false
                if success {
                    self.gameFolderBackupMessage = "✔ Copia de seguridad completa guardada."
                    self.log("✔ Copia de seguridad completa de la carpeta del juego guardada en \(zipURL.path)")
                } else {
                    self.gameFolderBackupMessage = "✘ No pude hacer la copia de seguridad completa."
                    self.log("✘ No pude comprimir la carpeta del juego para el respaldo.")
                }
                completion?(success)
            }
        }
    }

    static func zipFolder(at source: URL, to destinationZip: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destinationZip.path]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Nombres (en minúsculas) de archivos de texto "de un solo uso" que
    /// casi siempre vienen sueltos junto a un mod — instrucciones de
    /// instalación, changelog, enlaces — y que ni el juego ni ningún mod
    /// busca por su ruta en tiempo de ejecución. A propósito NO se tocan
    /// carpetas (CustomMode, Json, ModScript, PoseMod, etc.) ni archivos
    /// .dll/.exe/.bat/.ini/.log: esos sí pueden tener una ruta fija que
    /// algún mod espera encontrar exactamente donde está, y moverlos
    /// podría romperlo sin ningún aviso.
    static let safeToArchiveDocNames: Set<String> = [
        "__for youtubers__.txt",
        "change_log.txt",
        "how to install posemod.txt",
        "readme.txt",
        "tikfinity instructions.txt",
        "azerty workaround.txt",
    ]

    /// Hace un respaldo completo primero (`backupGameFolder`) y, solo si
    /// sale bien, mueve a una subcarpeta "Documentación y extras" los
    /// archivos de texto sueltos que son pura documentación. El resto de
    /// la carpeta (carpetas de mods, datos del juego, ejecutables) se deja
    /// tal cual a propósito: no hay forma de saber desde aquí qué ruta
    /// espera cada mod de terceros, así que moverlas es un riesgo real de
    /// romperlos.
    func organizeGameFolder() {
        guard let gameFolder = gameFolderURL, !isBusy, !isOrganizingGameFolder else { return }
        isOrganizingGameFolder = true
        organizeGameFolderMessage = nil

        backupGameFolder { [weak self] backedUp in
            guard let self else { return }
            guard backedUp else {
                self.isOrganizingGameFolder = false
                self.organizeGameFolderMessage = "No organicé nada: la copia de seguridad no se pudo completar, así que no quise arriesgarme a mover archivos sin un respaldo."
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let docsFolder = gameFolder.appendingPathComponent("Documentación y extras")
                var moved: [String] = []
                var failed: [String] = []

                if let contents = try? fm.contentsOfDirectory(at: gameFolder, includingPropertiesForKeys: [.isDirectoryKey]) {
                    for item in contents {
                        let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                        guard !isDir else { continue }
                        guard Self.safeToArchiveDocNames.contains(item.lastPathComponent.lowercased()) else { continue }

                        try? fm.createDirectory(at: docsFolder, withIntermediateDirectories: true)
                        let dest = docsFolder.appendingPathComponent(item.lastPathComponent)
                        do {
                            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                            try fm.moveItem(at: item, to: dest)
                            moved.append(item.lastPathComponent)
                        } catch {
                            failed.append(item.lastPathComponent)
                        }
                    }
                }

                DispatchQueue.main.async {
                    self.isOrganizingGameFolder = false
                    if moved.isEmpty {
                        self.organizeGameFolderMessage = "No encontré archivos sueltos de documentación para mover — tu carpeta ya está tan ordenada como se puede, sin arriesgar ningún mod."
                    } else {
                        self.organizeGameFolderMessage = "✔ Moví \(moved.count) archivo(s) de documentación a \"Documentación y extras\". El resto (carpetas de mods, datos del juego) se dejó tal cual, para no arriesgarse a romper algo."
                    }
                    let movedList = moved.isEmpty ? "ninguno" : moved.joined(separator: ", ")
                    self.log("Organización de la carpeta del juego — movidos: \(movedList)." + (failed.isEmpty ? "" : " No se pudieron mover: \(failed.joined(separator: ", "))."))
                }
            }
        }
    }

    func openBackupsFolder() {
        #if canImport(AppKit)
        try? FileManager.default.createDirectory(at: Self.backupsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.backupsDir)
        #endif
    }

}
