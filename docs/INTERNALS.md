# Xtopbar 實作細節（開發筆記）

README 只講使用者看得見的東西，這一份放工程內幕：視窗列舉方案、AX 的坑、簽名機制、動畫參數。改程式碼前先看這裡。

## 目錄結構

```
Sources/
  App.swift                  @main + Settings 場景（無主視窗）
  AppDelegate.swift          accessory 策略、啟動、選單列、除錯引數
  Preferences.swift          全域偏好（UserDefaults 的唯一入口）
  AppCatalog.swift           固定項 + 執行中 App 採集 / 分類 / 排序 / 啟用 / 啟動 / 固定
  AppCategory.swift          分類關鍵詞表（啟發式，僅決定排序）
  XtopbarIcon.swift           狀態列 template 圖示的程式化繪製
  StatusItemController.swift 選單列圖示 + 下拉選單
  SettingsWindow.swift       設定視窗（NSWindow + SwiftUI Form）
  LaunchAtLogin.swift        SMAppService 開機自啟封裝
  GlassEffect.swift          液態玻璃 / 毛玻璃 / 純色三種背景
  ScreenCaptureEngine.swift  SC 列舉 + 抓圖 + 快取 + 預熱；AX 視窗集合配對
  WindowBridge.swift         AX 視窗聚焦（下標優先，標題/幾何回退）
  TabBarView.swift           SwiftUI 標籤條 + 開始按鈕 + 命中區域上報 + 分隔線 + 右鍵選單
  TabBarController.swift     面板定位（DockGeometry）、自動隱藏、熱點喚出、預覽排程、預熱、開始選單開關
  AppLibrary.swift           已安裝 App 索引（掃 Applications 目錄）+ 搜尋
  StartMenuController.swift  開始選單浮層（定位 / key 視窗 / 鍵盤與點外面收起）
  StartMenuView.swift        開始選單檢視（搜尋 / 已固定 / 最近使用 / 所有應用 A–Z）
  SystemDock.swift           隱藏 / 還原系統 Dock（defaults + killall Dock）
  WindowPresence.swift       哪些執行中的 App 沒有視窗（「只顯示有視窗的 App」）
  PreviewController.swift    視窗預覽浮層（模型 + 檢視 + 面板 + 點選切視窗）
  FloatingPanel.swift        懸浮面板 + 視窗層命中測試 + 除錯日誌
  Updater.swift              線上更新（檢查 GitHub Releases + 下載替換自身）
Resources/Info.plist
scripts/make-signing-identity.sh   自簽名憑證
scripts/make-icons.swift           App 圖示生成（→ .icns）
scripts/make-release.sh            打包 + 發布 GitHub Release
build.sh
docs/INTERNALS.md                  ← 本檔案
docs/RELEASING.md                  發布流程 / 線上更新怎麼用
```

## 分類：這是啟發式，不是系統定義

`Sources/AppCategory.swift` 裡是一張**手寫關鍵詞表**（瀏覽器 / 終端 / 媒體 / 開發 / 通訊 / 文件 / 工具 / 其他），拿 App 名稱 + Bundle ID 做 `contains` 匹配，順序即優先順序。

macOS **沒有**提供任何"App 分類"的公開 API —— 這個分組完全是為了排序穩定而自造的，不是系統語義。

**目前條上已不按分類排序**：執行中的 App 統一一組、按開啟時間（`NSRunningApplication.launchDate`）從左到右排，新開的接在最右邊。分類仍會算出來寫進 `AppEntry.category`，但不影響順序和介面。早先按"分類邊界畫深線、組內畫淡線"來暗示分組，實測大多數 App 落到「其他」，後半條幾乎沒有線，看起來像壞了，所以**分隔線已統一成一種深線**。

## 權限為什麼這麼關鍵

**輔助使用權限是視窗列表準不準的關鍵。** 沒有它時只能靠視窗伺服器（`CGWindowList`）的啟發式猜，猜出來的就是"抖店工作臺 2 個真視窗顯示成 4 個"這類幽靈視窗；多視窗 App 點選縮圖也只會把 App 拉到前景，表現為"點哪個都回到第一個視窗"。

所以啟動後 1 秒會自動彈一次系統授權請求，簽名固定後授權一次就長期有效。

## 外觀：液態玻璃的實作

| 材質 | 實作 | 說明 |
|---|---|---|
| **液態玻璃**（預設） | `NSGlassEffectView`（macOS 26+） | 系統原生 Liquid Glass。**自動跟隨外觀（淺色/深色）和「降低透明度」「增強對比度」等輔助使用開關**，不需要自己適配 |
| 毛玻璃 | `NSVisualEffectView`（`.hudWindow`） | 經典 HUD 材質，所有系統版本可用 |
| 純色 | `CALayer` + 視窗背景色 | 不透明，最省 GPU |

實測確認玻璃**確實在取樣視窗背後**：把面板壓到黑色視窗上，面板底色同步變暗並透出模糊內容（`NSGlassEffectView` 走的是 behind-window 混合）。

在 macOS 26 以下執行時，「液態玻璃」選項不會出現在設定裡，存下來的值也會自動降級成毛玻璃（`GlassStyle.resolved`）。

## 圖示

| 圖示 | 形狀 | 生成方式 |
|---|---|---|
| 狀態列 | 一條膠囊（懸浮欄）+ 三個圓點（App） | 執行時用 `NSBezierPath` 畫，`isTemplate = true`，系統按選單列配色自動上色 |
| App | 藍紫漸變圓角方形 + 白色頂欄 + 三個標籤塊 | `scripts/make-icons.swift` 程式化生成 1024 PNG → `iconutil` 打成 `.icns`，`build.sh` 自動執行 |

狀態列圖示試過的形態：「橫條 + 三個方塊」→ 像床；「螢幕外框 + 頂欄」→ 像資料夾；「膠囊 + 三個豎片」→ 像梳子；「膠囊 + 雙箭頭」→ 兩個箭頭黏成菱形。圓點比方塊輕，是這幾個裡最經得起 18pt 縮放的。

