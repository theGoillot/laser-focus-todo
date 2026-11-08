import Foundation

public protocol SyncAPI: Sendable {
    func postOps(_ ops: [Op]) async throws -> SyncResponse
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

/// Pushes queued local ops, then pulls everything newer than the last version. Runs are coalesced:
/// a kick during a run schedules exactly one more run.
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
            await cycle()
        } while again
        running = false
    }

    public func socketConnected() async { await syncNow() }

    /// Called when the server announces a version. Pulls only if we are behind.
    public func versionAnnounced(_ version: Int) async {
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
        do {
            try await push()
        } catch {
            pushError = error
        }
        if case APIError.unauthorized? = pushError as? APIError {
            set(.unauthorized)
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

    private func push() async throws {
        while true {
            let batch = try store.pending(limit: 100)
            guard let last = batch.last else { return }
            do {
                _ = try await api.postOps(batch.map(\.op))
                try store.ack(upTo: last.id)
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
