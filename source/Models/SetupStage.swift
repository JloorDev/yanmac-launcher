import Foundation
import Combine
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Los tres pasos que ve el usuario, en orden. La interfaz solo muestra
/// el paso actual — nunca más de uno a la vez — para que nadie se
/// pierda entre botones que no sabe en qué orden usar.
enum SetupStage: Equatable {
    case checking
    case needsHomebrew
    case needsWine
    case needsGame
    case ready
}
