# 工作列小工具 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在工作列六個固定槽位放「正在播放」「CPU／記憶體」「開始選單資料夾」三種小工具。

**Architecture:** 小工具的資料模型、槽位排列與寬度估算寫成純邏輯檔（`TaskbarWidgets.swift`，不碰 AppKit），用獨立的 swiftc 測試程式驗證。條的版面不再只靠 `TTLayout.detachedStartWidth`，改由一份「左側條外／條內頭／條內尾／右側條外」的寬度描述驅動，估算（合併判斷）與實測（條寬）兩條路徑都吃它。點擊走現有的窗口層命中測試（保留 id 上報到 `catalog.tabFrames`，`AppCatalog.handlePress` 分派）。

**Tech Stack:** Swift、SwiftUI、AppKit，用 `build.sh` 裡的 `swiftc` 直接編譯（沒有 Xcode 專案、沒有 XCTest）。

**Spec:** `docs/superpowers/specs/2026-11-27-taskbar-widgets-design.md`

## Global Constraints

- 只支援 macOS 26 以上、Apple Silicon，編譯目標 `arm64-apple-macosx26.0`；只用 Liquid Glass（`GlassBackdrop`／`GlassPill`），不寫舊系統替代畫法
- 點擊一律走窗口層命中測試：保留 id 上報到 `catalog.tabFrames`，`AppCatalog.handlePress` 判斷；不靠 SwiftUI `Button` 收點擊
- 寬度用估算值，不等 SwiftUI 量回來決定合併；正在播放的歌名一律以 140pt 上限估寬
- 縮放一律走 `TTLayout.s()`／`TTLayout.font()`
- 播放控制只用 `NowPlaying`（媒體鍵＋分散式通知），不用 MediaRemote／Apple Event
- 預設 `taskbarWidgets` 是空陣列：沒開小工具的使用者不能有任何變化（寬度、外觀、效能）
- 程式碼註解沿用既有風格（簡體中文註解），使用者看得到的文字用繁體中文
- UserDefaults key：`taskbarWidgets`
- 保留 id 格式：`__widget__<uuid>`、`__widget__<uuid>__prev`、`__widget__<uuid>__next`

## Review Focus

1. **換歌、暫停、播放器開關時條寬不抖**：換歌不能改變估寬（只有播放器開／關時才重算一次）→ Task 1 測試 `nowPlayingWidthIgnoresTitle`
2. **沒有任何 App 標籤時**，條內槽的小工具要移到條外，不能消失或畫在空氣裡；「隱藏空工作列」不能把看得見的小工具藏掉 → Task 1 測試 `noTabsMovesInnerSlotsOutside`、Task 3 驗證步驟
3. **拖曳 App 標籤時**，指標掃過或放在小工具上，不能觸發播放／開資料夾 → Task 4 驗證步驟
4. **開始選單刪掉資料夾**，工作列上對應的小工具要一起消失，不能留下點了沒反應的空殼 → Task 2 測試 `removingFolderDropsWidget`
5. **介面縮放、切換「只顯示圖示」之後**，命中範圍必須和畫面對齊（點到哪顆就是哪顆）→ Task 4 驗證步驟（75% 與 150% 各點一次）

---

## 檔案結構

