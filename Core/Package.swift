// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StockpileCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RulesKit", targets: ["RulesKit"]),
        .library(name: "ScannerKit", targets: ["ScannerKit"]),
        .library(name: "InventoryKit", targets: ["InventoryKit"]),
        .library(name: "LedgerKit", targets: ["LedgerKit"]),
        .library(name: "ThermalKit", targets: ["ThermalKit"]),
        .library(name: "HonestKit", targets: ["HonestKit"]),
        .library(name: "MemoryKit", targets: ["MemoryKit"]),
        .library(name: "BatteryKit", targets: ["BatteryKit"]),
    ],
    targets: [
        .target(
            name: "LedgerKit"
        ),
        .target(
            name: "ThermalKit"
        ),
        .target(
            name: "HonestKit"
        ),
        .target(
            name: "MemoryKit",
            dependencies: ["HonestKit"]
        ),
        .target(
            name: "BatteryKit"
        ),
        .target(
            name: "RulesKit",
            resources: [.process("Resources")]
        ),
        .target(
            name: "ScannerKit",
            dependencies: ["RulesKit"]
        ),
        .target(
            name: "InventoryKit",
            dependencies: ["ScannerKit"]
        ),
        .testTarget(
            name: "RulesKitTests",
            dependencies: ["RulesKit"]
        ),
        .testTarget(
            name: "ScannerKitTests",
            dependencies: ["ScannerKit"]
        ),
        .testTarget(
            name: "InventoryKitTests",
            dependencies: ["InventoryKit"]
        ),
        .testTarget(
            name: "LedgerKitTests",
            dependencies: ["LedgerKit"]
        ),
        .testTarget(
            name: "ThermalKitTests",
            dependencies: ["ThermalKit"]
        ),
        .testTarget(
            name: "MemoryKitTests",
            dependencies: ["MemoryKit"]
        ),
        .testTarget(
            name: "BatteryKitTests",
            dependencies: ["BatteryKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
