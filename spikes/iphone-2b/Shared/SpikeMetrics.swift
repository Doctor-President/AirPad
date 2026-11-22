// Sweep 2b · 3.3 — device readings for the spike: memory (phys_footprint + os_proc_available_memory), heat
// (ProcessInfo.thermalState), battery (UIDevice, monitoring on), device identity, free space. No model calls.
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import os
#endif

enum Metrics {
    /// The app's memory as the system counts it (what jetsam judges), bytes. Metal/MLX buffers count here on iOS.
    static func physFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// How much more the app may allocate before jetsam (iOS only), bytes.
    static func availableMemory() -> UInt64? {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return nil
        #endif
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Battery level 0…1 and state; nil where there is no UIDevice (the Mac runner). The app turns monitoring on.
    @MainActor static func battery() -> (level: Double, state: String)? {
        #if canImport(UIKit) && os(iOS)
        let d = UIDevice.current
        guard d.isBatteryMonitoringEnabled else { return nil }
        let state: String
        switch d.batteryState {
        case .unplugged: state = "unplugged"
        case .charging: state = "charging"
        case .full: state = "full"
        default: state = "unknown"
        }
        return (Double(d.batteryLevel), state)
        #else
        return nil
        #endif
    }

    /// One reading, for every turn / phase boundary.
    @MainActor static func snapshot() -> [String: Any] {
        var s: [String: Any] = ["thermal": thermal(), "t": Date().timeIntervalSince1970]
        if let f = physFootprint() { s["physFootprintMB"] = Int(f / 1_048_576) }
        if let a = availableMemory() { s["availableMemoryMB"] = Int(a / 1_048_576) }
        if let b = battery() { s["batteryLevel"] = b.level; s["batteryState"] = b.state }
        s["lowPowerMode"] = ProcessInfo.processInfo.isLowPowerModeEnabled
        return s
    }

    static func machine() -> String {
        var u = utsname(); uname(&u)
        return withUnsafePointer(to: &u.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
    }

    /// hw.model: "Mac16,x" on a Mac (uname says only arm64 there); the iPhone's product type comes from uname.
    static func hwModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static func freeBytes(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    static func deviceInfo() -> [String: Any] {
        let p = ProcessInfo.processInfo
        return ["machine": machine(), "hwModel": hwModel(), "os": p.operatingSystemVersionString, "physicalMemoryGB": Double(p.physicalMemory) / 1_073_741_824,
                "cpuCount": p.processorCount, "lowPowerMode": p.isLowPowerModeEnabled]
    }

    /// Bytes on disk under a directory (the weights' size as stored on this device).
    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }
}