| 檔案 | 責任 |
|---|---|
| Create `Sources/TaskbarWidgets.swift` | 純邏輯：`TaskbarWidgetSlot`、`TaskbarWidget`、`WidgetArrangement`、估寬、清單編輯規則 |
| Create `Sources/SystemStats.swift` | CPU／記憶體的純計算（`SystemStatsMath`）＋按需取樣器（`SystemStats`） |
| Create `Sources/TaskbarWidgetViews.swift` | 小工具的 SwiftUI 視圖、`TaskbarWidgets.current`（MainActor 的現況排列） |
| Create `Sources/FolderWidgetPopup.swift` | 資料夾卡片浮窗（仿 `BackgroundFolderController` 的 popup） |
| Create `scripts/tests/widgets/main.swift`、`scripts/test-widgets.sh` | 純邏輯測試程式 |
| Modify `Sources/Preferences.swift` | `taskbarWidgets` 存取；`TTLayout` 的寬度描述 |
| Modify `Sources/AppCatalog.swift` | `layoutMetrics().fixed`、`preferredWidth`、`handlePress`、`deleteStartFolder` |
| Modify `Sources/TabBarView.swift` | 槽位排版、條內兩端、命中上報 |
| Modify `Sources/TabBarController.swift` | `TabBarHost` 新方法、`hasBarItems`、`openTaskbarMenu` 攔截、浮窗互斥 |
| Modify `Sources/NowPlaying.swift` | 監聽播放器啟動 |
| Modify `Sources/StartMenuView.swift` | 拆出共用 `FolderTile`、資料夾右鍵「放到工作列」 |
| Modify `Sources/SettingsWindow.swift` | 「工作列小工具」設定段 |
| Modify `README.md` | 功能說明 |

---

### Task 0: 開分支、提交設計與計畫

- [ ] **Step 1:** `git switch -c feature/taskbar-widgets`
- [ ] **Step 2:** 提交

```bash
git add docs/superpowers/specs/2026-11-27-taskbar-widgets-design.md docs/superpowers/plans/2026-11-27-taskbar-widgets.md
git commit -m "docs: 工作列小工具設計與實作計畫"
```

---

### Task 1: 純邏輯模型、排列與估寬

**Files:**
- Create: `Sources/TaskbarWidgets.swift`
- Create: `scripts/tests/widgets/main.swift`、`scripts/test-widgets.sh`

**Interfaces:**
- Produces:
  ```swift
  enum TaskbarWidgetSlot: String, Codable, CaseIterable, Identifiable {
      case beforeStart, afterStart, beforeBar, barLeading, barTrailing, afterBar
      var title: String   // 「開始按鈕左邊」「開始與搜尋之間」「搜尋右邊」「工作列開頭」「工作列結尾」「工作列右邊」
  }
  struct TaskbarWidget: Codable, Identifiable, Equatable {
      enum Kind: Codable, Equatable { case nowPlaying, systemStats, folder(UUID) }
      var id: UUID = UUID()
      var kind: Kind
      var slot: TaskbarWidgetSlot
      var hitID: String { "__widget__\(id.uuidString)" }
      var prevHitID: String { hitID + "__prev" }
      var nextHitID: String { hitID + "__next" }
  }
  struct WidgetArrangement: Equatable {
      var beforeStart: [TaskbarWidget], afterStart: [TaskbarWidget], beforeBar: [TaskbarWidget]
      var barLeading: [TaskbarWidget], barTrailing: [TaskbarWidget], afterBar: [TaskbarWidget]
      static func arrange(_ widgets: [TaskbarWidget], isVisible: (TaskbarWidget) -> Bool, hasTabs: Bool) -> WidgetArrangement
      var isEmpty: Bool
  }
  enum TaskbarWidgetMetrics {
      /// 未縮放的 pt，不含外部的縫
      static func width(_ kind: TaskbarWidget.Kind, iconOnly: Bool, barBaseHeight: CGFloat, folderName: String?) -> CGFloat
      static let nowPlayingTitleCap: CGFloat = 140
  }
  enum TaskbarWidgetList {
      static func canAdd(_ kind: TaskbarWidget.Kind, to list: [TaskbarWidget]) -> Bool
      static func moving(_ id: UUID, to slot: TaskbarWidgetSlot, in list: [TaskbarWidget]) -> [TaskbarWidget]   // 移到目標槽的最後
      static func shifting(_ id: UUID, by offset: Int, in list: [TaskbarWidget]) -> [TaskbarWidget]          // 同槽內上移(-1)／下移(+1)，到頭不動
      static func pruned(_ list: [TaskbarWidget], existingFolders: Set<UUID>) -> [TaskbarWidget]
  }
  ```
