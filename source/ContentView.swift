import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var game: GameManager
    @State private var showFilePicker = false
    @State private var showModImporter = false
    @State private var selectedSection: LauncherSection = .play

    var body: some View {
        Group {
            switch game.stage {
            case .checking:
                CheckingView()
            case .needsHomebrew, .needsWine, .needsGame:
                SetupFlowView(showFilePicker: $showFilePicker)
            case .ready:
                MainLauncherView(
                    selectedSection: $selectedSection,
                    showFilePicker: $showFilePicker,
                    showModImporter: $showModImporter
                )
            }
        }
        // Este picker vive aquí, al mismo nivel "estable" que el resto del
        // árbol de vistas, en vez de dentro de ModsSectionView. Un
        // .fileImporter pegado a una rama de un switch (que aparece y
        // desaparece al cambiar de sección) puede simplemente no
        // presentarse en macOS. Montado siempre aquí no tiene ese problema.
        //
        // IMPORTANTE: antes había DOS .fileImporter separados encadenados
        // uno tras otro en esta misma vista (uno para el .exe, otro para
        // mods). Ese patrón tiene un bug conocido en SwiftUI/macOS: cuando
        // encadenas varios .fileImporter (o .sheet) sobre la misma vista,
        // el sistema de presentación solo termina respetando uno de forma
        // confiable — en la práctica, el último de la cadena "gana" y el
        // primero queda mudo (por eso "Elegir otro .exe..." no abría el
        // Finder, mientras que "Subir mod..." sí). La solución es fusionar
        // ambos en un único .fileImporter que decide, según cuál de los
        // dos @State esté en true, qué filtro mostrar y qué hacer con el
        // resultado.
        .fileImporter(
            isPresented: Binding(
                get: { showFilePicker || showModImporter },
                set: { newValue in
                    if !newValue {
                        showFilePicker = false
                        showModImporter = false
                    }
                }
            ),
            allowedContentTypes: showFilePicker
                ? [UTType(filenameExtension: "exe") ?? .item]
                : [.item],
            allowsMultipleSelection: showModImporter
        ) { result in
            switch result {
            case .success(let urls):
                if showFilePicker, let first = urls.first {
                    game.chooseExeManually(first.path)
                } else if showModImporter {
                    game.importMods(from: urls)
                }
            case .failure:
                break
            }
            showFilePicker = false
            showModImporter = false
        }
        .preferredColorScheme(game.appTheme.colorScheme)
        // El idioma de la interfaz se resuelve con L10n.t(...) en cada
        // texto (ver GameManager.swift) en vez de con
        // .environment(\.locale, ...) — ese mecanismo de SwiftUI resultó
        // no funcionar de forma confiable cuando el idioma elegido es el
        // mismo que el idioma "fuente" del catálogo (español).
        //
        // El `.id(...)` de aquí abajo es lo que hace que el cambio de
        // idioma se vea al instante: le dice a SwiftUI "esta es una vista
        // distinta cada vez que cambia `appLanguage`", así que en vez de
        // confiar en que cada Text/Button individual se vuelva a dibujar
        // por su cuenta (lo cual a veces tardaba hasta que pasaba otra
        // cosa, como cambiar de sección), destruye y reconstruye TODA la
        // pantalla de una sola vez, ya traducida, en el mismo momento en
        // que se guarda el cambio.
        .id(game.appLanguage)
        .onAppear {
            game.refresh()
        }
    }
}

// MARK: - Pantalla de carga inicial

