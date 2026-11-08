import Foundation

public protocol SyncAPI: Sendable {
    /// Pushes a batch. The answer carries every change newer than `since` when the backend echoes it.
    func postOps(_ ops: [Op], since: Int) async throws -> SyncResponse
    func sync(since: Int) async throws -> SyncResponse
}

public enum APIError: Error, Equatable {
    case badOp(index: Int, code: String)
    case unauthorized
    case http(Int)
}

public enum SyncStatus: Equatable, Sendable {
    case idle, syncing, synced, offline, unauthorized
}

/// Pushes queued local ops; the push's answer is also the pull, so an edit costs one round trip. A separate pull
/// runs only when nothing was pushed, the backend is old, or a full resync is needed. Runs are coalesced: a kick
/// during a run schedules exactly one more run, and a version frame during a run only adds one if the run ends behind it.
public actor SyncEngine {
    private let store: LocalStore
    private let api: SyncAPI
    private let onAgentItems: @Sendable ([Item]) -> Void
    private let onStatus: @Sendable (SyncStatus) -> Void
    private var running = false
    private var again = false
    public private(set) var status: SyncStatus = .idle
    /// Ops the backend refused since launch (shown so a divergence is never silent).
    public private(set) var rejectedCount = 0
    private var needsFullResync = false
    /// Highest version announced over the socket while a run was in flight.
    private var announced = 0

    public init(store: LocalStore, api: SyncAPI, onAgentItems: @escaping @Sendable ([Item]) -> Void = { _ in },
                onStatus: @escaping @Sendable (SyncStatus) -> Void = { _ in }) {
        self.store = store
        self.api = api
        self.onAgentItems = onAgentItems
        self.onStatus = onStatus
    }

    /// Fire-and-forget request for a sync (after a local edit, on wake, on a timer).
    public nonisolated func kick() {
        Task { await self.syncNow() }
    }

    /// Runs a sync and returns when it (and any run requested meanwhile) is done.
    public func syncNow() async {
        if running {
            again = true
            return
        }
        running = true
        repeat {
            again = false
            announced = 0
            await cycle()
        } while again || announced > ((try? store.lastVersion()) ?? 0)
        running = false
    }

    public func socketConnected() async { await syncNow() }

    /// Called when the server announces a version. Pulls only if we are behind.
    public func versionAnnounced(_ version: Int) async {
        if running {
            // Usually the echo of our own push: the run in flight decides at its end whether it is still behind.
            announced = max(announced, version)
            return
        }
        if let current = try? store.lastVersion(), version <= current, (try? store.pendingCount()) == 0 { return }
        await syncNow()
    }

    private func set(_ s: SyncStatus) {
        status = s
        onStatus(s)
    }

    private func cycle() async {
        set(.syncing)
        var pushError: Error?
        var pulled = false
        do {
            pulled = try await push()
        } catch {
            pushError = error
        }
        if case APIError.unauthorized? = pushError as? APIError {
            set(.unauthorized)
            return
        }
        if pulled && !needsFullResync {
            set(.synced)
            return
        }
        do {
            // Pull even when the push failed: merge keeps pending fields, so it is always safe.
            var full = needsFullResync
            let since = full ? 0 : try store.lastVersion()
            var r = try await api.sync(since: since)
            if !full && r.version < since {
                // The server is behind our cursor: a different or reset backend. Start over from 0.
                full = true
                r = try await api.sync(since: 0)
            }
            let fresh = full ? try store.replaceAll(r.items, version: r.version) : try store.merge(r.items, version: r.version)
            needsFullResync = false
            if !fresh.isEmpty { onAgentItems(fresh) }
            set(pushError == nil ? .synced : .offline)
        } catch APIError.unauthorized {
            set(.unauthorized)
        } catch {
            set(.offline)
        }
    }

    /// Sends every pending batch with the local cursor. Returns true when the answers covered the pull.
    private func push() async throws -> Bool {
        var pulled = false
        while true {
            let batch = try store.pending(limit: 100)
            guard let last = batch.last else { return pulled }
            do {
                let since = try store.lastVersion()
                let r = try await api.postOps(batch.map(\.op), since: since)
                try store.ack(upTo: last.id)
                if r.since == since, r.version >= since {
                    // Ack first, so merge takes the server copy of what we just sent and keeps later pending fields.
                    let fresh = try store.merge(r.items, version: r.version)
                    if !fresh.isEmpty { onAgentItems(fresh) }
                    pulled = true
                } else {
                    pulled = false
                }
            } catch let APIError.badOp(index, _) where batch.indices.contains(index) {
                // The backend applies batches atomically, so nothing landed: drop the bad op and resend the rest.
                try store.drop(batch[index].id)
                rejectedCount += 1
                // Whatever that op did locally never happened on the server: re-read everything from it.
                needsFullResync = true
            }
        }
    }
}