## 簽名：為什麼不能再用 ad-hoc

ad-hoc 簽名（`codesign --sign -`）的指定要求裡帶的是**這次建置的 cdhash**，每次重編譯雜湊都變，macOS 就當成另一個 App —— 螢幕錄製和輔助使用授權全部失效，這就是"每次更新都要重新授權"的原因。

`scripts/make-signing-identity.sh` 生成一張自簽名程式碼簽名憑證（首次建置自動建立）放進獨立 keychain，`build.sh` 用它簽名。指定要求變成：

```
designated => identifier "com.buzzzzzboy.xtopbar" and certificate root = H"58d0e1e7…"
```

憑證不變 → 雜湊不變 → 授權一直有效。兩個容易踩的細節：

- 憑證是 `CSSMERR_TP_NOT_TRUSTED`（沒加進信任鏈），所以檢測身份**不能帶 `-v`** —— `security find-identity -v` 只列受信任的身份，會誤判成"沒有身份"而退回 ad-hoc。codesign 簽名本身不需要憑證受信，TCC 記的也只是 DR 裡的憑證雜湊
- 憑證放獨立 keychain 而不是 login keychain，配合 `security set-key-partition-list -S apple-tool:,apple:,codesign:`，codesign 呼叫不會彈鑰匙圈授權對話方塊，可以無人值守建置

從 ad-hoc 換到自簽名身份後**需要重新授權一次**（舊 TCC 記錄綁在舊 cdhash 上），之後重建都不用再授權。

## 實作要點

