import Darwin
import Foundation

/// What this process has cost so far.
///
/// > **The reading the 98 %-of-a-core episode wanted and did not have.** That
/// > regression was found in the system's own `cpu_resource.diag` report, hours
/// > after it happened, and was never reproduced. `scripts/perf-probe.py` can
/// > measure a running AgentBar from outside; this is the same question asked
/// > from inside, where a user can read it and paste it into a report.
///
/// **An average, and it says so.** `proc_pid_rusage` reports processor time
/// accumulated since launch, not an instantaneous rate, so the percentage here
/// is the whole life of the process divided by the whole life of the process. A
/// spike an hour ago is a rounding error in it — which is the honest thing for a
/// figure taken without a sampler, and the reason the sentence names the window
/// it covers.
enum ProcessResources {

    /// One line: resident memory, processor time, and what that averages to.
    static func summary(since launch: ContinuousClock.Instant) -> String {
        let uptime = ContinuousClock.now - launch
        let uptimeSeconds = seconds(of: uptime)
        guard let usage = current() else {
            return String(
                localized: "Running for \(uptimeText(uptime)); resource usage unavailable",
                comment: "Diagnostics resource line when the kernel would not answer")
        }
        let cpuSeconds =
            Double(usage.ri_user_time &+ usage.ri_system_time) / 1_000_000_000
        let memory = Measurement<UnitInformationStorage>(
            value: Double(usage.ri_resident_size), unit: .bytes
        )
        .converted(to: .megabytes)
        let share = uptimeSeconds > 0 ? cpuSeconds / uptimeSeconds * 100 : 0
        // Rounded here rather than in the format string: `String(localized:)`
        // takes a `LocalizationValue`, which has no `specifier:` — that is
        // `Text`'s. Formatting first keeps the localised sentence a sentence.
        let memoryText = memory.value.formatted(.number.precision(.fractionLength(0)))
        let cpuText = cpuSeconds.formatted(.number.precision(.fractionLength(1)))
        let shareText = share.formatted(.number.precision(.fractionLength(2)))
        return String(
            localized: """
                \(memoryText) MB resident · \(cpuText) s of processor time in \
                \(uptimeText(uptime)) · \(shareText) % of a core on average
                """,
            comment: "Diagnostics resource line")
    }

    /// `rusage_info_current` for this process, or `nil` if the kernel refused.
    ///
    /// The rebind is what the C interface needs: `proc_pid_rusage` takes an
    /// out-parameter typed as `rusage_info_t?` — an opaque pointer — and the
    /// flavour decides which struct is actually written through it.
    private static func current() -> rusage_info_current? {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, rebound)
            }
        }
        return result == 0 ? usage : nil
    }

    private static func seconds(of duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// `1 h 12 m`, `4 m`, `38 s` — whichever two units say the most.
    private static func uptimeText(_ duration: Duration) -> String {
        let total = Int(seconds(of: duration))
        if total >= 3600 { return "\(total / 3600) h \((total % 3600) / 60) m" }
        if total >= 60 { return "\(total / 60) m \(total % 60) s" }
        return "\(total) s"
    }
}
