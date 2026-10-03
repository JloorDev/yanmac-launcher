import Foundation
import Combine
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Un mod instalado: un archivo o carpeta dentro de "Mods", junto al .exe
/// del juego. `id` es el nombre sin el sufijo ".disabled".
struct ModEntry: Identifiable, Hashable {
    let id: String
    let isEnabled: Bool
    let itemURL: URL
}