- 本檔只能 `import Foundation` 和 `CoreGraphics`。

- [ ] **Step 1: 寫失敗的測試** `scripts/tests/widgets/main.swift`：頂層程式，用自己的 `func check(_ ok: Bool, _ name: String)` 計數，最後失敗數 > 0 就 `exit(1)`。測試：
  - `arrangeKeepsOrderWithinSlot`：三個 `.afterBar` 小工具 A、B、C（陣列順序）→ `arrange(...).afterBar.map(\.id) == [A, B, C]`
  - `invisibleWidgetsDropped`：`isVisible` 對 A 回 false → A 不出現在任何槽
  - `noTabsMovesInnerSlotsOutside`：`hasTabs: false`，`barLeading=[L]`、`barTrailing=[T]`、`beforeBar=[B]`、`afterBar=[R]` → `beforeBar == [B, L]`、`afterBar == [T, R]`、`barLeading`／`barTrailing` 都空
  - `nowPlayingWidthIgnoresTitle`：`width(.nowPlaying, iconOnly: false, barBaseHeight: 42, folderName: nil)` 呼叫兩次結果相同，且 ≥ `42/2*2 + 140`（兩端鍵各半個條高＋歌名上限）
  - `iconOnlyIsNarrower`：三種 kind 的 `iconOnly: true` 寬度都小於 `false`
  - `canAddRejectsDuplicates`：清單已有 `.nowPlaying` → `canAdd(.nowPlaying)` false；已有 `.folder(X)` → `canAdd(.folder(X))` false、`canAdd(.folder(Y))` true
  - `movingAppendsToTargetSlot`、`shiftingStaysInSlot`（只和同槽的鄰居換位，跨槽的不算鄰居；第一個上移不動）
  - `removingFolderDropsWidget`：`pruned([folder(X), folder(Y), nowPlaying], existingFolders: [Y])` 只剩 `folder(Y)` 和 `nowPlaying`
  - `codableRoundTrip`：`[TaskbarWidget]` 經 `JSONEncoder` → `JSONDecoder` 後相等（含 `.folder(UUID)`）
- [ ] **Step 2: 寫測試腳本** `scripts/test-widgets.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macosx26.0 \
  -o build/test-widgets Sources/TaskbarWidgets.swift Sources/SystemStats.swift scripts/tests/widgets/main.swift
./build/test-widgets
```
  （Task 1 時 `SystemStats.swift` 還不存在：先放一個只有檔頭註解的空檔，Task 6 再填）
- [ ] **Step 3: 跑測試確認失敗**：`./scripts/test-widgets.sh` → 編譯錯誤（型別未定義）
- [ ] **Step 4: 實作 `Sources/TaskbarWidgets.swift`**。估寬數字：
  - 正在播放（圖示＋名稱）：`barBaseHeight/2 * 2`（⏮⏭）＋ 封面 18 ＋ 間距 6 ＋ `nowPlayingTitleCap` ＋ 間距 6 ＋ 狀態圖示 14 ＋ 左右內距 16；只顯示圖示：`barBaseHeight/2 * 2` ＋ 封面 36 ＋ 14 ＋ 16
  - CPU／記憶體：兩組「標籤＋`100%` 等寬數字＋迷你橫條 24」用 `NSFont` 以外的固定數字估（不能 import AppKit）：圖示＋名稱 150、只顯示圖示 `barBaseHeight * 0.8`
  - 資料夾：只顯示圖示 `barBaseHeight`；圖示＋名稱 `barBaseHeight ＋ 名稱字數 × 12（上限 120）`
- [ ] **Step 5: 跑測試確認通過**：`./scripts/test-widgets.sh` → 印出全部 PASS、exit 0
- [ ] **Step 6: 確認主程式仍可編譯**：`./build.sh` 成功
- [ ] **Step 7: Commit** `feat: 工作列小工具的資料模型、排列與估寬`

---

### Task 2: 偏好設定與資料夾連動

