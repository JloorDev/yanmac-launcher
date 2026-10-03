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
    // MARK: - Mods
    //
    // Yandere Simulator no tiene una API de mods: los mods "de verdad"
    // (como PoseMod) se instalan copiando un montón de archivos ENCIMA de
    // la carpeta del juego, sobreescribiendo lo que ya había — y a veces
    // agregan su propio .exe (PoseMod64.exe, etc.) que hay que abrir en
    // vez del original. Eso es sobreescribir de verdad, así que para poder
    // "desactivar" un mod sin arriesgar los archivos originales del juego,
    // esta carpeta hace dos cosas:
    //
    //  1. Guarda una copia de cada mod que subes en `Mods/<nombre>/`, con
    //     la MISMA estructura de carpetas que tendría al pegarlo dentro
    //     del juego (así sabemos exactamente qué archivos toca).
    //  2. La primera vez que un archivo del juego está por sobreescribirse,
    //     guarda una copia de cómo estaba ANTES en `Mods/.vanilla-backup/`
    //     (con esa misma estructura de carpetas), para poder devolverlo a
    //     ese estado si el mod se desactiva.
    //
    // Activar o desactivar cualquier mod recalcula TODO desde cero: primero
    // devuelve a su estado original cada archivo que algún mod instalado
    // toca, y luego vuelve a copiar encima los archivos de los mods que
    // sigan activados. Es un poco más de trabajo que solo mover un
    // archivo, pero evita casos raros (como dos mods tocando el mismo
    // archivo) y es mucho más difícil de dejar a medias.

    static let vanillaBackupFolderName = ".vanilla-backup"

    /// Carpeta "Mods" junto al .exe del juego — aquí se guarda la copia de
    /// cada mod subido y el respaldo de los archivos originales. No la
    /// creamos hasta que hace falta.
    var modsDir: URL? {
        guard let exe = gameExePath else { return nil }
        return URL(fileURLWithPath: exe).deletingLastPathComponent().appendingPathComponent("Mods")
    }

    /// La carpeta del juego de verdad (donde vive el .exe) — es donde los
    /// mods activados terminan copiándose encima.
    var gameFolderURL: URL? {
        gameExePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
    }

    /// Solo el nombre del .exe que se va a abrir ahora mismo (sin la ruta
    /// completa), para comparar contra `availableExecutables` en el
    /// desplegable "Jugar con".
    var gameExeFileName: String? {
        gameExePath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Vuelve a mirar qué archivos ".exe" hay sueltos en la carpeta del
    /// juego (el original, y cualquiera que haya traído un mod activado).
    func refreshAvailableExecutables() {
        guard let folder = gameFolderURL else { availableExecutables = []; return }
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        availableExecutables = contents
            .map { $0.lastPathComponent }
            .filter { $0.lowercased().hasSuffix(".exe") }
            .sorted()
    }

    /// IDs (nombres de carpeta) de los mods marcados como activados. Se
    /// recuerda entre sesiones para poder reaplicarlos si hace falta.
    static var savedEnabledModIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "YansimLauncher.enabledModIDs") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "YansimLauncher.enabledModIDs") }
    }

    /// Vuelve a leer qué mods hay guardados dentro de "Mods" (cada
    /// subcarpeta, menos la de respaldo, es un mod) y si cada uno está
    /// activado según lo último que se guardó.
    func refreshMods() {
        guard let dir = modsDir else { mods = []; return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let enabledIDs = Self.savedEnabledModIDs
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        mods = contents
            .filter { $0.lastPathComponent != Self.vanillaBackupFolderName && !$0.lastPathComponent.hasPrefix(".") }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { url in ModEntry(id: url.lastPathComponent, isEnabled: enabledIDs.contains(url.lastPathComponent), itemURL: url) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Guarda lo que el usuario elija (con "Subir mod...") en su propia
    /// carpeta dentro de "Mods" — sin instalarlo todavía; hace falta
    /// activarlo para que se copie encima del juego. Un .zip se
    /// descomprime; una carpeta se copia por su CONTENIDO (como si
    /// pegaras lo de adentro directo en el juego); un archivo suelto se
    /// copia tal cual. Si el resultado queda con una sola carpeta
    /// "envolvente" adentro (típico de un .zip que mete todo dentro de
    /// una carpeta extra), se aplana un nivel automáticamente.
    func importMods(from urls: [URL]) {
        guard !isBusy, !isImportingMods else { return }
        guard let dir = modsDir else {
            log("✘ No pude importar el mod: todavía no se detectó el .exe del juego.")
            return
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log("✘ No pude crear la carpeta de Mods en \(dir.path): \(error.localizedDescription)")
            return
        }

        isImportingMods = true
        modImportMessage = nil
        modImportProgressFraction = 0
        modImportProgressText = nil

        // Un mod como PoseMod trae su propia copia completa de los datos
        // del juego — puede pesar cientos de MB y tardar varios segundos
        // en copiarse o descomprimirse. Antes esto corría en el mismo
        // hilo que dibuja la interfaz (se congelaba la app mientras
        // subía), y no había ninguna señal de avance. Ahora va a segundo
        // plano y reporta progreso real.
        let scopedURLs: [(url: URL, needsStop: Bool)] = urls.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }
        let total = scopedURLs.count

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var importedCount = 0

            for (index, entry) in scopedURLs.enumerated() {
                let url = entry.url
                defer { if entry.needsStop { url.stopAccessingSecurityScopedResource() } }

                let baseName = url.pathExtension.lowercased() == "zip"
                    ? url.deletingPathExtension().lastPathComponent
                    : url.lastPathComponent
                let destFolder = Self.uniqueURL(in: dir, baseName: baseName)

                DispatchQueue.main.async {
                    self?.modImportProgressText = total > 1 ? "\(baseName) (\(index + 1) de \(total))" : baseName
                }

                do {
                    try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                    if url.pathExtension.lowercased() == "zip" {
                        try Self.unzipWithProgress(url.path, to: destFolder.path) { extracted, zipTotal in
                            // Si no se pudo contar el total de entradas del
                            // .zip del mod de antemano, no tenemos con qué
                            // calcular una fracción — dejamos la barra tal
                            // como está (no retrocede) en vez de mandar un
                            // número sin sentido.
                            guard let zipTotal, zipTotal > 0 else { return }
                            let fraction = min(1.0, Double(extracted) / Double(zipTotal))
                            DispatchQueue.main.async {
                                self?.modImportProgressFraction = (Double(index) + fraction) / Double(total)
                            }
                        }
                    } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        for item in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                            try fm.copyItem(at: item, to: destFolder.appendingPathComponent(item.lastPathComponent))
                        }
                    } else {
                        try fm.copyItem(at: url, to: destFolder.appendingPathComponent(url.lastPathComponent))
                    }
                    Self.flattenSingleWrapperFolder(destFolder)
                    importedCount += 1
                } catch {
                    try? fm.removeItem(at: destFolder)
                    DispatchQueue.main.async {
                        self?.log("✘ No pude importar \"\(url.lastPathComponent)\": \(error.localizedDescription)")
                    }
                }

                DispatchQueue.main.async {
                    self?.modImportProgressFraction = Double(index + 1) / Double(total)
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isImportingMods = false
                self.modImportProgressFraction = nil
                self.modImportProgressText = nil
                self.modImportMessage = importedCount > 0
                    ? "✔ \(importedCount) mod(s) agregado(s). Actívalo(s) para instalarlos sobre el juego."
                    : "No se pudo agregar ningún mod. Revisa la Consola para más detalles."
                self.refreshMods()
            }
        }
    }

    /// Si `folder` contiene una sola carpeta y nada más, mueve el
    /// contenido de esa carpeta un nivel hacia arriba y borra la carpeta
    /// vacía que quedó — para cuando un .zip mete todo dentro de una
    /// carpeta extra en vez de los archivos sueltos.
    static func flattenSingleWrapperFolder(_ folder: URL) {
        let fm = FileManager.default
        for _ in 0..<3 {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            let visible = items.filter { !$0.lastPathComponent.hasPrefix(".") }
            guard visible.count == 1,
                  (try? visible[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
            let wrapper = visible[0]
            let inner = (try? fm.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil)) ?? []
            for item in inner {
                try? fm.moveItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
            }
            try? fm.removeItem(at: wrapper)
        }
    }

    /// Nombre de carpeta libre dentro de `dir`, agregando " 2", " 3"... si
    /// ya existe algo con ese nombre, en vez de sobreescribirlo.
    static func uniqueURL(in dir: URL, baseName: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(baseName)
        var attempt = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(baseName) \(attempt)")
            attempt += 1
        }
        return candidate
    }

    /// Todas las rutas relativas de archivos (no carpetas) dentro de
    /// `folder`, p. ej. ["PoseMod64.exe", "YandereSimulator_Data/x.dll"].
    static func relativeFilePaths(in folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        let basePath = folder.path
        var result: [String] = []
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDir else { continue }
            var relative = url.path
            if relative.hasPrefix(basePath) {
                relative = String(relative.dropFirst(basePath.count))
                if relative.hasPrefix("/") { relative.removeFirst() }
            }
            result.append(relative)
        }
        return result
    }

    /// El corazón de todo: recalcula desde cero qué archivos del juego
    /// deberían estar sobreescritos ahora mismo, según qué mods están
    /// activados en este momento. Se llama después de activar, desactivar,
    /// o borrar cualquier mod.
    func reapplyMods() {
        guard let gameFolder = gameFolderURL, let dir = modsDir else { return }
        let fm = FileManager.default
        let backupDir = dir.appendingPathComponent(Self.vanillaBackupFolderName)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let modFolders = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { $0.lastPathComponent != Self.vanillaBackupFolderName && !$0.lastPathComponent.hasPrefix(".") }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? []

        var pathsByMod: [String: [String]] = [:]
        var allPaths = Set<String>()
        for folder in modFolders {
            let paths = Self.relativeFilePaths(in: folder)
            pathsByMod[folder.lastPathComponent] = paths
            allPaths.formUnion(paths)
        }

        // 1. Asegurar que cada ruta que algún mod toca ya tenga su respaldo
        // de cómo estaba en el juego ANTES de instalar cualquier mod (si
        // el archivo no existía en el juego, lo marcamos igual, para saber
        // que hay que borrarlo — no "restaurarlo" — al desactivar).
        for relPath in allPaths {
            let backupPath = backupDir.appendingPathComponent(relPath)
            let neverExistedMarker = URL(fileURLWithPath: backupPath.path + ".neverexisted")
            guard !fm.fileExists(atPath: backupPath.path), !fm.fileExists(atPath: neverExistedMarker.path) else { continue }

            let current = gameFolder.appendingPathComponent(relPath)
            try? fm.createDirectory(at: backupPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: current.path) {
                try? fm.copyItem(at: current, to: backupPath)
            } else {
                fm.createFile(atPath: neverExistedMarker.path, contents: nil)
            }
        }

        // 2. Devolver cada ruta tocada a su estado original.
        for relPath in allPaths {
            let target = gameFolder.appendingPathComponent(relPath)
            let backupPath = backupDir.appendingPathComponent(relPath)
            let neverExistedMarker = URL(fileURLWithPath: backupPath.path + ".neverexisted")
            try? fm.removeItem(at: target)
            if fm.fileExists(atPath: backupPath.path) {
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: backupPath, to: target)
            }
            _ = neverExistedMarker // el archivo ya quedó borrado arriba; nada más que hacer.
        }

        // 3. Volver a copiar encima los mods que sigan activados, en orden
        // (si dos mods tocan el mismo archivo, gana el último).
        let enabledIDs = Self.savedEnabledModIDs
        var extraExeNames: [String] = []
        for folder in modFolders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = folder.lastPathComponent
            guard enabledIDs.contains(id) else { continue }
            let paths = pathsByMod[id] ?? []
            if paths.isEmpty {
                log("⚠️ El mod \"\(id)\" no tiene ningún archivo adentro — revisa que la carpeta \"Mods/\(id)\" no esté vacía.")
                continue
            }
            var copied = 0
            var failed: [String] = []
            for relPath in paths {
                let source = folder.appendingPathComponent(relPath)
                let target = gameFolder.appendingPathComponent(relPath)
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) {
                        try fm.removeItem(at: target)
                    }
                    try fm.copyItem(at: source, to: target)
                    copied += 1
                } catch {
                    failed.append("\(relPath) (\(error.localizedDescription))")
                }
                // Solo cuenta como "ejecutable alternativo" un .exe que vaya a
                // quedar SUELTO en la raíz de la carpeta del juego (sin "/" en
                // su ruta relativa) — que es lo único que escanea
                // `refreshAvailableExecutables()` para el desplegable "Jugar
                // con". Un .exe varios niveles adentro (como un navegador
                // empotrado que traiga el mod para alguna función interna)
                // nunca va a aparecer ahí, así que avisar de él solo
                // confunde.
                if relPath.lowercased().hasSuffix(".exe"), !relPath.contains("/") {
                    let exeName = (relPath as NSString).lastPathComponent
                    let currentExeName = gameExePath.map { (URL(fileURLWithPath: $0).lastPathComponent) }
                    if exeName != currentExeName { extraExeNames.append(exeName) }
                }
            }
            log("✔ Mod \"\(id)\" aplicado: \(copied) de \(paths.count) archivo(s) copiado(s) sobre el juego.")
            for f in failed {
                log("✘ No se pudo copiar \(f) del mod \"\(id)\".")
            }
        }

        refreshAvailableExecutables()

        if !extraExeNames.isEmpty {
            let names = extraExeNames.sorted().joined(separator: ", ")
            modImportMessage = "Este mod trae su propio ejecutable (\(names)). Elígelo en el desplegable \"Jugar con\" de la sección Jugar para que el mod tenga efecto."
        }
    }

    /// Activa o desactiva un mod (recalculando todo con `reapplyMods()`).
    /// Activa o desactiva un mod. Los mods de Yandere Simulator no suelen
    /// ser parches chiquitos: casi siempre traen su propia copia completa
    /// de los datos del juego (YandereSimulator_Data, UnityPlayer.dll,
    /// etc.), así que activar dos a la vez no los combina — termina
    /// mezclando archivos de versiones distintas del juego entre sí, lo
    /// cual puede romper ambos. Por eso solo uno puede estar activo a la
    /// vez: activar un mod apaga automáticamente cualquier otro que
    /// estuviera prendido.
    func toggleMod(_ mod: ModEntry) {
        let enabled: Set<String> = mod.isEnabled ? [] : [mod.id]
        Self.savedEnabledModIDs = enabled
        reapplyMods()
        refreshMods()
    }

    /// Apaga el mod activo (si hay alguno) y vuelve al juego sin mods.
    func disableAllMods() {
        guard !Self.savedEnabledModIDs.isEmpty else { return }
        Self.savedEnabledModIDs = []
        reapplyMods()
        refreshMods()
    }

    /// Quita un mod por completo: si estaba activado, primero devuelve a
    /// su estado original los archivos que tocaba, y recién después borra
    /// su copia guardada. No se puede deshacer — la interfaz ya pide
    /// confirmación antes de llamar esto.
    func deleteMod(_ mod: ModEntry) {
        var enabled = Self.savedEnabledModIDs
        let wasEnabled = enabled.contains(mod.id)
        enabled.remove(mod.id)
        Self.savedEnabledModIDs = enabled
        if wasEnabled { reapplyMods() }

        do {
            try FileManager.default.removeItem(at: mod.itemURL)
        } catch {
            log("✘ No pude quitar el mod \"\(mod.id)\": \(error.localizedDescription)")
        }
        refreshMods()
    }

    /// Abre en Finder la carpeta "Mods" (creándola si todavía no existe).
    func openModsFolder() {
        #if canImport(AppKit)
        guard let dir = modsDir else {
            log("✘ No pude abrir la carpeta de Mods: todavía no se detectó el .exe del juego.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log("✘ No pude crear la carpeta de Mods en \(dir.path): \(error.localizedDescription)")
            return
        }
        if !NSWorkspace.shared.open(dir) {
            log("✘ No pude abrir la carpeta de Mods en Finder (\(dir.path)).")
        }
        #endif
    }

}
