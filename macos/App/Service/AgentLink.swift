import Foundation
import SistCore
import SistScan

/// How the app and the background agent talk: distributed notifications, requests one way and
/// scan reports the other, with JSON in their user info. Both open the same catalog, so nothing
/// else has to travel. Which side scans is settled by ScanLock: the agent holds it while it runs.
public enum AgentLink {
    static let prefix = "sist.index."

    // Agent to app
    public static let agentStarted = Notification.Name(prefix + "agentStarted")
    public static let agentStopped = Notification.Name(prefix + "agentStopped")
    public static let scanEvent = Notification.Name(prefix + "scanEvent")

    // App to agent
    public static let scanRequest = Notification.Name(prefix + "scanRequest")
    public static let cancelRequest = Notification.Name(prefix + "cancelRequest")
    public static let sourcesChanged = Notification.Name(prefix + "sourcesChanged")
    public static let statusRequest = Notification.Name(prefix + "statusRequest")
    public static let quit = Notification.Name(prefix + "quit")

    public struct ScanRequest: Codable, Sendable {
        public var sourceId: Int64
        public var mode: ScanMode
        public var scopes: [ScanScope]?

        public init(sourceId: Int64, mode: ScanMode = .incremental, scopes: [ScanScope]? = nil) {
            self.sourceId = sourceId
            self.mode = mode
            self.scopes = scopes
        }
    }

    /// A cancel request for one source, or for all of them
    public struct CancelRequest: Codable, Sendable {
        public var sourceId: Int64?

        public init(sourceId: Int64?) {
            self.sourceId = sourceId
        }
    }

    enum WireEvent: Codable {
        case progress(ScanProgress)
        case finished(sourceId: Int64, error: String?)
    }

    public static func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
    }

    public static func post<Payload: Encodable>(_ name: Notification.Name, _ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: ["json": String(decoding: data, as: UTF8.self)], deliverImmediately: true)
    }

    public static func post(_ event: ScanScheduler.Event) {
        switch event {
        case .progress(let progress): post(scanEvent, WireEvent.progress(progress))
        case .finished(let id, let error): post(scanEvent, WireEvent.finished(sourceId: id, error: error))
        }
    }

    public static func decode<Payload: Decodable>(_ type: Payload.Type, from notification: Notification) -> Payload? {
        guard let json = notification.userInfo?["json"] as? String else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    public static func event(from notification: Notification) -> ScanScheduler.Event? {
        switch decode(WireEvent.self, from: notification) {
        case .progress(let progress)?: return .progress(progress)
        case .finished(let id, let error)?: return .finished(sourceId: id, error: error)
        case nil: return nil
        }
    }

    /// Calls `handler` on the main thread for each notification of that name
    @discardableResult
    public static func observe(_ name: Notification.Name,
                               _ handler: @escaping @MainActor (Notification) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated { handler(notification) }
        }
    }

    /// The agent's bundle identifier, from the app's
    public static func agentIdentifier(appIdentifier: String) -> String {
        appIdentifier + ".agent"
    }
}
