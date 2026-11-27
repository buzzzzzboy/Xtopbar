import Foundation
import Combine
import Darwin

/// 工作列「CPU／記憶體」小工具的数据源：纯计算（`SystemStatsMath`，可离线回归）+ 按需取样器。
///
/// - CPU：`host_statistics(HOST_CPU_LOAD_INFO)` 前后两次 tick 的差
/// - 内存：`host_statistics64(HOST_VM_INFO64)` 的（active + wired + compressed）÷ 物理内存，
///   和「活动监视器」的「已使用内存」同口径
struct CPUTicks: Equatable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64

    var total: UInt64 { user + system + idle + nice }
}

enum SystemStatsMath {
    /// 超过就用警示色
    static let warningThreshold = 0.8

    /// 0...1；两次之间没有 tick（同一份快照）回 0
    static func cpuUsage(from a: CPUTicks, to b: CPUTicks) -> Double {
        let total = b.total &- a.total
        guard b.total > a.total, total > 0 else { return 0 }
        let idle = b.idle >= a.idle ? b.idle - a.idle : 0
        return min(max(Double(total - min(idle, total)) / Double(total), 0), 1)
    }

    /// 0...1，夹在范围内
    static func memoryUsage(activePages: UInt64, wiredPages: UInt64, compressedPages: UInt64,
                            pageSize: UInt64, physicalBytes: UInt64) -> Double {
        guard physicalBytes > 0 else { return 0 }
        let used = Double(activePages + wiredPages + compressedPages) * Double(pageSize)
        return min(max(used / Double(physicalBytes), 0), 1)
    }
}

/// 全局只有一个取样器：有小工具在显示（引用计数 > 0）才每 2 秒取一次，全部收起就停
@MainActor
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    @Published private(set) var cpu: Double = 0
    @Published private(set) var memory: Double = 0

    private var users = 0
    private var timer: Timer?
    private var lastTicks: CPUTicks?

    private init() {}

    func retain() {
        users += 1
        guard users == 1 else { return }
        TTLog("systemStats 開始取樣")
        sample()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
        lastTicks = nil
        TTLog("systemStats 停止取樣")
    }

    var isSampling: Bool { timer != nil }

    private func sample() {
        if let ticks = Self.readCPUTicks() {
            if let last = lastTicks { set(\.cpu, SystemStatsMath.cpuUsage(from: last, to: ticks)) }
            lastTicks = ticks
        }
        if let m = Self.readMemoryUsage() { set(\.memory, m) }
    }

    /// 只在数字（百分比）变了才发布，免得条每 2 秒白白重画
    private func set(_ key: ReferenceWritableKeyPath<SystemStats, Double>, _ value: Double) {
        if (self[keyPath: key] * 100).rounded() != (value * 100).rounded() { self[keyPath: key] = value }
    }

    private static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    private static func readMemoryUsage() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        return SystemStatsMath.memoryUsage(activePages: UInt64(stats.active_count),
                                           wiredPages: UInt64(stats.wire_count),
                                           compressedPages: UInt64(stats.compressor_page_count),
                                           pageSize: UInt64(pageSize),
                                           physicalBytes: ProcessInfo.processInfo.physicalMemory)
    }
}
