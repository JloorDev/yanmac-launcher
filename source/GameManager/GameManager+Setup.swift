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
    // MARK: - Instalar WINE (Homebrew)

    func installHomebrewInstructions() -> String {
        "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    }

    func openHomebrewInstallInTerminal() {
        let script = installHomebrewInstructions()
        runInTerminal(script)
    }

    /// Lo que llama el botón "Ya lo instalé, revisar de nuevo": a diferencia
    /// de un `refresh()` silencioso, si Homebrew sigue sin aparecer deja un
    /// mensaje explicando qué revisar, en vez de dejar al usuario mirando
    /// la misma pantalla sin ninguna pista de qué falló.
    func recheckHomebrew() {
        refresh()
        if brewPath == nil {
            homebrewCheckMessage = "Todavía no encuentro Homebrew instalado. Si acabas de terminar el comando en Terminal, confirma que no se haya quedado esperando tu contraseña a la mitad, y que haya terminado sin errores en rojo."
        } else {
            homebrewCheckMessage = nil
        }
    }

    /// Cancela la instalación de WINE o la descarga del juego que esté en
    /// curso ahora mismo. Mejor esfuerzo: a brew le manda la señal de
    /// terminar, pero como instala cosas por su cuenta, puede dejar algo a
    /// medias — está bien, se puede volver a intentar después.
    func cancelInstall() {
        guard isBusy, canCancelInstall else { return }
        installWasCancelled = true
        runningInstallProcess?.terminate()
        downloadTask?.terminate()
        downloadPollTimer?.invalidate()
        downloadPollTimer = nil
    }

    func installWine() {
        guard let brew = brewPath, !isBusy else { return }
        isBusy = true
        canCancelInstall = true
        installWasCancelled = false
        downloadProgressFraction = nil
        downloadProgressText = nil
        progressText = "Paso 1 de 2: preparando el repositorio de WINE..."
        statusLines.removeAll()
        log(progressText)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = self.runStreamed(brew, ["tap", "gcenx/wine"])

            DispatchQueue.main.async {
                self.progressText = "Paso 2 de 2: descargando e instalando WINE (Game Porting Toolkit)... esto puede tardar varios minutos."
                self.downloadProgressFraction = nil
                self.downloadProgressText = nil
            }

            let installOK = self.installWasCancelled
                ? false
                : self.runStreamed(brew, ["install", "--cask", "gcenx/wine/game-porting-toolkit"]) { [weak self] line in
                    // Homebrew/curl van imprimiendo líneas como
                    // "######## 73.2%" mientras descargan — cuando
                    // aparece ese porcentaje lo usamos como progreso
                    // real; el resto del tiempo (preparando, moviendo
                    // archivos) se queda como spinner indeterminado.
                    guard let self, let fraction = Self.parsePercentage(from: line) else { return }
                    self.downloadProgressFraction = fraction
                    self.downloadProgressText = "\(Int(fraction * 100))%"
                }

            DispatchQueue.main.async {
                self.finishWineInstall(installOK: installOK)
            }
        }
    }

    func finishWineInstall(installOK: Bool) {
        let cancelled = installWasCancelled
        isBusy = false
        canCancelInstall = false
        installWasCancelled = false
        downloadProgressFraction = nil
        downloadProgressText = nil
        if cancelled {
            log("Instalación de WINE cancelada.")
            return
        }
        refresh()
        if winePath != nil {
            log("✔ WINE instalado correctamente.")
            notify("WINE instalado", "Ya puedes continuar con el juego.")
        } else {
            log("✘ No pude confirmar que WINE haya quedado instalado. Revisa el mensaje de arriba.")
            notify("Falló la instalación de WINE", "Revisa el mensaje en la app para más detalles.")
        }
    }

    /// Corre un proceso y manda cada línea de su salida al registro A
    /// MEDIDA que va apareciendo (en vez de esperar a que termine todo),
    /// para que instalaciones largas como la de WINE no se sientan
    /// congeladas en un solo spinner sin ninguna señal de vida. Devuelve
    /// `true` si terminó con código 0. `onLine` recibe cada línea además
    /// del registro, para que quien llama pueda sacarle un porcentaje de
    /// progreso si lo trae (ver `installWine()`).
    func runStreamed(_ executable: String, _ arguments: [String], onLine: ((String) -> Void)? = nil) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            DispatchQueue.main.async {
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    self?.log(trimmed)
                    onLine?(trimmed)
                }
            }
        }

        DispatchQueue.main.async { [weak self] in self?.runningInstallProcess = task }

        do {
            try task.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { [weak self] in
                self?.log("✘ No pude ejecutar \(executable): \(error.localizedDescription)")
                self?.runningInstallProcess = nil
            }
            return false
        }
        task.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.async { [weak self] in self?.runningInstallProcess = nil }
        return task.terminationStatus == 0
    }

}