**1. 面板** — `FloatingPanel: NSPanel`
- `styleMask: [.borderless, .nonactivatingPanel]`：無邊框、點選不搶焦點
- `level = .statusBar`：浮在所有普通視窗之上
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`：所有空間可見，含全螢幕 App
- App 以 `LSUIElement = true` + `.accessory` 執行：不進 Dock、不進 Cmd+Tab

**2. 點選命中** — 不走 SwiftUI 手勢
SwiftUI 的 tap 手勢在非啟用懸浮窗裡命中不穩定。所以：
- `AppTab` 用 `GeometryReader` + `PreferenceKey` 把每個標籤的 frame 上報給 `AppCatalog.tabFrames`
- `FloatingPanel.sendEvent(_:)` 攔截 `leftMouseDown`，把 AppKit 視窗座標（原點左下）翻轉成檢視座標（原點左上），命中標籤則直接觸發切換，並吞掉配對的 `mouseUp`

**3. 切換 App** — LaunchServices 路徑
macOS 14+ 下，非啟用 App 呼叫 `NSRunningApplication.activate()` 會被系統接受但靜默忽略（返回 `true` 卻不生效）。

可靠做法是走和"點選 Dock 圖示"同一條 LaunchServices 通道：

```swift
let config = NSWorkspace.OpenConfiguration()
config.activates = true
config.promptsUserIfNeeded = false
NSWorkspace.shared.openApplication(at: app.bundleURL!, configuration: config) { _, error in
    if error != nil { forceActivate(app) }   // 兜底：AX frontmost + activate()
}
```

對已在執行的 App，這個呼叫只會把它帶到前景，不會重啟。

**4. 重新整理** — `NSWorkspace` 的 launch / terminate / activate / hide 通知 + 1.2s 兜底輪詢；列表簽名不變則不觸發重繪。

**5. 自動隱藏** — 10Hz 輪詢 `NSEvent.mouseLocation`（不需要任何權限，讀滑鼠位置極廉價）：

```swift
let inHot = hotZone.contains(NSEvent.mouseLocation)   // 頂部中央喚醒區
if inHot || inPanel || inPreview { lastInteraction = now; if !isRevealed { reveal() } }
else if isRevealed, hideDelay > 0, now.timeIntervalSince(lastInteraction) > hideDelay { hide() }
```

隱藏用 `orderOut` 而不是僅把 alpha 設成 0，這樣視窗徹底離開合成器，不佔任何資源也不參與滑鼠命中。

**離場時 `orderOut` 必須在復位 `alphaValue` 之前**：反過來的話，視窗還在螢幕上的那一幀會帶著 `alpha = 1` 被畫出來 —— 主面板和預覽面板各閃一下，就是"消失時閃兩次"的來源。

喚醒區的上邊界要**故意越過螢幕頂部 2pt**：滑鼠貼到最上面時 `mouseLocation.y` 正好等於 `screen.frame.maxY`，而 `NSRect.contains` 是半開區間，不越過就會漏判（這個 bug 實測會出現"頂到最上面反而不出來"）。

**5b. 多螢幕：熱區錨在哪塊螢幕（`ScreenPick`）**

熱區與"預設停靠位"用哪塊螢幕，由 `Preferences.hotZoneScreen` 決定：`.menuBar`（預設，帶選單列的系統主螢幕）/ `.notch`（內建螢幕，有劉海那塊）/ `.followMouse`。選擇邏輯抽在 `ScreenPick` 裡（純下標運算，可離線測）：

- `.menuBar` → `screens[0]`。頂部喚出本來就貼在選單列上，而 `screens[0]` 原點恆為 `(0,0)`，就是系統意義上的主顯示器
- `.notch` → `notched.firstIndex(of: true) ?? 0`。劉海螢幕用 `NSScreen.auxiliaryTopLeftArea != nil`（macOS 12+）判定，這是唯一可靠的官方訊號；合蓋 / 純外接時沒有劉海螢幕，自動退化成 `screens[0]`
- `.followMouse` → 滑鼠所在螢幕，找不到就兜底 `screens[0]`

**這兩個概念在多螢幕下不是一回事**：接了外接螢幕並把外接螢幕設為主螢幕時，系統的"主顯示器"是外接螢幕（無劉海），而劉海在內建螢幕上。本機實測就是這樣：

```
[0] RV100 Q                (0,0,1920,1080)      無劉海  ← 系統主螢幕（帶選單列）
[1] Built-in Retina Display (-1470,124,1470,956) 有劉海  ← 頂部中點 x = -735
```

所以預設取 `.menuBar`（使用者說"主顯示器"時指的就是它），劉海螢幕要顯式選 —— 別替使用者猜。

> **修掉的老 bug**：熱區以前按 `panel.screen` 算，而 `panel.screen` 是"面板當前停在哪個螢幕"。⌘Tab 會在滑鼠位置彈出並釘住面板，於是在另一塊螢幕用過一次 ⌘Tab 之後，面板 frame 就留在那塊螢幕，熱區跟著搬過去 —— 表現為"只有那塊螢幕頂部能喚出，主螢幕徹底沒反應"。
>
> 同理不能用 `NSScreen.main`：它跟著"當前接收鍵盤事件的視窗"漂移，副螢幕上的 App 一啟用它就變成副螢幕。
>
> 三處一起改：① 熱區與預設停靠位改看 `anchorScreen`（不再看 `panel.screen`）；② 收起後 `parkOnAnchorScreen()` 把面板 frame 挪回錨定螢幕，不留舊位置；③ 常駐模式（不自動隱藏）下 ⌘Tab 提交後主動歸位，否則會一直釘在滑鼠那處。

**⌘Tab 叫出刻意不走這套** —— 它永遠在滑鼠位置彈出（`revealAtMouse` / `pinnedAnchor`），那才是這個功能的意義。錨定螢幕只約束"頂部喚出"。

**5c. ⌘Tab 會話：迴圈序列與叫出動效**

`CmdTabTap` 用會話級 `CGEventTap` 吞掉「按住 ⌘ 時按下 Tab」（⌘Tab 會被 Dock 搶在任何 App 之前消費，只有 HID/會話層的 tap 能截住）。會話由 `AppCatalog` 的三個方法驅動：`startKeyboardSession` / `cycleKeyboardSession` / `commitKeyboardSession`。

**迴圈序列 = 面板的視覺順序**（`groups.flatMap(\.entries)`，也就是標籤從左到右），起點另算：

- 起點 = MRU 裡第一個既不是當前前景、又還在條上的 App（`SessionCycle.startIndex`）。快按快放因此仍然等於切回上一個 App
- 之後每一發 Tab 只做 `(index + 1) % count`，走一格挪一格，末尾回到第一個

> **修掉的老 bug**：序列以前直接按 MRU 順序排（"最近用過"優先，當前前景插到最前，剩下的補在後面）。它跟螢幕上看到的排布毫無關係 —— 反白於是會在圖示之間橫跳（第二個直接蹦到第四個），功能沒錯但看著像漏幀。順序抽在 `SessionCycle` 裡（純下標運算），迴歸要斷言的不變數是：**從任何起點連按 N 發，相鄰兩步的下標差恆為 `+1 mod count`**。

**⌘Tab 叫出不做動效**：`beginReveal(animated:)` 傳 `false`。它是高頻純鍵盤動作，滑落 + 淡入那 50ms 在這裡只是延遲 —— 手指按下去那一刻條就該在。頂部熱區喚出仍走動畫（滑鼠慢慢頂上來，有過程可看）。無動畫路徑必須**先把 frame 擺好、再設 alpha、最後 `orderFrontRegardless()`**，順序錯了會閃一幀。

**選完立刻消失**：`dismissQuickSwitch()`。⌘Tab 叫出的條在完成選擇那一刻（鬆 ⌘ 提交 / 滑鼠點標籤 / 點視窗縮圖 / Esc 反悔）直接收掉，不走"滑鼠離開後 N 秒"那套 —— 條就貼在滑鼠位置，選完還杵著會擋住剛切過去的視窗。收場同樣走 `hide(animated: false)`，和叫出兩頭一致。

判定抽在 `QuickSwitchDismiss.action(pinnedToMouse:hideDelay:)`（三值：`ignore` / `hideNow` / `parkBack`），可離線迴歸。兩條邊界必須守住：

- **不是 ⌘Tab 叫出的（`pinnedToMouse == false`）→ `ignore`**。滑鼠從頂部頂出來的條點標籤後仍按原延遲淡出，不能被鍵盤邏輯收掉；
- **常駐模式（`hideDelay ≤ 0`）→ `parkBack`**。條本來就該一直在，只擺回錨定螢幕頂部。

還有個坑：⌘Tab 面板彈在滑鼠處，指標停在螢幕頂部中央時和頂部喚出區正好重疊 —— 瞬間收起後下一幀 `tick` 看到 `inHot` 就又把條拉出來，表現為"選完閃一下又回來"。所以收起時置 `suppressHotZoneUntilExit`，等指標離開喚出區一次再恢復喚出。

**6. 視窗預覽** — 懸停 0.12s 防抖後彈出第二個 `NSPanel`。

視窗列舉用 **AX 定集合、ScreenCaptureKit 出像素**，這是"預覽只有前景視窗""最小化視窗沒縮圖"兩個問題的根因所在：

| 方案 | 最小化 / 其它桌面的視窗 | 噪聲 |
|---|---|---|
| `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` | 根本列不出來 | 少 |
| `CGWindowListCopyWindowInfo(.optionAll)` | 列得出來，但 `CGWindowListCreateImage` 抓圖一律返回 **nil** | 極多（Chrome 2 個真視窗 → 7 條記錄，微信 1 個 → 4 條） |
| **AX `kAXWindowsAttribute` 定集合 + SC 出像素** | 列出且能抓到 | 無 |

實測同一時刻對比：

```
                   AX 視窗數   CG(.optionAll) 條數
