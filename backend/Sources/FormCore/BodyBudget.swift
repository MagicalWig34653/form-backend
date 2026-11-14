// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Process-wide budget of request-body memory that is in flight at the same time (Security findings S2-02 / fb-sec 1+2).
/// A request reserves `memoryFactor` times its declared Content-Length BEFORE any body byte is collected (body buffer plus the
/// parsed/working copies of the handler); a request that does not fit is refused (503) without being buffered. A single request
/// larger than the whole budget is clamped to it and therefore only runs alone. The total stays below the container limit
/// (default 128 MiB reserved against the 1024 MiB of deploy/swarm/stack.yaml); `FORM_BODY_BUDGET_MB` overrides it.
public final class BodyBudget: @unchecked Sendable {
    public static let defaultCapacity = 128 << 20
    /// Peak working-set multiple of a collected body (ByteBuffer, Data/Array copy, sealing/decoding).
    public static let memoryFactor = 3

    /// How long a request that does not fit right now may wait for capacity (in seconds) before it is refused with 503.
    /// Waiting buffers nothing (the body is not read yet); 0 = refuse at once.
    public static let defaultMaxWait: TimeInterval = 20

    public let capacity: Int
    public let maxWait: TimeInterval
    private let lock = NSLock()
    private var used = 0, peakUsed = 0, grantedCount = 0, refusedCount = 0, waitedCount = 0
    private struct Waiter { let id: Int; let cost: Int; let cont: CheckedContinuation<Lease?, Never> }
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0

    public init(capacity: Int = BodyBudget.defaultCapacity, maxWait: TimeInterval = 0) {
        self.capacity = max(1, capacity); self.maxWait = max(0, maxWait)
    }

    /// Reserved bytes right now.
    public var inFlight: Int { lock.lock(); defer { lock.unlock() }; return used }
    /// Highest reservation seen (measurement for tests and operations).
    public var peak: Int { lock.lock(); defer { lock.unlock() }; return peakUsed }
    public var granted: Int { lock.lock(); defer { lock.unlock() }; return grantedCount }
    public var refused: Int { lock.lock(); defer { lock.unlock() }; return refusedCount }
    /// Requests that had to wait for capacity (whether or not they were admitted in the end).
    public var waited: Int { lock.lock(); defer { lock.unlock() }; return waitedCount }

    public final class Lease: @unchecked Sendable {
        private let owner: BodyBudget
        private let cost: Int
        private let lock = NSLock()
        private var open = true
        fileprivate init(owner: BodyBudget, cost: Int) { self.owner = owner; self.cost = cost }
        public func release() {
            lock.lock(); let was = open; open = false; lock.unlock()
            if was, cost > 0 { owner.give(cost) }
        }
        deinit { release() }
    }

    /// Reserves for a body of `bodyBytes`; nil = does not fit now. 0 bytes is always granted and costs nothing.
    public func reserve(bodyBytes: Int) -> Lease? {
        let cost = cost(for: bodyBytes)
        lock.lock(); defer { lock.unlock() }
        guard used + cost <= capacity else { refusedCount += 1; return nil }
        used += cost; peakUsed = max(peakUsed, used); grantedCount += 1
        return Lease(owner: self, cost: cost)
    }

    private func cost(for bodyBytes: Int) -> Int {
        bodyBytes <= 0 ? 0 : min(capacity, bodyBytes.multipliedReportingOverflow(by: Self.memoryFactor).partialValue)
    }

    /// Like `reserve`, but a request that does not fit waits (first come, first served) up to `maxWait` seconds for capacity
    /// instead of being refused at once; nil = still does not fit after the wait.
    public func reserveWaiting(bodyBytes: Int) async -> Lease? {
        let cost = cost(for: bodyBytes)
        let id: Int
        lock.lock()
        if waiters.isEmpty, used + cost <= capacity {
            used += cost; peakUsed = max(peakUsed, used); grantedCount += 1; lock.unlock()
            return Lease(owner: self, cost: cost)
        }
        if maxWait <= 0 { refusedCount += 1; lock.unlock(); return nil }
        waitedCount += 1; id = nextWaiterID; nextWaiterID += 1
        lock.unlock()
        let timeout = maxWait
        return await withCheckedContinuation { (cont: CheckedContinuation<Lease?, Never>) in
            lock.lock(); waiters.append(Waiter(id: id, cost: cost, cont: cont)); lock.unlock()
            // a release may have happened between the check above and the registration
            drain()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.expire(id)
            }
        }
    }

    private func expire(_ id: Int) {
        lock.lock()
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        let w = waiters.remove(at: i); refusedCount += 1; lock.unlock()
        w.cont.resume(returning: nil)
        drain()   // the head may have been blocking smaller followers
    }

    /// Admits waiters in arrival order while the head fits.
    private func drain() {
        while true {
            lock.lock()
            guard let w = waiters.first, used + w.cost <= capacity else { lock.unlock(); return }
            waiters.removeFirst(); used += w.cost; peakUsed = max(peakUsed, used); grantedCount += 1
            lock.unlock()
            w.cont.resume(returning: Lease(owner: self, cost: w.cost))
        }
    }

    fileprivate func give(_ cost: Int) { lock.lock(); used = max(0, used - cost); lock.unlock(); drain() }
}
