import Foundation
import Combine
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif


/// Toda la lógica de "encontrar WINE", "instalar WINE", "encontrar/descargar
/// el juego", "jugar" y "diagnosticar por qué se cerró" vive aquí, separada
/// de la interfaz (ContentView).
///
/// Nota de diseño: esta clase usa GCD (DispatchQueue), no async/await.
/// El trabajo pesado (instalar, descargar, correr WINE) va a una cola en
/// segundo plano, y cada actualización de la interfaz se manda
/// explícitamente de vuelta a DispatchQueue.main. Es más fácil de leer y
/// depurar que la concurrencia estructurada de Swift, y evita errores de
/// aislamiento de actor al compilar.
final class GameManager: ObservableObject {

    // MARK: - Rutas fijas

    static let appDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/YansimLauncher")
    static let gameDir = appDir.appendingPathComponent("Game")
    static let logFile = appDir.appendingPathComponent("last-run.log")
    /// Carpeta con un archivo de registro por cada vez que se jugó (con
    /// fecha y hora en el nombre), para poder comparar "la vez que
    /// funcionó" contra "la vez que se congeló" en vez de tener solo el
    /// último intento.
    static let logsDir = appDir.appendingPathComponent("Logs")
    static let exeName = "YandereSimulator.exe"
    static let shimName = "version.dll"
    static let downloadURL = "https://yanderesimulator.com/dl/latest.zip"

    /// Versión de la app tal como la ve Xcode (CFBundleShortVersionString +
    /// número de build), para mostrar en "Acerca de" e incluir en el
    /// informe de diagnóstico.
    static var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    static let wineCandidates = [
        "/opt/homebrew/bin/wine64", "/opt/homebrew/bin/wine",
        "/usr/local/bin/wine64", "/usr/local/bin/wine",
    ]
    static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static let winetricksCandidates = ["/opt/homebrew/bin/winetricks", "/usr/local/bin/winetricks"]