Google Chrome          2              7
微信                    1              4
抖店工作臺              2              5
```

- 配對方式：幾何完全一致（容差 2pt）優先，其次標題一致；命中即從候選池移除，避免同名同尺寸的多個視窗全指向同一條
- AX 查詢要**併發 + 失敗重試**：Chromium / Electron 系（微信、抖店工作臺、Chrome）第一次被 AX 問的時候要現場建置無障礙樹，常常超時返回 `kAXErrorCannotComplete`。舊程式碼把這種失敗和"這個 App 沒有視窗"一視同仁，於是掉進啟發式分支 —— 幽靈視窗就是這麼來的。現在失敗會等 200ms 重試一次
- **回空也要重試**：Electron 系被問到回「success + 空陣列」時錯誤碼是 0，和"真的沒有視窗"在返回值上分不開。重試後仍是空就照實記錄 —— 那是真沒視窗
- **併發必須按程序序列化（`WindowBridge.axGate`）**：Electron 系被併發問 `kAXWindowsAttribute` 會回「success + 空陣列」，實測 QQ 循序 5/5 正常、6 路併發 48/48 全空。不同 App 之間照常並行，互不影響
- **AX 回了空陣列就信**（`resolve`）：說明這個 App 真的沒有視窗。早先「空」和「拿不到」一樣走啟發式，微信因此一直多出一張點不動也關不掉的卡片
- **座位池（`SeatPool`）**：QQ 偶發把同一個視窗在無障礙樹裡報成兩條（同標題同幾何，日誌抓到過 `raw=2 titles=["QQ","QQ"]`），第二條在 SC/CG 裡都沒有對應表面 —— 就是使用者看到的「多餘的空白視窗」（合成卡片、圖示兜底、縮圖空白）。修法：AX 報的每個真視窗都必須在 `CGWindowListCopyWindowInfo(.optionAll)` 的該 pid layer-0 大表面裡**領到一個座位**，領不到就丟棄；SC 匹配到的也記一筆賬，同一表面只發一張票。**不能按"標題+幾何去重"** —— Chrome 真實存在同標題同幾何的多個視窗，只能靠視窗伺服器數座位
- AX 過濾：`kAXWindowsAttribute` 並不保證只給視窗（Finder 會多報一條 `role=AXScrollArea` 的桌面捲動區）。按 role / subrole / 尺寸三重判定
- AX 拿不到時的兜底門檻（兩者之一）：① 此刻真在螢幕上；② 不在螢幕、且**同一幀幾何沒有被 3 個以上程序同時列出**（`500×500 @0,456` 這種是系統共享緩衝，會掛到幾乎每個程序名下）、有標題、尺寸 ≥ 800×500。寧可少列，也不能把幽靈塞進預覽
- 抓圖用 `SCScreenshotManager.captureImage`，直接按目標尺寸渲染，省掉"全解析度抓取 + 自己縮放"
- 點選縮圖優先用列舉階段記下的 AX 下標定位；下標失效（期間開了/關了視窗）就用標題 + 幾何重新配對
- 提窗順序：`minimize=false` → `AXMain=true` → `AXFocused=true` → `AXRaise` → **最後**才把 App 設為 frontmost。反過來的話 Chromium / Electron 系會把 App 拉到前景但保留它自己認定的 main window
- 游標從標籤滑向預覽面板的途中會經過 8pt 空隙，所以離開標籤後留 **0.4s 寬限**再收起預覽，否則會閃斷。收起純按指標位置判斷（既不在預覽上、也不在面板裡的標籤上，就開始計時），不依賴 `onTabHoverEnd` —— 以前進過預覽再移走不會重新計時，預覽會一直掛著、只能點視窗才關得掉
- 空態（該 App 沒有視窗）刻意做成**和單視窗預覽等寬**：早先為放下提示文字把它撐到兩張卡寬，懸停時尺寸來回跳很突兀

**6b. 卡片互動（懸停 / 按下 / 關閉視窗）**

- 點選做成**兩段式**（`FloatingPanel.onPress` / `onRelease`）：按下只給反饋，抬起才執行。原來的 `onTap` 在 mouseDown 就動手，按下到切視窗之間一個像素都不動，使用者看不出自己有沒有點中
- 抬起時**必須驗證落點還是同一個部位**（`spot == pressed`），拖出去再鬆手算取消 —— 否則誤點會直接切視窗
- 命中優先順序：**關閉按鈕 > 卡片**。關閉按鈕疊在縮圖左上角，兩塊區域天然重疊
- 懸停反白複用主面板那條 10Hz 滑鼠輪詢（`preview.updatePointer`），不用 SwiftUI `.onHover`：預覽是非啟用浮窗，onHover 的到達時機不可靠，而按下判定本來就在視窗層，共用一套座標不容易錯位
- 關窗三級按下：`kAXCloseButtonAttribute` + `AXPress` → 子樹裡 `subrole == AXCloseButton` 的元素 + `AXPress` → 視窗自身的 `AXClose` 動作。**不發 Cmd+W** —— 快捷鍵是發給當前前景 App 的，預覽裡那個 App 未必在前景，會關錯視窗
- **關閉結果不看 AX 的返回值，看視窗還在不在**。Chromium / Electron 系（QQ、微信、抖店工作臺）經常"返回成功其實沒關"，反之也有"返回失敗其實關了"。所以按下前後各數一次「這個幾何下、屬於該 pid 的視窗有幾個」（`CGWindowListCopyWindowInfo`，按 owner pid + bounds 匹配），數量減少才算成功
- **數數量而不是查存在**：Chrome 兩個視窗都是 `0,33 1470×841` 是常態（實測同名同尺寸一次 4 個），"還在不在"必然誤判
- **驗證用視窗伺服器而不是 AX**：AX 是同步阻塞的，對端卡住時要等超時；輪詢驗證需要 120ms 一次地反覆問，只能用 `CGWindowList`
- **必須按目標程序序列化 AX 查詢（`WindowBridge.axGate`）**。這是"App 沒有響應關閉請求"的真正根因：Electron 系被**併發**詢問 `kAXWindowsAttribute` 會返回「success + 空陣列」—— 實測 QQ 循序 5/5 正常，6 路併發 **48/48 全空**，錯誤碼還是 0，跟"真的沒視窗"分不開。而 Xtopbar 恰好會同一瞬間對同一程序發兩路（預覽列舉 + 關窗前重新配對）。按 pid 上閘之後不同 App 仍並行，同一 App 排隊
- **AX 問不出來還有最後一條路：真實點選紅點**。`closeByRedDotClick` 點視窗左上角 `(minX+13, minY+13)`，點之前必須確認①紅點位置最上層就是目標視窗（`topmostWindowOwner`）②這個點不被自己的預覽/主面板壓住（`avoid`），否則寧可不點 —— 點歪了就是切視窗。實測對**背景** App 的視窗點紅點能關掉，而且不會把那個 App 拉到前景
- Electron 冷啟動樹沒建好時寫 `AXManualAccessibility`（Electron）/ `AXEnhancedUserInterface`（Chromium）喚醒，代價是對端要維護整棵樹，只在「明明有視窗卻問不出來」時才用
- 關掉之後要 `refresh(minInterval: 0)` 再重新列舉，且**等 200ms** 讓視窗真的消失。重列舉後用視窗伺服器確認視窗**還在**才提示失敗 —— 幽靈卡片（微信掛在螢幕外的主介面）點不動是正常的，不該報錯嚇人
- **預覽只為「多視窗」服務**：單視窗的 App 點標籤本身就切過去了，再彈預覽純屬打擾。視窗數 < 2 一律不彈（`show` 裡 `hide()` + return，面板若還在螢幕上順手收掉）。視窗剛被關到只剩 1 個時，預覽也會隨之自動收起
- 卡片標題的字重**不能跟著懸停變**：`.semibold` 比 `.medium` 寬 1~2pt，截斷位置跟著跳，滑鼠橫掃幾張卡時看得見抖

**7. 預覽速度** — 從舊方案的 ~600–900ms 降到 **~180ms**（實測 176–222ms）：

- **面板一出現就預熱**：背景做一次 SC 列舉 + AX 配對，再把視窗縮圖按 6 路併發抓進 `NSCache`。使用者真正懸停時圖已在快取裡
- **先鋪卡片再補圖**：`show()` 同步用快取鋪滿，缺圖的卡片並行補抓，誰先回來誰更新
- **防抖 0.28s → 0.12s**：夠濾掉掃過標籤時的抖動，體感接近即時
- **快取 stale-while-revalidate**：4s 內算新鮮直接複用；過期也是先用舊圖頂上、背景再刷
- AX 是同步阻塞 API，全部丟進 `Task.detached`；列舉有最短間隔節流，連續懸停不同標籤不會反覆列舉

**8. 動效** — 面板進出場控制在 0.18s 以內，卡片互動 0.13s 以內，不拖效率：

| 位置 | 動效 |
|---|---|
| 喚出 / 收起 | 面板整體"落下 / 升回" 10pt + 淡入淡出（0.18s / 0.13s），比單純變透明度自然。**⌘Tab 例外：進出場都不動效**（見 5c） |
| 標籤懸停 | 圖示彈簧放大到 1.12（0.22s）；底色漸變 0.11s |
| 前景 App 反白 | 彈簧（0.26s, damping 0.74），切換 App 時反白塊"落"下來；指標離開條面時縮回 |
| 預覽彈出 | 面板下滑 + 淡入；整塊只託一下（0.99 → 1，0.12s easeOut） |
| 縮圖卡片 | 錯峰入場，每張只延遲 18ms，0.13s easeOut；圖片後到時淡入 0.14s |
| 卡片懸停 | 陰影浮起（radius 6 / y 2）+ 強調色描邊 + 關閉按鈕淡入，0.12s easeOut |
| 卡片按下 | 縮到 0.975、邊框加粗到 1.8pt，0.1s easeOut |
| 卡片點中 | 只閃一下邊框，**動作立刻執行** |

**點選動效刻意做"小"**：卡片互動是高頻動作，用 spring 會拖出尾巴、看著"黏"；按下幅度 0.955→0.975、曲線從 spring 換成 easeOut，動作本身在 mouseUp 那一刻就發生。早先為了讓"有沒有點到"看得見，點中後先彈 0.1s 再切視窗 —— 每次切換白等 100ms，正是"不夠乾脆"的來源，已去掉。

兩個刻意的約束：**縮放只作用在圖示或整塊預覽上，絕不做在標籤上** —— 標籤的命中區域是 `GeometryReader` 上報的，縮放會讓點選判定和視覺錯位；懸停 / 選中一律用顏色過渡而不是位移。佈局上：位置錨定螢幕（預設系統主顯示器，見 5b）可見區域頂部居中，距選單列 6pt（⌘Tab 叫出時釘在滑鼠位置，預設在指標上方，貼頂則翻到下方）；寬度隨 App 數量自適應，上限為螢幕寬 −24pt（超出可橫向捲動，兩端漸隱）；分隔線每兩個標籤之間都是同一條淡豎線（1×16pt，opacity 0.14）；左右留白各 12pt，標籤自身 9pt 內邊距 —— 內邊距太小（8pt）時最右那個標籤看起來像"貼邊"。前景 App 反白**只在指標夠得著的時候亮**：指標在喚出熱點區或標籤條上時亮起，離開即撤下。反白表達的是"這個可以點"，不是"它是前景" —— 讓它常駐的話，切走 App 之後反白還掛在舊標籤上，看起來像選中了它，很容易誤讀。

## Dock 化：停靠邊、固定、開始選單

**1. 停靠邊（`DockEdge` / `DockGeometry`）**

`Preferences.dockEdge`：`.top`（預設，原版外觀）/ `.bottom`。「只顯示圖示」`iconOnly` 和「顯示開始按鈕」`showStartButton` 也預設關 —— 不動設定就是原版的頂部標籤條。所有跟停靠邊有關的幾何都收在 `TabBarController.swift` 裡的 `DockGeometry`（純矩形運算，同 `ScreenPick` 的思路，`--test-pins` 會把兩邊都打一遍）：

| 函式 | 頂部 | 底部 |
|---|---|---|
| `barFrame` | `visible.maxY - inset - height`（選單列正下方） | `visible.minY + inset`（系統 Dock 常駐時 visibleFrame 已經讓出它的位置，不會疊） |
| `hotZone` | 選單列中央、寬度可調（預設 120pt，免得誤觸狀態圖示），上邊界越出螢幕 2pt | 底邊一條 6pt 高的窄帶，向下越出 2pt（同樣是半開區間的坑），寬度 = max(條寬, 設定值) —— 底邊沒有狀態圖示可誤觸 |
| `slideSign` | +1（從上方落下） | −1（從下方升起） |

預覽和開始選單往哪邊彈，**看條的實際位置而不是設定**（`opensUpward`：條在螢幕下半部就向上）—— ⌘Tab 把條釘在滑鼠處時，兩種停靠邊都可能出現在螢幕任何位置。彈出面板統一走 `popupFrame` 擺位 + 夾進可用區。預覽面板順手改成按"主面板所在螢幕"夾邊界，不再用會跟著鍵盤焦點漂的 `NSScreen.main`。

**2. 固定項與執行項（`AppCatalog.collect`）**

`AppEntry` 多了 `bundleURL` / `isRunning` / `isPinned`。沒在執行的固定項 `pid = 0`：

- 分組 = 「已固定」組（`AppCategory.pinned`，rank −1，按使用者排的順序，**不按名稱排**）+ 其餘執行中的 App 一組、按開啟時間排。固定項按 bundle id 合併執行實例
- 標籤模式下固定項不畫執行小圓點（只有 Dock 風格才畫，同 macOS Dock）
- 右鍵選單開著時（`NSMenu.didBeginTracking` → `menuTracking`）凍結 `pointerOverBar` 和 `refresh()`：選單是 SwiftUI `contextMenu` 按視圖狀態生成的，任何 @Published 變化都會重建整個選單，已展開的「固定」子選單會當場收起 —— 子選單常伸出條外，指標一移過去 `pointerOverBar` 就翻轉，於是永遠夠不著。關選單時補一次 refresh
- 固定項不受「隱藏此 App」影響；固定時順手把它從隱藏列表裡放出來
- 所有"只對執行中 App 有意義"的地方都要按 `pid > 0` 過濾：⌘Tab 迴圈序列、預熱、預覽、退出。`activePID` / `keyboardHighlightPID` 永遠不會是 0，所以反白也不會落到沒執行的圖示上
- 點沒執行的固定項 → `launch(url:)`（`NSWorkspace.openApplication`），啟動完成後 `didLaunchApplication` 通知觸發 refresh，小圓點自己亮
- 固定的 .app 被挪走：按 bundle id 問 LaunchServices（`urlForApplication(withBundleIdentifier:)`）兜底；兩邊都找不到也留在條上，方便右鍵取消固定
- 持久化：`dockPins` / `startPins` 是 `[PinnedApp]`（bundle id + 路徑 + 名稱）編碼成 JSON 存 UserDefaults；陣列順序即顯示順序

**3. 開始按鈕 / 開始選單**

- 開始按鈕是條上的第一個元素，命中區域用保留 id `AppCatalog.startButtonID`（`"__start__"`）上報，`handleTap` 先判它 → `host.toggleStartMenu()`。和標籤一樣走視窗層命中，不走 SwiftUI 手勢
- 開始選單是獨立的 `FloatingPanel`，比主面板高一層。它要接收鍵盤（搜尋框），所以開啟時 `makeKeyAndOrderFront` —— 面板是 nonactivating 的，能成為 key 視窗但**不啟用 Xtopbar**，前景 App 不會失焦（Spotlight / Alfred 同款）。面板是 key，所以裡面直接用 SwiftUI `Button`
- 鍵盤不走 SwiftUI `onKeyPress`：焦點在搜尋框裡時 ↑↓ 會先被文字框吃掉。控制器裝一個本地 keyDown 監聽處理 Esc / ↑↓ / Return。監聽回呼裡只用 `MainActor.assumeIsolated` 帶出 `Bool`（"吃不吃"）—— 它只允許帶出 Sendable 的值
- 收起時機：Esc、開啟 App、點外面（本地 + 全域滑鼠監聽）、面板失去 key。**點在條上不算點外面**：否則點開始按鈕想關選單時，本地監聽先把它關了，按鈕的命中測試又把它開啟
- 選單開著時 `tick` 把它當成 `menuTracking` 一樣續命：條不自動隱藏、保持滿不透明度、不彈視窗預覽
- 已安裝 App 索引（`AppLibrary`）：直接掃 `/Applications`、`/System/Applications`、`/System/Library/CoreServices/Applications`、`/System/Cryptexes/App/System/Applications`（macOS 13+ 的 Safari）、`~/Applications` 往下 4 層以內的 `.app`（符號連結先解析到真身），外加套在 App 包 `Contents/Applications`、`Contents/Developer/Applications` 裡的獨立 App（Xcode 的 Simulator、Instruments…，選單列輔助程序不收），再單獨補上 CoreServices 根下的 Finder；Finder、Safari 最後按 bundle id 向 LaunchServices 兜底查一次。純背景 App（`LSBackgroundOnly`）不收，按 bundle id 去重。
- App 顯示名（`AppNames`）：Xtopbar 自己沒有本地化，系統介面（`FileManager.displayName`、`NSRunningApplication.localizedName`）會按呼叫方程序能用的語言挑名字，結果總是英文。這裡改為拿 `Locale.preferredLanguages` 直接匹配目標 App 的 `InfoPlist.loctable`（macOS 14+ 系統 App）或 `<語言>.lproj/InfoPlist.strings`，讀 `CFBundleDisplayName` / `CFBundleName`；開始選單、條上的標籤、固定項都走它，找不到再退回原來的名字。分類仍按系統介面給的名字判定。Info.plist 另開了 `CFBundleAllowMixedLocalizations`。
- 「所有應用」排序（`Preferences.startMenuSort`）：名稱 / 最近加入 / 最近更新。掃描時記每個 App 的加入時間（`addedToDirectoryDate`，沒有就用建立時間）和更新時間（加入時間、包與 `Contents/Info.plist` 修改時間取最新）。加入時間在 App 更新換包後會重新整理，所以第一次見到某個 App 時把時間存進 `appFirstSeen`（bundle id → 秒），之後「最近加入」一直用存下的那個；功能剛上線時沒有歷史，只能以當時的加入時間為起點。分組見 `StartMenuIndex.dateSections`。
- 指揮中心讓位（`MissionControlWatcher`）：沒有公開 API，兩路一起看。主力是視窗：指揮中心 / App Exposé 開著時 Dock 會鋪一張 layer 20、蓋滿整塊螢幕的視窗（平時 Dock 沒有這種視窗，自己的 Dock 條只有一條），0.15 秒輪詢一次 `CGWindowListCopyWindowInfo`（不到 1ms，不讀標題所以不需要螢幕錄製權限），只在看到的狀態變了才動。macOS 27 起下面的無障礙通知掛得上卻不再發，只能靠這一路。另一路是 Dock 程序無障礙物件的私有通知 `AXExposeShowAllWindows` / `AXExposeShowFrontWindows`（進入）、`AXExposeShowDesktop` / `AXExposeExit`（退出），yabai 同款。Dock 重啟後 pid 變了觀察者作廢，所以盯 Dock 的啟動通知重掛，另有 5 秒輪詢兜底（權限後給、漏通知）。萬一丟了退出通知：指揮中心開著時前景 App 變了（點視窗 / 切 App 必然退出它），1 秒後還沒等到退出、Dock 的全螢幕視窗也不在了，就按已退出處理。進入時條走 `hide(fade:)` 淡出、期間 tick / 喚出 / 巡檢全部暫停；退出時常駐類模式 `beginReveal(fade:)` 淡入。不用 Spotlight：索引被關掉 / 重建中時會返回空。啟動時掃一次，之後每次開啟選單超過 60 秒就背景重掃
- 「所有應用」按首字母分組：中文名先 `applyingTransform(.toLatin)` + `.stripDiacritics` 轉拼音取首字母（「微信」→ W），非字母開頭歸「#」排最後
- 「最近使用」= `Preferences.recentApps`（bundle id，最多 8 個，`noteActive` 與 `launch` 時記一筆），已固定到開始選單的不重複列

**4. 只顯示有視窗的 App（`WindowPresence`）**

`Preferences.onlyWindowedApps`（預設開）。關窗不發任何 `NSWorkspace` 通知，只能跟著 catalog 的 1.2s 兜底輪詢（外加 launch / activate 等通知）背景查一輪：

- AX `kAXWindowsAttribute` + 預覽同款 `isRealWindow` 過濾數真視窗，**最小化的也算**；按 pid 走 `axGate`，不同 App 併發，整輪在 `Task.detached` 裡
- AX 回空但視窗伺服器裡這個 pid 在螢幕上有一塊 ≥120×90、不透明的 layer-0 表面 → 算有視窗（Electron 系偶發「success + 空陣列」，不兜會把開著視窗的微信藏掉）
- 問不出來（超時 / 失敗）= 維持原判；**連續兩次**"沒視窗"才藏 —— 新啟動的 App 視窗還沒建好時不閃
- 固定項在 `collect` 裡先被收走，不受過濾；沒有輔助使用權限時不過濾（拿不到最小化視窗，寧可多顯示）

**5. 隱藏系統 Dock（`SystemDock`）**

沒有公開 API 能關掉系統 Dock，做法是 `defaults write com.apple.dock autohide -bool true` + `autohide-delay -float 1000`，再 `killall Dock`（launchd 立刻拉起，視窗不受影響）。

- 開關變化才動手（`AppDelegate` 裡 `$hideSystemDock.dropFirst()`），每次先彈確認框；使用者取消就把開關彈回去，用 `revertingDockToggle` 擋掉彈回本身觸發的第二次確認
- 原值**只在第一次開啟時存**（`hasSavedSystemDock`）：否則"開著再開一次"會把 1000 秒延遲當原值存下來，關掉後系統 Dock 永遠出不來
- 原本沒寫過的 key，還原時 `defaults delete` 而不是寫預設值 —— 還原成"沒動過"的樣子

## 偏好與設定實作

- **開機自啟動**用 `SMAppService.mainApp`（macOS 13+），不寫 LaunchAgent plist。實測自簽名 App 也能正常註冊（`register → 已啟用`）。注意它註冊的是**當前 App 所在路徑**，把 App 挪到別處需要重新註冊；註冊被系統攔下時會在設定裡顯示原因並給出「開啟登入項設定」按鈕
- 設定改動**即時生效**，不需要重啟（`TabBarController` 訂閱 `Preferences` 的 publisher）
- 偏好集中在 `Sources/Preferences.swift`，統一管 UserDefaults 讀寫

> 修掉的一個老 bug：舊程式碼用 `v > 0 ? v : 1.5` 讀 `hideDelay`，把「不自動隱藏」的 `0` 也讀成了 1.5，導致常駐模式永遠無法生效。現在用 `object(forKey:) != nil` 判斷是否寫過。

## 建置

```bash
./build.sh          # 生成圖示 + 雙架構編譯 + 自簽名 + 驗證
open Xtopbar.app
```

要求：Xcode 命令列工具；SDK 走 `xcrun --sdk macosx --show-sdk-path`（不要用 `/Library/Developer/CommandLineTools` 的 SDK，版本可能與編譯器不匹配）。

## 線上更新（`Sources/Updater.swift`）

**沒有伺服器，也沒有雲空間。** 更新源就是 GitHub Releases：

- 地址恆定：`https://api.github.com/repos/buzzzzzboy/Xtopbar/releases/latest`
- 倉庫公開 → 客戶端下載不需要任何 token
- 發布流程見 `docs/RELEASING.md`

