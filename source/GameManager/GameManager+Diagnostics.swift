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
    // MARK: - Diagnóstico

    static func diagnose(_ text: String) -> [String] {
        let t = text.lowercased()
        var hints: [String] = []

        if t.contains("ismouseinpointerenabled") || t.contains("createfence") || t.contains("id3d11device5") {
            hints.append("""
                Este juego usa Unity 6 y necesita el parche version.dll junto \
                al .exe. La app intenta copiarlo sola; si sigue fallando, borra \
                version.dll de la carpeta del juego y vuelve a intentar para \
                que la app lo vuelva a copiar.
                """)
        }
        if ["d3d11", "direct3d", "failed to create device", "d3dmetal", "dxgi", "graphics device"]
            .contains(where: { t.contains($0) }) {
            hints.append("""
                Problema gráfico: WINE no logró crear el dispositivo Direct3D. \
                Prueba el modo 'Forzar Direct3D 11'.
                """)
        }
        if ["mtldebugrendercommandencoder", "validatecommondrawerrors", "missing buffer binding",
            "draw errors validation", "failed assertion"]
            .contains(where: { t.contains($0) }) {
            hints.append("""
                Metal (el traductor de gráficos de Apple) rechazó un shader \
                del juego a mitad de un dibujo, y por eso se congeló la \
                imagen mientras el audio sigue sonando aparte. Es un shader \
                específico que GPTK tradujo mal, no algo que dependa de tu \
                Mac. Prueba activar 'Reducir validación de Metal \
                (experimental)' en Opciones — puede evitar que se congele, \
                a cambio de algún glitch visual pasajero. Este mismo tipo \
                de fallo también puede explicar texto (HUD, TextMeshPro) \
                que no se dibuja.
                """)
        }
        if t.contains("bad cpu type") {
            hints.append("Falta Rosetta 2. La app puede pedirlo la primera vez que instala WINE; si no, instálalo desde una Terminal con: softwareupdate --install-rosetta --agree-to-license")
        }
        if t.contains("unhandled exception") || t.contains("c0000005") {
            hints.append("El juego tuvo una falla interna. Suele deberse a gráficos o a archivos del juego dañados (intenta 'Descargar juego' de nuevo).")
        }
        if t.contains("err:module") || t.contains("could not load") || t.contains("import_dll") {
            hints.append("A WINE le falta un componente de Windows (una DLL). Copia el mensaje del registro y pregúntame por él.")
        }
        if t.contains("out of memory") {
            hints.append("Se quedó sin memoria. Cierra otras apps y vuelve a intentar.")
        }
        if t.contains("no space left on device") || t.contains("enospc") {
            hints.append("Tu Mac se quedó sin espacio en disco a mitad de la partida. Libera espacio (por ejemplo, en la papelera o en Descargas) y vuelve a intentar.")
        }
        if ["no such file or directory", "cannot find the file", "the system cannot find the path"]
            .contains(where: { t.contains($0) }) {
            hints.append("Falta un archivo que el juego necesita. Prueba 'Verificar archivos del juego' en Herramientas; si sigue fallando, 'Reinstalar el juego' vuelve a bajarlo completo.")
        }
        if ["segmentation fault", "sigsegv", "sigabrt", "wine has crashed"]
            .contains(where: { t.contains($0) }) {
            hints.append("WINE se cerró de golpe por una falla interna (no algo que el juego haya causado a propósito). Suele arreglarse con 'Reparar parche' o, si persiste, reinstalando el juego.")
        }
        if t.contains("permission denied") || t.contains("operation not permitted") {
            hints.append("macOS bloqueó el acceso a un archivo (a veces pasa con juegos bajados fuera de la App Store, por Gatekeeper). Prueba 'Reparar parche'; si sigue, puede que necesites reinstalar el juego desde aquí.")
        }
        if hints.isEmpty {
            hints.append("No reconocí una causa conocida en el registro. Copia el registro de abajo para revisarlo.")
        }
        return hints
    }

}