private struct CheckingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.yanPink.gradient)
                    .frame(width: 40, height: 40)
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 18, weight: .semibold))
            }
            Text("YanMac Launcher")
                .font(.headline)
            ProgressView(L10n.t("Revisando tu Mac..."))
        }
        .frame(minWidth: 680, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Asistente de instalación (pasos 1 y 2, antes de estar listo)

private struct SetupFlowView: View {
    @EnvironmentObject var game: GameManager
    @Binding var showFilePicker: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.yanPink.gradient)
                        .frame(width: 40, height: 40)
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 18, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("YanMac Launcher")
                        .font(.headline)
                    Text(L10n.t("Para Yandere Simulator — no afiliado a YandereDev"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if game.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            // Igual que en TopBar: con la barra de título nativa oculta, los
            // botones rojo/amarillo/verde flotan encima de esta barra, así
            // que necesitan su espacio a la izquierda (64pt) en vez del
            // padding parejo que había antes, que dejaba el ícono montado
            // sobre esos botones.
            .padding(.leading, 64)
            .padding(.trailing, 20)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color.yanPinkSoft, Color.clear],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StepIndicator(stage: game.stage)

                    Card {
                        Group {
                            switch game.stage {
                            case .needsHomebrew:
                                HomebrewStepView()
                            case .needsWine:
                                WineStepView()
                            case .needsGame:
                                GameStepView(showFilePicker: $showFilePicker)
                            default:
                                EmptyView()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Tarjeta contenedora

private struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

// MARK: - Indicador de pasos

private struct StepIndicator: View {
    let stage: SetupStage

    private var stepNumber: Int {
        switch stage {
        case .checking: return 0
        case .needsHomebrew, .needsWine: return 1
        case .needsGame: return 2
        case .ready: return 3
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            pill(1, "Preparar WINE", active: stepNumber == 1, done: stepNumber > 1)
            connector(done: stepNumber > 1)
            pill(2, "Descargar el juego", active: stepNumber == 2, done: stepNumber > 2)
            connector(done: stepNumber > 2)
            pill(3, "Jugar", active: stepNumber == 3, done: false)
        }
    }

    private func connector(done: Bool) -> some View {
        Rectangle()
            .frame(height: 2)
            .foregroundStyle(done ? Color.yanPink.opacity(0.5) : Color.primary.opacity(0.1))
    }

    private func pill(_ number: Int, _ text: String, active: Bool, done: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(done ? Color.yanPink : (active ? Color.yanPink.opacity(0.15) : Color.primary.opacity(0.08)))
                    .frame(width: 20, height: 20)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(active ? Color.yanPink : .secondary)
                }
            }
            Text(L10n.t(text))
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Color.primary : .secondary)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Paso 1a: falta Homebrew

private struct HomebrewStepView: View {
    @EnvironmentObject var game: GameManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.t("Primero necesitamos Homebrew"), systemImage: "shippingbox.fill")
                .font(.headline)
            Text(L10n.t("Homebrew es el instalador que usa esta app para traer WINE (lo que permite correr el juego de Windows en tu Mac). Solo se instala una vez."))
                .foregroundStyle(.secondary)

            Button(L10n.t("Instalar Homebrew...")) {
                game.openHomebrewInstallInTerminal()
            }
            .buttonStyle(.borderedProminent)
            .tint(.yanPink)

            Text(L10n.t("Esto abre la Terminal con el comando ya escrito. Pulsa Enter, escribe tu contraseña de Mac cuando la pida (no se ve mientras escribes, es normal) y espera a que termine. Luego vuelve aquí y pulsa \"Ya lo instalé\"."))
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(L10n.t("Ya lo instalé, revisar de nuevo")) { game.recheckHomebrew() }
                .padding(.top, 4)

            if let message = game.homebrewCheckMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Paso 1b: falta WINE

private struct WineStepView: View {
    @EnvironmentObject var game: GameManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.t("Ahora instalemos WINE"), systemImage: "wineglass.fill")
                .font(.headline)
            Text(L10n.t("Esto permite correr el juego de Windows en tu Mac. Puede tardar varios minutos."))
                .foregroundStyle(.secondary)

            if game.isBusy {
                ProgressView(game.progressText)

                // Últimas líneas reales de lo que está haciendo brew, para
                // que no se sienta como un spinner congelado en una
                // instalación que puede tardar varios minutos.
                if !game.statusLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(game.statusLines.suffix(6), id: \.self) { line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.04)))
                }

                if game.canCancelInstall {
                    Button(L10n.t("Cancelar instalación"), role: .destructive) {
                        game.cancelInstall()
                    }
                    .padding(.top, 2)
                }
            } else {
                Button(L10n.t("Instalar WINE")) { game.installWine() }
                    .buttonStyle(.borderedProminent)
                    .tint(.yanPink)
            }
        }
    }
}

// MARK: - Paso 2: falta el juego

private struct GameStepView: View {
    @EnvironmentObject var game: GameManager
    @Binding var showFilePicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.t("Ahora, el juego"), systemImage: "arrow.down.circle.fill")
                .font(.headline)
            Text(L10n.t("Descarga Yandere Simulator, o si ya lo tienes en tu Mac, elige el archivo .exe a mano."))
                .foregroundStyle(.secondary)

            if game.isBusy {
                VStack(alignment: .leading, spacing: 8) {
                    if let fraction = game.downloadProgressFraction {
                        ProgressView(value: fraction) {
                            Text(game.progressText)
                        }
                    } else {
                        ProgressView(game.progressText)
                    }
                    if let text = game.downloadProgressText {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if game.canCancelInstall {
                        Button(L10n.t("Cancelar descarga"), role: .destructive) {
                            game.cancelInstall()
                        }
                    }
                }
            } else {
                HStack {
                    Button(L10n.t("Descargar el juego")) { game.downloadGame() }
                        .buttonStyle(.borderedProminent)
                        .tint(.yanPink)
                    Button(L10n.t("Ya lo tengo, elegir el .exe...")) { showFilePicker = true }
                }
            }
        }
    }
}

// MARK: - Secciones del Launcher principal (una vez listo)

enum LauncherSection: String, CaseIterable {
    case play, settings, mods, tools, console

    var icon: String {
        switch self {
        case .play: return "play.fill"
        case .settings: return "gearshape.fill"
        case .mods: return "puzzlepiece.extension.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .console: return "terminal.fill"
        }
    }

    var label: String {
        switch self {
        case .play: return "Jugar"
        case .settings: return "Opciones"
        case .mods: return "Mods"
        case .tools: return "Herramientas"
        case .console: return "Consola"
        }
    }
}