**Files:**
- Modify: `Sources/Preferences.swift`（`Key`、`@Published` 屬性、載入區 `:577` 附近）
- Modify: `Sources/AppCatalog.swift:1153`（`deleteStartFolder`）

**Interfaces:**
- Consumes: Task 1 的 `TaskbarWidget`、`TaskbarWidgetList`
- Produces:
  ```swift
  // Preferences
  @Published var taskbarWidgets: [TaskbarWidget]   // key "taskbarWidgets"，JSON
  // AppCatalog
  func addTaskbarWidget(_ kind: TaskbarWidget.Kind, slot: TaskbarWidgetSlot)   // canAdd 為 false 時不動
  func moveTaskbarWidget(_ id: UUID, to slot: TaskbarWidgetSlot)
  func shiftTaskbarWidget(_ id: UUID, by offset: Int)
  func removeTaskbarWidget(_ id: UUID)
  ```
- 每個 AppCatalog 方法改完 `prefs.taskbarWidgets` 後要觸發一次重新排版（和改 `showStartButton` 時走同一條路）。

- [ ] **Step 1:** 加 `Key.taskbarWidgets`、`@Published var taskbarWidgets: [TaskbarWidget] = []`（`didSet` 編碼寫入），載入時解碼；解碼失敗當空陣列
- [ ] **Step 2:** 載入完 `startFolders` 後套一次 `TaskbarWidgetList.pruned`；`deleteStartFolder` 結尾同樣套一次
- [ ] **Step 3:** 實作 AppCatalog 四個方法（內部都用 `TaskbarWidgetList`）
- [ ] **Step 4: 驗證**：`./build.sh` 成功；`defaults read <bundle id> taskbarWidgets` 在升級後不存在（沒寫過就不寫）
- [ ] **Step 5: Commit** `feat: 工作列小工具偏好設定`

---

### Task 3: 版面寬度描述，取代 `detachedStartWidth`

**Files:**
- Modify: `Sources/Preferences.swift:646-691`（`TTLayout`）
- Create: `Sources/TaskbarWidgetViews.swift`（先只放 `TaskbarWidgets.current`）
- Modify: `Sources/AppCatalog.swift:520`（`layoutMetrics().fixed`）、`:1193-1215`（`preferredWidth`）
- Modify: `Sources/TabBarView.swift:446-466`（`bar` 寬度、捲動可見範圍）
- Modify: `Sources/TabBarController.swift:108`（`hasBarItems`）

**Interfaces:**
- Consumes: Task 1 `WidgetArrangement.arrange`、`TaskbarWidgetMetrics.width`；Task 2 `prefs.taskbarWidgets`
- Produces:
  ```swift
  @MainActor enum TaskbarWidgets {
      /// 依偏好、正在播放的播放器是否在跑、目前有沒有 App 標籤排出現況
      static func current(hasTabs: Bool) -> WidgetArrangement
      static func isVisible(_ w: TaskbarWidget) -> Bool   // 正在播放：依 prefs.nowPlayingSource 判斷播放器是否在跑
  }
  extension TTLayout {
      /// 條左邊的條外東西（槽 1、開始圓、槽 2、搜尋圓、槽 3）連縫的總寬；base = 未縮放
      @MainActor static func leftOuterWidth(_ a: WidgetArrangement) -> CGFloat
      @MainActor static func leftOuterBaseWidth(_ a: WidgetArrangement) -> CGFloat
      /// 條右邊的槽 6（含和條之間的縫）
      @MainActor static func rightOuterWidth(_ a: WidgetArrangement) -> CGFloat
      @MainActor static func rightOuterBaseWidth(_ a: WidgetArrangement) -> CGFloat
      /// 條內兩端（槽 4、5）
      @MainActor static func innerBaseWidth(_ a: WidgetArrangement) -> CGFloat
      @MainActor static func innerWidth(_ a: WidgetArrangement) -> CGFloat
  }
  ```
