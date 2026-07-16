import AutoThemeSwitcherCore
import SwiftUI

@main
@MainActor
struct AutoThemeSwitcherApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(controller: controller)
        } label: {
            Label("Auto Theme Switcher", systemImage: controller.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
