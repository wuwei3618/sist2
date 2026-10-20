import AppKit
import SistCore
import SistScan
import SistService
import SistStore

/// The background agent: a login item without any user interface (Sist.app/Contents/Library/
/// LoginItems/SistAgent.app, registered by the app with SMAppService). It keeps the catalog up
/// to date while the app is closed, and scans for the app when it is open.
@MainActor
final class Agent: NSObject, NSApplicationDelegate {
    private let lock = ScanLock(catalogPath: Catalog.defaultPath)
    private var keeper: IndexKeeper?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AgentLink.observe(AgentLink.quit) { _ in NSApp.terminate(nil) }
        Task { await start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lock.release()
        AgentLink.post(AgentLink.agentStopped)
    }

    private func start() async {
        // The app scans by itself until it sees the agent: wait for it to let go
        while !lock.tryAcquire() {
            try? await Task.sleep(for: .seconds(2))
        }
        let catalog: Catalog
        do {
            catalog = try await Task.detached { try Catalog(path: Catalog.defaultPath) }.value
        } catch {
            NSLog("Sist agent: cannot open the catalog: \(error)")
            NSApp.terminate(nil)
            return
        }
        let keeper = IndexKeeper(catalog: catalog) { AgentLink.post($0) }
        self.keeper = keeper

        AgentLink.observe(AgentLink.scanRequest) { notification in
            guard let request = AgentLink.decode(AgentLink.ScanRequest.self, from: notification) else { return }
            Task { await keeper.scheduler.scan(request.sourceId, mode: request.mode, scopes: request.scopes) }
        }
        AgentLink.observe(AgentLink.cancelRequest) { notification in
            guard let request = AgentLink.decode(AgentLink.CancelRequest.self, from: notification) else { return }
            Task {
                if let id = request.sourceId {
                    await keeper.scheduler.cancel(id)
                } else {
                    await keeper.scheduler.cancelAll()
                }
            }
        }
        AgentLink.observe(AgentLink.sourcesChanged) { _ in
            Task { await keeper.reloadSources() }
        }
        AgentLink.observe(AgentLink.statusRequest) { _ in
            AgentLink.post(AgentLink.agentStarted)
        }

        await keeper.reloadSources()
        AgentLink.post(AgentLink.agentStarted)
        // Catch up with what changed while nothing was watching: unchanged files cost a stat each
        for info in (try? await catalog.sources()) ?? [] {
            await keeper.scheduler.scan(info.id)
        }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    // The application holds its delegate weakly: this one lives as long as run() does
    let agent = Agent()
    application.delegate = agent
    application.setActivationPolicy(.prohibited)
    application.run()
}