- 規則：每顆條外膠囊後面跟一個 `detachedStartGap`；沒有 App 標籤時，最右一顆條外東西右邊不留縫（同現在 `preferredWidth` 的處理）。

- [ ] **Step 1: 先錄基準**：在 `main` 上 `touch /tmp/xtopbar.debug && rm -f /tmp/xtopbar.log`，`./build.sh` 後 `open Xtopbar.app --args --test-pins`，等 3 秒，把 `/tmp/xtopbar.log` 的「條=」行存成 `build/pins-before.txt`
- [ ] **Step 2:** 實作 `TaskbarWidgets.current`／`isVisible` 與 `TTLayout` 六個函式；`detachedStartWidth`／`detachedStartBaseWidth` 保留但只當「開始＋搜尋」用，所有外部呼叫點改成新函式
- [ ] **Step 3:** `layoutMetrics().fixed = 24 + leftOuterBaseWidth + rightOuterBaseWidth + innerBaseWidth`
- [ ] **Step 4:** `preferredWidth` 兩條路徑（實測 `contentWidth`、估算）都加上 `leftOuterWidth + rightOuterWidth + innerWidth`；`groups.isEmpty` 分支改用 `current(hasTabs: false)` 的左右總寬
- [ ] **Step 5:** `TabBarView.bar` 寬度 = `barWidth - leftOuterWidth - rightOuterWidth`；捲動可見範圍的 x 起點 = `leftOuterWidth + 條內開頭寬`、寬度扣掉條內兩端
- [ ] **Step 6:** `hasBarItems` 加上 `!TaskbarWidgets.current(hasTabs: !catalog.groups.isEmpty).isEmpty`
- [ ] **Step 7: 驗證沒開小工具時零變化**：重跑 Step 1 的流程存成 `build/pins-after.txt`，`diff build/pins-before.txt build/pins-after.txt` 只有時間戳不同
- [ ] **Step 8: Commit** `refactor: 條的版面改由小工具寬度描述驅動`

---

### Task 4: 槽位排版、命中與點擊分派

**Files:**
- Modify: `Sources/TabBarView.swift:408-430`（`body`）、`bar`
- Modify: `Sources/TaskbarWidgetViews.swift`
- Modify: `Sources/AppCatalog.swift:645-668`（`handlePress`）
- Modify: `Sources/TabBarController.swift:7-14`（`TabBarHost`）

**Interfaces:**
- Consumes: Task 3 `TaskbarWidgets.current`
- Produces:
  ```swift
  enum WidgetPart { case main, previous, next }
  // TabBarHost
  func pressWidget(_ widget: TaskbarWidget, part: WidgetPart)
  // TaskbarWidgetViews.swift
  struct TaskbarWidgetCapsule<Content: View>: View   // 條外：GlassBackdrop 膠囊；條內：不墊玻璃
      init(widget: TaskbarWidget, inBar: Bool, @ViewBuilder content: () -> Content)
  struct TaskbarWidgetView: View   // 依 kind 分派到各小工具視圖；Task 5–7 填各 kind，這一步先畫佔位（SF Symbol + 名稱）
  ```
- 每個小工具用 `TabFramesKey` 上報 `widget.hitID` 的範圍（座標系 `TabBarView.space`）。

