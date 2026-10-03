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
    // MARK: - Utilidades

    func log(_ text: String) {
        statusLines.append(text)
    }

    func clearLog() {
        statusLines.removeAll()
    }

    func copyLogToClipboard() {
        #if canImport(AppKit)
        let text = statusLines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Junta versión de la app, de WINE, tus ajustes gráficos actuales, y
    /// las últimas líneas del registro de la última vez que jugaste, en un
    /// solo texto listo para pegar donde vayas a reportar un problema — sin
    /// tener que ir armándolo a mano cada vez.
    func copyDiagnosticReportToClipboard() {
        #if canImport(AppKit)
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let wine = wineVersionString ?? "no detectado"
        let profile = GraphicsProfile.allCases.first {
            $0.graphicsModeIndex == selectedModeIndex && $0.reduceMetalValidation == reduceMetalValidation
        }?.label ?? "Personalizado"
        let lastLog = Self.tail(currentSessionLogFile, lines: 40)

        let report = """
            YanMac Launcher \(Self.appVersionString)
            macOS: \(macOS)
            WINE: \(wine)
            Perfil de gráficos: \(profile) (modo: \(graphicsModes[selectedModeIndex].label), validación de Metal reducida: \(reduceMetalValidation ? "sí" : "no"))

            Últimas líneas del registro:
            \(lastLog.isEmpty ? "(sin registro todavía — juega una vez antes de reportar)" : lastLog)
            """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        reportCopiedMessage = "✔ Copiado. Pégalo donde quieras reportar el problema."
        #endif
    }

    static func tail(_ url: URL, lines: Int) -> String {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let allLines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return allLines.suffix(lines).joined(separator: "\n")
    }

    static func runShell(_ command: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    static func runProcess(_ executable: String, _ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw NSError(
                domain: "YansimLauncher",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) terminó con código \(task.terminationStatus)"]
            )
        }
    }

    /// Igual que runProcess, pero devuelve la salida como texto en vez de
    /// lanzar una excepción (útil para mostrar en el panel de registro).
    static func runProcessCapture(_ executable: String, _ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "No se pudo ejecutar \(executable): \(error.localizedDescription)"
        }
    }

    /// Busca un porcentaje (p. ej. "73.2%" o "100%") dentro de una línea de
    /// progreso de curl/Homebrew, para convertir su salida de texto en una
    /// barra de progreso real. Las líneas de "tap" o de instalar fórmulas
    /// no suelen traer esto — cuando no aparece ninguno, `nil`, y quien
    /// llama deja la barra como indeterminada para ese tramo.
    static func parsePercentage(from line: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s*%"#) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let numberRange = Range(match.range(at: 1), in: line),
              let value = Double(line[numberRange]) else { return nil }
        return min(1.0, max(0.0, value / 100.0))
    }

    /// Cuántas entradas (archivos y carpetas) tiene un .zip, usando
    /// `unzip -Z1` (un nombre por línea, sin encabezados). Se usa para
    /// calcular progreso real al extraer — no hace falta que sea exacto,
    /// solo una base razonable para la barra. Con .zips de varios GB, esta
    /// sola consulta a veces tarda muchísimo (incluso más que la propia
    /// extracción) — `timeout` evita quedarnos esperando para siempre: si
    /// no contesta a tiempo, se mata el proceso y se sigue sin total (quien
    /// llama usa el contador en vivo en su lugar).
    static func zipEntryCount(_ zipPath: String, timeout: TimeInterval = 20) -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-Z1", zipPath]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in semaphore.signal() }

        do {
            try task.run()
        } catch {
            return nil
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let count = text.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        return count > 0 ? count : nil
    }

    /// Revisa que un .zip esté completo y no corrupto ANTES de intentar
    /// extraerlo, usando `unzip -t` (prueba la integridad de cada entrada
    /// sin escribir nada a disco). Esto evita el caso en el que una
    /// descarga se cortó a la mitad (por ejemplo, por una conexión que se
    /// cayó) y acabamos con una carpeta del juego a medio extraer, con
    /// archivos faltantes que después se ven como errores confusos al
    /// jugar. Debe llamarse desde un hilo en segundo plano — puede tardar
    /// unos segundos con un .zip grande.
    ///
    /// El viejo `unzip` de macOS puede quedarse colgado para siempre con
    /// algunos .zips de varios GB (lo vimos con `zipEntryCount`), así que
    /// esto también tiene un límite de tiempo. Si se agota, en vez de
    /// bloquear la descarga entera con un falso "está corrupto", seguimos
    /// adelante sin confirmar — la extracción (que ya usa `ditto`, no
    /// `unzip`) va a fallar igual de forma clara si el archivo de verdad
    /// estaba dañado, así que no perdemos esa protección, solo la
    /// adelantamos un paso.
    static func verifyZipIntegrity(_ zipPath: String, timeout: TimeInterval = 20) -> Bool {
        guard FileManager.default.fileExists(atPath: zipPath) else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-t", zipPath]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in semaphore.signal() }

        do {
            try task.run()
        } catch {
            return false
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            return true
        }

        return task.terminationStatus == 0
    }

    /// Extrae un .zip mandando progreso real a `onProgress` en cada archivo
    /// que termina de extraerse, en vez de solo un spinner indeterminado
    /// mientras no se sabe cuánto va a tardar. Manda siempre cuántos
    /// archivos van (`extracted`), y además el total (`total`) cuando se
    /// pudo contar de antemano con `zipEntryCount` — quien llama decide si
    /// muestra una barra con porcentaje (cuando hay total) o solo el
    /// contador en vivo (cuando no). Antes, si no se lograba contar el
    /// total, `onProgress` nunca se llamaba y la interfaz se quedaba con
    /// un spinner sin ninguna señal de que algo seguía pasando — con
    /// .zips grandes (miles de archivos chicos, como los del juego) eso se
    /// sentía como si estuviera trabado aunque estuviera avanzando bien.
    /// Debe llamarse desde un hilo en segundo plano — bloquea hasta que
    /// termina.
    static func unzipWithProgress(_ zipPath: String, to destPath: String, onProgress: @escaping (_ extracted: Int, _ total: Int?) -> Void) throws {
        // El total es "mejor esfuerzo": con .zips de varios GB, el propio
        // `unzip -Z1` a veces tarda muchísimo (o no vuelve) solo para
        // CONTAR las entradas, así que le ponemos un límite de tiempo y, si
        // no contesta a tiempo, seguimos sin número total (el contador en
        // vivo de abajo sigue funcionando igual).
        let total = zipEntryCount(zipPath, timeout: 20)

        // `ditto` es la herramienta de archivos que usa el propio macOS
        // (Finder la usa para "Descomprimir"), y maneja mucho mejor que el
        // viejo `/usr/bin/unzip` los .zips grandes (varios GB, miles de
        // archivos) — `unzip` es una utilidad vieja que en la práctica se
        // vuelve extremadamente lenta o se cuelga con archivos así.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", "-V", zipPath, destPath]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        var extracted = 0
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lineCount = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            guard lineCount > 0 else { return }
            lock.lock()
            extracted += lineCount
            let extractedSoFar = extracted
            lock.unlock()
            onProgress(extractedSoFar, total)
        }

        try task.run()
        task.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        guard task.terminationStatus == 0 else {
            throw NSError(
                domain: "YansimLauncher",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "ditto terminó con código \(task.terminationStatus)"]
            )
        }
    }

    func runInTerminal(_ command: String) {
        #if canImport(AppKit)
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        var error: NSDictionary?
        if let script = NSAppleScript(source: appleScript) {
            script.executeAndReturnError(&error)
        }
        #endif
    }
}
