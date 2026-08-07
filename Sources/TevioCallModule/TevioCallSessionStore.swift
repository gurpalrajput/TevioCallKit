import Foundation

final class UserDefaultsCallSessionStore: CallSessionStoring {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let sessionKey = "com.tevio.callkit.currentSession"
    private let pendingEventsKey = "com.tevio.callkit.pendingEvents"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func saveCurrentSession(_ session: CallSession) {
        guard let data = try? encoder.encode(session) else { return }
        defaults.set(data, forKey: sessionKey)
    }

    func loadCurrentSession() -> CallSession? {
        guard let data = defaults.data(forKey: sessionKey) else { return nil }
        return try? decoder.decode(CallSession.self, from: data)
    }

    func clearCurrentSession() {
        defaults.removeObject(forKey: sessionKey)
    }

    func enqueuePendingEvent(_ event: PendingCallEvent) {
        var events = loadPendingEvents()
        if events.contains(where: { $0.id == event.id }) {
            return
        }
        events.append(event)
        guard let data = try? encoder.encode(events) else { return }
        defaults.set(data, forKey: pendingEventsKey)
    }

    func loadPendingEvents() -> [PendingCallEvent] {
        guard let data = defaults.data(forKey: pendingEventsKey) else { return [] }
        return (try? decoder.decode([PendingCallEvent].self, from: data)) ?? []
    }

    func removePendingEvent(id: UUID) {
        let filtered = loadPendingEvents().filter { $0.id != id }
        guard let data = try? encoder.encode(filtered) else { return }
        defaults.set(data, forKey: pendingEventsKey)
    }
}
