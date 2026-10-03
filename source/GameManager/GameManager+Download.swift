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
    // MARK: - Descarga del juego

    func downloadGame() {
        guard !isBusy else { return }
        isBusy = true
        canCancelInstall = true
        installWasCancelled = false
        downloadProgressFraction = nil
        downloadProgressText = nil
        progressText = "Descargando Yandere Simulator..."
        statusLines.removeAll()
        log(progressText)

        let zipPath = Self.appDir.appendingPathComponent("yansim.zip")
        try? FileManager.default.removeItem(at: zipPath)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let remoteSignature = Self.remoteFileSignature(Self.downloadURL)
            let expectedTotal = remoteSignature?.size

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            // Cabeceras "no-cache" para no bajar una copia vieja que haya
            // quedado guardada en un CDN por delante del servidor real.
            task.arguments = [
                "-L", "--fail",
                "-H", "Cache-Control: no-cache",
                "-H", "Pragma: no-cache",
                "-o", zipPath.path, Self.downloadURL
            ]

            DispatchQueue.main.async {
                self.downloadTask = task
                self.startDownloadProgressPolling(fileURL: zipPath, expectedTotal: expectedTotal)
            }

            do {
                try task.run()
            } catch {
                DispatchQueue.main.async {
                    self.finishDownload(success: false, message: "No pude iniciar la descarga: \(error.localizedDescription)")
                }
                return
            }
            task.waitUntilExit()
            DispatchQueue.main.async { self.stopDownloadProgressPolling() }

            if self.installWasCancelled {
                DispatchQueue.main.async { self.finishDownload(success: false, cancelled: true) }
                return
            }
            guard task.terminationStatus == 0 else {
                DispatchQueue.main.async {
                    self.finishDownload(success: false, message: "Falló la descarga (código \(task.terminationStatus)).")
                }
                return
            }

            DispatchQueue.main.async {
                self.log("Descarga completa. Comprobando que el archivo esté íntegro...")
                self.progressText = "Comprobando descarga..."
                self.downloadProgressFraction = nil
                self.downloadProgressText = nil
            }

            // Antes de extraer, comprobamos que el .zip no haya quedado a
            // medias (por ejemplo, por una conexión que se cayó a mitad de
            // la descarga). Sin esto, un .zip corrupto se extraía de todas
            // formas, y el resultado era una carpeta del juego incompleta
            // cuyos síntomas (texturas o archivos faltantes) eran muy
            // confusos de diagnosticar después.
            guard Self.verifyZipIntegrity(zipPath.path) else {
                try? FileManager.default.removeItem(at: zipPath)
                DispatchQueue.main.async {
                    self.finishDownload(success: false, message: "El archivo descargado llegó incompleto o dañado. Vuelve a intentar la descarga.")
                }
                return
            }

            DispatchQueue.main.async {
                self.log("Archivo íntegro. Extrayendo...")
                self.progressText = "Extrayendo..."
            }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: zipPath.path),
               let size = attrs[.size] as? Int {
                Self.lastDownloadedSize = size
            }
            Self.lastDownloadedLastModified = remoteSignature?.lastModified

            do {
                try Self.unzipWithProgress(zipPath.path, to: Self.gameDir.path) { extracted, total in
                    DispatchQueue.main.async {
                        if let total, total > 0 {
                            // Sí sabemos el total: barra con porcentaje real.
                            let fraction = min(1.0, Double(extracted) / Double(total))
                            self.downloadProgressFraction = fraction
                            self.downloadProgressText = "\(Int(fraction * 100))% (\(extracted) de \(total) archivos)"
                        } else {
                            // No se pudo contar el total de antemano (puede
                            // pasar con .zips grandes): en vez de dejar la
                            // interfaz sin ninguna señal, mostramos cuántos
                            // archivos van, para que se note que sigue
                            // avanzando y no se siente trabado.
                            self.downloadProgressFraction = nil
                            self.downloadProgressText = "\(extracted) archivos extraídos..."
                        }
                    }
                }
                try? FileManager.default.removeItem(at: zipPath)
                DispatchQueue.main.async { self.finishDownload(success: true) }
            } catch {
                DispatchQueue.main.async {
                    self.finishDownload(success: false, message: "Falló la extracción: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Revisa cada cierto rato cuánto pesa el .zip que está bajando curl
    /// (nadie más lo está escribiendo) y lo compara con el tamaño total
    /// esperado (si se pudo averiguar de antemano) para armar una barra de
    /// progreso real en vez de dejar solo un spinner indeterminado.
    func startDownloadProgressPolling(fileURL: URL, expectedTotal: Int?) {
        downloadPollTimer?.invalidate()
        downloadPollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int ?? 0
            if let total = expectedTotal, total > 0 {
                self.downloadProgressFraction = min(1.0, Double(size) / Double(total))
                self.downloadProgressText = "\(Self.formatBytes(size)) de \(Self.formatBytes(total))"
            } else {
                self.downloadProgressFraction = nil
                self.downloadProgressText = "\(Self.formatBytes(size)) descargados"
            }
        }
    }

    func stopDownloadProgressPolling() {
        downloadPollTimer?.invalidate()
        downloadPollTimer = nil
    }

    func finishDownload(success: Bool, cancelled: Bool = false, message: String? = nil) {
        isBusy = false
        canCancelInstall = false
        downloadTask = nil
        downloadProgressFraction = nil
        downloadProgressText = nil
        installWasCancelled = false
        if cancelled {
            log("Descarga cancelada.")
            try? FileManager.default.removeItem(at: Self.appDir.appendingPathComponent("yansim.zip"))
            return
        }
        if success {
            updateAvailable = false
            refresh()
            log("✔ Juego instalado en \(Self.gameDir.path)")
            notify("Yandere Simulator instalado", "El juego ya está listo para jugar.")
        } else {
            log("✘ \(message ?? "Falló la descarga o la extracción.")")
        }
    }

    static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Reparar

    /// Vuelve a copiar el parche de Unity 6 aunque ya exista una versión
    /// (por si quedó a medias o corrupta). No borra nada del juego.
    func repairShim() {
        guard let exe = gameExePath else { return }
        let dest = URL(fileURLWithPath: exe)
            .deletingLastPathComponent()
            .appendingPathComponent(Self.shimName)
        try? FileManager.default.removeItem(at: dest)
        installShimIfNeeded(nextTo: exe)
        log("✔ Parche de Unity 6 vuelto a copiar junto al juego.")
    }

    /// Borra la copia del juego y te deja lista la carpeta para descargarlo
    /// de nuevo. Solo funciona si el juego está en la carpeta que maneja
    /// esta app (no toca un .exe que hayas elegido a mano en otro lugar,
    /// por seguridad).
    func reinstallGame() {
        guard let exe = gameExePath, exe.hasPrefix(Self.gameDir.path), !isBusy else {
            log("✘ Solo puedo reinstalar el juego si lo descargaste con el botón 'Descargar el juego'.")
            return
        }
        try? FileManager.default.removeItem(at: Self.gameDir)
        try? FileManager.default.createDirectory(at: Self.gameDir, withIntermediateDirectories: true)
        Self.savedExePath = nil
        log("Carpeta del juego borrada. Usa 'Descargar el juego' para instalarlo de nuevo.")
        refresh()
    }

    // MARK: - Actualizaciones

    /// Pregunta al servidor qué tan pesado es el .zip ahora mismo (sin
    /// descargarlo) y lo compara con el tamaño que tenía la última vez que
    /// lo bajamos. Si cambió, probablemente hay una versión nueva. Solo
    /// aplica si el juego se instaló con el botón "Descargar el juego" de
    /// esta app (no tenemos nada que comparar si el usuario eligió un .exe
    /// que ya tenía de antes).
    ///
    /// `manual` distingue el chequeo silencioso que se hace solo al abrir
    /// la app (no queremos mensajes emergentes cada vez que la abres) del
    /// chequeo que el usuario pide con el botón "Buscar actualizaciones",
    /// donde sí esperamos alguna respuesta aunque no haya nada nuevo.
    func checkForUpdate(manual: Bool = false) {
        updateCheckMessage = nil

        guard let exe = gameExePath, exe.hasPrefix(Self.gameDir.path) else {
            if manual {
                updateCheckMessage = "Esto solo funciona si descargaste el juego con el botón \"Descargar el juego\" de aquí."
            }
            return
        }
        guard let lastSize = Self.lastDownloadedSize else {
            if manual {
                updateCheckMessage = "Todavía no tengo con qué comparar. Vuelve a descargar el juego una vez desde aquí y luego podré avisarte de futuras actualizaciones."
            }
            return
        }

        isCheckingUpdate = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let remoteSignature = Self.remoteFileSignature(Self.downloadURL)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCheckingUpdate = false
                guard let remoteSignature else {
                    if manual {
                        self.updateCheckMessage = "No pude conectarme para revisar. Intenta de nuevo en un momento."
                    }
                    return
                }
                let wasAlreadyAvailable = self.updateAvailable
                // Nos quedamos solo con el tamaño como señal (no con la
                // fecha "Last-Modified"): algunos servidores devuelven esa
                // fecha de forma inconsistente o la ponen en el momento de
                // la petición, lo que terminaría marcando "actualización
                // disponible" todo el tiempo aunque no haya nada nuevo.
                self.updateAvailable = remoteSignature.size != lastSize
                if manual {
                    self.updateCheckMessage = self.updateAvailable
                        ? nil
                        : "Ya tienes la última versión instalada."
                } else if self.updateAvailable && !wasAlreadyAvailable {
                    // Solo avisamos por notificación cuando la revisión fue
                    // automática (en segundo plano) y de verdad es una
                    // novedad — si el usuario ya la vio (revisión manual, o
                    // ya estaba marcada), no hace falta repetírselo.
                    self.notify("Actualización disponible", "Hay una versión nueva de Yandere Simulator. Descárgala desde Jugar.")
                }
            }
        }
    }

    static func remoteContentLength(_ urlString: String) -> Int? {
        remoteFileSignature(urlString)?.size
    }

    /// Tamaño y fecha de modificación del .zip remoto, en una sola
    /// petición HEAD. Mandamos cabeceras "no-cache" por si hay un CDN por
    /// delante que guarda en caché la respuesta de esta URL (YandereDev no
    /// le cambia el nombre al archivo con cada versión). A propósito NO le
    /// agregamos un parámetro distinto a la URL en cada consulta (tipo
    /// "?_=12345") para "romper" la caché: algunos servidores responden
    /// con un error o una página distinta cuando la URL no es exactamente
    /// la esperada, lo que haría ver una "actualización" falsa todo el
    /// tiempo en vez de arreglar el problema.
    static func remoteFileSignature(_ urlString: String) -> (size: Int, lastModified: String?)? {
        let command = "curl -sIL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' '\(urlString)'"
        guard let output = runShell(command) else { return nil }

        var size: Int?
        var lastModified: String?
        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                if let parsed = Int(value) { size = parsed }
            } else if lower.hasPrefix("last-modified:") {
                lastModified = line.dropFirst("last-modified:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let size else { return nil }
        return (size, lastModified)
    }

}
