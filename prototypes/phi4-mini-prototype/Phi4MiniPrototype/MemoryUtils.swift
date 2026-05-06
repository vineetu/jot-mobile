import Darwin
import Foundation

/// Available memory in megabytes from the per-process kernel reservation.
/// Returns 0 if the syscall is unavailable.
func availableMemoryMB() -> Int {
    Int(os_proc_available_memory()) / (1024 * 1024)
}