private struct MainLauncherView: View {
    @EnvironmentObject var game: GameManager
    @Binding var selectedSection: LauncherSection
    @Binding var showFilePicker: Bool
    @Binding var showModImporter: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Una sombra sutil (en vez del Divider plano que había antes)
            // le da un poco de profundidad a la barra superior, como en
            // apps nativas de macOS, sin verse como una línea dura.
            TopBar(selectedSection: selectedSection)
                .zIndex(1)
                .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)

            HStack(spacing: 0) {
                SidebarView(selectedSection: $selectedSection)

                Divider()

                // Opciones necesita su propia barra de "Guardar / Restablecer"
                // fija al fondo (que no se vaya con el scroll), así que se
                // arma aparte del resto de secciones, que sí van todas
                // dentro de un solo ScrollView simple.
                if selectedSection == .settings {
                    SettingsPaneView(showFilePicker: $showFilePicker)
                } else {
                    ScrollView {
                        Group {
                            switch selectedSection {
                            case .play:
                                PlaySectionView()
                            case .mods:
                                ModsSectionView(showModImporter: $showModImporter)
                            case .tools:
                                ToolsSectionView()
                            case .console:
                                ConsoleSectionView()
                            case .settings:
                                EmptyView() // Nunca se llega aquí (ver el if de arriba).
                            }
                        }
                        .padding(24)
                        // .center (no .leading): en una ventana grande o a
                        // pantalla completa, el contenido de cada sección
                        // tiene su propio ancho máximo (para que las
                        // tarjetas no queden gigantes), así que sin esto se
                        // quedaba pegado a la izquierda con todo el resto
                        // de la ventana vacío a la derecha.
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Barra superior (nombre del Launcher + sección actual)

private struct TopBar: View {
    @EnvironmentObject var game: GameManager
    let selectedSection: LauncherSection

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.yanPink.gradient)
                    .frame(width: 26, height: 26)
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("YanMac Launcher")
                .font(.subheadline.weight(.semibold))

            Divider().frame(height: 14)

            HStack(spacing: 6) {
                Image(systemName: selectedSection.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(L10n.t(selectedSection.label))
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)

            Spacer()

            if game.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("Trabajando..."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Con la barra de título nativa oculta (.windowStyle(.hiddenTitleBar)
        // en YansimLauncherApp), los botones rojo/amarillo/verde flotan
        // sobre esta barra. 64pt les deja el espacio justo (el clúster de
        // los tres botones mide ~54pt) sin dejar un hueco exagerado antes
        // de nuestro contenido, como pasaba con 78pt.
        .padding(.leading, 64)
        .padding(.trailing, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Color.yanSidebarBackground)
    }
}

// MARK: - Barra lateral de iconos

private struct SidebarView: View {
    @EnvironmentObject var game: GameManager
    @Binding var selectedSection: LauncherSection

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.yanPink.gradient)
                    .frame(width: 38, height: 38)
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.top, 16)
            .padding(.bottom, 14)

            ForEach(LauncherSection.allCases, id: \.self) { section in
                SidebarButton(
                    section: section,
                    isSelected: selectedSection == section,
                    action: { selectedSection = section }
                )
                // Separador entre "Jugar" y el resto de secciones — mismo
                // gesto que usa Modrinth para apartar Home/Library de las
                // demás pestañas de su barra lateral.
                if section == .play {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 32, height: 1)
                        .padding(.vertical, 6)
                }
            }

            Spacer()

            if game.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 16)
            }
        }
        .frame(width: 78)
        .frame(maxHeight: .infinity)
        .background(Color.yanSidebarBackground)
        .zIndex(1)
    }
}

/// Forma de la "burbuja" del tooltip: un rectángulo redondeado con una
/// colita triangular en el lado izquierdo que apunta al icono, igual que
/// el tooltip de Modrinth.
private struct TooltipBubble: Shape {
    var cornerRadius: CGFloat
    var tailSize: CGFloat

    func path(in rect: CGRect) -> Path {
        let bodyRect = CGRect(
            x: rect.minX + tailSize, y: rect.minY,
            width: rect.width - tailSize, height: rect.height
        )
        var path = Path(roundedRect: bodyRect, cornerRadius: cornerRadius)

        let midY = rect.midY
        var tail = Path()
        tail.move(to: CGPoint(x: bodyRect.minX, y: midY - tailSize))
        tail.addLine(to: CGPoint(x: rect.minX, y: midY))
        tail.addLine(to: CGPoint(x: bodyRect.minX, y: midY + tailSize))
        tail.closeSubpath()

        path.addPath(tail)
        return path
    }
}

/// Un botón de la barra lateral: icono solo (sin texto debajo), con un
/// círculo relleno cuando está seleccionado, y una etiqueta flotante con
/// colita que aparece pegada al icono al pasar el mouse (como en Modrinth).
private struct SidebarButton: View {
    let section: LauncherSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    private let buttonWidth: CGFloat = 62

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        isSelected ? Color.yanPink :
                            (isHovering ? Color.primary.opacity(0.08) : Color.clear)
                    )
                    .frame(width: 46, height: 46)
                Image(systemName: section.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
            .frame(width: buttonWidth, height: 54)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .overlay(alignment: .leading) {
            if isHovering {
                Text(L10n.t(section.label))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 8)
                    .padding(.trailing, 14)
                    .padding(.leading, 22)
                    .background(
                        TooltipBubble(cornerRadius: 8, tailSize: 8)
                            .fill(Color.black.opacity(0.92))
                    )
                    .fixedSize()
                    .offset(x: buttonWidth)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isHovering ? 10 : 0)
    }
}

// MARK: - Sección: Jugar

