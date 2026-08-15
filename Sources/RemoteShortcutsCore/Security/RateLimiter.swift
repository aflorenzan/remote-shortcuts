import Foundation

/// Sliding-window rate limiter keyed by source address.
///
/// Two jobs: keep a misbehaving automation from hammering EventKit, and make
/// online token guessing impractical even though the token itself is already
/// 256 bits of entropy.
public final class RateLimiter: @unchecked Sendable {
    private struct Window {
        var timestamps: [Date]
    }

    private let queue = DispatchQueue(label: "com.remoteshortcuts.ratelimiter")
    private let limit: Int
    private let interval: TimeInterval
    private var windows: [String: Window] = [:]
    private var lastSweep = Date()

    public init(limitPerMinute: Int, interval: TimeInterval = 60) {
        self.limit = max(0, limitPerMinute)
        self.interval = interval
    }

    /// Returns `nil` when the request may proceed, or the number of seconds to
    /// wait (for the `Retry-After` header) when it must be rejected.
    public func consume(key: String, now: Date = Date()) -> Int? {
        guard limit > 0 else { return nil }

        return queue.sync {
            sweepIfNeeded(now: now)

            let cutoff = now.addingTimeInterval(-interval)
            var window = windows[key] ?? Window(timestamps: [])
            window.timestamps.removeAll { $0 < cutoff }

            if window.timestamps.count >= limit {
                let oldest = window.timestamps[0]
                windows[key] = window
                let retryAfter = Int(ceil(interval - now.timeIntervalSince(oldest)))
                return max(1, retryAfter)
            }

            window.timestamps.append(now)
            windows[key] = window
            return nil
        }
    }

    /// Drops idle buckets so a long-running server does not accumulate one
    /// entry per address that ever connected.
    private func sweepIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastSweep) > interval else { return }
        lastSweep = now
        let cutoff = now.addingTimeInterval(-interval)
        windows = windows.compactMapValues { window in
            let kept = window.timestamps.filter { $0 >= cutoff }
            return kept.isEmpty ? nil : Window(timestamps: kept)
        }
    }
}
