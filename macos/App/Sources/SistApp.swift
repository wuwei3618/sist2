import AppKit
import SwiftUI

@main
struct SistMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Sist", id: "main") {
            ContentView()
                .environment(model)
                .environment(model.search)
                .frame(minWidth: 960, minHeight: 600)
                .task { await model.start() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("添加文件夹…") { model.chooseFoldersToAdd() }
                    .keyboardShortcut("o")
            }
            CommandMenu("索引") {
                Button("扫描全部文件夹") { model.scanAll() }
                    .keyboardShortcut("r")
                Button("停止扫描") { model.cancelAllScans() }
                    .keyboardShortcut(".")
                    .disabled(model.activeScans.isEmpty)
            }
        }

        Window("统计", id: "stats") {
            StatsView()
                .environment(model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run from `swift run` or Xcode's SistApp scheme there is no app bundle: without this
        // the process gets no Dock icon, menu bar or key window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
