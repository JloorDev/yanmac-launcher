import AppKit

/// Maneja el ciclo de vida de toda la app (no de una ventana en particular):
/// evita que se abra dos veces a la vez, pregunta antes de cerrarla si el
/// juego está corriendo o algo se está instalando/descargando, y se asegura
/// de que no quede ningún proceso de WINE huérfano corriendo en segundo
/// plano si la app se cierra.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Se asigna desde `YansimLauncherApp` justo después de crear el
    /// `GameManager`, antes de que la interfaz pueda hacer nada. Es
    /// opcional porque `NSApplicationDelegateAdaptor` crea el delegado
    /// antes que la vista raíz construya su `@StateObject`.
    var game: GameManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        // Si ya hay otra instancia de esta misma app corriendo (el mismo
        // bundle identifier), no tiene sentido seguir abriendo esta
        // segunda copia: dos instancias compitiendo por el mismo
        // WINEPREFIX y la misma carpeta del juego pueden pisarse una a la
        // otra (por ejemplo, las dos tratando de escribir el mismo
        // archivo de registro, o las dos intentando lanzar el juego a la
        // vez). En vez de eso, traemos al frente la que ya estaba abierta
        // y cerramos esta.
        let runningInstances = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        if let existing = runningInstances.first {
            existing.activate()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let game else { return .terminateNow }

        // Si el juego está corriendo, o algo se está instalando/
        // descargando, cerrar de golpe puede dejar el WINEPREFIX o la
        // carpeta del juego en un estado raro (un .zip a medio extraer,
        // por ejemplo). Preguntamos primero en vez de cortar sin avisar.
        guard game.isPlaying || game.isBusy else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = game.isPlaying ? "¿Cerrar YanMac Launcher mientras el juego está corriendo?" : "¿Cerrar YanMac Launcher mientras hay algo en progreso?"
        alert.informativeText = game.isPlaying
            ? "El juego se cerrará también. Si estabas jugando, podrías perder tu progreso si no habías guardado."
            : "Hay una instalación, descarga o subida de mod en curso. Si cierras ahora, podría quedar incompleta."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cerrar de todas formas")
        alert.addButton(withTitle: "Cancelar")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            game.terminateAllChildProcesses()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        game?.terminateAllChildProcesses()
    }
}