- [ ] **Step 1:** `body` 的 HStack 依序：槽 1 → 開始 → 槽 2 → 搜尋 → 槽 3 → 把手 → `bar` → 槽 6；每顆條外東西後接 `detachedStartGap`
- [ ] **Step 2:** `bar` 內改成 HStack：槽 4 → ScrollView（原本的捲動標籤＋漸層）→ 槽 5，漸層只蓋 ScrollView 那段
- [ ] **Step 3:** `handlePress`：在搜尋判斷之後、`entry(at:)` 之前，依 `catalog.tabFrames` 先比 `prevHitID`／`nextHitID` 再比 `hitID`，命中就 `host?.pressWidget(w, part:)` 並 `return true`；`catalog.drag != nil` 時放開不算點擊
- [ ] **Step 4:** 懸停：小工具用 `GlassPill(kind: .hover)`，條件 `catalog.pointerOverBar && catalog.drag == nil`，**不加動畫**（立刻亮）
- [ ] **Step 5:** `TabBarController.pressWidget` 先只 `TTLog` 印出 kind 和 part
- [ ] **Step 6: 驗證**（手動，`defaults write` 塞一份六個槽各一個佔位小工具的 JSON 或等 Task 9 的設定 UI）：
  - 六個槽位置正確；關掉開始／搜尋按鈕後相鄰槽靠攏
  - 點每顆，log 印出對應的 kind
  - 拖曳 App 標籤經過、放在小工具上：log 沒有 `pressWidget`
  - 設定介面縮放 75%、150%，切換「只顯示圖示」，各點一次每顆：命中正確
  - 關掉所有 App 視窗（沒有標籤）：槽 4、5 移到條外，條不被「隱藏空工作列」藏掉
- [ ] **Step 7: Commit** `feat: 工作列小工具的槽位排版與點擊`

---

### Task 5: 正在播放小工具

**Files:**
- Modify: `Sources/NowPlaying.swift:100-110`（通知註冊處）
- Modify: `Sources/TaskbarWidgetViews.swift`
- Modify: `Sources/TabBarController.swift`（`pressWidget`）

**Interfaces:**
- Consumes: `NowPlaying.shared`（`track`、`player`、`playPause()`、`previous()`、`next()`）、Task 4 `TaskbarWidgetCapsule`
- Produces: `struct NowPlayingWidgetView: View`；`NowPlaying` 在播放器啟動或結束時讓 `objectWillChange` 發一次

- [ ] **Step 1:** `NowPlaying` 加 `NSWorkspace.didLaunchApplicationNotification` 監聽（只認 `MediaPlayer.allCases` 的 bundle id）；啟動或結束後呼叫 catalog 重新排版（和 Task 2 的同一條路）
- [ ] **Step 2:** `NowPlayingWidgetView`：`⏮ │ 封面＋歌名（最寬 140，截斷）＋播放/暫停狀態圖示 │ ⏭`。⏮⏭ 寬 `TTLayout.barHeight/2`、高 `barHeight`，各自上報 `prevHitID`／`nextHitID` 與各自的懸停底；中間塊上報 `hitID`，懸停底蓋滿中間塊、無動畫。沒有曲目時 ⏮⏭ 半透明不可按，中間顯示 App 圖示＋「未在播放」。只顯示圖示樣式拿掉歌名，歌名與歌手放 `.help`。封面沿用 `NowPlayingBar` 取封面的方式
- [ ] **Step 3:** `pressWidget`：`.main` → `playPause()`；`.previous`／`.next` → 有曲目才呼叫
- [ ] **Step 4: 驗證**（手動）：開 Spotify 播歌 → 膠囊出現；指標進中間塊立刻亮；點中間暫停／播放；點 ⏮⏭ 切歌；換歌時條寬不變（看 log 的 barWidth）；結束 Spotify → 膠囊消失；Apple Music 同樣跑一次
- [ ] **Step 5: Commit** `feat: 正在播放小工具`

---

### Task 6: CPU／記憶體小工具

**Files:**
- Modify: `Sources/SystemStats.swift`
- Modify: `scripts/tests/widgets/main.swift`
- Modify: `Sources/TaskbarWidgetViews.swift`、`Sources/TabBarController.swift`

**Interfaces:**
- Produces:
  ```swift
  struct CPUTicks: Equatable { var user, system, idle, nice: UInt64 }
  enum SystemStatsMath {
      static func cpuUsage(from a: CPUTicks, to b: CPUTicks) -> Double          // 0...1；總差為 0 回 0
      static func memoryUsage(activePages: UInt64, wiredPages: UInt64, compressedPages: UInt64,
                              pageSize: UInt64, physicalBytes: UInt64) -> Double  // 0...1，夾在範圍內
      static let warningThreshold = 0.8
  }
  @MainActor final class SystemStats: ObservableObject {
      static let shared: SystemStats
      @Published private(set) var cpu: Double
      @Published private(set) var memory: Double
      func retain()   // 參考計數 > 0 時每 2 秒取樣
      func release()
  }
  struct SystemStatsWidgetView: View
  ```

