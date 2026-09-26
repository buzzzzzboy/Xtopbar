# 發布與線上更新

## 結論：不需要伺服器，也不需要買雲空間

App 裡的「檢查更新」直接讀 **GitHub Releases**。這一個東西同時提供了兩樣：

| 需要什麼 | GitHub 給什麼 |
|---|---|
| 一個地址恆定、不會變的介面 | `https://api.github.com/repos/buzzzzzboy/Xtopbar/releases/latest` |
| 檔案託管（放新版本的安裝包） | Release 附件，走 GitHub 的 CDN |
| 費用 | 公開倉庫免費、無流量限制 |

倉庫是公開的，所以**客戶端拉更新不需要任何 token**。你唯一需要 token 的地方是自己發版時調 API 上傳附件。

對比一下別的方案，看為什麼選它：

| 方案 | 成本 | 說明 |
|---|---|---|
| **GitHub Releases**（當前） | 免費 | 無需伺服器、無需網域、無需備案 |
| 物件儲存（OSS / COS） | 幾毛錢/月 | 只當檔案託管，還得自己寫一個 appcast 檔案 |
| 自建 VPS | 伺服器費用 + 網域 | 為了一個版本號檔案養一臺機器，不划算 |
| Sparkle + GitHub Pages | 免費 | Sparkle 要嵌 xcframework 進 App 再單獨簽名，本專案是 swiftc 直編、沒有 SPM 工程，接入成本高於自己寫 |
| Mac App Store | 年費 | 要審核，且 App 要開沙盒，AX 功能會殘廢 |

## 發版：一條命令

```bash
GITHUB_TOKEN=<你的 token> ./scripts/make-release.sh 1.3.0 "新增線上更新
- 啟動後自動檢查新版本
- 設定裡可以手動檢查"
```

腳本會做四件事：

1. 把版本號寫進 `Resources/Info.plist`（`CFBundleVersion` 自增）
2. `./build.sh` 雙架構編譯 + 自簽名
3. 打成 `dist/Xtopbar-v1.3.0.zip` —— **必須是 zip**，App 要解包後替換自己
4. 建 Release 並把 zip 傳成附件（已經有同名 Release 時會改成替換附件）

打包後會**自動解壓縮回來驗一次簽名**，簽名損壞會直接報錯停住 —— 這一步很關鍵，簽名壞的包使用者裝上去打不開。

### 沒設 token 會怎樣

腳本會跳過發布，只產出 `dist/Xtopbar-v1.3.0.zip`，並列印手動上傳步驟。手動上傳完全可以：

1. 開啟 <https://github.com/buzzzzzboy/Xtopbar/releases/new>
2. Tag 填 `v1.3.0`，標題填 `v1.3.0`
3. 說明裡寫更新內容 —— **這段文字會顯示在使用者的更新彈窗裡**，寫人話
4. 把 `dist/Xtopbar-v1.3.0.zip` 拖進去當附件

只要附件的檔名以 `.zip` 結尾，App 就能自動安裝；沒有 zip 時按鈕會退化成「開啟發布頁」。

### token 從哪來

GitHub → Settings → Developer settings → Personal access tokens → Fine-grained token，
對 `buzzzzzboy/Xtopbar` 倉庫給 **Contents: Read and write** 權限即可。

別把 token 寫進腳本或提交進倉庫，用環境變數傳：

```bash
export GITHUB_TOKEN=xxx          # 臨時
# 或者只對這一次命令生效
GITHUB_TOKEN=xxx ./scripts/make-release.sh 1.3.0 "說明"
```

## 鐵律：每次都必須用同一張簽名憑證

`build.sh` 用的是固定身份 `Xtopbar Self-Signed`（存在獨立 keychain
`~/Library/Keychains/xtopbar-signing.keychain-db`）。

macOS 的 TCC（螢幕錄製 / 輔助功能授權）認的是簽名裡的 **designated requirement**，
它包含憑證指紋。所以：

- **憑證不變** → 更新後使用者權限照舊，什麼都不用重做
- **憑證變了**（換機器建置、刪了 keychain 重建）→ 使用者更新完必須重新授權一次

更新器會在裝包前對比新舊兩包的 DR，發現不一致會先彈窗提醒「更新後需要重新授權」，
不會默默讓使用者以為權限丟了。

所以：**別刪那個 keychain，也別在別的機器上重新生成憑證發版。**

## 使用者側的更新體驗

- 啟動 3 秒後靜默檢查一次（每小時最多一次），沒新版本就毫無動靜
- 有新版本 → 彈窗，三個按鈕：立即更新 / 稍後 / 跳過這個版本
- 「跳過這個版本」後靜默檢查不再提示，但手動點「檢查更新…」仍會提示
- 選單列圖示 →「檢查更新…」，或 設定 → 關於 →「檢查更新」
- 更新過程：下載 → 解壓縮 → 驗證（bundle id / 版本號 / 簽名）→ 退出自己 → 覆蓋 → 重新拉起
- 裝不上會明確說明原因（位置不可寫、App Translocation），並給「開啟發布頁」的退路

## 自己驗證更新鏈路

不想等真實發版、也不想手點彈窗時：

```bash
# 1. 造一個更高的版本號發到本機
#    把 feed.json 裡的 browser_download_url 指向本機 http 服務
# 2. 用一個舊版本副本啟動，跳過彈窗直接裝
XTOPBAR_DEBUG=1 \
XTOPBAR_UPDATE_FEED=http://127.0.0.1:18777/feed.json \
  /path/to/Xtopbar.app/Contents/MacOS/Xtopbar --update-install
```

`XTOPBAR_UPDATE_FEED` 會把檢查地址換成你指定的任意 URL（本機 `file://` 也行），
`--update-install` 跳過彈窗直接安裝，日誌在 `/tmp/xtopbar.log`。

`--check-update` 是只檢查、正常彈窗。

## 踩過的坑

| 現象 | 原因 |
|---|---|
| 使用者點「立即更新」提示位置不可寫 | App 在 `/Applications` 下但不是當前使用者所有。更新器會提前探測並給出提示 |
| 提示「請先移動 Xtopbar」 | App Translocation —— 使用者從 DMG 裡直接雙擊執行，沒拖進應用程式資料夾，系統把它掛在一個隨機唯讀路徑下。更新器會識別並引導 |
| 下載的包打不開 | 自簽名 App 沒公證，從網路下來的副本會被打上 `com.apple.quarantine`。更新腳本裝完會 `xattr -dr` 去掉 |
| 更新完權限全沒了 | 換了簽名憑證，見上面「鐵律」 |
| 附件傳了 `.dmg` | 自動安裝需要能解包，只認 `.zip`。可以同時傳 dmg 給人手動裝，但 zip 必須傳 |
