# 工作列視窗按鈕（Vista 式）設計

日期：2026-10-18
分支：`worktree-window-buttons`（從 v2.10.1）

## 目標

讓開了多扇視窗的 App 像 Windows Vista 工作列那樣，**每扇視窗各一個按鈕**，點按鈕就直接切到那扇視窗；按鈕擠不下時，同一個 App 的按鈕才合併成一格。現在「一個 App 一格＋視窗數圓圈」的做法保留成選項之一。

成功標準：
- 預設設定下，Safari 開 3 扇視窗，條上就有 3 個「圖示＋視窗標題」按鈕，點哪個就切到哪扇
- 按鈕多到超出條的最大寬度時，自動合併視窗最多的 App，合併後條上不需要捲動
- 視窗開／關、改標題、換螢幕時，按鈕不會跳位，也不會閃

## 設定

新增「工作列按鈕」（`Preferences.taskbarGrouping`，UserDefaults key `taskbarGrouping`），放在設定視窗「只顯示圖示」附近：

| 值 | 顯示文字 | 行為 |
|---|---|---|
| `whenFull`（預設） | 擠滿時才合併 | 每扇視窗一格，放不下時才合併 |
| `never` | 永不合併 | 每扇視窗一格，放不下就縮窄按鈕，再不夠就橫向捲動 |
| `always` | 依 App 合併 | 現在的行為：一個 App 一格＋視窗數圓圈 |

- 預設是 `whenFull`，**從舊版升級的使用者也會套用新預設**（舊版沒有這個 key）
- 「圖示＋名稱」和「只顯示圖示」兩種樣式都照這個設定走
- 沒有輔助使用權限時拿不到單扇視窗，一律當成 `always`，設定選項旁邊加註說明

## 行為規格

1. **視窗按鈕的內容**：「圖示＋名稱」樣式下是圖示＋該視窗標題，太長就截斷；標題是空的就用 App 名稱。「只顯示圖示」樣式下是大圖示＋執行小圓點，視窗標題放進懸停提示。最小化的視窗也有按鈕，整格半透明（約 0.55）
2. **前景標示**：前景 App 最前面的那扇視窗，按鈕畫成目前的「前景」樣式（藍底）。同一個 App 的其他視窗不畫
3. **點擊視窗按鈕**：
   - 不是前景視窗 → 啟用 App，再把這扇視窗拉到最前（`WindowBridge.focusWindow`）；如果它是最小化的就還原
   - 已經是前景視窗，且「點選前景 App 最小化視窗」開著 → 只最小化這一扇（`WindowBridge.minimizeIfCurrent`）
   - 已經是前景視窗，但開關關著 → 維持在最前
4. **懸停視窗按鈕**：預覽面板只顯示這一扇的縮圖，卡片點擊和關閉鈕照舊。單扇視窗也要彈預覽（Vista 同款），播放控制條照舊
5. **合併按鈕**（`whenFull` 擠不下時）：內容是「圖示＋App 名稱」，右上角是視窗數圓圈，外觀跟現在的 App 按鈕一樣。**點擊**就把現有的多視窗預覽面板打開，從裡面挑一扇，不做最小化／切換；**懸停**也打開同一個面板
6. **排列**：
   - 同一個 App 的視窗永遠相鄰，順序依 CGWindowID 由小到大，也就是開啟的先後，新視窗接在那組最後面。前後次序變了也不重排，避免點了就跳位
   - App 之間的順序沿用現有規則：固定項依 `dockPins`，執行中的 App 依 `runningOrder`／啟動時間
   - 拖曳排序以 App 為單位：拖任何一個視窗按鈕都會整組一起移，寫回 `dockPins`／`runningOrder` 的邏輯不變
