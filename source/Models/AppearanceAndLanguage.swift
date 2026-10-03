import Foundation
import Combine
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Tema visual del Launcher: puede seguir el modo del sistema, o forzar
/// siempre claro u oscuro sin importar lo que tenga el Mac.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Claro"
        case .dark: return "Oscuro"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// Lo que espera `.preferredColorScheme(_:)`: `nil` deja que macOS decida.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Traduce los textos fijos de la interfaz pidiéndole el string DIRECTAMENTE
/// al bundle del idioma elegido, en vez de dejar que SwiftUI lo resuelva solo
/// a partir de `.environment(\.locale, ...)`.
///
/// Por qué: cuando el idioma elegido es el mismo que el "idioma fuente" del
/// catálogo de traducciones (aquí, español — todo el código está escrito en
/// español), SwiftUI a veces no vuelve a resolver el texto correctamente
/// solo con `.environment(\.locale)` — es un comportamiento conocido y poco
/// documentado de los String Catalogs. Pedirle el string al bundle exacto
/// (`es.lproj` o `en.lproj`) nosotros mismos evita depender de eso: siempre
/// funciona igual sin importar cuál sea el idioma "fuente".
enum L10n {
    /// El bundle del idioma activo ahora mismo. GameManager lo actualiza
    /// cada vez que cambia `appLanguage` (ver su `didSet`).
    static var bundle: Bundle = .main

    /// Cuando el idioma activo es español, no buscamos nada en ningún
    /// bundle: el `key` que se le pasa a `t(_:)` YA es el texto en español
    /// (así está escrito en el código), así que se devuelve tal cual.
    ///
    /// Esto evita depender de que exista una carpeta `es.lproj` en la app
    /// compilada. Como español es el "idioma fuente" del catálogo de
    /// traducciones, Xcode guarda esos textos en `Base.lproj`, NO en
    /// `es.lproj` — buscar `es.lproj` a mano (como hacíamos antes) fallaba
    /// siempre, y el fallback a `Bundle.main` terminaba resolviendo según
    /// el idioma del sistema operativo en vez del idioma elegido dentro
    /// de la app. Por eso cambiar a Español no tenía ningún efecto.
    static var usesKeyDirectly: Bool = false

    /// Busca `key` (el texto tal cual está escrito en el código, en
    /// español) en el bundle del idioma activo.
    static func t(_ key: String) -> String {
        if usesKeyDirectly { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Recalcula `bundle` para el idioma dado. Se llama al arrancar y cada
    /// vez que se guarda un cambio de idioma en Opciones.
    static func refresh(for language: AppLanguage) {
        switch language {
        case .spanish:
            usesKeyDirectly = true
            bundle = .main
        case .english:
            usesKeyDirectly = false
            if let path = Bundle.main.path(forResource: language.localeIdentifier, ofType: "lproj"),
               let languageBundle = Bundle(path: path) {
                bundle = languageBundle
            } else {
                bundle = .main
            }
        }
    }
}

/// Idioma de la interfaz. El nombre de cada idioma (label) se muestra
/// siempre igual, sin traducir — así es como se hace normalmente en un
/// selector de idioma (verías "Español" ahí aunque el resto de la app
/// esté en inglés).
enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
    case english, spanish

    var id: String { rawValue }

    var label: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        }
    }

    var flag: String {
        switch self {
        case .english: return "🇺🇸"
        case .spanish: return "🇪🇸"
        }
    }

    /// Identificador de configuración regional (BCP-47) que se le pasa a
    /// `.environment(\.locale, ...)` para forzar el idioma de la interfaz
    /// sin importar el idioma del sistema.
    var localeIdentifier: String {
        switch self {
        case .english: return "en"
        case .spanish: return "es"
        }
    }
}
