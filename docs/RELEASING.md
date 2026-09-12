# 发布与在线更新

## 结论：不需要服务器，也不需要买云空间

App 里的「检查更新」直接读 **GitHub Releases**。这一个东西同时提供了两样：

| 需要什么 | GitHub 给什么 |
|---|---|
| 一个地址恒定、不会变的接口 | `https://api.github.com/repos/lrylnx/TopTab/releases/latest` |
| 文件托管（放新版本的安装包） | Release 附件，走 GitHub 的 CDN |
| 费用 | 公开仓库免费、无流量限制 |

仓库是公开的，所以**客户端拉更新不需要任何 token**。你唯一需要 token 的地方是自己发版时调 API 上传附件。

对比一下别的方案，看为什么选它：

| 方案 | 成本 | 说明 |
|---|---|---|
| **GitHub Releases**（当前） | 免费 | 无需服务器、无需域名、无需备案 |
| 对象存储（OSS / COS） | 几毛钱/月 | 只当文件托管，还得自己写一个 appcast 文件 |
| 自建 VPS | 服务器费用 + 域名 | 为了一个版本号文件养一台机器，不划算 |
| Sparkle + GitHub Pages | 免费 | Sparkle 要嵌 xcframework 进 App 再单独签名，本项目是 swiftc 直编、没有 SPM 工程，接入成本高于自己写 |
| Mac App Store | 年费 | 要审核，且 App 要开沙盒，AX 功能会残废 |

## 发版：一条命令

```bash
GITHUB_TOKEN=<你的 token> ./scripts/make-release.sh 1.3.0 "新增在线更新
- 启动后自动检查新版本
- 设置里可以手动检查"
```

脚本会做四件事：

1. 把版本号写进 `Resources/Info.plist`（`CFBundleVersion` 自增）
2. `./build.sh` 双架构编译 + 自签名
3. 打成 `dist/TopTab-v1.3.0.zip` —— **必须是 zip**，App 要解包后替换自己
4. 建 Release 并把 zip 传成附件（已经有同名 Release 时会改成替换附件）

打包后会**自动解压回来验一次签名**，签名损坏会直接报错停住 —— 这一步很关键，签名坏的包用户装上去打不开。

### 没设 token 会怎样

脚本会跳过发布，只产出 `dist/TopTab-v1.3.0.zip`，并打印手动上传步骤。手动上传完全可以：

1. 打开 <https://github.com/lrylnx/TopTab/releases/new>
2. Tag 填 `v1.3.0`，标题填 `v1.3.0`
3. 说明里写更新内容 —— **这段文字会显示在用户的更新弹窗里**，写人话
4. 把 `dist/TopTab-v1.3.0.zip` 拖进去当附件

只要附件的文件名以 `.zip` 结尾，App 就能自动安装；没有 zip 时按钮会退化成「打开发布页」。

### token 从哪来

GitHub → Settings → Developer settings → Personal access tokens → Fine-grained token，
对 `lrylnx/TopTab` 仓库给 **Contents: Read and write** 权限即可。

别把 token 写进脚本或提交进仓库，用环境变量传：

```bash
export GITHUB_TOKEN=xxx          # 临时
# 或者只对这一次命令生效
GITHUB_TOKEN=xxx ./scripts/make-release.sh 1.3.0 "说明"
```

## 铁律：每次都必须用同一张签名证书

`build.sh` 用的是固定身份 `TopTab Self-Signed`（存在独立 keychain
`~/Library/Keychains/toptab-signing.keychain-db`）。

macOS 的 TCC（屏幕录制 / 辅助功能授权）认的是签名里的 **designated requirement**，
它包含证书指纹。所以：

- **证书不变** → 更新后用户权限照旧，什么都不用重做
- **证书变了**（换机器构建、删了 keychain 重建）→ 用户更新完必须重新授权一次

更新器会在装包前对比新旧两包的 DR，发现不一致会先弹窗提醒「更新后需要重新授权」，
不会默默让用户以为权限丢了。

所以：**别删那个 keychain，也别在别的机器上重新生成证书发版。**

## 用户侧的更新体验

- 启动 3 秒后静默检查一次（每小时最多一次），没新版本就毫无动静
- 有新版本 → 弹窗，三个按钮：立即更新 / 稍后 / 跳过这个版本
- 「跳过这个版本」后静默检查不再提示，但手动点「检查更新…」仍会提示
- 菜单栏图标 →「检查更新…」，或 设置 → 关于 →「检查更新」
- 更新过程：下载 → 解压 → 校验（bundle id / 版本号 / 签名）→ 退出自己 → 覆盖 → 重新拉起
- 装不上会明确说明原因（位置不可写、App Translocation），并给「打开发布页」的退路

## 自己验证更新链路

不想等真实发版、也不想手点弹窗时：

```bash
# 1. 造一个更高的版本号发到本地
#    把 feed.json 里的 browser_download_url 指向本地 http 服务
# 2. 用一个旧版本副本启动，跳过弹窗直接装
TOPTAB_DEBUG=1 \
TOPTAB_UPDATE_FEED=http://127.0.0.1:18777/feed.json \
  /path/to/TopTab.app/Contents/MacOS/TopTab --update-install
```

`TOPTAB_UPDATE_FEED` 会把检查地址换成你指定的任意 URL（本地 `file://` 也行），
`--update-install` 跳过弹窗直接安装，日志在 `/tmp/toptab.log`。

`--check-update` 是只检查、正常弹窗。

## 踩过的坑

| 现象 | 原因 |
|---|---|
| 用户点「立即更新」提示位置不可写 | App 在 `/Applications` 下但不是当前用户所有。更新器会提前探测并给出提示 |
| 提示「请先移动 TopTab」 | App Translocation —— 用户从 DMG 里直接双击运行，没拖进应用程序文件夹，系统把它挂在一个随机只读路径下。更新器会识别并引导 |
| 下载的包打不开 | 自签名 App 没公证，从网络下来的副本会被打上 `com.apple.quarantine`。更新脚本装完会 `xattr -dr` 去掉 |
| 更新完权限全没了 | 换了签名证书，见上面「铁律」 |
| 附件传了 `.dmg` | 自动安装需要能解包，只认 `.zip`。可以同时传 dmg 给人手动装，但 zip 必须传 |