7. **固定項**：沒有開任何視窗時是一個啟動按鈕，跟現在一樣；有視窗時就在固定位置展開成那幾扇的視窗按鈕。固定項只有一扇視窗時也照樣是視窗按鈕
8. **多螢幕**：每一條只放視窗落在那塊螢幕上的按鈕，判定沿用 `ScreenAssign`（跨螢幕的視窗算重疊多的那塊）。各條各自判斷要不要合併。既然每扇視窗都有自己的按鈕，名稱後面就不再加「(分頁標題)」
9. **沒有視窗的 App**：照舊收進「背景執行」資料夾，或依「只顯示有視窗的 App」直接不顯示
10. **右鍵選單**：視窗按鈕和合併按鈕都沿用 App 的右鍵選單（固定、隱藏、結束…），另外在最上面加一項「關閉視窗」（`WindowBridge.closeWindow`，合併按鈕沒有這一項）

## 架構

### 資料模型（`AppCatalog.swift`）

沿用 `AppEntry`，一扇視窗就是一個 entry：

```swift
struct WindowRef: Equatable, Sendable {
    let windowID: CGWindowID   // 拿不到時是合成 ID，見下方「視窗識別」
    let title: String
    let frame: CGRect          // CG 座標
    let minimized: Bool
}

struct AppEntry {
    // 既有欄位不變
    var window: WindowRef? = nil   // 非 nil = 視窗按鈕
    var mergedCount: Int = 0       // ≥ 2 = 合併按鈕
    var appID: String              // bundle id；視窗按鈕的 id 是 "\(appID)#\(windowID)"
}
```

- `id`：App／合併按鈕維持用 bundle id，視窗按鈕用 `bundleID#windowID`。`tabFrames`、SwiftUI 的 identity、拖曳時的 `TabDrag` 都用這個 id
- 原本把 `id` 當 bundle id 用的地方（固定、隱藏、`runningOrder`、`BrowserProfiles.prefetch`、圖示快取）全部改成讀 `appID`
- `==` 和 `refresh()` 的 signature 要把 `window` 和 `mergedCount` 算進去

### 視窗識別（`WindowPresence.swift`）

- `WindowSample` 加上 `windowID: CGWindowID`，在 `axWindows(_:)` 裡用私有 API `_AXUIElementGetWindow` 取得（`@_silgen_name` 宣告，放在 `WindowBridge.swift`）
- 拿不到時（回傳錯誤）就用 `hash(pid, 四捨五入後的 frame, title)` 當合成 ID，並設最高位元避免撞到真的 ID
- 新增 `@Published windowsByPID: [pid_t: [WindowSample]]`，在原本那一輪掃描裡順便填好，不多查一次。`changed` 的觸發條件把它算進去

### 展開與合併（新檔 `TaskbarLayout.swift`，純邏輯）

```swift
enum TaskbarLayout {
    /// 依目前設定，把 App 層的 entries 展開成按鈕清單
    static func expand(apps: [AppEntry],
                       windows: [pid_t: [WindowSample]],   // 已過濾成這條螢幕上的
                       grouping: TaskbarGrouping,
                       maxWidth: CGFloat,
                       metrics: ButtonMetrics) -> [AppEntry]
}

struct ButtonMetrics {
    let windowButton: CGFloat   // 固定寬
    let minWindowButton: CGFloat
    let appButton: (AppEntry) -> CGFloat   // 合併／啟動按鈕的寬，照現有方式估
    let fixed: CGFloat          // 開始按鈕、分隔線、左右內距
}
```

合併演算法（`whenFull`）：
1. 先全部展開成視窗按鈕，算總寬
2. 總寬 ≤ `maxWidth` → 結束
3. 否則在還沒合併、視窗數 ≥ 2 的 App 裡，挑視窗最多的那個合併（同樣多就挑在條上比較右邊的），回到第 2 步
4. 全部都合併了還是放不下 → 交給現有的橫向捲動

`never`：總寬超過時，視窗按鈕寬度從 `windowButton` 等比縮小，最小到 `minWindowButton`，再不夠就捲動。`always`：直接回傳 App 層 entries，也就是現在的行為。

`maxWidth` 用 `DockGeometry.barFrame` 的上限（可見寬度 − 24）。所有寬度都依 `TTLayout.scale` 換算，不靠 SwiftUI 量回來的寬度，所以不會「量完→重排→再量」來回抖動。