    static var searchDirs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            gameDir,
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Games"),
        ]
    }

    /// El parche para Unity 6 viene compilado dentro de la app (Resources).
    /// El usuario nunca instala MinGW ni compila nada.
    static var bundledShimURL: URL? {
        Bundle.main.url(forResource: "version", withExtension: "dll")
    }

    /// El .exe que el usuario eligió (o que encontramos) se recuerda entre
    /// una sesión y otra, para no tener que volver a buscarlo/elegirlo cada
    /// vez que se abre la app.
    static var savedExePath: String? {
        get { UserDefaults.standard.string(forKey: "YansimLauncher.savedExePath") }
        set { UserDefaults.standard.set(newValue, forKey: "YansimLauncher.savedExePath") }
    }

    /// Tamaño (en bytes) del .zip descargado la última vez. Lo comparamos
    /// contra el tamaño que reporta el servidor ahora mismo para saber si
    /// hay una versión distinta disponible. No es perfecto (YandereDev no
    /// publica un número de versión), pero detecta cuando el archivo cambió.
    static var lastDownloadedSize: Int? {
        get {
            let v = UserDefaults.standard.integer(forKey: "YansimLauncher.lastDownloadedSize")
            return v == 0 ? nil : v
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "YansimLauncher.lastDownloadedSize") }
    }

    /// Fecha de modificación del .zip que descargamos la última vez
    /// (cabecera "Last-Modified" del servidor). La usamos como segunda
    /// señal además del tamaño: si YandereDev publica una versión nueva
    /// que por casualidad pesa lo mismo que la anterior, el tamaño solo
    /// no lo detectaría, pero la fecha sí habrá cambiado.
    static var lastDownloadedLastModified: String? {
        get { UserDefaults.standard.string(forKey: "YansimLauncher.lastDownloadedLastModified") }
        set { UserDefaults.standard.set(newValue, forKey: "YansimLauncher.lastDownloadedLastModified") }
    }

    /// Segundos totales jugados, acumulados entre sesiones de la app (no
    /// solo la sesión actual del juego).
    static var savedTotalPlaySeconds: Int {
        get { UserDefaults.standard.integer(forKey: "YansimLauncher.totalPlaySeconds") }
        set { UserDefaults.standard.set(newValue, forKey: "YansimLauncher.totalPlaySeconds") }
    }

    /// Cuántas veces se jugó una sesión "de verdad" (no un cierre casi
    /// inmediato por un choque). Junto con `totalPlaySeconds`, es lo que
    /// alimenta las estadísticas de la sección Jugar.
    static var savedPlaySessionCount: Int {
        get { UserDefaults.standard.integer(forKey: "YansimLauncher.playSessionCount") }
        set { UserDefaults.standard.set(newValue, forKey: "YansimLauncher.playSessionCount") }
    }

    /// Cuándo terminó la última sesión de juego "de verdad" (no un choque
    /// casi inmediato). `nil` si todavía no se ha jugado ninguna.
    static var savedLastPlayedAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: "YansimLauncher.lastPlayedAt")
            return t == 0 ? nil : Date(timeIntervalSince1970: t)
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "YansimLauncher.lastPlayedAt") }
    }

    /// Carpeta donde se guardan las copias de seguridad de partidas, cada
    /// una en su propia subcarpeta con fecha y hora.
    static var backupsDir: URL { appDir.appendingPathComponent("Backups") }

    /// Tema elegido por el usuario (claro / oscuro / sistema), recordado
    /// entre una sesión y otra.
    static var savedAppTheme: AppTheme {
        get {
            let raw = UserDefaults.standard.string(forKey: "YansimLauncher.appTheme") ?? AppTheme.system.rawValue
            return AppTheme(rawValue: raw) ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "YansimLauncher.appTheme") }
    }

    /// Idioma de la interfaz, recordado entre sesiones. Por defecto,
    /// inglés — aunque el resto del Launcher esté escrito en español,
    /// así se pidió que arrancara.
    static var savedAppLanguage: AppLanguage {
        get {
            let raw = UserDefaults.standard.string(forKey: "YansimLauncher.appLanguage") ?? AppLanguage.english.rawValue
            return AppLanguage(rawValue: raw) ?? .english
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "YansimLauncher.appLanguage") }
    }

    /// El WINEPREFIX que realmente se usa al jugar (mismo criterio que
    /// runWithWine): el de la variable de entorno si existe, o ~/.wine.
    static var winePrefixPath: URL {
        if let custom = ProcessInfo.processInfo.environment["WINEPREFIX"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wine")
    }

    /// Si está activo, se lanzan variables de entorno que relajan la
    /// validación de Metal (ver reduceMetalValidation más abajo). Se
    /// recuerda entre sesiones porque es una preferencia de "modo
    /// experimental", igual que el modo gráfico.
    static var savedReduceMetalValidation: Bool {
        get { UserDefaults.standard.bool(forKey: "YansimLauncher.reduceMetalValidation") }
        set { UserDefaults.standard.set(newValue, forKey: "YansimLauncher.reduceMetalValidation") }
    }

    /// El modo gráfico elegido (Automático / Forzar Direct3D 11). Antes no
    /// se guardaba entre sesiones — con el patrón "Guardar" de Opciones,
    /// que sí se recuerde tiene más sentido (si no, "Guardar" no guardaría
    /// nada de verdad para este ajuste).
    static var savedGraphicsModeIndex: Int {
        get { UserDefaults.standard.integer(forKey: "YansimLauncher.selectedModeIndex") }
        set { UserDefaults.standard.set(newValue, forKey: "YansimLauncher.selectedModeIndex") }
    }

    /// Si se muestra el overlay nativo de FPS de Apple (Metal HUD) mientras
    /// se juega — útil para comparar de verdad el impacto de cada perfil
    /// de gráficos, en vez de adivinar "se siente más fluido".
    static var savedShowMetalHUD: Bool {
        get { UserDefaults.standard.bool(forKey: "YansimLauncher.showMetalHUD") }
        set { UserDefaults.standard.set(newValue, forKey: "YansimLauncher.showMetalHUD") }
    }

    /// Si ya se intentó (con éxito o no) la instalación automática de las
    /// fuentes de Windows una vez que todo quedó listo. Se guarda para
    /// siempre, para no volver a bajarlas cada vez que se abre la app —
    /// si falló, el usuario puede repetirlo a mano desde Herramientas.
    static var fontsAutoInstallAttempted: Bool {
        get { UserDefaults.standard.bool(forKey: "YansimLauncher.fontsAutoInstallAttempted") }
        set { UserDefaults.standard.set(newValue, forKey: "YansimLauncher.fontsAutoInstallAttempted") }
    }

    // MARK: - Estado observado por la interfaz (siempre se toca en el hilo principal)

    @Published var stage: SetupStage = .checking
    @Published var winePath: String?
    /// Versión de WINE detectada (lo que reporta `wine --version`), para
    /// mostrarla en "Acerca de" e incluirla en el informe de diagnóstico.
    @Published var wineVersionString: String?
    @Published var brewPath: String?
    @Published var gameExePath: String?
    /// Todos los .exe que hay sueltos en la carpeta del juego ahora mismo
    /// (el original, y cualquiera que haya traído un mod activado, como
    /// PoseMod64.exe). Alimenta el desplegable "Jugar con" de la sección
    /// Jugar, para cambiar de uno a otro sin tener que ir a Opciones.
    @Published var availableExecutables: [String] = []
    @Published var statusLines: [String] = []
    @Published var statusMessage: String = ""
    @Published var isBusy: Bool = false
    /// Distinto de `isBusy`: `isBusy` se enciende para CUALQUIER tarea
    /// larga (instalar WINE, descargar/actualizar el juego, jugar), para
    /// evitar que se disparen dos a la vez. `isPlaying` solo se enciende
    /// mientras el juego en sí está corriendo, para que el botón "Jugar"
    /// diga "Jugando..." únicamente cuando de verdad está jugando, y no
    /// también mientras se está descargando una actualización.
    @Published var isPlaying: Bool = false
    @Published var progressText: String = ""
    @Published var canCancelInstall: Bool = false
    @Published var downloadProgressFraction: Double?
    @Published var downloadProgressText: String?
    @Published var homebrewCheckMessage: String?
    var installWasCancelled = false
    var runningInstallProcess: Process?
    var downloadTask: Process?
    var downloadPollTimer: Timer?
    @Published var selectedModeIndex: Int = GameManager.savedGraphicsModeIndex {
        didSet { Self.savedGraphicsModeIndex = selectedModeIndex }
    }
    @Published var updateAvailable: Bool = false
    @Published var isCheckingUpdate: Bool = false
    @Published var updateCheckMessage: String?
    @Published var totalPlaySeconds: Int = GameManager.savedTotalPlaySeconds
    @Published var playSessionCount: Int = GameManager.savedPlaySessionCount
    @Published var lastPlayedAt: Date? = GameManager.savedLastPlayedAt
    @Published var mods: [ModEntry] = []
    @Published var modImportMessage: String?
    @Published var isImportingMods: Bool = false
    /// Progreso real de "Subir mod...": de 0 a 1 mientras se copia o
    /// descomprime lo que el usuario eligió. `nil` cuando no hay nada
    /// subiéndose (la interfaz muestra un spinner indeterminado en vez de
    /// la barra mientras tanto, si hace falta).
    @Published var modImportProgressFraction: Double?
    @Published var modImportProgressText: String?
    @Published var isBackingUp: Bool = false
    @Published var backupMessage: String?
    @Published var isBackingUpGameFolder: Bool = false
    @Published var gameFolderBackupMessage: String?
    @Published var isOrganizingGameFolder: Bool = false
    @Published var organizeGameFolderMessage: String?
    @Published var isVerifying: Bool = false
    @Published var verifyResults: [String]?
    /// Progreso real de "Verificar archivos": de 0 a 1 mientras se revisa
    /// archivo por archivo dentro de la carpeta de datos del juego (que
    /// puede tener miles). `nil` antes de saber cuántos hay en total.
    @Published var verifyProgressFraction: Double?
    @Published var isResettingSettings: Bool = false
    @Published var resetSettingsMessage: String?
    @Published var reportCopiedMessage: String?
    @Published var isInstallingFonts: Bool = false
    @Published var fontsInstallMessage: String?
    /// Mensaje que se muestra cuando el vigilante detecta que el juego
    /// lleva mucho tiempo sin escribir nada nuevo en su registro (una
    /// señal típica de que se congeló, por ejemplo en una cinemática).
    /// `nil` mientras todo parece normal.
    @Published var stuckGameHint: String?
    @Published var reduceMetalValidation: Bool = GameManager.savedReduceMetalValidation {
        didSet { Self.savedReduceMetalValidation = reduceMetalValidation }
    }
    @Published var showMetalHUD: Bool = GameManager.savedShowMetalHUD {
        didSet { Self.savedShowMetalHUD = showMetalHUD }
    }
    @Published var appTheme: AppTheme = GameManager.savedAppTheme {
        didSet { Self.savedAppTheme = appTheme }
    }
    @Published var appLanguage: AppLanguage = GameManager.savedAppLanguage {
        didSet {
            Self.savedAppLanguage = appLanguage
            L10n.refresh(for: appLanguage)
        }
    }

    // MARK: - Borrador de Opciones (patrón Guardar / Restablecer)

    /// La pantalla de Opciones no aplica los cambios al tocarlos, como el
    /// resto del Launcher — el usuario cambia lo que quiera y decide con
    /// "Guardar" o "Restablecer" (igual que en Modrinth). Estas tres
    /// propiedades son el "borrador": lo que se ve seleccionado en la
    /// pantalla mientras no se guarde. Se inicializan con el valor ya
    /// guardado, para que al abrir Opciones no aparezca como "cambiado"
    /// algo que en realidad no se tocó.
    @Published var draftAppTheme: AppTheme = GameManager.savedAppTheme
    @Published var draftAppLanguage: AppLanguage = GameManager.savedAppLanguage
    @Published var draftGraphicsModeIndex: Int = GameManager.savedGraphicsModeIndex
    @Published var draftReduceMetalValidation: Bool = GameManager.savedReduceMetalValidation
    @Published var draftShowMetalHUD: Bool = GameManager.savedShowMetalHUD

    /// Si el borrador difiere de lo que está aplicado ahora mismo. La
    /// interfaz usa esto para mostrar (o no) la barra de "Tienes cambios
    /// sin guardar" al fondo de Opciones.
    var hasUnsavedSettingsChanges: Bool {
        draftAppTheme != appTheme
            || draftAppLanguage != appLanguage
            || draftGraphicsModeIndex != selectedModeIndex
            || draftReduceMetalValidation != reduceMetalValidation
            || draftShowMetalHUD != showMetalHUD
    }

    /// Copia el borrador a los valores reales — cada uno ya se guarda solo
    /// en UserDefaults por su propio `didSet`.
    func saveSettings() {
        appTheme = draftAppTheme
        appLanguage = draftAppLanguage
        selectedModeIndex = draftGraphicsModeIndex
        reduceMetalValidation = draftReduceMetalValidation
        showMetalHUD = draftShowMetalHUD
    }

    /// Descarta el borrador y lo vuelve a dejar igual a lo que está
    /// aplicado ahora mismo.
    func resetSettingsDraft() {
        draftAppTheme = appTheme
        draftAppLanguage = appLanguage
        draftGraphicsModeIndex = selectedModeIndex
        draftReduceMetalValidation = reduceMetalValidation
        draftShowMetalHUD = showMetalHUD
    }

    /// El perfil de gráficos que coincide con el borrador actual, o `nil`
    /// si el modo gráfico y la validación de Metal se tocaron a mano en
    /// una combinación que no corresponde a ninguno de los tres perfiles
    /// predefinidos ("Personalizado").
    var matchingDraftGraphicsProfile: GraphicsProfile? {
        GraphicsProfile.allCases.first {
            $0.graphicsModeIndex == draftGraphicsModeIndex && $0.reduceMetalValidation == draftReduceMetalValidation
        }
    }

    /// Aplica un perfil al borrador (modo gráfico + validación de Metal a
    /// la vez). Sigue haciendo falta pulsar "Guardar" para que tenga efecto.
    func applyGraphicsProfile(_ profile: GraphicsProfile) {
        draftGraphicsModeIndex = profile.graphicsModeIndex
        draftReduceMetalValidation = profile.reduceMetalValidation
    }

    /// Tiempo jugado en formato legible, p. ej. "3 h 12 min" o "45 min".
    var playTimeFormatted: String {
        let hours = totalPlaySeconds / 3600
        let minutes = (totalPlaySeconds % 3600) / 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }

    /// "Hace 2 días", "Nunca", etc. — para la StatTile de "Última vez".
    var lastPlayedFormatted: String {
        guard let lastPlayedAt else { return "Nunca" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: appLanguage.localeIdentifier)
        return formatter.localizedString(for: lastPlayedAt, relativeTo: Date())
    }

    /// El perfil de gráficos que coincide con lo APLICADO ahora mismo (no
    /// con el borrador de Opciones) — para mostrar en la StatTile de Jugar.
    var currentGraphicsProfileLabel: String {
        GraphicsProfile.allCases.first {
            $0.graphicsModeIndex == selectedModeIndex && $0.reduceMetalValidation == reduceMetalValidation
        }?.label ?? "Personalizado"
    }

    var process: Process?

    /// El registro de la sesión de juego más reciente (uno por cada vez
    /// que se jugó, ver `logsDir`). `openLog()` y el diagnóstico al
    /// terminar el juego usan este archivo en vez del viejo `logFile` fijo.
    var currentSessionLogFile: URL = GameManager.logFile

    /// Proceso aparte que escucha el registro unificado de macOS (`log
    /// stream`) mientras se juega. Algunos errores de Metal/GPTK (por
    /// ejemplo, un shader que no se tradujo bien de Direct3D) no salen por
    /// la salida normal del juego que ya capturamos — macOS los manda a su
    /// propio sistema de registro (el que se ve en Consola.app). Con esto
    /// los dejamos guardados en el mismo archivo de la sesión, para no
    /// tener que perseguirlos aparte la próxima vez que algo como el texto
    /// de los diálogos no aparezca en pantalla.
    var metalLogProcess: Process?

    /// Temporizador del vigilante de "juego congelado": revisa cada pocos
    /// segundos si el registro de la sesión actual sigue creciendo.
    var watchdogTimer: Timer?
    /// Tamaño (en bytes) del registro de la sesión la última vez que el
    /// vigilante lo revisó.
    var lastSessionLogSize: Int = 0
    /// Cuándo fue la última vez que el registro de la sesión creció. Si
    /// pasa demasiado tiempo sin crecer mientras se está jugando, es una
    /// señal de que el juego se congeló (no necesariamente de que se
    /// cerró: por eso no lo forzamos solos, solo avisamos).
    var lastSessionLogActivityAt: Date = Date()

    init() {
        // didSet de appLanguage no se dispara con el valor inicial de la
        // propiedad, así que hay que preparar L10n.bundle a mano aquí para
        // que el primer render ya traduzca correctamente.
        L10n.refresh(for: appLanguage)
        if let failure = Self.ensureCoreDirectoriesExist() {
            // Si no se pudieron crear las carpetas básicas (por ejemplo,
            // por falta de espacio o de permisos), es mejor decirlo que
            // quedarse en silencio y fallar de forma más confusa más
            // adelante al intentar descargar o jugar.
            statusMessage = "⚠️ No se pudieron crear las carpetas de la app: \(failure.localizedDescription)"
        }
        requestNotificationPermissionIfNeeded()
        // A propósito, NO llamamos refresh() aquí. GameManager se crea como
        // @StateObject justo cuando SwiftUI está construyendo la primera
        // vista, y refresh() cambia varias @Published (stage, winePath,
        // etc.) — hacerlo en ese instante (aunque sea con
        // DispatchQueue.main.async) sigue disparando el warning "Publishing
        // changes from within view updates is not allowed". stage empieza
        // en .checking, así que se ve la pantalla de carga, y es
        // ContentView quien llama a refresh() desde .onAppear, que SwiftUI
        // garantiza que corre DESPUÉS de que la vista ya terminó de armarse.
    }

    /// Crea las carpetas básicas que la app necesita para funcionar
    /// (datos de la app, carpeta del juego, registros). Antes esto se
    /// hacía con `try?`, que traga cualquier error en silencio — si por lo
    /// que sea no se pudo crear una carpeta (permisos, disco lleno), la
    /// app seguía adelante como si nada y fallaba de forma más confusa
    /// más tarde. Ahora se devuelve el primer error que ocurra, para
    /// poder avisar de una vez.
    static func ensureCoreDirectoriesExist() -> Error? {
        let dirs = [appDir, gameDir, logsDir]
        for dir in dirs {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                // Si la carpeta ya existe (por ejemplo, creada por otra de
                // las carpetas en una corrida anterior) no es un error de
                // verdad.
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                    continue
                }
                return error
            }
        }
        return nil
    }

    /// Termina de golpe cualquier proceso hijo que haya quedado vivo
    /// (el juego vía WINE, y el que escucha el registro del sistema).
    /// Se llama al cerrar la app (desde `AppDelegate`) y también sirve
    /// como limpieza de respaldo en `deinit`, para no dejar procesos de
    /// WINE huérfanos corriendo en segundo plano si la app se cierra de
    /// forma inesperada.
    func terminateAllChildProcesses() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        if let metal = metalLogProcess, metal.isRunning {
            metal.terminate()
        }
        if let install = runningInstallProcess, install.isRunning {
            install.terminate()
        }
        if let download = downloadTask, download.isRunning {
            download.terminate()
        }
    }

    // MARK: - Detección / avance del asistente

    func refresh() {
        winePath = Self.findWine()
        brewPath = Self.findBrew()
        wineVersionString = winePath.flatMap { Self.detectWineVersion(wine: $0) }

        if let saved = Self.savedExePath, FileManager.default.fileExists(atPath: saved) {
            gameExePath = saved
        } else {
            gameExePath = Self.findGameExe()
        }

        if let exe = gameExePath {
            installShimIfNeeded(nextTo: exe)
            Self.savedExePath = exe
        }
        refreshAvailableExecutables()

        if winePath == nil && brewPath == nil {
            stage = .needsHomebrew
        } else if winePath == nil {
            stage = .needsWine
        } else if gameExePath == nil {
            stage = .needsGame
        } else {
            stage = .ready
            statusMessage = "Todo listo. Pulsa Jugar."
            checkForUpdate()
            startPeriodicUpdateChecksIfNeeded()
            // Las fuentes de Windows (Tahoma, Verdana, etc.) casi siempre
            // hacen falta para que se vea el texto del HUD dentro de WINE.
            // Antes había que acordarse de ir a Herramientas y pulsar un
            // botón aparte — ahora se instalan solas la primera vez que
            // todo queda listo (juego + WINE), sin que el usuario tenga
            // que hacer nada. `fontsAutoInstallAttempted` asegura que esto
            // pase una sola vez por Mac, no cada vez que se abre la app.
            if !Self.fontsAutoInstallAttempted {
                Self.fontsAutoInstallAttempted = true
                installFonts(silent: true)
            }
        }
    }

    var updateCheckTimer: Timer?

    /// Revisa si hay una actualización del juego cada cierto tiempo,
    /// mientras la app siga abierta — así te enteras sin tener que
    /// acordarte de pulsar "Buscar actualizaciones" tú misma. Solo se
    /// arma una vez (si ya hay un temporizador corriendo, no hace nada).
    func startPeriodicUpdateChecksIfNeeded() {
        guard updateCheckTimer == nil else { return }
        let twoHours: TimeInterval = 2 * 60 * 60
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: twoHours, repeats: true) { [weak self] _ in
            // No revisamos mientras el juego está corriendo, para no
            // competir por la conexión justo en ese momento.
            guard let self, !self.isBusy else { return }
            self.checkForUpdate()
        }
    }

    deinit {
        updateCheckTimer?.invalidate()
        downloadPollTimer?.invalidate()
        watchdogTimer?.invalidate()
        terminateAllChildProcesses()
    }

    static func findWine() -> String? {
        let fm = FileManager.default
        for candidate in wineCandidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let found = runShell("command -v wine64 || command -v wine"), !found.isEmpty {
            return found
        }
        return nil
    }

    /// Lo que reporta `wine --version` (algo como "wine-9.0"), para mostrar
    /// en "Acerca de" qué versión de WINE/GPTK hay instalada de verdad.
    static func detectWineVersion(wine: String) -> String? {
        let result = runShell("\"\(wine)\" --version")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result?.isEmpty ?? true) ? nil : result
    }

    static func findBrew() -> String? {
        let fm = FileManager.default
        for candidate in brewCandidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let found = runShell("command -v brew"), !found.isEmpty {
            return found
        }
        return nil
    }

    static func findGameExe() -> String? {
        let fm = FileManager.default
        for dir in searchDirs {
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in enumerator {
                if file.lastPathComponent.lowercased() == exeName.lowercased() {
                    return file.path
                }
            }
        }
        return nil
    }

    func chooseExeManually(_ path: String) {
        Self.savedExePath = path
        log("✔ Juego seleccionado manualmente: \(path)")
        refresh()
    }

    /// Copia el version.dll incluido en la app junto al .exe del juego,
    /// si todavía no está ahí. Silencioso: si algo falla, el diagnóstico
    /// al jugar lo va a explicar de todas formas.
    func installShimIfNeeded(nextTo exePath: String) {
        guard let shim = Self.bundledShimURL else { return }
        let dest = URL(fileURLWithPath: exePath)
            .deletingLastPathComponent()
            .appendingPathComponent(Self.shimName)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? FileManager.default.copyItem(at: shim, to: dest)
    }

}
