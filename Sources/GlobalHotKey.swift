import AppKit
import Carbon.HIToolbox

/// 一组快捷键：Carbon 键码 + Carbon 修饰键，外加录制时记下的显示文字（「⌥Space」）
struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    /// 预设：⌥Space（同 Raycast）
    static let defaultSearch = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), display: "⌥Space")

    /// 录制：从按键事件取出快捷键。至少要带 ⌘ / ⌃ / ⌥ 之一（F 键除外），否则返回 nil
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let isFunctionKey = Self.functionKeys[Int(event.keyCode)] != nil
        guard isFunctionKey || !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option)  { carbon |= UInt32(optionKey);  symbols += "⌥" }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey);   symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey);     symbols += "⌘" }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon,
                  display: symbols + Self.keyName(event))
    }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        let code = Int(event.keyCode)
        if let name = functionKeys[code] ?? specialKeys[code] { return name }
        // 按住 ⌥ 时 characters 会变成特殊符号（⌥A = å），取不带修饰键的那个字
        return (event.charactersIgnoringModifiers ?? "").uppercased()
    }
}

/// 全局快捷键（Carbon RegisterEventHotKey）：不需要「辅助使用」权限，
/// 任何 App 在前台都能收到。按下时回调在主线程
@MainActor
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var keys: [UInt32: HotKey] = [:]
    /// 设置里正在录新快捷键：先全部注销，不然按下现有组合会被系统先拿去触发、录不到
    private var suspended = false
    private var handlerInstalled = false
    private static let signature: OSType = 0x5854_4248 // 'XTBH'

    /// 注册（同一个 id 先注销旧的）。返回是否成功 —— 和别的 App 冲突时会失败
    @discardableResult
    func register(id: UInt32, _ key: HotKey, action: @escaping () -> Void) -> Bool {
        unregister(id: id)
        keys[id] = key
        actions[id] = action
        return suspended ? true : activate(id: id)
    }

    func unregister(id: UInt32) {
        deactivate(id: id)
        actions.removeValue(forKey: id)
        keys.removeValue(forKey: id)
    }

    func suspend() {
        guard !suspended else { return }
        suspended = true
        refs.keys.forEach(deactivate)
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        keys.keys.forEach { activate(id: $0) }
    }

    @discardableResult
    private func activate(id: UInt32) -> Bool {
        guard let key = keys[id] else { return false }
        installHandler()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            TTLog("hotkey register failed id=\(id) key=\(key.display) status=\(status)")
            return false
        }
        refs[id] = ref
        TTLog("hotkey registered id=\(id) key=\(key.display)")
        return true
    }

    private func deactivate(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKeys.shared.actions[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