private struct PlaySectionView: View {
    @EnvironmentObject var game: GameManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.t("Jugar"))
                .font(.title2.weight(.bold))

            PlayHeroCard()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                StatTile(icon: "clock.fill", label: "Tiempo jugado", value: game.playTimeFormatted)
                StatTile(icon: "number", label: "Sesiones jugadas", value: "\(game.playSessionCount)")
                StatTile(icon: "calendar", label: "Última vez", value: game.lastPlayedFormatted)
                StatTile(icon: "square.stack.3d.up.fill", label: "Perfil", value: game.currentGraphicsProfileLabel)
                StatTile(
                    icon: game.updateAvailable ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill",
                    label: "Versión",
                    value: game.updateAvailable ? "Actualización disponible" : "Al día"
                )
            }
            .frame(maxWidth: 800)

            if game.updateAvailable {
                HStack {
                    Label(L10n.t("Hay una actualización del juego disponible"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button(L10n.t(game.isBusy ? "Descargando..." : "Actualizar ahora")) {
                        game.downloadGame()
                    }
                    .disabled(game.isBusy)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.yanPinkSoft))
                .frame(maxWidth: 420)
            }

            if game.isBusy {
                VStack(alignment: .leading, spacing: 6) {
                    // Si el vigilante detecta que el registro del juego
                    // lleva mucho tiempo sin cambiar mientras se juega, lo
                    // mostramos justo encima del botón, para que sepas que
                    // esta vez sí conviene forzar el cierre en vez de
                    // seguir esperando a ciegas.
                    // Nota: este texto no pasa por L10n.t() porque incluye
                    // un número que cambia (segundos sin actividad), igual
                    // que los mensajes de diagnose() — no es una de las
                    // cadenas fijas de Localizable.xcstrings.
                    if let hint = game.stuckGameHint {
                        Label(hint, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    Button(role: .destructive) {
                        game.forceQuitGame()
                    } label: {
                        Label(L10n.t("Forzar cierre"), systemImage: "xmark.octagon.fill")
                    }
                    Text(L10n.t("Úsalo si el juego se queda congelado (por ejemplo, en una cinemática) y no responde."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Ancho máximo (en vez de .infinity): así, en una ventana grande,
        // el contenido se centra en vez de quedarse pegado a la izquierda
        // con todo el resto vacío a la derecha.
        .frame(maxWidth: 900, alignment: .leading)
    }
}

/// Tarjeta principal de la sección Jugar: icono + nombre del juego + estado
/// a la izquierda, botón Jugar a la derecha. Reemplaza el botón estirado de
/// borde a borde por un panel que ocupa el ancho disponible sin dejar tanto
/// espacio muerto alrededor.
private struct PlayHeroCard: View {
    @EnvironmentObject var game: GameManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.yanPink.gradient)
                        .frame(width: 64, height: 64)
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 28, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Yandere Simulator")
                        .font(.title3.weight(.bold))
                    Label(game.statusMessage, systemImage: "checkmark.seal.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: { game.play() }) {
                    Label(L10n.t(game.isPlaying ? "Jugando..." : "Jugar"), systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yanPink)
                .controlSize(.large)
                .disabled(game.isBusy)
            }

            // Solo aparece cuando hay más de un .exe en la carpeta del
            // juego (el original + al menos uno que trajo un mod
            // activado, como PoseMod64.exe) — con un solo .exe no hay
            // nada entre qué elegir, así que no se muestra.
            if game.availableExecutables.count > 1 {
                Divider()
                HStack {
                    Text(L10n.t("Jugar con:"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { game.gameExeFileName ?? "" },
                        set: { newName in
                            if let folder = game.gameFolderURL {
                                game.chooseExeManually(folder.appendingPathComponent(newName).path)
                            }
                        }
                    )) {
                        ForEach(game.availableExecutables, id: \.self) { name in
                            Text(name.caseInsensitiveCompare(GameManager.exeName) == .orderedSame
                                 ? L10n.t("Sin mods (original)")
                                 : name)
                                .tag(name)
                        }
                    }
                    .labelsHidden()
                    .disabled(game.isBusy)
                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 640)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.yanPinkSoft))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.yanPink.opacity(0.15))
        )
    }
}

/// Mini-tarjeta de estadística (etiqueta arriba, valor abajo), usada en fila
/// dentro de la sección Jugar para que el espacio bajo la tarjeta principal
/// se sienta como un panel de control en vez de quedar vacío.
private struct StatTile: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.t(label), systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L10n.t(value))
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

// MARK: - Sección: Opciones

/// Categorías de Opciones, agrupadas como en el panel de Settings de
/// Modrinth: una barra lateral angosta con las categorías (agrupadas bajo
/// encabezados como "PANTALLA"/"JUEGO"/"SISTEMA") a la izquierda, y el
/// contenido de la categoría elegida a la derecha — en vez de un solo
/// scroll larguísimo con todo junto.
private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, language, game, gameFile, updates, about

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush.fill"
        case .language: return "globe"
        case .game: return "gamecontroller.fill"
        case .gameFile: return "doc.fill"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .appearance: return "Apariencia"
        case .language: return "Idioma"
        case .game: return "Juego"
        case .gameFile: return "Archivo del juego"
        case .updates: return "Actualizaciones"
        case .about: return "Acerca de"
        }
    }
}

private enum SettingsGroup: CaseIterable {
    case display, game, system

    var label: String {
        switch self {
        case .display: return "Pantalla"
        case .game: return "Juego"
        case .system: return "Sistema"
        }
    }

