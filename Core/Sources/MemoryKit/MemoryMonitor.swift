import Foundation
import Darwin

/// Reads RAM state from the Mach kernel — no sudo. Uses the same page
/// accounting Activity Monitor does (app / wired / compressed / cached).
public struct MemoryMonitor: Sendable {
    public init() {}

    public func read() -> MemoryReading? {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Int64(pageSize)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        let speculative = Int64(stats.speculative_count)
        let free = max(0, Int64(stats.free_count) - speculative)
        let purgeable = Int64(stats.purgeable_count)
        let external = Int64(stats.external_page_count)
        let internalPages = Int64(stats.internal_page_count)

        // File-backed + purgeable + speculative = evictable on demand.
        let cached = (external + purgeable + speculative) * page
        // Anonymous app memory = internal minus its purgeable share.
        let app = max(0, internalPages - purgeable) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page

        return MemoryReading(
            total: total,
            free: free * page,
            cached: cached,
            app: app,
            wired: wired,
            compressed: compressed
        )
    }
}