- [ ] **Step 1: 寫失敗的測試**：`cpuUsageFromDeltas`（a = 100/100/800/0、b = 150/150/900/0 → 0.5）、`cpuUsageZeroDelta`（a == b → 0）、`memoryUsageClamped`（頁數超過實體記憶體 → 1.0）、`memoryUsageTypical`（(1000+500+500)×16384 ÷ 65536000 ≈ 0.5）
- [ ] **Step 2:** `./scripts/test-widgets.sh` → 失敗
- [ ] **Step 3:** 實作 `SystemStatsMath`；`SystemStats` 用 `host_statistics(HOST_CPU_LOAD_INFO)`、`host_statistics64(HOST_VM_INFO64)`、`ProcessInfo.physicalMemory`，`Timer` 每 2 秒
- [ ] **Step 4:** `./scripts/test-widgets.sh` → 通過
- [ ] **Step 5:** `SystemStatsWidgetView`：`onAppear` 呼叫 `retain()`、`onDisappear` 呼叫 `release()`；`CPU 23%`／`記憶體 61%` 用 `.monospacedDigit()`，各帶寬 24 的迷你橫條；≥ `warningThreshold` 用 `Color.orange`；只顯示圖示樣式為兩條直立迷你條，數字進 `.help`
- [ ] **Step 6:** `pressWidget(.systemStats)` → 用 `NSWorkspace` 開啟 `com.apple.ActivityMonitor`
- [ ] **Step 7: 驗證**：數字約每 2 秒變一次、寬度不跳；移除小工具後 Timer 停止（加 `TTLog` 確認不再取樣）；點了開活動監視器
- [ ] **Step 8: Commit** `feat: CPU／記憶體小工具`

---

### Task 7: 資料夾小工具與卡片

**Files:**
- Modify: `Sources/StartMenuView.swift:947`（`FolderTile` 拆成 internal、改吃參數化尺寸）、`:347-352`（`folderMenu`）
- Create: `Sources/FolderWidgetPopup.swift`
- Modify: `Sources/TaskbarWidgetViews.swift`、`Sources/TabBarController.swift`、`Sources/BackgroundFolder.swift`

**Interfaces:**
- Consumes: `prefs.startFolders`、`AppLibrary`（取圖示、開啟 App）、`FloatingPanel`、`DockGeometry.popupFrame`
- Produces:
  ```swift
  struct FolderTile: View   // 原 private 版本改為 internal，尺寸由呼叫端給（size: CGFloat），開始選單維持原尺寸
  struct FolderWidgetView: View
  @MainActor final class FolderWidgetPopup {
      func toggle(folderID: UUID, anchor: CGRect /* 螢幕座標 */, barFrame: CGRect)
      func close()
      var isOpen: Bool { get }
      var onClose: (() -> Void)?
  }
  ```
- 卡片：唯讀 App 格子（圖示＋名稱），點一個就用 `NSWorkspace` 開啟並收起；空資料夾顯示「資料夾是空的」＋「在開始選單中編輯」按鈕（開開始選單並設 `model.openFolder = id`）。

