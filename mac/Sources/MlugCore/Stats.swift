import Foundation

/// Rolling latency averages, printed once a second when MLUG_STATS=1.
final class Stats {
    static let shared = Stats()
    static let enabled = ProcessInfo.processInfo.environment["MLUG_STATS"] == "1"
    private var sums: [String: (total: Double, n: Int)] = [:]
    private var lastPrint = Date()
    private let lock = NSLock()

    static func machToMs(_ t: UInt64) -> Double {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(t) * Double(tb.numer) / Double(tb.denom) / 1e6
    }
    static var nowMs: Double { machToMs(mach_absolute_time()) }

    func add(_ key: String, _ ms: Double) {
        guard Stats.enabled else { return }
        lock.withLock {
            let s = sums[key] ?? (0, 0)
            sums[key] = (s.total + ms, s.n + 1)
            if Date().timeIntervalSince(lastPrint) >= 1 {
                let line = sums.keys.sorted().map { k in
                    let s = sums[k]!
                    return String(format: "%@ %.1fms (n=%d)", k, s.total / Double(s.n), s.n)
                }.joined(separator: " | ")
                log(line)
                sums.removeAll()
                lastPrint = Date()
            }
        }
    }
}
