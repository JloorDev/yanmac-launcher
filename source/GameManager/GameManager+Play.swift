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
    // MARK: - Jugar

    func play() {
        guard let exe = gameExePath else { return }

        // El .exe de un mod (como PoseMod64.exe) no es el juego original:
        // suele traer su propio buscador de la carpeta "..._Data", que es
        // frágil con argumentos de línea de comandos que no reconoce (por
        // ejemplo "-force-d3d11"). Si se lo mandamos, confunde el nombre
        // que busca y termina sin encontrar la carpeta de datos del juego,
        // cerrándose solo a los pocos segundos. Por eso los ajustes
        // gráficos (modo gráfico elegido en Opciones) solo se le pasan al
        // YandereSimulator.exe original; a cualquier otro .exe lo lanzamos
        // sin argumentos extra.
        let isVanillaExe = gameExeFileName?.caseInsensitiveCompare(Self.exeName) == .orderedSame
        let args = isVanillaExe ? graphicsModes[selectedModeIndex].args : []

        runWithWine(exe: exe, extraArgs: args,
                    startMessage: "El juego se está ejecutando...",
                    startLog: "Iniciando el juego... (la primera vez puede tardar un minuto)")
    }

    /// Lanza el juego con una configuración mínima y fija (ventana chica,
    /// Direct3D 11 forzado, validación de Metal reducida) sin importar lo
    /// que tengas elegido en Opciones. Sirve para responder una pregunta
    /// simple: "¿el problema es de WINE/mi Mac en general, o de algún
    /// ajuste gráfico en particular?" — si el juego corre bien así pero no
    /// con tus ajustes normales, el problema está en esos ajustes, no en
    /// la instalación.
    func runDiagnosticMode() {
        guard let exe = gameExePath else { return }
        runWithWine(
            exe: exe,
            extraArgs: ["-force-d3d11", "-screen-width", "800", "-screen-height", "600", "-popupwindow"],
            startMessage: "Ejecutando diagnóstico seguro...",
            startLog: "Iniciando modo de diagnóstico seguro (ventana chica, Direct3D 11, validación de Metal reducida)...",
            forceSafeMetal: true
        )
    }

    /// Corre el .exe del juego con WINE, con los argumentos extra que pida
    /// el modo gráfico elegido. `forceSafeMetal` se usa solo para
    /// `runDiagnosticMode()`: reduce la validación de Metal para esa
    /// corrida puntual sin tocar el ajuste guardado en Opciones.
    func runWithWine(exe: String, extraArgs: [String], startMessage: String, startLog: String, forceSafeMetal: Bool = false) {
        guard let wine = winePath, !isBusy else { return }

        isBusy = true
        isPlaying = true
        statusMessage = startMessage
        statusLines.removeAll()
        log(startLog)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: wine)
        task.arguments = [exe] + extraArgs
        task.currentDirectoryURL = URL(fileURLWithPath: exe).deletingLastPathComponent()

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        if env["WINEPREFIX"] == nil {
            env["WINEPREFIX"] = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".wine").path
        }
        env["WINEDEBUG"] = "err+all,fixme-all"
        // El parche unity6-wine-macos (version.dll) ya está junto al .exe;
        // esto le dice a WINE que lo use en vez de su propia version.dll.
        env["WINEDLLOVERRIDES"] = "version=n,b"

        // Experimental: cuando Metal encuentra un shader mal traducido por
        // GPTK (Direct3D→Metal), su capa de validación prefiere matar el
        // hilo gráfico de inmediato en vez de dejarlo seguir con errores
        // visuales — eso es lo que se ve como "se congela pero sigue el
        // audio". Estas variables apagan esa validación estricta, con la
        // esperanza de que el juego pueda seguir (quizá con algún glitch
        // visual pasajero) en vez de trabarse por completo. No es un
        // arreglo garantizado: la decisión de qué tan estricto ser es de
        // Apple, no algo que controlemos del todo desde aquí.
        if reduceMetalValidation || forceSafeMetal {
            env["MTL_DEBUG_LAYER"] = "0"
            env["MTL_SHADER_VALIDATION"] = "0"
            env["METAL_DEVICE_WRAPPER_TYPE"] = "0"
        }

        // Overlay nativo de FPS de macOS (Metal HUD) — lo dibuja el propio
        // sistema encima del juego, no algo que la app tenga que calcular.
        // Sirve para comparar de verdad el rendimiento de cada perfil de
        // gráficos en vez de tener que adivinar "se siente más fluido".
        if showMetalHUD {
            env["MTL_HUD_ENABLED"] = "1"
        }

        task.environment = env

        // Un archivo de registro nuevo por cada vez que se juega, con
        // fecha y hora, en vez de sobreescribir siempre el mismo — así se
        // puede comparar una corrida que funcionó contra una que falló.
        let sessionLog = Self.newSessionLogFile()
        currentSessionLogFile = sessionLog
        FileManager.default.createFile(atPath: sessionLog.path, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: sessionLog.path) else {
            log("✘ No pude crear el archivo de registro.")
            isBusy = false
            isPlaying = false
            return
        }
        task.standardOutput = logHandle
        task.standardError = logHandle

        let startedAt = Date()

        task.terminationHandler = { [weak self] proc in
            logHandle.closeFile()
            DispatchQueue.main.async {
                self?.onGameExit(exitCode: proc.terminationStatus, startedAt: startedAt)
            }
        }

        do {
            try task.run()
            process = task
            startMetalLogCapture(writingTo: logHandle)
            startStuckGameWatchdog(logFile: sessionLog)
        } catch {
            log("✘ No se pudo iniciar: \(error.localizedDescription)")
            isBusy = false
            isPlaying = false
        }
    }

    /// Vigila que el registro de la sesión siga creciendo mientras se
    /// juega. Si el juego se congela (por ejemplo, en una cinemática que
    /// nunca termina de cargar), suele dejar de escribir nada nuevo en su
    /// registro — el audio puede seguir sonando, pero no pasa nada más.
    /// Cuando eso lleva demasiado tiempo sin cambiar, avisamos con
    /// `stuckGameHint` para que sepas que puedes usar "Forzar cierre" en
    /// vez de esperar sin saber si de verdad está trabado o solo tardando.
    func startStuckGameWatchdog(logFile: URL) {
        watchdogTimer?.invalidate()
        lastSessionLogSize = (try? FileManager.default.attributesOfItem(atPath: logFile.path))?[.size] as? Int ?? 0
        lastSessionLogActivityAt = Date()
        stuckGameHint = nil

        // Le damos un margen de un par de minutos después de lanzar el
        // juego antes de empezar a sospechar, porque la primera carga
        // (sobre todo la primera vez) puede tardar sin que eso signifique
        // que está congelado.
        let gracePeriod: TimeInterval = 120
        let stuckThreshold: TimeInterval = 45
        let startedWatchingAt = Date()

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard Date().timeIntervalSince(startedWatchingAt) > gracePeriod else { return }

            let currentSize = (try? FileManager.default.attributesOfItem(atPath: logFile.path))?[.size] as? Int ?? self.lastSessionLogSize
            if currentSize != self.lastSessionLogSize {
                self.lastSessionLogSize = currentSize
                self.lastSessionLogActivityAt = Date()
                self.stuckGameHint = nil
                return
            }

            let idleFor = Date().timeIntervalSince(self.lastSessionLogActivityAt)
            if idleFor > stuckThreshold {
                self.stuckGameHint = "El juego no ha mostrado actividad en el registro desde hace \(Int(idleFor)) segundos. Si parece congelado, puedes usar \"Forzar cierre\" abajo."
            }
        }
    }

    func stopStuckGameWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        stuckGameHint = nil
    }

    /// Escucha el registro unificado de macOS (lo mismo que se ve en
    /// Consola.app) mientras se juega, y lo guarda en el mismo archivo de
    /// la sesión. Esto es aparte de la salida normal del juego: algunos
    /// errores de Metal o de la traducción de GPTK (por ejemplo, un
    /// shader de Direct3D que no se tradujo bien) no salen por ahí, salen
    /// por el registro del sistema. Si "log" no puede arrancar por
    /// cualquier motivo, simplemente no tendremos esa pista extra — no
    /// afecta a que el juego corra.
    func startMetalLogCapture(writingTo handle: FileHandle) {
        let predicate = """
        (eventMessage CONTAINS[c] "shader" OR eventMessage CONTAINS[c] "Metal" OR \
        eventMessage CONTAINS[c] "error" OR eventMessage CONTAINS[c] "failed") AND \
        processImagePath CONTAINS[c] "wine"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["stream", "--style", "compact", "--level", "debug", "--predicate", predicate]
        task.standardOutput = handle
        task.standardError = nil
        do {
            try task.run()
            metalLogProcess = task
        } catch {
            // No pasa nada si esto falla: seguimos sin esa pista extra.
        }
    }

    func onGameExit(exitCode: Int32, startedAt: Date) {
        isBusy = false
        isPlaying = false
        stopStuckGameWatchdog()
        metalLogProcess?.terminate()
        metalLogProcess = nil
        process = nil
        let elapsed = Date().timeIntervalSince(startedAt)
        let wineLog = Self.tail(currentSessionLogFile, lines: 80)

        if elapsed < 90 || exitCode != 0 {
            statusMessage = "El juego se cerró pronto. Mira el diagnóstico abajo."
            log("El juego terminó a los \(Int(elapsed)) segundos (código de salida \(exitCode)).")
            log("")
            log("== Qué puede estar pasando ==")
            for hint in Self.diagnose(wineLog) {
                log("• \(hint)")
            }
            log("")
            log("== Registro de WINE (últimas líneas) ==")
            log(wineLog)
        } else {
            statusMessage = "Juego cerrado. ¡Hasta la próxima!"
            totalPlaySeconds += Int(elapsed)
            Self.savedTotalPlaySeconds = totalPlaySeconds
            playSessionCount += 1
            Self.savedPlaySessionCount = playSessionCount
            lastPlayedAt = Date()
            Self.savedLastPlayedAt = lastPlayedAt
        }
    }

    /// Abre el registro de la última vez que se jugó (no un archivo fijo:
    /// cada corrida tiene el suyo, ver `newSessionLogFile()`).
    func openLog() {
        #if canImport(AppKit)
        NSWorkspace.shared.open(currentSessionLogFile)
        #endif
    }

    /// Abre en Finder la carpeta con el historial completo de registros,
    /// uno por cada vez que se jugó.
    func openLogsFolder() {
        #if canImport(AppKit)
        NSWorkspace.shared.open(Self.logsDir)
        #endif
    }

    /// Nombre de archivo con fecha y hora para el registro de esta corrida,
    /// p. ej. "2026-09-29_22-40-15.log". De paso, borra los registros más
    /// viejos si hay más de 20, para que la carpeta no crezca sin límite.
    static func newSessionLogFile() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = formatter.string(from: Date()) + ".log"

        let existing = (try? FileManager.default.contentsOfDirectory(
            at: logsDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        let maxKept = 20
        if existing.count >= maxKept {
            for old in existing.prefix(existing.count - maxKept + 1) {
                try? FileManager.default.removeItem(at: old)
            }
        }

        return logsDir.appendingPathComponent(name)
    }

    /// Fuerza el cierre del juego cuando se queda congelado (por ejemplo,
    /// en una cinemática). Primero pide un cierre normal (SIGTERM) y, si
    /// en un par de segundos sigue vivo, lo mata sin miramientos (SIGKILL).
    /// El process.terminationHandler ya existente se encarga de limpiar
    /// el estado (isBusy, process, diagnóstico) cuando de verdad termina.
    func forceQuitGame() {
        guard let proc = process else {
            log("No hay ningún proceso del juego corriendo ahora mismo.")
            return
        }
        log("Forzando el cierre del juego...")
        proc.terminate()

        let pid = proc.processIdentifier
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            if proc.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

}
