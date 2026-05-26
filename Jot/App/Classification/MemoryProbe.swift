import Foundation
import Darwin
import os.log

/// Cheap snapshot of the process's current memory state. Used by the
/// Lab classifications dashboard to surface a live readout so the
/// user (Vineet) can correlate visible memory pressure with the
/// classify-jetsam diagnostic events. Not meant for general production
/// use — costs a syscall + a touch of formatting per sample.
struct MemoryProbeSample: Sendable {
    /// Process physical footprint in MB. Maps to what `Xcode > Debug
    /// Navigator > Memory` shows for a running app; matches Apple's
    /// own jetsam accounting.
    let usedMB: Double

    /// Bytes remaining before the OS expects the process to be under
    /// pressure. Returned by `os_proc_available_memory()`. Caveats:
    /// (a) it's an estimate, (b) iOS may report 0 when the process is
    /// in a memory-warning state, (c) drops to negative under extreme
    /// pressure (we floor at 0 for display).
    let availableMB: Double

    /// Convenience for at-a-glance reading. Returns ".comfortable"
    /// when there's headroom, ".tight" when getting close, ".critical"
    /// when iOS is likely to send a memory warning soon. Thresholds
    /// are empirical guesses, not load-bearing.
    enum PressureLevel: Sendable {
        case comfortable
        case tight
        case critical
    }
    var pressure: PressureLevel {
        if availableMB > 800 { return .comfortable }
        if availableMB > 200 { return .tight }
        return .critical
    }
}

enum MemoryProbe {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "memory-probe"
    )

    /// Snapshots the current process footprint + headroom. Cheap
    /// enough to call from a SwiftUI `.task` that loops every couple
    /// of seconds.
    static func sample() -> MemoryProbeSample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        let usedBytes: Double
        if result == KERN_SUCCESS {
            usedBytes = Double(info.phys_footprint)
        } else {
            log.error("task_info failed result=\(result, privacy: .public)")
            usedBytes = 0
        }

        let availableBytes = max(0, os_proc_available_memory())

        return MemoryProbeSample(
            usedMB: usedBytes / (1024 * 1024),
            availableMB: Double(availableBytes) / (1024 * 1024)
        )
    }
}