- [ ] **Step 1:** 拆 `FolderTile`，開始選單外觀不變（截圖比對前後）
- [ ] **Step 2:** `FolderWidgetView`：只顯示圖示＝`FolderTile`；圖示＋名稱＝`FolderTile`＋名稱（空名顯示「未命名」）；不顯示數字
- [ ] **Step 3:** `FolderWidgetPopup`：照 `BackgroundFolderController` 的 popup／外部點擊監聽寫法；彈出方向用 `DockGeometry.opensUpward`
- [ ] **Step 4:** 互斥：開資料夾卡片前收起背景網格與開始選單；背景網格打開時也收起資料夾卡片；卡片開著時條不自動隱藏（比照開始選單）
- [ ] **Step 5:** `pressWidget(.folder)` → `toggle`
- [ ] **Step 6:** 開始選單資料夾右鍵加「放到工作列」→ `catalog.addTaskbarWidget(.folder(id), slot: .afterBar)`；已加過的變灰
- [ ] **Step 7: 驗證**：點開／再點收起／點外面收起；點 App 開啟；空資料夾的按鈕會開到那個資料夾；在開始選單刪掉資料夾 → 小工具消失；開著背景網格時點資料夾小工具 → 背景網格先收
- [ ] **Step 8: Commit** `feat: 開始選單資料夾小工具`

---

### Task 8: 小工具右鍵選單

**Files:**
- Modify: `Sources/TabBarController.swift:1266`（`openTaskbarMenu`）
- Modify: `Sources/TaskbarMenu.swift`

**Interfaces:**
- Consumes: Task 2 的 `moveTaskbarWidget`／`removeTaskbarWidget`
- Produces: `TaskbarMenu` 的 `static func widgetMenu(for widget: TaskbarWidget, catalog: AppCatalog) -> NSMenu`

- [ ] **Step 1:** `openTaskbarMenu` 開頭：point 落在任何 `hitID`／`prevHitID`／`nextHitID` 範圍 → 彈 `widgetMenu` 並回傳 true（整條的 SwiftUI `.contextMenu` 就不會出現）
- [ ] **Step 2:** 選單項目：正在播放多一項「開啟 Spotify」或「開啟音樂」（依目前播放器）＋分隔線；共用「移到」▸ 六個槽（目前的打勾）／「在設定中調整…」（開設定到「Dock 與開始選單」）／「從工作列移除」
- [ ] **Step 3: 驗證**：每種小工具右鍵；移到別的槽立刻換位；移除後寬度回收；右鍵 App 標籤的選單不受影響
- [ ] **Step 4: Commit** `feat: 小工具右鍵選單`

---

### Task 9: 設定頁「工作列小工具」

**Files:**
- Modify: `Sources/SettingsWindow.swift:311`（`dockPage`）

**Interfaces:**
- Consumes: Task 1 `TaskbarWidgetList.canAdd`、`TaskbarWidgetSlot.title`；Task 2 AppCatalog 四個方法

- [ ] **Step 1:** 新增一段「工作列小工具」：每列＝名稱（正在播放／CPU 與記憶體／資料夾名）＋槽位 `Picker`＋上移＋下移＋移除；空清單時寫「還沒有加入小工具」
- [ ] **Step 2:** 「新增小工具」`Menu`：正在播放／CPU 與記憶體／資料夾 ▸（列 `prefs.startFolders`），`canAdd` 為 false 的 `.disabled`；新加入的放 `.afterBar`
- [ ] **Step 3: 驗證**：`open Xtopbar.app --args --settings`，逐一加入、改槽、排序、移除，工作列即時跟著變
- [ ] **Step 4: Commit** `feat: 工作列小工具設定`

---

### Task 10: 多螢幕、文件與總驗收

**Files:**
- Modify: `README.md`（「工作列 / Dock」表格加「小工具」一列）

- [ ] **Step 1: 多螢幕驗證**：開「在所有螢幕上顯示」，每條都有同一套小工具；在副螢幕點資料夾，卡片從副螢幕那條彈出；CPU 數字兩條一致（只有一個取樣器在跑）
- [ ] **Step 2:** README 加一列「**工作列小工具**」，說明三種小工具、六個位置、設定與右鍵調整
- [ ] **Step 3: 總驗收**：`./scripts/test-widgets.sh` 全過；`./build.sh` 成功；清空 `taskbarWidgets` 後重跑 Task 3 Step 7 的 diff 仍無差異
- [ ] **Step 4: Commit** `docs: README 加入工作列小工具`