    var categories: [SettingsCategory] {
        switch self {
        case .display: return [.appearance, .language]
        case .game: return [.game, .gameFile]
        case .system: return [.updates, .about]
        }
    }
}

/// Envoltorio de la sección Opciones: barra de categorías + contenido en un
/// ScrollView aparte, y la barra de "Guardar / Restablecer" queda fija al
/// fondo, fuera de ambos — igual que en Modrinth, donde esa barra nunca se
/// va aunque cambies de categoría o bajes por el contenido.
private struct SettingsPaneView: View {
    @EnvironmentObject var game: GameManager
    @Binding var showFilePicker: Bool
    @State private var selectedCategory: SettingsCategory = .appearance

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SettingsCategorySidebar(selected: $selectedCategory)
                    .frame(width: 200)
                    .frame(maxHeight: .infinity)

                Divider()

                ScrollView {
                    SettingsCategoryContent(category: selectedCategory, showFilePicker: $showFilePicker)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            if game.hasUnsavedSettingsChanges {
                Divider()
                UnsavedChangesBar()
            }
        }
    }
}

/// La barra lateral angosta con las categorías agrupadas. Vive dentro de
/// Opciones, separada de la barra de iconos principal (Jugar/Mods/etc.) —
/// mismo patrón que usa Modrinth para su ventana de Settings.
private struct SettingsCategorySidebar: View {
    @Binding var selected: SettingsCategory

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.t("Opciones"))
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.top, 2)

                ForEach(SettingsGroup.allCases, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        SectionLabel(group.label)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 2)
                        ForEach(group.categories) { category in
                            SettingsCategoryButton(
                                category: category,
                                isSelected: selected == category,
                                action: { selected = category }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 16)
        }
        .background(Color.primary.opacity(0.03))
    }
}

/// Un botón de categoría dentro de Opciones: ícono + nombre, con una
/// "píldora" rosa rellena cuando está seleccionada (igual que el verde de
/// Modrinth para su categoría activa, "Appearance" en el video).
private struct SettingsCategoryButton: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(L10n.t(category.label))
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.yanPink : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Barra fija al fondo de Opciones que aparece solo cuando hay cambios sin
/// aplicar en el borrador (game.draftAppTheme, etc.). "Restablecer" descarta
/// el borrador; "Guardar" lo aplica de verdad (y cada ajuste ya se persiste
/// solo en UserDefaults a través de su propio didSet en GameManager).
private struct UnsavedChangesBar: View {
    @EnvironmentObject var game: GameManager

    var body: some View {
        HStack {
            Text(L10n.t("Tienes cambios sin guardar."))
                .foregroundStyle(.secondary)
            Spacer()
            Button(L10n.t("Restablecer")) { game.resetSettingsDraft() }
                .buttonStyle(.bordered)
            Button(L10n.t("Guardar")) { game.saveSettings() }
                .buttonStyle(.borderedProminent)
                .tint(.yanPink)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.background.secondary)
    }
}

/// Etiqueta de sección en mayúsculas pequeñas y color secundario (p. ej.
/// "APARIENCIA"), como los encabezados de grupo ("DISPLAY", "ACCOUNT") en
/// el panel de ajustes de Modrinth.
private struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        // .textCase(.uppercase) en vez de .uppercased() a mano: así se
        // traduce el texto original (p. ej. "Apariencia") y RECIÉN
        // después se pone en mayúsculas para mostrarlo — si hiciéramos
        // .uppercased() antes de traducir, buscaríamos "APARIENCIA" en
        // vez de "Apariencia" y no encontraría su traducción.
        Text(L10n.t(text))
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.5)
    }
}

