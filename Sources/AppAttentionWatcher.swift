import AppKit
import Combine

/// Dock 从 LaunchServices 读取的注意请求。所有屏共用一次轮询，去掉前台和已退出的 App。
@MainActor
final class AppAttentionWatcher {
    private(set) var pids: Set<pid_t> = []
    var onChange: ((Set<pid_t>) -> Void)?

    private var timer: Timer?
    private var workspaceEvents: AnyCancellable?
    private var reading = false
    private var clearedDuringRead: Set<pid_t> = []

    func start() {
        guard timer == nil, LaunchServicesAttention.isAvailable else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceEvents = Publishers.Merge(
            workspace.publisher(for: NSWorkspace.didActivateApplicationNotification),
            workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.clear(app.processIdentifier)
        }

        // 普通请求可能只持续约一秒。查询走后台，上一轮没跑完就等下一拍。
        let poll = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        poll.tolerance = 0.05
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
        sample()
    }

    private func sample() {
        guard !reading else { return }
        let workspace = NSWorkspace.shared
        let frontPID = workspace.frontmostApplication?.processIdentifier
        let candidates = workspace.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != frontPID
        }.map(\.processIdentifier)
        reading = true
        Task.detached(priority: .utility) { [weak self] in
            let requests = Set(candidates.filter(LaunchServicesAttention.isRequested))
            await self?.finish(requests)
        }
    }

    private func finish(_ requests: Set<pid_t>) {
        reading = false
        var current = requests.subtracting(clearedDuringRead)
        clearedDuringRead.removeAll()
        if let front = NSWorkspace.shared.frontmostApplication {
            current.remove(front.processIdentifier)
        }
        publish(current)
    }

    private func clear(_ pid: pid_t) {
        if reading { clearedDuringRead.insert(pid) }
        guard pids.contains(pid) else { return }
        publish(pids.subtracting([pid]))
    }

    private func publish(_ current: Set<pid_t>) {
        guard current != pids else { return }
        pids = current
        onChange?(current)
    }
}

/// 私有 API，运行时解析。系统缺少任一符号时跳过注意请求监测。
private enum LaunchServicesAttention {
    private typealias CreateASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    private static let symbols: (createASN: CreateASN, copyItem: CopyItem, key: CFString)? = {
        let path = "/System/Library/Frameworks/CoreServices.framework/CoreServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        guard let createASN = dlsym(handle, "_LSASNCreateWithPid"),
              let copyItem = dlsym(handle, "_LSCopyApplicationInformationItem"),
              let key = dlsym(handle, "_kLSApplicationDesiresAttentionKey")?
                  .assumingMemoryBound(to: CFString?.self).pointee
        else {
            dlclose(handle)
            return nil
        }
        return (unsafeBitCast(createASN, to: CreateASN.self),
                unsafeBitCast(copyItem, to: CopyItem.self), key)
    }()

    static var isAvailable: Bool { symbols != nil }

    static func isRequested(_ pid: pid_t) -> Bool {
        guard let symbols,
              let asn = symbols.createASN(kCFAllocatorDefault, pid)?.takeRetainedValue(),
              let value = symbols.copyItem(-1, asn, symbols.key)?.takeRetainedValue() as? NSNumber
        else { return false }
        return value.boolValue
    }
}