按鈕寬度：
- 「圖示＋名稱」樣式：視窗按鈕固定 160pt，最小 72pt，都乘上 `TTLayout.scale`
- 「只顯示圖示」樣式：視窗按鈕和 App 按鈕同寬（現有 dock cell 的寬度），`never` 模式不縮窄，直接捲動

### 接進現有流程

- `AppCatalog.collect()`：照舊先算出 App 層的 `pinned`／`others`，最後在 `group()` 前呼叫 `TaskbarLayout.expand`。固定組和執行中組各自展開，但合併判斷要算兩組的總寬
- `AppCatalog.activate(_:fromClick:)`：
  - 視窗按鈕走新的 `activateWindow(_:)`，行為見規格第 3 點
  - 合併按鈕點擊改成交給控制器打開預覽，透過新的 `onMergedClick` 回呼
- `TabBarView`／`AppTab`：視窗按鈕顯示 `window.title`，加上固定寬度 `.frame(width:)`，最小化時半透明；合併按鈕沿用現在的 App 畫法
- `PreviewController.show(for:)`：如果 entry 有 `window`，`windows` 就只留 `id == windowID` 的那一扇（對不上就用 frame 最近的那扇），並且跳過「少於 2 扇不彈」的判斷
- 拖曳：`TabDrag` 以 App 為單位。開始拖的時候把同一個 `appID` 的連續按鈕當成一格一起移，`commit` 寫回去時用 `appID`
- `Preferences`：加 `taskbarGrouping`，並加進 `TabBarController.observePreferences()` 的重排觸發條件
- `SettingsWindow`：在「只顯示圖示」下面加一個 Picker

## 錯誤與邊界處理

- **沒有輔助使用權限**：`windowsByPID` 是空的，`expand` 一律走 `always`
- **AX 查詢逾時**：沿用 `WindowPresence` 的「問不出來＝維持原判」，`windowsByPID` 保留上一輪的結果，按鈕不會消失
- **視窗剛開，AX 還沒列出來**：App 已經上條但查不到視窗時，先顯示成 App 按鈕，下一輪掃描（≤ 1.2 秒）再展開
- **原生分頁**（Finder、終端機）：`hiddenTabIndices` 已經濾掉隱藏的分頁視窗，一個分頁群組只算一扇
- **右鍵選單開著／拖曳中**：沿用 `menuTracking`／`drag != nil` 時暫停 `refresh()`

## 測試

- `TaskbarLayout` 是純函式，在 `--test-pins` 的 `diagnosePins()` 裡加樣例並印出結果：
  - `whenFull`：寬度夠 → 全展開；不夠 → 先合併視窗最多的；全部合併還不夠 → 交給捲動
  - `never`：縮窄，到最小寬度後就不再縮
  - `always`：輸出等於輸入
  - 固定項沒有視窗 → 啟動按鈕；有 2 扇 → 原位置展開成 2 格
  - 同一個 App 的視窗依 windowID 排序，前後次序變了也不重排
- 手動驗證（`./build.sh` 後用真的 App 實測）：
  - Safari 開 3 扇 → 3 格；點非前景的那格會切過去；點前景那格會最小化它；再點就還原
  - 開到擠滿 → 視窗最多的 App 先合併；點合併按鈕跳出視窗清單
  - 雙螢幕：把視窗拖到另一塊螢幕，按鈕約 1 秒內跟著換到那條
  - 拖一個視窗按鈕 → 整組一起移，重開 Xtopbar 後固定項的順序還在
  - 撤掉輔助使用權限 → 退回依 App 合併
  - 「只顯示圖示」樣式下重跑上面幾項

## 不做的事

- 不做 Win 7 的縮圖工具列、跳躍清單（Jump List）、Aero Peek
- 不讓單扇視窗在 App 組內個別拖曳排序
- 不改 ⌥Tab 視窗切換器和開始選單
- 不改「背景執行」資料夾
