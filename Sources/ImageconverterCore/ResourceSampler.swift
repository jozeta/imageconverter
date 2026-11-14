import Darwin
import Foundation

/// Reads this process's CPU use and memory footprint. CPU is a delta between two samples, so the first call
/// after creation covers the time since creation.
public final class ResourceSampler: @unchecked Sendable {
    public struct Sample: Equatable, Sendable {
        /// Share of all cores used by this process since the previous sample: 0 to 100 (not per core).
        public let cpuPercent: Double
        /// `phys_footprint`, the number Activity Monitor shows as "Memory".
        public let memoryBytes: UInt64
    }

    private let lock = NSLock()
    private var lastCPU: TimeInterval
    private var lastWall: TimeInterval
    private let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)

    public init() {
        lastCPU = Self.cpuSeconds() ?? 0
        lastWall = ProcessInfo.processInfo.systemUptime
    }

    /// Nil when the kernel refuses either query.
    public func sample() -> Sample? {
        guard let memory = Self.footprint(), let cpu = Self.cpuSeconds() else { return nil }
        let wall = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        let dWall = wall - lastWall
        let dCPU = cpu - lastCPU
        lastWall = wall
        lastCPU = cpu
        guard dWall > 0 else { return Sample(cpuPercent: 0, memoryBytes: memory) }
        let percent = min(100, max(0, dCPU / dWall / Double(cores) * 100))
        return Sample(cpuPercent: percent, memoryBytes: memory)
    }

    /// Cumulative CPU seconds: live threads (thread times) plus threads that already ended (basic info).
    private static func cpuSeconds() -> TimeInterval? {
        var live = task_thread_times_info_data_t()
        var liveCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<integer_t>.size)
        let liveResult = withUnsafeMutablePointer(to: &live) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(liveCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &liveCount)
            }
        }
        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        guard liveResult == KERN_SUCCESS, basicResult == KERN_SUCCESS else { return nil }
        func seconds(_ time: time_value_t) -> TimeInterval {
            TimeInterval(time.seconds) + TimeInterval(time.microseconds) / 1_000_000
        }
        return seconds(live.user_time) + seconds(live.system_time)
            + seconds(basic.user_time) + seconds(basic.system_time)
    }

    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