流程：

```
checkInteractively / 啟動靜默檢查
  → GET /releases/latest（Accept: application/vnd.github+json）
  → 解析 tag_name / body / assets[]，優先挑 .zip 資源
  → 版本比較（versionTuple 補齊到 3 段後逐位比）
  → 有新版：NSAlert（立即更新 / 稍後 / 跳過這個版本）
  → URLSession.download → ditto -x -k 解到臨時目錄
  → 驗證：bundle id 一致 / 包內版本不低於發布版本 / codesign --verify --strict
  → 對比新舊包的 designated requirement（不一致就先警告要重新授權）
  → 寫 install.sh 到臨時目錄，/bin/sh 起一個脫離的 helper
  → 自己 terminate，helper 等 pid 消失 → mv 備份 → ditto 覆蓋 → 去 quarantine → open
```

幾個關鍵決定：

- **必須另起程序替換自己**。執行中的 `.app` 沒法覆蓋自己；而且新版本要拉起來，父程序得先消失。helper 用 `kill -0 "$PID"` 輪詢（最多 60s）等舊程序退出，再動手。
- **helper 裡先 `mv` 成 `.old` 再 `ditto`**，失敗就把 `.old` 挪回來。直接覆蓋一旦中斷就是半個 App。
- **裝完必須 `xattr -dr com.apple.quarantine`**。自簽名 App 沒公證，從網路下來的副本會被 Gatekeeper 打隔離屬性，不去掉使用者會看到"已損壞"。
- **簽名驗證不能省**。打包 → 上傳 → 下載 → 解壓縮這一趟容易出問題（比如用 `zip` 而不是 `ditto` 會把簽名弄壞）。`make-release.sh` 打包後會自己解壓縮回來驗一次。
- **DR 變了要警告**。TCC 授權記錄綁在憑證上，`codesign -d -r-` 輸出的 requirement 一致就說明授權能延續。不同就彈窗提醒，別讓使用者以為權限憑空沒了。
- **App Translocation 要提前攔**。使用者從 DMG 裡直接雙擊執行時，App 跑在 `/private/var/folders/.../AppTranslocation/...` 這種唯讀路徑下，替換必然失敗。識別到就引導使用者先拖進「應用程式」。
- **先探寫入權限再下載**。`FileManager.isWritableFile` 查父目錄，不可寫就直接給「開啟發布頁」的退路，避免下完才報錯。
- **不用 Sparkle**：本專案是 `swiftc` 直編 + `build.sh`，沒有 SPM / Xcode 工程。引入 Sparkle 要另外嵌 xcframework、複製 framework、再單獨簽名，成本高於自己寫這 400 行。

