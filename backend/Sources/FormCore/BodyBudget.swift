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

    public let capacity: Int
    private let lock = NSLock()
    private var used = 0, peakUsed = 0, grantedCount = 0, refusedCount = 0

    public init(capacity: Int = BodyBudget.defaultCapacity) { self.capacity = max(1, capacity) }

    /// Reserved bytes right now.
    public var inFlight: Int { lock.lock(); defer { lock.unlock() }; return used }
    /// Highest reservation seen (measurement for tests and operations).
    public var peak: Int { lock.lock(); defer { lock.unlock() }; return peakUsed }
    public var granted: Int { lock.lock(); defer { lock.unlock() }; return grantedCount }
    public var refused: Int { lock.lock(); defer { lock.unlock() }; return refusedCount }

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
        let cost = bodyBytes <= 0 ? 0 : min(capacity, bodyBytes.multipliedReportingOverflow(by: Self.memoryFactor).partialValue)
        lock.lock(); defer { lock.unlock() }
        guard used + cost <= capacity else { refusedCount += 1; return nil }
        used += cost; peakUsed = max(peakUsed, used); grantedCount += 1
        return Lease(owner: self, cost: cost)
    }

    fileprivate func give(_ cost: Int) { lock.lock(); used = max(0, used - cost); lock.unlock() }
}
