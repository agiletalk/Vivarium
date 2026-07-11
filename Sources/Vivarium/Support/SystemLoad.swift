import Darwin
import Foundation

/// Samples system-wide CPU load (0...1) between calls, nudged up by thermal pressure. Used purely as
/// an ambient visual cue (water current + murkiness) — never for any semantic/simulation logic.
final class SystemLoad {
    /// Cumulative CPU ticks from the previous sample; a delta is needed to get an interval rate.
    private var previous: (busy: Double, total: Double)?

    /// CPU busy fraction since the last call, blended with a bump for an elevated thermal state.
    func sample() -> Double {
        min(1, cpuBusyFraction() + thermalBump() * 0.4)
    }

    private func cpuBusyFraction() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        // mach_host_self() hands back a send right that must be balanced, or we leak a host-port
        // user reference every sample. (mach_task_self() is a cached special port — do NOT release.)
        // `mach_task_self()` is a C macro (unavailable in Swift); use the exported task-port global.
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return systemLoadFallback() }

        // cpu_ticks = (user, system, idle, nice); cumulative since boot.
        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle

        defer { previous = (busy, total) }
        guard let previous else { return 0 } // first call only seeds the baseline
        let deltaBusy = busy - previous.busy
        let deltaTotal = total - previous.total
        guard deltaTotal > 0 else { return 0 }
        return min(1, max(0, deltaBusy / deltaTotal))
    }

    /// If the mach call ever fails, fall back to the 1-minute load average over core count.
    private func systemLoadFallback() -> Double {
        var avg = [Double](repeating: 0, count: 3)
        guard getloadavg(&avg, 3) > 0 else { return 0 }
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        return min(1, max(0, avg[0] / cores))
    }

    private func thermalBump() -> Double {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 0
        case .fair: return 0.3
        case .serious: return 0.7
        case .critical: return 1.0
        @unknown default: return 0
        }
    }
}