除錯入口：

```bash
open Xtopbar.app --args --check-update    # 檢查並正常彈窗
open Xtopbar.app --args --update-install  # 跳過彈窗，發現新版直接裝

# 指向任意更新源（本機檔案或自己的 http 服務），用來測整條鏈路
XTOPBAR_UPDATE_FEED=http://127.0.0.1:18777/feed.json \
  /path/to/Xtopbar.app/Contents/MacOS/Xtopbar --update-install
```

相關偏好：`autoCheckUpdates`（預設開）、`ignoredVersion`（點過「跳過這個版本」的版本號，
靜默檢查時不再提示，手動檢查仍然提示）。

## 除錯

環境變數 `XTOPBAR_DEBUG=1`，或存在標記檔案 `/tmp/xtopbar.debug`（後者用於 `open Xtopbar.app` 啟動的場景 —— 走 LaunchServices 時環境變數傳不進去）。日誌寫到 `/tmp/xtopbar.log`。

啟動引數：

```bash
open Xtopbar.app --args --settings      # 直接拉起設定視窗
open Xtopbar.app --args --test-login    # 跑一遍 SMAppService 註冊/取消註冊並記錄結果
open Xtopbar.app --args --test-hotzone=0  # 模擬"在 0 號螢幕用過一次 ⌘Tab"，看熱區最終落在哪塊螢幕
open Xtopbar.app --args --test-cycle=8    # 不開面板，把 ⌘Tab 會話連按 8 發，看反白是否一格一格連著
open Xtopbar.app --args --test-quickswitch # 模擬"⌘Tab 叫出 → 選完"，看條是否當場消失、會不會被喚出區拉回來
open Xtopbar.app --args --test-pins       # 列印固定 / 執行分組、兩種停靠邊的條 / 喚出區 / 開始選單位置、一次應用搜尋
open Xtopbar.app --args --start-menu      # 啟動後直接彈開始選單
```

