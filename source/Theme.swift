import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Colores de marca de YanMac Launcher, tomados del icono original del
/// juego (el corazón blanco sobre fondo rosa/fucsia). En vez de usar el
/// `Color.pink` genérico del sistema, definimos nuestro propio rosa y lo
/// ajustamos un poco para que se vea bien tanto en tema claro como oscuro.
///
/// `NSColor(name:dynamicProvider:)` elige el valor según la apariencia
/// activa en ese momento — y como forzamos el tema con
/// `.preferredColorScheme` en ContentView, esto cambia solo cuando el
/// usuario cambia el tema en Opciones, sin que tengamos que pasar el
/// color a mano por cada vista.
extension Color {
    static let yanPink = Color(nsColor: .adaptive(
        light: NSColor(red: 1.00, green: 0.29, blue: 0.66, alpha: 1.0),
        dark: NSColor(red: 1.00, green: 0.42, blue: 0.75, alpha: 1.0)
    ))

    static let yanPinkSoft = Color(nsColor: .adaptive(
        light: NSColor(red: 1.00, green: 0.29, blue: 0.66, alpha: 0.12),
        dark: NSColor(red: 1.00, green: 0.42, blue: 0.75, alpha: 0.18)
    ))

    static let yanSidebarBackground = Color(nsColor: .adaptive(
        light: NSColor(red: 0.99, green: 0.96, blue: 0.98, alpha: 1.0),
        dark: NSColor(red: 0.13, green: 0.11, blue: 0.13, alpha: 1.0)
    ))
}

#if canImport(AppKit)
extension NSColor {
    /// Crea un NSColor que se resuelve distinto según si la apariencia
    /// activa es clara u oscura.
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }
}
#endif
