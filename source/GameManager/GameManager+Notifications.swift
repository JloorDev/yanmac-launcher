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
    // MARK: - Notificaciones

    /// Pide permiso una sola vez para mostrar notificaciones nativas de
    /// macOS (solo visuales, sin sonido — nada de esto suena todavía a
    /// propósito). Si el usuario lo niega, `notify(...)` simplemente no
    /// muestra nada; no hace falta revisarlo en cada llamada.
    func requestNotificationPermissionIfNeeded() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        #endif
    }

    /// Muestra una notificación nativa de macOS, para enterarte de que algo
    /// que tardó (instalar fuentes, verificar archivos, hacer una copia de
    /// seguridad...) ya terminó, aunque hayas cambiado de ventana o de app
    /// mientras esperabas.
    func notify(_ title: String, _ body: String) {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        #endif
    }

}
