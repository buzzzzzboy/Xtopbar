import AppKit
import Combine

/// 发布信息（来自 GitHub Releases）。
struct UpdateRelease: Equatable {
    var version: String        // 去掉 v 前缀，如 "1.3.0"
    var tag: String            // 原始 tag，如 "v1.3.0"
    var notes: String          // Release 说明
    var zipURL: String?        // 可自动安装的分发包（.zip）
    var pageURL: String        // 发布页，手动下载用
}

/// 在线更新。
///
/// **不需要任何自建服务器**：GitHub Releases 同时充当「固定地址」和「云空间」。
/// `https://api.github.com/repos/<owner>/<repo>/releases/latest` 这个地址恒定不变，
/// 每次发版把 zip 传成 Release 资源即可。仓库是公开的，所以下载不需要 token。
///
/// 装包流程（轻量自研 Sparkle）：
/// 下载 zip → 解到临时目录 → 校验（bundle id / 版本号 / 签名）→
/// 写一个「等旧进程退出」的 shell helper → 自己退出 → helper 覆盖 .app 并重新拉起。
///
/// 为什么不用 Sparkle：本项目是 swiftc 直编 + build.sh，没有 SPM / Xcode 工程，
/// 引入 Sparkle 要另外嵌 xcframework、复制 framework 再单独签名，成本高于自己写。
@MainActor
final class Updater: ObservableObject {

    static let shared = Updater()

