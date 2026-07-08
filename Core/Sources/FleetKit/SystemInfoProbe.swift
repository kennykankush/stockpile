import Foundation

/// A machine's static identity — the "System Information" spec sheet
/// (msinfo32 / About This Mac). Fetched once, on demand; not polled.
public struct SystemInfo: Sendable, Hashable {
    public var sections: [InfoSection]
    public init(sections: [InfoSection]) { self.sections = sections }
}

public struct InfoSection: Sendable, Hashable, Identifiable {
    public var id: String { title }
    public let title: String
    public let rows: [InfoRow]
    public init(title: String, rows: [InfoRow]) { self.title = title; self.rows = rows }
}

public struct InfoRow: Sendable, Hashable, Identifiable {
    public var id: String { label }
    public let label: String
    public let value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
}

/// Gathers the spec sheet over SSH — Linux via `/sys/class/dmi` + `lscpu`
/// (no root needed), Windows via CIM. Emits `===Section===` then `Label|Value`
/// lines, parsed into ordered sections.
public enum SystemInfoProbe {
    public static func fetch(ssh: SSHRunner, os: Machine.OS) async throws -> SystemInfo {
        switch os {
        case .windows: return parse(try await ssh.run(windowsScript, shell: .powershell))
        default:       return parse(try await ssh.run(linuxScript, shell: .bash))
        }
    }

    public static let linuxScript = """
    dmi() { cat /sys/class/dmi/id/$1 2>/dev/null; }
    lv() { lscpu 2>/dev/null | grep -m1 -F "$1" | sed 's/^[^:]*: *//'; }
    echo "===System==="
    echo "Manufacturer|$(dmi sys_vendor)"
    echo "Model|$(dmi product_name)"
    echo "Board|$(dmi board_vendor) $(dmi board_name)"
    echo "Hostname|$(hostname 2>/dev/null)"
    echo "===Operating System==="
    . /etc/os-release 2>/dev/null
    echo "Distribution|$PRETTY_NAME"
    echo "Kernel|$(uname -r)"
    echo "Architecture|$(uname -m)"
    echo "Uptime|$(uptime -p 2>/dev/null | sed 's/^up //')"
    echo "===Processor==="
    echo "Model|$(lv 'Model name')"
    echo "Vendor|$(lv 'Vendor ID')"
    echo "Sockets|$(lv 'Socket(s)')"
    echo "Cores per socket|$(lv 'Core(s) per socket')"
    echo "Threads per core|$(lv 'Thread(s) per core')"
    echo "Max frequency|$(lv 'CPU max MHz') MHz"
    echo "L2 cache|$(lv 'L2 cache')"
    echo "L3 cache|$(lv 'L3 cache')"
    echo "Virtualization|$(lv 'Virtualization')"
    echo "===Memory==="
    echo "Total|$(free -h 2>/dev/null | awk '/^Mem/{print $2}')"
    echo "Swap|$(free -h 2>/dev/null | awk '/^Swap/{print $2}')"
    echo "===Firmware==="
    echo "BIOS|$(dmi bios_vendor) $(dmi bios_version)"
    echo "BIOS date|$(dmi bios_date)"
    echo "===Graphics==="
    lspci 2>/dev/null | grep -iE 'vga|3d|display' | sed 's/^.*: //' | while read -r g; do echo "GPU|$g"; done
    """

    public static let windowsScript = """
    $ErrorActionPreference='SilentlyContinue'
    $cs=Get-CimInstance Win32_ComputerSystem
    $os=Get-CimInstance Win32_OperatingSystem
    $bios=Get-CimInstance Win32_BIOS
    $bb=Get-CimInstance Win32_BaseBoard
    $cpu=Get-CimInstance Win32_Processor | Select-Object -First 1
    "===System==="
    "Manufacturer|$($cs.Manufacturer)"
    "Model|$($cs.Model)"
    "Type|$($cs.SystemType)"
    "Hostname|$($cs.Name)"
    "===Operating System==="
    "Edition|$($os.Caption)"
    "Version|$($os.Version)"
    "Build|$($os.BuildNumber)"
    "Architecture|$($os.OSArchitecture)"
    "Installed|$($os.InstallDate.ToString('yyyy-MM-dd'))"
    "===Processor==="
    "Model|$($cpu.Name)"
    "Cores|$($cpu.NumberOfCores)"
    "Threads|$($cpu.NumberOfLogicalProcessors)"
    "Max frequency|$($cpu.MaxClockSpeed) MHz"
    "Socket|$($cpu.SocketDesignation)"
    "L2 cache|$([math]::Round($cpu.L2CacheSize/1024,1)) MB"
    "L3 cache|$([math]::Round($cpu.L3CacheSize/1024,1)) MB"
    "===Memory==="
    $i=1; Get-CimInstance Win32_PhysicalMemory | ForEach-Object { "DIMM $i|$([math]::Round($_.Capacity/1GB))GB @ $($_.Speed)MHz ($($_.PartNumber.Trim()))"; $i++ }
    "===Motherboard==="
    "Board|$($bb.Manufacturer) $($bb.Product)"
    "===Firmware==="
    "BIOS|$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)"
    "BIOS date|$($bios.ReleaseDate.ToString('yyyy-MM-dd'))"
    "===Graphics==="
    Get-CimInstance Win32_VideoController | Where-Object { $_.Name } | ForEach-Object { "GPU|$($_.Name)" }
    """

    public static func parse(_ output: String) -> SystemInfo {
        let clean = output.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var sections: [InfoSection] = []
        var title: String?
        var rows: [InfoRow] = []
        func flush() {
            if let t = title, !rows.isEmpty { sections.append(InfoSection(title: t, rows: rows)) }
            rows = []
        }
        for raw in clean.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("===") && line.hasSuffix("===") {
                flush()
                title = String(line.dropFirst(3).dropLast(3))
            } else if line.contains("|") {
                let p = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                let label = p[0]
                let value = p.count > 1 ? p[1] : ""
                // Drop rows whose value is empty or just a dangling unit ("MHz", "MB").
                if !label.isEmpty, !value.isEmpty, value != "MHz", value != "MB" {
                    rows.append(InfoRow(label: label, value: value))
                }
            }
        }
        flush()
        return SystemInfo(sections: sections)
    }
}
