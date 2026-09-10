import AppKit
import ApplicationServices

/// 窗口聚焦（辅助功能 API）与标题补全
enum WindowBridge {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 直接深链到「辅助功能」设置面板，省得用户自己去找
    static func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - AX 并发闸门

    /// Chromium / Electron / Qt 系被**并发**询问 `kAXWindowsAttribute` 时会返回
    /// 「success + 空数组」。实测最典型的是 QQ：串行问 5/5 正常返回 1 个窗口，
    /// 6 路并发 48/48 **全部返回空**，且错误码是 success（不是超时）——
    /// 所以「查到空」和「没有窗口」根本分不开。
    ///
    /// 而 TopTab 恰好会在同一个瞬间对同一个进程发两路：预览枚举（`refresh`）+
    /// 关窗前的重新配对（`closeWindow`）。两边一撞，关窗永远拿不到窗口列表，
    /// 用户看到的就是"App 没有响应关闭请求"。
    ///
    /// 解决：按目标进程串行。不同 App 之间仍然并行（实测互不影响），
    /// 同一个 App 排队进闸。
    private static let gateTableLock = NSLock()
    private static var gates: [pid_t: NSLock] = [:]

    static func axGate<R>(for pid: pid_t, _ body: () -> R) -> R {
        let lock: NSLock = {
            gateTableLock.lock(); defer { gateTableLock.unlock() }
            if let existing = gates[pid] { return existing }
            let fresh = NSLock(); gates[pid] = fresh; return fresh
        }()
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Electron / Chromium 冷启动时无障碍树可能还没建，`AXWindows` 会一直回空。
    /// 写这两个开关是让对端开始建树的公认做法（`AXManualAccessibility` 对 Electron，
    /// `AXEnhancedUserInterface` 对 Chromium）。代价是对端要维护整棵树，
    /// 所以只在「明明有窗口却问不出来」时才用，不常开。
    static func wakeUpAccessibility(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // MARK: - 窗口配对

    private struct AXWindow {
        let element: AXUIElement
        let title: String
        let frame: CGRect?
    }

    /// 聚焦某个 App 的指定窗口。
    ///
    /// 定位优先级：**CG 窗口编号**（预览缩略图的像素来源，绝无歧义）→
    /// 枚举阶段记下的 AX 下标 → 标题 + 几何重新配对。
    static func focusWindow(pid: pid_t, axIndex: Int?, frame: CGRect, title: String, cgID: UInt32? = nil) {
        guard isTrusted else {
            activateApp(pid)
            return
        }
        // 切窗口和预览枚举也会撞车（同一个 App），必须同走一道闸
        axGate(for: pid) { _focusWindow(pid: pid, axIndex: axIndex, frame: frame, title: title, cgID: cgID) }
    }

    private static func _focusWindow(pid: pid_t, axIndex: Int?, frame: CGRect, title: String, cgID: UInt32?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)

        let windows = axWindows(app)
        guard !windows.isEmpty else {
            activateApp(pid)
            return
        }

        guard let target = locateTarget(pid: pid, app: app, axIndex: axIndex,
                                        frame: frame, title: title, cgID: cgID) else {
            TTLog("focus ax=\(String(describing: axIndex)) → 无匹配，只激活 App")
            activateApp(pid)
            return
        }

        TTLog("focus cgID=\(String(describing: cgID)) ax=\(String(describing: axIndex)) title=\"\(title)\"")

        AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        // ── 提窗流程（隔离实验 foc5/foc6/foc7 定稿）──
        // Chromium（Chrome 多窗）的激活是**异步**的：激活过程中它会把「自己认定的
        // 上个主窗口」重排到顶，紧跟其后的 AXRaise 会被这次重排冲掉——表现就是
        // "点哪个预览都回到上一个窗口"。纯 AXRaise 本身 100% 准（后台实测 4/4），
        // 所以顺序必须是：main/focused 前置（Electron 系需要）→ 激活 → 等重排稳定
        // → 纯 raise → 用**窗口服务器层级**做地面真值验证，不对就重发（最多 3 次）。
        // 注意不能用 AX 的 main window 汇报做验证——Chrome 会接受 main 写入但屏幕不真切。
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        usleep(350_000)   // 等激活引发的窗口重排落地，raise 必须排在它后面

        var attempts = 0
        while attempts < 3 {
            // 每次都用最新列表重新定位（窗口重排后旧元素的映射可能失效）
            let fresh = locateTarget(pid: pid, app: app, axIndex: axIndex,
                                     frame: frame, title: title, cgID: cgID)
            AXUIElementPerformAction(fresh ?? target, kAXRaiseAction as CFString)
            attempts += 1
            usleep(300_000)
            if title.isEmpty || cgFrontMatches(pid: pid, frame: frame, title: title) { break }
        }
        if attempts > 1 { TTLog("focus 重发 raise \(attempts) 次") }
    }

    /// 按 **CG 编号位置配对 → AX 下标 → 标题几何** 的顺序在最新窗口列表里定位目标元素
    private static func locateTarget(pid: pid_t, app: AXUIElement, axIndex: Int?,
                                     frame: CGRect, title: String, cgID: UInt32?) -> AXUIElement? {
        let windows = axWindows(app)
        guard !windows.isEmpty else { return nil }
        // 首选：CG 窗口编号定位。CG 列表与 AX 列表都按前→后排序且成员一致
        //（实测连 Chrome 的底部状态气泡都按相同顺序出现在两边），按位置一一对应。
        // 预览缩略图像素就是从这个 CG 编号抓的，所以这是唯一不会错位的锚点。
        if let cgID, cgID < 0xF000_0000 {   // >= 0xF000_0000 是 AX 独有窗口的合成 ID
            let cg = cgWindowIDs(pid: pid)
            if let pos = cg.firstIndex(of: cgID), cg.count == windows.count,
               windows.indices.contains(pos) {
                let c = windows[pos]
                if title.isEmpty || c.title.isEmpty || c.title == title
                    || c.title.contains(title) || title.hasPrefix(c.title) {
                    return c.element
                }
            }
        }
        if let axIndex, windows.indices.contains(axIndex) {
            let c = windows[axIndex]
            // 下标可能已经错位，标题对不上就重新配对
            if title.isEmpty || c.title.isEmpty || c.title == title || c.title.contains(title) {
                return c.element
            }
        }
        return bestMatch(in: windows, frame: frame, title: title)
    }

    /// pid 的 layer-0 窗口编号，前→后（含小表面，成员与 AX 窗口列表对齐）
    private static func cgWindowIDs(pid: pid_t) -> [UInt32] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [UInt32] = []
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? UInt32 else { continue }
            out.append(id)
        }
        return out
    }

    /// 窗口服务器地面真值：pid 的 layer-0 最前面的「大窗口」是否就是目标窗口。
    /// 只有 AX 汇报不可信（Chrome 会接受 main 写入但屏幕不真切），层级以 CG 为准。
    /// kCGWindowName 需要录屏权限（TopTab 有）；名字拿不到时退回几何配对。
    /// 返回 true 表示"已就位 / 无法判断"，只有确凿不匹配才返回 false 触发重试。
    private static func cgFrontMatches(pid: pid_t, frame: CGRect, title: String) -> Bool {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return true }
        for w in list {
            guard let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let wd = (b["Width"] as? NSNumber)?.doubleValue,
                  let ht = (b["Height"] as? NSNumber)?.doubleValue else { continue }
            guard wd > 200, ht > 100 else { continue }   // 跳过状态气泡 / tooltip 等小表面
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty {
                // CG 的窗口名是截断版（"哔哩哔哩…" vs AX 全名"哔哩哔哩… - Google Chrome"）
                return title.hasPrefix(name) || name.hasPrefix(title) || title.contains(name)
            }
            guard let x = (b["X"] as? NSNumber)?.doubleValue,
                  let y = (b["Y"] as? NSNumber)?.doubleValue else { return true }
            let cb = CGRect(x: x, y: y, width: wd, height: ht)
            return abs(cb.minX - frame.minX) < 8 && abs(cb.minY - frame.minY) < 8
                && abs(cb.width - frame.width) < 8 && abs(cb.height - frame.height) < 8
        }
        return true
    }

    /// 按前台→后台顺序取窗口标题，用于窗口服务器拿不到标题时兜底
    static func titles(pid: pid_t) -> [String] {
        guard isTrusted else { return [] }
        return axGate(for: pid) { _titles(pid: pid) }
    }

    private static func _titles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        return axWindows(app).map(\.title)
    }

    /// 关闭指定窗口。
    ///
    /// 首选走窗口自己的关闭按钮（等价于点左上角那个红点），**不发 Cmd+W** ——
    /// 快捷键是发给"当前前台 App"的，预览里那个 App 未必在前台，会关错窗口。
    ///
    /// 这里同时兜住三件容易翻车的事：
    ///
    /// 1. **查询超时 ≠ 没有窗口**。Chromium / Electron 系（微信、QQ、抖店工作台）
    ///    第一次被 AX 询问时要现场构建整棵无障碍树，很容易超过超时返回
    ///    `kAXErrorCannotComplete`。旧代码把这种失败和"这个 App 没窗口"混在一起
    ///    （`axWindows` 出错也返回 `[]`），于是直接返回 false —— 用户看到的
    ///    就是"App 没有响应关闭请求"。现在拆开：出错就等一拍重试一次。
    /// 2. **AX 的返回值不可信**。有的 App 返回成功其实没关，有的返回失败其实关了。
    ///    所以按下之后统一用「窗口还在不在」来判定，不看返回值。
    /// 3. **同名同尺寸的窗口**。Chrome 两个窗口都是 `0,33 1470×841` 是常态，
    ///    所以验证用的是"这个几何下的窗口**数量有没有减少**"，不是"还有没有"。
    ///
    /// 配对逻辑和 `focusWindow` 一致：先按下标，标题对不上再靠标题 + 几何重配。
    @discardableResult
    static func closeWindow(pid: pid_t, axIndex: Int?, frame: CGRect, title: String,
                            avoid: [CGRect] = []) -> Bool {
        guard isTrusted else { return false }
        // 整个「查窗口 → 按关闭 → 验证」都在闸内，期间预览那边的枚举会排队，
        // 不会再插进来一根并发查询把 Electron 系问到回空
        return axGate(for: pid) {
            _closeWindow(pid: pid, axIndex: axIndex, frame: frame, title: title, avoid: avoid)
        }
    }

    private static func _closeWindow(pid: pid_t, axIndex: Int?, frame: CGRect,
                                     title: String, avoid: [CGRect]) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        // 关闭要等对端把树建完，超时给宽一点（旧值 0.4s 对 Electron 系偏紧）
        AXUIElementSetMessagingTimeout(app, 1.2)

        var windows = axWindows(app)
        if windows.isEmpty {
            // 可能是超时，也可能真的没有 —— 给对端一拍时间再问一次
            usleep(250_000)
            windows = axWindows(app)
        }
        if windows.isEmpty {
            // 窗口服务器明明看得到它，AX 却问不出来 —— 多半是 Electron 系
            // 还没建无障碍树，写开关唤醒后再问两次
            TTLog("close pid=\(pid) AX 回空，尝试唤醒无障碍（AXManualAccessibility）")
            wakeUpAccessibility(pid)
            usleep(400_000)
            windows = axWindows(app)
            if windows.isEmpty {
                usleep(600_000)
                windows = axWindows(app)
            }
        }
        guard !windows.isEmpty else {
            // AX 彻底问不出来。窗口本身还在（frame 是预览阶段从窗口服务器拿的），
            // 还能走最后一条路：真实点击它左上角的红点。
            TTLog("close pid=\(pid) → AX 列不出窗口，改用合成点击红点兜底")
            return closeByRedDotClick(pid: pid, frame: frame, avoid: avoid)
        }

        var target: AXUIElement?
        if let axIndex, windows.indices.contains(axIndex) {
            let candidate = windows[axIndex]
            // 下标可能已经错位，标题对不上就重新配对
            if title.isEmpty || candidate.title.isEmpty || candidate.title == title
                || candidate.title.contains(title) {
                target = candidate.element
            }
        }
        if target == nil { target = bestMatch(in: windows, frame: frame, title: title) }
        guard let target else {
            TTLog("close ax=\(String(describing: axIndex)) → 无匹配 "
                  + "all=\(windows.map(\.title))")
            return false
        }

        // 预先数一下这个几何下有几个窗口：关掉一个之后数量应该变少。
        // 数不出来（比如窗口在别的桌面且窗口服务器不列）就退回信任 AX 的返回值。
        let before = matchingWindowCount(pid: pid, frame: frame)

        // 三级按下方式，逐级升级。每试一级都回头看看窗口有没有真的走掉 ——
        // 光看返回值会误判（Chromium 系就常有"返回成功但什么都没发生"）。
        let attempts: [(AXUIElement) -> Bool] = [
            pressCloseButtonAttribute,     // 标准做法：AXCloseButton + AXPress
            pressCloseButtonInSubtree,     // 有的 App 不挂属性，得靠 subrole 深搜
            pressWindowCloseAction         // 少数 App 支持窗口自身的 AXClose
        ]
        for (i, attempt) in attempts.enumerated() {
            let issued = attempt(target)
            let gone = before > 0
                ? waitUntilWindowGone(pid: pid, frame: frame, before: before, timeout: 1.0)
                : issued
            TTLog("close\(i + 1) issued=\(issued) gone=\(gone) before=\(before)")
            if gone { return true }
        }
        // AX 三级都按了但窗口纹丝不动 —— 最后再试一次真实点击红点
        return closeByRedDotClick(pid: pid, frame: frame, avoid: avoid)
    }

    // MARK: - 合成点击红点（AX 完全使不上力时的最后一条路）

    /// 直接点击窗口左上角的红色关闭按钮。
    ///
    /// 这是"未经 App 同意"的操作，必须满足两个前提才敢点：
    /// 1. **红点位置最上层的就是目标窗口**。合成点击落在屏幕坐标上，
    ///    如果目标被别的窗口压住，点到的就是别人的东西 —— 绝对不行。
    /// 2. 点之前先数一遍这个几何下的窗口数，点完看数量有没有减少。
    ///
    /// 实测：对**后台** App 的窗口点红点，窗口会关掉，而且不会把那个 App
    /// 拉到前台（前台 App 保持不变），正好是用户想要的语义。
    private static func closeByRedDotClick(pid: pid_t, frame: CGRect, avoid: [CGRect]) -> Bool {
        let dot = CGPoint(x: frame.minX + 13, y: frame.minY + 13)
        // 自己的面板正好压在红点上时，这一下会点进预览卡片里去（变成切窗口）—— 绝不点
        guard !avoid.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(dot) }) else {
            TTLog("close 兜底放弃：红点位置被自己的面板挡住 dot=\(dot)")
            return false
        }
        guard topmostWindowOwner(at: dot) == pid else {
            TTLog("close 兜底放弃：红点位置最上层不是目标窗口（dot=\(dot)）")
            return false
        }
        let before = matchingWindowCount(pid: pid, frame: frame)
        guard before > 0 else {
            TTLog("close 兜底放弃：窗口服务器里数不到这个窗口")
            return false
        }

        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: dot, mouseButton: .left) else { continue }
            event.post(tap: .cghidEventTap)
            usleep(70_000)
        }
        let gone = waitUntilWindowGone(pid: pid, frame: frame, before: before, timeout: 1.5)
        TTLog("close 兜底点击红点 @\(Int(dot.x)),\(Int(dot.y)) before=\(before) gone=\(gone)")
        return gone
    }

    /// 屏幕上这个坐标点，最上层那个普通窗口属于哪个进程。
    /// `CGWindowListCopyWindowInfo` 按前台→后台排列，取第一个 layer 0 且覆盖该点的。
    private static func topmostWindowOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: NSNumber] else { continue }
            let rect = CGRect(x: bounds["X"]?.doubleValue ?? 0,
                              y: bounds["Y"]?.doubleValue ?? 0,
                              width: bounds["Width"]?.doubleValue ?? 0,
                              height: bounds["Height"]?.doubleValue ?? 0)
            if rect.contains(point) { return owner }
        }
        return nil
    }

    // MARK: - 关闭的三级按下

    private static func pressCloseButtonAttribute(_ window: AXUIElement) -> Bool {
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button)
                == .success, let button,
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        let element = unsafeBitCast(button, to: AXUIElement.self)
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// 属性没有就往下翻，找 `subrole == AXCloseButton` 的元素。
    /// 深度限在 5 层：关闭按钮要么在窗口本体上，要么在第一层工具栏里。
    private static func pressCloseButtonInSubtree(_ window: AXUIElement) -> Bool {
        guard let button = findCloseButton(in: window, depth: 0) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private static func findCloseButton(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 5 else { return nil }
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let s = subrole as? String, s == "AXCloseButton" {
            return element
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                == .success, let list = children as? [AXUIElement] else { return nil }
        for child in list {
            if let hit = findCloseButton(in: child, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func pressWindowCloseAction(_ window: AXUIElement) -> Bool {
        AXUIElementPerformAction(window, "AXClose" as CFString) == .success
    }

    // MARK: - 关闭结果验证

    /// 这个几何下、属于该进程的窗口数量。
    ///
    /// 用窗口服务器而不是 AX：AX 查询会阻塞（对端卡住时要等超时），
    /// 而这里要在一个很短的轮询里反复调用。
    private static func matchingWindowCount(pid: pid_t, frame: CGRect) -> Int {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return 0 }

        return list.reduce(into: 0) { count, info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: NSNumber] else { return }
            let rect = CGRect(x: bounds["X"]?.doubleValue ?? 0,
                              y: bounds["Y"]?.doubleValue ?? 0,
                              width: bounds["Width"]?.doubleValue ?? 0,
                              height: bounds["Height"]?.doubleValue ?? 0)
            if abs(rect.minX - frame.minX) <= 4, abs(rect.minY - frame.minY) <= 4,
               abs(rect.width - frame.width) <= 4, abs(rect.height - frame.height) <= 4 {
                count += 1
            }
        }
    }

    /// 轮询等窗口数量掉下来。关闭动画要走几百毫秒，所以给足时间；
    /// 这段时间是在后台线程上花的，不影响界面。
    private static func waitUntilWindowGone(pid: pid_t, frame: CGRect,
                                           before: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if matchingWindowCount(pid: pid, frame: frame) < before { return true }
            if Date() >= deadline { return false }
            usleep(120_000)
        }
    }

    /// 这个几何下、属于该进程的窗口现在还在吗（走窗口服务器，不碰 AX）。
    /// 关闭失败时用来判断"是真的没关掉"还是"窗口早就不在了"。
    static func windowExists(pid: pid_t, frame: CGRect) -> Bool {
        matchingWindowCount(pid: pid, frame: frame) > 0
    }

    // MARK: - 内部

    private static func bestMatch(in windows: [AXWindow], frame: CGRect, title: String) -> AXUIElement? {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if !wanted.isEmpty {
            let exact = windows.filter { $0.title == wanted }
            if exact.count == 1 { return exact[0].element }
            if exact.count > 1 {
                return closest(exact, to: frame)?.element
            }
            let loose = windows.filter { !$0.title.isEmpty && $0.title.contains(wanted) }
            if !loose.isEmpty { return closest(loose, to: frame)?.element }
        }

        // 标题对不上就纯靠几何配对（AX 窗口位置的坐标系与 CG/SC 一致：原点上左）
        return closest(windows.filter { $0.frame != nil }, to: frame)?.element
    }

    private static func closest(_ windows: [AXWindow], to frame: CGRect) -> AXWindow? {
        windows.min { a, b in
            distance(a.frame, frame) < distance(b.frame, frame)
        }
    }

    private static func distance(_ lhs: CGRect?, _ rhs: CGRect) -> CGFloat {
        guard let lhs else { return .greatestFiniteMagnitude }
        let dx = lhs.midX - rhs.midX
        let dy = lhs.midY - rhs.midY
        let dw = lhs.width - rhs.width
        let dh = lhs.height - rhs.height
        return dx * dx + dy * dy + dw * dw + dh * dh
    }

    private static func axWindows(_ app: AXUIElement) -> [AXWindow] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list.map { win in
            var title: CFTypeRef?
            var titleString = ""
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &title) == .success,
               let t = title as? String {
                titleString = t
            }
            return AXWindow(element: win, title: titleString, frame: axFrame(win))
        }
    }

    private static func axFrame(_ win: AXUIElement) -> CGRect? {
        guard let origin = axPoint(win, kAXPositionAttribute as CFString),
              let size = axSize(win, kAXSizeAttribute as CFString) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func axPoint(_ win: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, attribute, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSize(_ win: AXUIElement, _ attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, attribute, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(v as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// 拿不到 AX 窗口时的兜底：走 LaunchServices 激活整个 App
    static func activateApp(_ pid: pid_t) {
        guard let running = NSRunningApplication(processIdentifier: pid),
              let url = running.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