    /// 改这两行就能指到别的仓库
    static let owner = "lrylnx"
    static let repo  = "TopTab"

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case working(String)       // 下载 / 解压 / 校验 / 安装中的说明
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .working: return true
            default: return false
            }
        }
    }

    enum UpdateError: LocalizedError {
        case http(Int)
        case parse
        case network
        case unpack(String)
        case verify(String)

        var errorDescription: String? {
            switch self {
            case .http(let code):    return "发布接口返回 HTTP \(code)"
            case .parse:             return "发布信息解析失败"
            case .network:           return "网络请求失败"
            case .unpack(let why):   return "解压失败：\(why)"
            case .verify(let why):   return "校验失败：\(why)"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    /// 上次检查时间，用于「静默检查」的频率限制
    private var lastCheck: Date?

    private init() {}

    // MARK: - 版本号

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// "1.3.0" → [1, 3, 0]；容忍 "v1.3"、"1.3.0-beta" 这类写法
    static func versionTuple(_ raw: String) -> [Int] {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        var parts = text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        return parts
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = versionTuple(remote), b = versionTuple(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 接口

    /// 测试用：设了 `TOPTAB_UPDATE_FEED` 就换成自己的地址（本地文件 URL 也行）
    static var feedURL: URL {
        if let raw = ProcessInfo.processInfo.environment["TOPTAB_UPDATE_FEED"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }

    static var releasePageURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases")!
    }

    private func fetchLatest() async throws -> UpdateRelease {
        var request = URLRequest(url: Self.feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TopTab", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UpdateError.network
        }
        guard let http = response as? HTTPURLResponse else { throw UpdateError.network }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.parse
        }

        let tag = (object["tag_name"] as? String) ?? ""
        var version = tag
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        guard !version.isEmpty else { throw UpdateError.parse }

        var zipURL: String?
        if let assets = object["assets"] as? [[String: Any]] {
            // 自动更新必须能解包，所以优先挑 .zip；没有就退回第一个资源
            let zips = assets.filter {
                (($0["name"] as? String) ?? "").lowercased().hasSuffix(".zip")
            }
            zipURL = zips.first?["browser_download_url"] as? String
                ?? assets.first?["browser_download_url"] as? String
        }

        return UpdateRelease(
            version: version,
            tag: tag,
            notes: (object["body"] as? String) ?? "",
            zipURL: zipURL,
            pageURL: (object["html_url"] as? String) ?? Self.releasePageURL.absoluteString
        )
    }

    // MARK: - 检查

    /// 菜单里点「检查更新…」：有新版本就直接弹更新框，没有就明确告诉用户
    func checkInteractively() {
        if case .available(let release) = phase {
            presentUpdateAlert(release)
            return
        }
        check(silent: false)
    }

    func check(silent: Bool) {
        guard !phase.isBusy else { return }
        if silent, let last = lastCheck, Date().timeIntervalSince(last) < 3600 { return }
        lastCheck = Date()

        phase = .checking
        Task {
            do {
                let release = try await fetchLatest()
                if Self.isNewer(release.version, than: Self.currentVersion) {
                    phase = .available(release)
                    TTLog("updater: 发现新版本 \(release.version)（当前 \(Self.currentVersion)）"
                          + " zip=\(release.zipURL ?? "无")")
                    // 静默检查时，用户已经点过「跳过这个版本」就不再打扰
                    if silent, Preferences.shared.ignoredVersion == release.version { return }
                    presentUpdateAlert(release)
                } else {
                    phase = .upToDate
                    TTLog("updater: 已是最新 \(Self.currentVersion)")
                    if !silent {
                        presentInfo("已是最新版本",
                                    "当前 v\(Self.currentVersion) 已经是最新版本。")
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                phase = .failed(message)
                TTLog("updater: 检查失败 \(message)")
                if !silent { presentInfo("检查更新失败", message) }
            }
        }
    }

    func openReleasePage(_ release: UpdateRelease? = nil) {
        let url = release.flatMap { URL(string: $0.pageURL) } ?? Self.releasePageURL
        NSWorkspace.shared.open(url)
    }

    /// 调试用（`--update-install`）：不弹窗，发现新版本就直接装上。
    /// 用来验证「打包 → 上传 → 下载 → 替换」整条链路，省得每次手点。
    func checkAndInstallAutomatically() {
        guard !phase.isBusy else { return }
        phase = .checking
        Task {
            do {
                let release = try await fetchLatest()
                guard Self.isNewer(release.version, than: Self.currentVersion) else {
                    phase = .upToDate
                    TTLog("updater: --update-install 但已是最新 \(Self.currentVersion)")
                    return
                }
                phase = .available(release)
                TTLog("updater: --update-install 直接安装 \(Self.currentVersion) → \(release.version)")
                downloadAndInstall(release, confirmSignatureChange: false)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                phase = .failed(message)
                TTLog("updater: --update-install 失败 \(message)")
            }
        }
    }

    // MARK: - 弹窗

    private func presentUpdateAlert(_ release: UpdateRelease) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "TopTab \(release.version) 可以更新"
        var info = "当前版本 v\(Self.currentVersion) → v\(release.version)"
        if !release.notes.isEmpty {
            let notes = release.notes.prefix(600)
            info += "\n\n" + notes + (release.notes.count > 600 ? "…" : "")
        }
        if release.zipURL == nil {
            info += "\n\n这个版本没有上传 .zip 分发包，只能去发布页手动下载。"
        }
        alert.informativeText = info
        alert.addButton(withTitle: release.zipURL == nil ? "打开发布页" : "立即更新")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过这个版本")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if release.zipURL != nil {
                downloadAndInstall(release)
            } else {
                openReleasePage(release)
            }
        case .alertThirdButtonReturn:
            Preferences.shared.ignoredVersion = release.version
        default:
            break
        }
    }

    private func presentInfo(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 下载 + 安装

    func downloadAndInstall(_ release: UpdateRelease, confirmSignatureChange: Bool = true) {
        guard let raw = release.zipURL, let zipURL = URL(string: raw) else {
            openReleasePage(release)
            return
        }

        let destination = Bundle.main.bundleURL

        // App Translocation：从 DMG 直接打开、没拖进 Applications 时，
        // 系统会把 App 挂到一个随机只读路径下跑，那里替换不了。
        if destination.path.contains("/AppTranslocation/") {
            presentInfo("请先移动 TopTab",
                        "TopTab 现在运行在系统的临时挂载位置。\n"
                        + "请把 TopTab.app 拖到「应用程序」文件夹里再打开，之后就能自动更新了。")
            openReleasePage(release)
            return
        }

        // 先探路：位置不可写就直说，别等下完才发现装不进去
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            presentInfo("无法自动更新",
                        "TopTab 所在的 \(parent.path) 没有写入权限。\n"
                        + "请到发布页手动下载，或把 App 移到自己的用户目录下再试。")
            openReleasePage(release)
            return
        }

        Task {
            var work: URL?
            do {
                let workDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TopTabUpdate-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                work = workDir

                phase = .working("正在下载 v\(release.version)…")
                let (downloaded, _) = try await URLSession.shared.download(from: zipURL)
                let archive = workDir.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: downloaded, to: archive)

                phase = .working("正在解压…")
                let extractDir = workDir.appendingPathComponent("extract")
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
                let unpack = Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, extractDir.path])
                guard unpack.status == 0 else { throw UpdateError.unpack(unpack.output) }

                guard let newApp = Self.findApp(in: extractDir) else {
                    throw UpdateError.unpack("压缩包里没有 .app")
                }

                phase = .working("正在校验…")
                try Self.verify(newApp, expecting: release)

                // 签名证书变了 → TCC 里的授权记录（屏幕录制 / 辅助功能）会失效
                let sameSigner = Self.designatedRequirement(of: destination)
                    == Self.designatedRequirement(of: newApp)
                if !sameSigner, confirmSignatureChange {
                    NSApp.activate(ignoringOtherApps: true)
                    let warn = NSAlert()
                    warn.messageText = "更新后需要重新授权"
                    warn.informativeText =
                        "这个版本的签名与当前安装的不同。\n"
                        + "更新完成后 TopTab 会需要重新授予「屏幕录制」和「辅助功能」权限。\n\n"
                        + "（如果你是拿同一台机器、同一张证书重新构建的，看到这个提示说明证书被重建过。）"
                    warn.addButton(withTitle: "继续更新")
                    warn.addButton(withTitle: "取消")
                    guard warn.runModal() == .alertFirstButtonReturn else {
                        phase = .available(release)
                        return
                    }
                }

                phase = .working("正在安装…")
                try Self.launchInstaller(source: newApp, destination: destination)

                TTLog("updater: helper 已启动，TopTab 即将退出并由 helper 重新拉起")
                // 给 helper 一点时间起来，然后退出自己 —— 剩下的交给它
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                TTLog("updater: 安装失败 \(message)")
                phase = .failed(message)
                if let work { try? FileManager.default.removeItem(at: work) }
                presentInfo("更新失败", message + "\n\n可以到发布页手动下载。")
                openReleasePage(release)
            }
        }
    }

    // MARK: - 工具

    private struct ToolResult {
        var status: Int32
        var output: String
    }

    private static func run(_ path: String, _ arguments: [String]) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ToolResult(status: -1, output: "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolResult(status: process.terminationStatus,
                          output: String(data: data, encoding: .utf8) ?? "")
    }

    /// 签名里的 designated requirement。两个包一致 → TCC 授权能延续。
    private static func designatedRequirement(of app: URL) -> String? {
        let result = run("/usr/bin/codesign", ["-d", "-r-", app.path])
        // codesign 把 requirement 写在 stderr，形如：
        //   # designated => identifier "com.zxwzz.toptab" and certificate root = H"..."
        for line in result.output.split(separator: "\n") {
            guard let range = line.range(of: "designated =>") else { continue }
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func verify(_ app: URL, expecting release: UpdateRelease) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let bundleID = info["CFBundleIdentifier"] as? String else {
            throw UpdateError.verify("包内缺少 Info.plist")
        }
        guard bundleID == Bundle.main.bundleIdentifier else {
            throw UpdateError.verify("包内的 App 不是 TopTab（\(bundleID)）")
        }
        let newVersion = (info["CFBundleShortVersionString"] as? String) ?? ""
        guard !Self.isNewer(release.version, than: newVersion) else {
            throw UpdateError.verify("包内版本 \(newVersion) 低于发布版本 \(release.version)")
        }
        let check = run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        guard check.status == 0 else {
            throw UpdateError.verify("签名校验没通过：\(check.output)")
        }
    }

    /// 在解压结果里找 .app（压缩包常见两种结构：根目录直接是 .app，或套一层文件夹）
    private static func findApp(in root: URL) -> URL? {
        let manager = FileManager.default
        func apps(in dir: URL) -> [URL] {
            (try? manager.contentsOfDirectory(at: dir,
                                              includingPropertiesForKeys: nil,
                                              options: [.skipsHiddenFiles]))?
                .filter { $0.pathExtension == "app" } ?? []
        }
        if let direct = apps(in: root).first { return direct }
        let subdirs = (try? manager.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
        for dir in subdirs {
            if let found = apps(in: dir).first { return found }
        }
        return nil
    }

    /// 把「等退出 → 覆盖 → 去隔离属性 → 重新拉起」写成脚本丢出去执行。
    ///
    /// 必须另起进程做：正在运行的 .app 没法自己覆盖自己，
    /// 而且新版本要拉起来，父进程得先消失。
    private static func launchInstaller(source: URL, destination: URL) throws {
        let workDir = source.deletingLastPathComponent()
        let script = workDir.appendingPathComponent("install.sh")
        let body = """
        #!/bin/sh
        # TopTab 自动更新 helper
        # $1 = 旧进程 pid   $2 = 新 .app   $3 = 目标 .app
        PID="$1"; SRC="$2"; DST="$3"
        if [ -z "$PID" ] || [ -z "$SRC" ] || [ -z "$DST" ]; then exit 2; fi

        # 等旧进程退出，最多 60 秒
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          i=$((i + 1))
          [ "$i" -gt 300 ] && exit 1
          sleep 0.2
        done
        sleep 0.5

        BAK="$DST.old"
        rm -rf "$BAK"
        if mv "$DST" "$BAK" 2>/dev/null; then
          if ditto "$SRC" "$DST"; then
            rm -rf "$BAK"
          else
            rm -rf "$DST"
            mv "$BAK" "$DST"
            open "$DST"
            exit 1
          fi
        else
          # 跨卷等 mv 失败的情况，退回原地覆盖
          ditto "$SRC" "$DST" || { open "$DST"; exit 1; }
        fi

        # 自签名 App 没公证，从网络下来的副本会被 Gatekeeper 隔离，必须去掉
        xattr -dr com.apple.quarantine "$DST" 2>/dev/null
        open "$DST"
        exit 0
        """
        try body.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            source.path,
            destination.path
        ]
        // 不 waitUntilExit：本进程马上就要退出，helper 得在它之后活着
        try process.run()
    }
}
