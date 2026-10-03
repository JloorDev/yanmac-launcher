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
    // MARK: - Verificar archivos del juego

    /// Revisa que los archivos y carpetas más importantes del juego sigan
    /// junto al .exe, y además recorre archivo por archivo la carpeta de
    /// datos del juego (YandereSimulator_Data) buscando archivos vacíos o
    /// corruptos — no solo que la carpeta exista. No repara nada por sí
    /// sola — si algo falta o aparece dañado, la solución es reinstalar
    /// el juego.
    ///
    /// Esa carpeta de datos puede tener varios miles de archivos, así que
    /// revisarla de verdad tarda unos segundos: va a segundo plano y
    /// reporta progreso real (`verifyProgressFraction`) en vez de dejar
    /// solo un spinner sin ninguna señal de cuánto falta.
    func verifyGameFiles() {
        guard let exe = gameExePath, !isBusy, !isVerifying else { return }
        isVerifying = true
        verifyResults = nil
        verifyProgressFraction = 0

        let gameFolder = URL(fileURLWithPath: exe).deletingLastPathComponent()
        let exeBaseName = (exe as NSString).lastPathComponent
            .replacingOccurrences(of: ".exe", with: "", options: .caseInsensitive)
        let dataFolderName = "\(exeBaseName)_Data"
        let dataFolder = gameFolder.appendingPathComponent(dataFolderName)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var results: [String] = []

            for name in ["UnityPlayer.dll", Self.shimName] {
                let path = gameFolder.appendingPathComponent(name).path
                results.append(fm.fileExists(atPath: path) ? "✔ \(name)" : "✘ Falta \(name)")
            }

            guard fm.fileExists(atPath: dataFolder.path) else {
                results.append("✘ Falta la carpeta \(dataFolderName)")
                DispatchQueue.main.async { self?.finishVerify(results: results) }
                return
            }

            // Primera pasada: solo contar cuántos archivos hay, para poder
            // mostrar una barra de progreso real en la segunda (en vez de
            // ir calculando el total a medida que avanzamos, que daría un
            // porcentaje que salta de un lado a otro).
            let allFiles: [URL] = (fm.enumerator(at: dataFolder, includingPropertiesForKeys: [.isRegularFileKey])
                .map { Array($0) } ?? [])
                .compactMap { $0 as? URL }
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }

            let total = allFiles.count
            var emptyFiles: [String] = []
            for (index, fileURL) in allFiles.enumerated() {
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size == 0 {
                    emptyFiles.append(fileURL.lastPathComponent)
                }
                // Actualizar la barra en cada archivo sería innecesario
                // (miles de saltos al hilo principal por segundo); con
                // cada 25 alcanza para que se vea fluida.
                if total > 0, index % 25 == 0 || index == total - 1 {
                    let fraction = Double(index + 1) / Double(total)
                    DispatchQueue.main.async { self?.verifyProgressFraction = fraction }
                }
            }

            results.append("✔ Carpeta \(dataFolderName) (\(total) archivo(s) revisado(s))")
            if !emptyFiles.isEmpty {
                let preview = emptyFiles.prefix(5).joined(separator: ", ")
                let suffix = emptyFiles.count > 5 ? "…" : ""
                results.append("✘ \(emptyFiles.count) archivo(s) vacío(s) o corrupto(s): \(preview)\(suffix)")
            }

            DispatchQueue.main.async { self?.finishVerify(results: results) }
        }
    }

    func finishVerify(results: [String]) {
        var results = results
        let hasProblems = results.contains { $0.hasPrefix("✘") }
        results.append("")
        results.append(hasProblems
            ? "Falta algo. Usa 'Reinstalar el juego' para descargarlo de nuevo."
            : "Todo parece estar en orden.")

        verifyResults = results
        isVerifying = false
        verifyProgressFraction = nil
        log("== Verificación de archivos del juego ==")
        for line in results { log(line) }
        notify(
            "Verificación de archivos terminada",
            hasProblems ? "Falta algo — revisa Herramientas para más detalles." : "Todo parece estar en orden."
        )
    }

    // MARK: - Restablecer ajustes del juego

    /// Unity guarda las preferencias del juego (resolución, calidad
    /// gráfica, controles, y switches propios como activar/desactivar el
    /// pasto) en el registro de Windows — dentro del WINEPREFIX, en el
    /// archivo `user.reg`. Si una de esas opciones deja el juego pegado
    /// (como pasó con el pasto), no hay manera de arreglarlo desde dentro
    /// del juego porque ni siquiera llega a abrir. Esto busca esa clave y
    /// la borra, para que la próxima vez el juego abra "de fábrica", como
    /// la primera vez — sin tocar las partidas guardadas (viven en una
    /// carpeta aparte) ni nada de la carpeta del juego.
    func resetGameSettings() {
        guard let wine = winePath, !isBusy, !isResettingSettings else { return }
        isResettingSettings = true
        resetSettingsMessage = nil
        log("Restableciendo los ajustes del juego a los valores de fábrica...")

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        env["WINEPREFIX"] = Self.winePrefixPath.path
        env["WINEDEBUG"] = "-all"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deletedCount = Self.deleteYandereRegistryKeys(wine: wine, env: env)

            DispatchQueue.main.async {
                guard let self else { return }
                self.isResettingSettings = false
                if deletedCount > 0 {
                    self.resetSettingsMessage = "✔ Ajustes del juego restablecidos."
                    self.log("✔ Se borraron \(deletedCount) clave(s) de configuración. La próxima vez que abras el juego, va a pedir configurar todo de nuevo (resolución, gráficos, controles), como la primera vez.")
                    self.notify("Ajustes del juego restablecidos", "El juego va a abrir \"de fábrica\" la próxima vez.")
                } else {
                    self.resetSettingsMessage = "No encontré ajustes guardados para borrar."
                    self.log("No encontré ninguna clave de configuración del juego en el registro. Puede que ya esté en su configuración por defecto, o que el juego guarde sus ajustes de otra forma.")
                }
            }
        }
    }

    /// Busca en `user.reg` (el archivo de registro de WINE) cualquier
    /// clave bajo `Software\` cuyo nombre contenga "yandere" — ahí es
    /// donde Unity guarda las preferencias de este juego. Nos quedamos
    /// solo con el primer nivel (la "empresa"), para borrar de una vez
    /// todo lo que tenga adentro (la clave del "producto" y todo lo demás).
    static func findYandereRegistryKeys() -> [String] {
        let userRegPath = winePrefixPath.appendingPathComponent("user.reg")
        guard let contents = try? String(contentsOf: userRegPath, encoding: .utf8) else { return [] }

        var keys: [String] = []
        for line in contents.components(separatedBy: "\n") {
            guard line.hasPrefix("["), let closeIndex = line.firstIndex(of: "]") else { continue }
            let rawKey = String(line[line.index(after: line.startIndex)..<closeIndex])
            let key = rawKey.replacingOccurrences(of: "\\\\", with: "\\")
            guard key.lowercased().hasPrefix("software\\"), key.lowercased().contains("yandere") else { continue }

            let parts = key.components(separatedBy: "\\")
            guard parts.count >= 2 else { continue }
            let topLevel = parts[0] + "\\" + parts[1]
            if !keys.contains(topLevel) {
                keys.append(topLevel)
            }
        }
        return keys
    }

    /// Borra (con `wine reg delete`) cada clave que encontró
    /// `findYandereRegistryKeys()`. Devuelve cuántas se borraron con éxito.
    static func deleteYandereRegistryKeys(wine: String, env: [String: String]) -> Int {
        var deletedCount = 0
        for key in findYandereRegistryKeys() {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: wine)
            task.arguments = ["reg", "delete", "HKEY_CURRENT_USER\\" + key, "/f"]
            task.environment = env
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    deletedCount += 1
                }
            } catch {
                // Si una falla, seguimos con las demás.
            }
        }
        return deletedCount
    }

    // MARK: - Instalar fuentes de Windows (arregla texto invisible del HUD)

    static func findWinetricks() -> String? {
        let fm = FileManager.default
        for candidate in winetricksCandidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let found = runShell("command -v winetricks"), !found.isEmpty {
            return found
        }
        return nil
    }

    /// Encuentra winetricks, instalándolo primero con Homebrew (junto con
    /// cabextract, que necesita para extraer las fuentes) si todavía no
    /// está. Debe llamarse desde un hilo en segundo plano. `logLine` recibe
    /// cada línea de progreso para mandarla al registro desde quien llama
    /// (en el hilo principal); se usa solo si hay que instalar algo.
    static func findOrInstallWinetricks(logLine: @escaping (String) -> Void) -> String? {
        if let found = findWinetricks() { return found }
        guard let brew = findBrew() else { return nil }
        logLine("winetricks no estaba instalado. Instalándolo con Homebrew...")
        let installResult = runProcessCapture(brew, ["install", "winetricks", "cabextract"])
        logLine(installResult)
        return findWinetricks()
    }

    /// Unity dibuja parte del texto de la interfaz (como el HUD del juego)
    /// usando fuentes del sistema operativo — Arial, Tahoma, etc. — que
    /// WINE no trae instaladas por defecto. Sin ellas, ese texto se dibuja
    /// con una fuente vacía y parece que "no está". `winetricks allfonts`
    /// instala el paquete completo de fuentes de Windows dentro del
    /// WINEPREFIX (incluye lo que trae el paquete básico "corefonts" más
    /// fuentes adicionales como Tahoma o Verdana, que varias partes del
    /// HUD necesitan).
    ///
    /// Esto se llama solo una vez automáticamente (ver `fontsAutoInstallAttempted`
    /// en `refresh()`), así que ya no hace falta que nadie se acuerde de
    /// venir a instalar esto a mano. El botón de Herramientas que llama a
    /// esta misma función sigue ahí solo como repuesto, por si la
    /// instalación automática falló o algo se corrompió.
    ///
    /// Importante: esto solo ayuda con texto que dependa de fuentes del
    /// sistema (como el HUD). El texto de los diálogos del juego usa
    /// TextMeshPro, que trae su propia fuente incluida dentro del juego
    /// (ver notas de investigación más abajo) — no depende de esto.
    ///
    /// `silent` evita mandar una notificación emergente y mensajes de
    /// progreso "ruidosos"; se usa en la instalación automática para que
    /// no se sienta como que algo inesperado está pasando de fondo.
    func installFonts(verb: String = "allfonts", silent: Bool = false) {
        guard !isBusy, !isInstallingFonts else { return }
        isInstallingFonts = true
        fontsInstallMessage = nil
        if !silent {
            log("Instalando fuentes de Windows (\(verb)) para arreglar texto que no aparece...")
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        env["WINEPREFIX"] = Self.winePrefixPath.path

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let winetricks = Self.findOrInstallWinetricks(logLine: { line in
                DispatchQueue.main.async { self?.log(line) }
            }) else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isInstallingFonts = false
                    self.fontsInstallMessage = "No pude instalar winetricks. Revisa la Consola para más detalles."
                    self.log("✘ No pude instalar las fuentes de Windows (no encontré ni pude instalar winetricks).")
                }
                return
            }

            // "-q" evita ventanas emergentes de progreso de winetricks (que
            // se verían raras dentro de este flujo), y sigue mostrando el
            // avance por texto, que capturamos para la consola.
            let result = Self.runProcessCapture(winetricks, ["-q", verb])

            DispatchQueue.main.async {
                guard let self else { return }
                self.isInstallingFonts = false
                self.log(result)
                if result.lowercased().contains("error") {
                    self.fontsInstallMessage = "Algo falló al instalar las fuentes. Revisa la Consola para más detalles."
                    self.log("✘ winetricks reportó un error instalando \(verb).")
                    if !silent {
                        self.notify("Falló la instalación de fuentes", "Revisa la Consola para más detalles.")
                    }
                } else {
                    self.fontsInstallMessage = "✔ Fuentes instaladas (\(verb))."
                    self.log("✔ \(verb) instalado en el WINEPREFIX.")
                    if !silent {
                        self.notify("Fuentes de Windows instaladas", "Abre el juego de nuevo para ver si el texto ya aparece.")
                    }
                }
            }
        }
    }

}
