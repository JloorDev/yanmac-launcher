import Foundation
import Combine
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Modo gráfico: nombre visible + argumentos extra para el juego (Unity).
struct GraphicsMode: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let args: [String]
}

// Solo Automático y Direct3D 11: el WINE de esta app corre sobre Apple
// Game Porting Toolkit, que traduce Direct3D a Metal — no tiene soporte
// real de OpenGL, así que "Forzar OpenGL" solo causa errores como
// "InitializeEngineGraphics failed" y se quitó de las opciones.
let graphicsModes: [GraphicsMode] = [
    GraphicsMode(label: "Automático", args: []),
    GraphicsMode(label: "Forzar Direct3D 11", args: ["-force-d3d11"]),
]

/// Combinación lista para usar de "modo gráfico" + "validación de Metal",
/// para no tener que tocar los dos ajustes por separado cada vez. Cada
/// perfil prioriza algo distinto (velocidad, fidelidad visual, o evitar
/// que el juego se congele).
enum GraphicsProfile: String, CaseIterable, Identifiable, Hashable {
    case performance, quality, compatibility

    var id: String { rawValue }

    var label: String {
        switch self {
        case .performance: return "Rendimiento"
        case .quality: return "Calidad"
        case .compatibility: return "Compatibilidad"
        }
    }

    var summary: String {
        switch self {
        case .performance:
            return "La combinación más rápida: traducción automática de gráficos, sin la validación extra de Metal."
        case .quality:
            return "La más fiel a como se ve el juego, con todas las verificaciones de Metal activas."
        case .compatibility:
            return "Si el juego no abre o se congela seguido, suele ser la más estable, a cambio de algo de calidad visual."
        }
    }

    var icon: String {
        switch self {
        case .performance: return "hare.fill"
        case .quality: return "sparkles"
        case .compatibility: return "wrench.and.screwdriver.fill"
        }
    }

    /// Índice dentro de `graphicsModes` (0 = Automático, 1 = Forzar Direct3D 11).
    var graphicsModeIndex: Int {
        switch self {
        case .performance, .quality: return 0
        case .compatibility: return 1
        }
    }

    var reduceMetalValidation: Bool {
        switch self {
        case .performance, .compatibility: return true
        case .quality: return false
        }
    }
}