`--test-hotzone=<螢幕序號>` 就是上面 5b 那個 bug 的迴歸入口：它會模擬 ⌘Tab 把面板釘到指定螢幕，再按正常流程收起，然後把面板停靠位置、熱區矩形、熱區落在哪塊螢幕一起寫進日誌。換個螢幕號再跑一次，就能看出熱區是否會被 ⌘Tab 帶跑。

`--test-cycle=<次數>` 是 5c 的迴歸入口：它不開面板、不搶鍵，只用真實的 App 列表把會話走一遍，日誌裡每一步都帶「App 名 + 下標 / 總數」。下標必須是逐個 ±1 的（`1/8 → 2/8 → … → 0/8 → 1/8`），一旦出現跳號就說明迴圈序列又串了順序。

`--test-quickswitch` 是"選完立刻消失"的迴歸入口：走一遍真實的 `revealAtMouse()`（釘在滑鼠位置叫出）+ 結束會話 + `dismissQuickSwitch()`，日誌給出 `isRevealed` / `panel.isVisible` / `suppressHotZone` 三個值，並在 +0.5s 再打一次 —— 該看到當場 `panel.isVisible=false`，且半秒後 `suppressHotZone` 已復位（指標不在喚出區時自然會解除），熱區矩形不變。

判定"是否真的切到前景"要看視窗疊放序（`CGWindowListCopyWindowInfo` 的 layer 0 首條），別信 `NSWorkspace.frontmostApplication` —— 它返回快取值，會出現"日誌說成功、實際沒變"的假象。
