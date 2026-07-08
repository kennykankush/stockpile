import Foundation
import Darwin
import IOKit
import FleetKit

/// The local Mac's spec sheet, from sysctl + IOKit — the same shape as the
/// remote SystemInfoProbe so one view renders any machine.
enum LocalSystemInfo {
    static func build() -> SystemInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let mem = Int64(ProcessInfo.processInfo.physicalMemory)
        let cores = ProcessInfo.processInfo.processorCount
        let perf = sysctlInt("hw.perflevel0.logicalcpu")
        let eff = sysctlInt("hw.perflevel1.logicalcpu")

        var system: [InfoRow] = [InfoRow(label: "Model", value: sysctlStr("hw.model"))]
        if let serial = serialNumber() { system.append(InfoRow(label: "Serial", value: serial)) }
        system.append(InfoRow(label: "Hostname", value: Host.current().localizedName ?? ProcessInfo.processInfo.hostName))

        let os: [InfoRow] = [
            InfoRow(label: "System", value: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"),
            InfoRow(label: "Build", value: sysctlStr("kern.osversion")),
            InfoRow(label: "Kernel", value: "Darwin \(sysctlStr("kern.osrelease"))"),
            InfoRow(label: "Architecture", value: sysctlStr("hw.machine")),
        ]

        var cpu: [InfoRow] = [InfoRow(label: "Chip", value: sysctlStr("machdep.cpu.brand_string"))]
        cpu.append(InfoRow(label: "Cores", value: "\(cores)"))
        if perf > 0, eff > 0 {
            cpu.append(InfoRow(label: "Layout", value: "\(perf) performance + \(eff) efficiency"))
        }

        let memory: [InfoRow] = [InfoRow(label: "Total", value: mem.bytesFormatted)]

        return SystemInfo(sections: [
            InfoSection(title: "System", rows: system.filter { !$0.value.isEmpty }),
            InfoSection(title: "Operating System", rows: os.filter { !$0.value.isEmpty }),
            InfoSection(title: "Processor", rows: cpu.filter { !$0.value.isEmpty }),
            InfoSection(title: "Memory", rows: memory),
        ])
    }

    private static func sysctlStr(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : 0
    }

    private static func serialNumber() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString,
                                                       kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        else { return nil }
        return cf
    }
}
