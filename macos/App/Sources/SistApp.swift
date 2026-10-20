import AppKit
import SwiftUI

@main
struct SistMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppModel.showMenuBarItemKey) private var showMenuBarItem = true

    var body: some Scene {
        let model = appDelegate.model

        // One main window: the quick search panel and the menu bar bring it back after it is closed
        Window("Sist", id: "main") {
            ContentView()
                .environment(model)
                .environment(model.search)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("添加文件夹…") { model.chooseFoldersToAdd() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存搜索…") { model.search.isSavingSearch = true }
                    .keyboardShortcut("s")
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

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarMenu()
                .environment(model)
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
        }
    }
}

/// The menu of the menu bar item
private struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button("快速搜索…") { model.showQuickSearch() }
            if model.quickSearchShortcut != .none {
                Text("快捷键 \(model.quickSearchShortcut.displayName)")
            }
            Button("打开 Sist") { model.showMainWindow() }
            Divider()
            if !model.activeScans.isEmpty {
                Text("正在扫描 \(model.activeScans.count) 个文件夹…")
            }
            Button("扫描全部文件夹") { model.scanAll() }
                .disabled(model.sources.isEmpty)
            Divider()
            SettingsLink {
                Text("设置…")
            }
            Button("退出 Sist") { NSApp.terminate(nil) }
        }
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run from `swift run` or Xcode's SistApp scheme there is no app bundle: without this
        // the process gets no Dock icon, menu bar or key window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        Task { await model.start() }
    }

    /// With the menu bar item, the app keeps running for the quick search shortcut and to keep
    /// the index up to date
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.showsMenuBarItem
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            model.showMainWindow()
        }
        return true
    }
}