/// El contenido de la categoría elegida en la barra de la izquierda. Cada
/// categoría muestra su propio título (ya no hace falta el "Opciones"
/// repetido ni los Divider entre secciones — eso ahora lo resuelve estar en
/// pantallas separadas).
private struct SettingsCategoryContent: View {
    @EnvironmentObject var game: GameManager
    let category: SettingsCategory
    @Binding var showFilePicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t(category.label))
                .font(.title2.weight(.bold))

            switch category {
            case .appearance: appearanceContent
            case .language: languageContent
            case .game: gameContent
            case .gameFile: gameFileContent
            case .updates: updatesContent
            case .about: aboutContent
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder private var appearanceContent: some View {
        HStack(spacing: 12) {
            ThemeOptionCard(theme: .system, selection: $game.draftAppTheme)
            ThemeOptionCard(theme: .light, selection: $game.draftAppTheme)
            ThemeOptionCard(theme: .dark, selection: $game.draftAppTheme)
        }
        .frame(maxWidth: 640)
    }

    @ViewBuilder private var languageContent: some View {
        HStack(spacing: 12) {
            LanguageOptionCard(language: .english, selection: $game.draftAppLanguage)
            LanguageOptionCard(language: .spanish, selection: $game.draftAppLanguage)
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder private var gameContent: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(GraphicsProfile.allCases) { profile in
                GraphicsProfileCard(
                    profile: profile,
                    isSelected: game.matchingDraftGraphicsProfile == profile,
                    action: { game.applyGraphicsProfile(profile) }
                )
            }
        }
        .frame(maxWidth: 640, alignment: .leading)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.t("Modo gráfico:"))
                Picker("", selection: $game.draftGraphicsModeIndex) {
                    ForEach(graphicsModes.indices, id: \.self) { i in
                        Text(L10n.t(graphicsModes[i].label)).tag(i)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Text(L10n.t("Si el juego se cierra solo, prueba cambiar esto antes que nada."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle(L10n.t("Reducir validación de Metal (experimental)"), isOn: $game.draftReduceMetalValidation)
                .toggleStyle(.switch)
            Text(L10n.t("Si el juego se congela (la imagen se queda pegada pero el audio sigue), esto puede evitarlo, a cambio de algún glitch visual pasajero. No es un arreglo garantizado."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle(L10n.t("Mostrar FPS mientras juegas"), isOn: $game.draftShowMetalHUD)
                .toggleStyle(.switch)
            Text(L10n.t("Muestra el contador de FPS nativo de macOS encima del juego. Útil para comparar de verdad el rendimiento entre un perfil de gráficos y otro."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if game.matchingDraftGraphicsProfile == nil {
                Text(L10n.t("Personalizado (no coincide con ningún perfil de arriba)."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }

    @ViewBuilder private var gameFileContent: some View {
        HStack {
            Button(L10n.t("Elegir otro .exe...")) { showFilePicker = true }
            Button(L10n.t("Revisar de nuevo")) {
                // refresh() es tan rápido que, cuando el resultado no
                // cambia (el .exe ya estaba detectado), el mensaje de abajo
                // se queda exactamente igual y el botón se siente "muerto"
                // aunque sí hizo su trabajo. Este pequeño retraso muestra
                // "Revisando..." un instante antes del resultado, para que
                // el clic siempre se sienta como que pasó algo.
                game.gameFileCheckMessage = L10n.t("Revisando...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    game.refresh()
                }
            }
        }
        // "Revisar de nuevo" sí hacía su trabajo (volvía a buscar el .exe),
        // pero esta pantalla nunca mostraba el resultado, así que se sentía
        // como si no pasara nada. game.gameFileCheckMessage se actualiza al
        // final de refresh() — ver GameManager.swift.
        if let message = game.gameFileCheckMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var updatesContent: some View {
        HStack {
            Button(L10n.t(game.isCheckingUpdate ? "Buscando..." : "Buscar actualizaciones")) {
                game.checkForUpdate(manual: true)
            }
            .disabled(game.isCheckingUpdate)
            if game.isCheckingUpdate {
                ProgressView().controlSize(.small)
            }
        }
        if let message = game.updateCheckMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("YanMac Launcher").font(.subheadline.weight(.semibold))
                Text(GameManager.appVersionString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.t("WINE detectado:") + " " + (game.wineVersionString ?? L10n.t("No detectado")))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Button(L10n.t("Copiar informe para reportar un problema")) {
            game.copyDiagnosticReportToClipboard()
        }
        Text(L10n.t("Junta la versión de la app, de WINE, tus ajustes gráficos y las últimas líneas del registro en un solo texto, listo para pegar donde reportes el problema."))
            .font(.caption)
            .foregroundStyle(.secondary)
        if let message = game.reportCopiedMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Tarjeta de tema con una vista previa en miniatura (como las de "Dark" /
/// "Light" en Modrinth) en vez del segmented picker de antes. Toca la
/// tarjeta para seleccionarla; el punto relleno indica cuál está elegida.
private struct ThemeOptionCard: View {
    let theme: AppTheme
    @Binding var selection: AppTheme

    private var isSelected: Bool { selection == theme }

    var body: some View {
        Button(action: { selection = theme }) {
            VStack(alignment: .leading, spacing: 10) {
                ThemePreviewMock(theme: theme)
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Color.yanPink : .secondary)
                    Text(L10n.t(theme.label))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: theme.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.yanPink : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Tarjeta de un perfil de gráficos (Rendimiento / Calidad / Compatibilidad):
/// aplica de una sola vez la combinación de modo gráfico + validación de
/// Metal que le corresponde a ese perfil, en vez de tocar los dos ajustes
/// por separado.
private struct GraphicsProfileCard: View {
    let profile: GraphicsProfile
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: profile.icon)
                        .foregroundStyle(isSelected ? Color.yanPink : .secondary)
                    Text(L10n.t(profile.label))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Color.yanPink : .secondary)
                }
                Text(L10n.t(profile.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.yanPink : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Miniatura falsa de una ventana (icono + un par de líneas de texto) que
/// se ve clara, oscura, o mitad y mitad según el tema — solo para dar una
/// idea visual rápida de qué hace cada opción, no una vista previa real.
private struct ThemePreviewMock: View {
    let theme: AppTheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(iconColor)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(lineColor).frame(width: 44, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(lineColor.opacity(0.6)).frame(width: 28, height: 5)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var background: some View {
        switch theme {
        case .light:
            Color.white
        case .dark:
            Color(white: 0.15)
        case .system:
            LinearGradient(colors: [Color.white, Color(white: 0.15)], startPoint: .leading, endPoint: .trailing)
        }
    }

    private var iconColor: Color {
        switch theme {
        case .light: return Color.black.opacity(0.12)
        case .dark: return Color.white.opacity(0.2)
        case .system: return Color.gray.opacity(0.35)
        }
    }

    private var lineColor: Color {
        switch theme {
        case .light: return Color.black.opacity(0.6)
        case .dark: return Color.white.opacity(0.75)
        case .system: return Color.gray
        }
    }
}

/// Tarjeta de idioma: bandera + nombre del idioma EN SÍ MISMO (nunca
/// traducido — "Español" se ve igual aunque el resto de la app esté en
/// inglés, que es como funcionan los selectores de idioma normalmente).
private struct LanguageOptionCard: View {
    let language: AppLanguage
    @Binding var selection: AppLanguage

    private var isSelected: Bool { selection == language }

    var body: some View {
        Button(action: { selection = language }) {
            HStack(spacing: 10) {
                Text(language.flag)
                    .font(.title2)
                Text(language.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.yanPink : .secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.yanPink : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sección: Herramientas

private struct ToolsSectionView: View {
    @EnvironmentObject var game: GameManager
    @State private var showResetConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.t("Herramientas"))
                .font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Accesos rápidos"))
                    .font(.headline)
                HStack {
                    Button(L10n.t("Abrir carpeta del juego")) { game.openGameFolder() }
                    Button(L10n.t("Abrir capturas")) { game.openScreenshotsFolder() }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Organizar carpeta del juego"))
                    .font(.headline)
                Text(L10n.t("Antes de mover nada, se hace un respaldo completo de tu carpeta del juego (juego + mods tal como están). Después, solo se guardan aparte los archivos de texto sueltos (instrucciones, changelog) en una carpeta \"Documentación y extras\" — las carpetas de mods y los archivos del juego NO se tocan, para no arriesgarse a romper algo."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L10n.t(game.isBackingUpGameFolder ? "Respaldando..." : "Solo hacer respaldo completo")) {
                        game.backupGameFolder()
                    }
                    .disabled(game.isBackingUpGameFolder || game.isOrganizingGameFolder)

                    Button(L10n.t(game.isOrganizingGameFolder ? "Organizando..." : "Respaldar y organizar")) {
                        game.organizeGameFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.yanPink)
                    .disabled(game.isBackingUpGameFolder || game.isOrganizingGameFolder)

                    if game.isBackingUpGameFolder || game.isOrganizingGameFolder {
                        ProgressView().controlSize(.small)
                    }
                }
                if let message = game.gameFolderBackupMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = game.organizeGameFolderMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Copia de seguridad de partidas"))
                    .font(.headline)
                Text(L10n.t("Busca tus partidas guardadas y guarda una copia aparte, por si algo sale mal."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L10n.t(game.isBackingUp ? "Respaldando..." : "Hacer copia de seguridad")) {
                        game.backupSaves()
                    }
                    .disabled(game.isBackingUp)
                    if game.isBackingUp {
                        ProgressView().controlSize(.small)
                    }
                    Button(L10n.t("Abrir copias de seguridad")) { game.openBackupsFolder() }
                }
                if let message = game.backupMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Verificar archivos del juego"))
                    .font(.headline)
                Button(L10n.t(game.isVerifying ? "Revisando..." : "Verificar archivos")) {
                    game.verifyGameFiles()
                }
                .disabled(game.isVerifying)
                if game.isVerifying {
                    if let fraction = game.verifyProgressFraction {
                        ProgressView(value: fraction) {
                            Text("\(Int(fraction * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                if let results = game.verifyResults {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(
                                    line.hasPrefix("✘") ? .red :
                                    (line.hasPrefix("✔") ? .green : .secondary)
                                )
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Texto que no aparece (HUD)"))
                    .font(.headline)
                Text(L10n.t("Las fuentes de Windows que necesita el HUD (vida, misiones, menús) ya se instalan solas la primera vez que todo queda listo. Usa este botón solo si ese texto sigue sin verse, o si crees que la instalación automática falló."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L10n.t(game.isInstallingFonts ? "Instalando..." : "Reinstalar fuentes de Windows")) {
                        game.installFonts()
                    }
                    .disabled(game.isInstallingFonts || game.isBusy)
                    if game.isInstallingFonts {
                        ProgressView().controlSize(.small)
                    }
                }
                if let message = game.fontsInstallMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Si algo no funciona"))
                    .font(.headline)
                HStack {
                    Button(L10n.t("Reparar parche")) { game.repairShim() }
                    Button(L10n.t("Reinstalar el juego"), role: .destructive) { game.reinstallGame() }
                }
                Text(L10n.t("\"Reparar parche\" vuelve a copiar el archivo que arregla el mouse y los gráficos. \"Reinstalar el juego\" borra la copia actual (solo si la descargaste desde aquí) para bajarla de nuevo."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 2)

                Button(L10n.t("Diagnóstico seguro")) { game.runDiagnosticMode() }
                    .disabled(game.isBusy)
                Text(L10n.t("Abre el juego en una ventana chica, con Direct3D 11 y validación de Metal reducida, sin tocar tus ajustes guardados. Sirve para saber si el problema es de la instalación en general o de algún ajuste gráfico en particular: si aquí corre bien pero con \"Jugar\" no, el problema está en tus ajustes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Restablecer ajustes del juego"))
                    .font(.headline)
                Text(L10n.t("Si activaste una opción gráfica (como el pasto) y ahora el juego se congela siempre al abrir, esto borra esos ajustes guardados para que abra \"de fábrica\", como la primera vez. No borra tus partidas guardadas."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.t(game.isResettingSettings ? "Restableciendo..." : "Restablecer ajustes"), role: .destructive) {
                    showResetConfirm = true
                }
                .disabled(game.isResettingSettings || game.isBusy)
                if let message = game.resetSettingsMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
        .confirmationDialog(
            L10n.t("¿Restablecer los ajustes del juego?"),
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.t("Restablecer ajustes"), role: .destructive) {
                game.resetGameSettings()
            }
            Button(L10n.t("Cancelar"), role: .cancel) {}
        } message: {
            Text(L10n.t("Esto borra la resolución, calidad gráfica, controles y otras opciones guardadas del juego. Tus partidas guardadas no se tocan."))
        }
    }
}

// MARK: - Sección: Mods

/// Yandere Simulator no tiene una API de mods oficial y documentada, así
/// que esto usa la convención más común entre juegos de Unity: una carpeta
/// "Mods" junto al .exe, con una carpeta por cada mod. A diferencia de un
/// mod "parche chico", los mods de Yandere Simulator casi siempre traen su
/// propia copia completa de los datos del juego (YandereSimulator_Data,
/// UnityPlayer.dll, etc.) y su propio .exe — por eso aquí solo uno puede
/// estar activo a la vez (como una selección única, no checkboxes
/// independientes): activar uno apaga cualquier otro automáticamente, para
/// no mezclar archivos de versiones distintas del juego entre sí.
private struct ModsSectionView: View {
    @EnvironmentObject var game: GameManager
    @Binding var showModImporter: Bool
    @State private var pendingDelete: ModEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.t("Mods"))
                    .font(.title2.weight(.bold))
                Spacer()
                Button {
                    showModImporter = true
                } label: {
                    Label(L10n.t("Subir mod..."), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.yanPink)
            }

            Text(L10n.t("Sube el .zip o la carpeta de un mod (como PoseMod). Solo uno puede estar activo a la vez — casi todos traen su propia copia completa del juego, así que activar dos juntos los mezclaría mal. Al activar uno, sus archivos se copian encima del juego y la app guarda una copia de tus archivos originales primero, para poder devolverlos si lo desactivas."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(L10n.t("Usar juego original (sin mods)")) { game.disableAllMods() }
                    .disabled(game.mods.allSatisfy { !$0.isEnabled })
                Spacer()
                Button(L10n.t("Abrir carpeta de Mods")) { game.openModsFolder() }
                    .buttonStyle(.borderless)
                Button(L10n.t("Actualizar")) { game.refreshMods() }
                    .buttonStyle(.borderless)
            }

            if game.isImportingMods {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = game.modImportProgressFraction {
                        ProgressView(value: fraction) {
                            Text(L10n.t("Subiendo mod..."))
                        }
                    } else {
                        ProgressView(L10n.t("Subiendo mod..."))
                    }
                    if let text = game.modImportProgressText {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let message = game.modImportMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if game.mods.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(L10n.t("Todavía no subiste ningún mod."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.primary.opacity(0.06))
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(game.mods) { mod in
                        ModRow(
                            mod: mod,
                            onToggle: { game.toggleMod(mod) },
                            onDelete: { pendingDelete = mod }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .onAppear { game.refreshMods() }
        .confirmationDialog(
            L10n.t("¿Quitar este mod?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.t("Quitar mod"), role: .destructive) {
                if let mod = pendingDelete { game.deleteMod(mod) }
                pendingDelete = nil
            }
            Button(L10n.t("Cancelar"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L10n.t("Si estaba activado, primero se restauran tus archivos originales del juego. Después se borra la copia guardada del mod. No se puede deshacer."))
        }
    }
}

/// Una fila por mod: ícono genérico + nombre + interruptor para
/// activarlo/desactivarlo + botón de basura para quitarlo del todo.
private struct ModRow: View {
    let mod: ModEntry
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill((mod.isEnabled ? Color.yanPink : Color.secondary).opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(mod.isEnabled ? Color.yanPink : .secondary)
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(mod.id)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(mod.isEnabled ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: Binding(get: { mod.isEnabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch)
                .tint(Color.yanPink)
                .labelsHidden()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

// MARK: - Sección: Consola

private struct ConsoleSectionView: View {
    @EnvironmentObject var game: GameManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("Consola"))
                    .font(.title2.weight(.bold))
                Spacer()
                Button(L10n.t("Copiar")) { game.copyLogToClipboard() }
                    .buttonStyle(.borderless)
                Button(L10n.t("Limpiar")) { game.clearLog() }
                    .buttonStyle(.borderless)
                Button(L10n.t("Abrir archivo de registro")) { game.openLog() }
                    .buttonStyle(.borderless)
                Button(L10n.t("Abrir carpeta de registros")) { game.openLogsFolder() }
                    .buttonStyle(.borderless)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    if game.statusLines.isEmpty {
                        Text(L10n.t("Aquí va a aparecer lo que pase al instalar, descargar o jugar."))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(game.statusLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(color(for: line))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .id("log-bottom")
                    }
                }
                .frame(minHeight: 380)
                .background(Color.black.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onChange(of: game.statusLines.count) {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("✔") { return .green }
        if line.hasPrefix("✘") { return .red }
        if line.hasPrefix("•") { return .orange }
        if line.hasPrefix("==") { return .secondary }
        return .primary
    }
}
