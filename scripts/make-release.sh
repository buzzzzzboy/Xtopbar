#!/usr/bin/env bash
#
# 打包并发布一个 GitHub Release —— App 里的「检查更新」就是从这个 Release 读的。
#
#   ./scripts/make-release.sh 1.3.0 "新增在线更新"                       # 只构建 + 打包（不发布）
#   GITHUB_TOKEN=xxx ./scripts/make-release.sh 1.3.0 "说明" "发布标题"      # 构建 + 打包 + 发布
#
# 不需要任何自建服务器、云空间或域名。GitHub Releases 同时提供两样东西：
#   1. 一个地址恒定的接口：https://api.github.com/repos/<owner>/<repo>/releases/latest
#   2. 文件托管（Release 资源），别人下载走 GitHub 的 CDN。
# 仓库是公开的，所以客户端拉取更新不需要任何 token。
#
# 一件事必须守住：**每次都必须用同一张自签名证书构建**（build.sh 里那张
# TopTab Self-Signed）。证书一变，macOS 的 TCC 授权记录（屏幕录制 / 辅助功能）
# 就全部失效，用户更新完得重新授权一次。
set -euo pipefail
cd "$(dirname "$0")/.."

OWNER="lrylnx"
REPO="TopTab"
PLIST="Resources/Info.plist"

VERSION="${1:-}"
NOTES="${2:-}"

if [ -z "$VERSION" ]; then
  echo "用法: ./scripts/make-release.sh <版本号> [更新说明] [发布标题]"
  echo "例:   ./scripts/make-release.sh 1.3.0 \"新增在线更新\""
  exit 1
fi

# 版本号去掉 v 前缀写进 Info.plist（CFBundleShortVersionString 不该带 v），
# 但 git tag 保留 v 前缀，跟历史版本一致（v1.1.1 / v1.1.2 / v1.2.0）。
VERSION="${VERSION#v}"
TAG="v$VERSION"
TITLE="${3:-TopTab $TAG}"

# ── 1. 写版本号（Info.plist 是唯一的版本来源） ────────────────────────────
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((CURRENT_BUILD + 1))" "$PLIST"
echo "→ 版本 $VERSION（tag $TAG，CFBundleVersion $((CURRENT_BUILD + 1))）"

# ── 2. 构建 ──────────────────────────────────────────────────────────────
./build.sh

# ── 3. 打包。--keepParent 让 zip 里就是 TopTab.app（更新器靠这个找包） ────
mkdir -p dist
ZIP="dist/TopTab-${TAG}.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent TopTab.app "$ZIP"

echo "→ 打包完成 $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "  sha256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

# 自检：解压回来必须还能通过签名校验，否则用户装上去会打不开
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
codesign --verify --strict "$TMP/TopTab.app"
echo "  ✓ 解压后签名校验通过"

# ── 4. 发布 ──────────────────────────────────────────────────────────────
TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  cat <<EOF

没有设置 GITHUB_TOKEN，跳过自动发布。手动上传方式：
  1. 打开 https://github.com/$OWNER/$REPO/releases/new
  2. Tag 填 $TAG，标题填 $TAG
  3. 说明里写更新内容（会显示在 App 的更新弹窗里）
  4. 把 $ZIP 拖进去当附件 —— 必须是 .zip，App 要解包后替换自己
EOF
  exit 0
fi

echo "→ 创建 Release $TAG"

# JSON 体交给 python3 生成，说明里带引号或换行都不会把请求搞坏
if command -v python3 >/dev/null 2>&1; then
  PAYLOAD="$(python3 -c 'import json,sys;print(json.dumps({"tag_name":sys.argv[1],"name":sys.argv[2],"body":sys.argv[3],"draft":False,"prerelease":False}))' "$TAG" "$TITLE" "$NOTES")"
else
  ESCAPED="$(printf '%s' "$NOTES" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | awk '{printf "%s\\n", $0}' | sed -e 's/\\n$//')"
  PAYLOAD="{\"tag_name\":\"$TAG\",\"name\":\"$TITLE\",\"body\":\"$ESCAPED\",\"draft\":false,\"prerelease\":false}"
fi

RESPONSE="$(curl -sS -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$OWNER/$REPO/releases" \
  -d "$PAYLOAD")"

RELEASE_ID="$(printf '%s' "$RESPONSE" | plutil -extract id raw -o - - 2>/dev/null || true)"

if [ -z "$RELEASE_ID" ]; then
  # 422：这个 tag 已经有 Release 了。改成往已有 Release 上补/换附件。
  echo "  Release 已存在，改为更新它的附件"
  RESPONSE="$(curl -sS -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER/$REPO/releases/tags/$TAG")"
  RELEASE_ID="$(printf '%s' "$RESPONSE" | plutil -extract id raw -o - - 2>/dev/null || true)"
  [ -z "$RELEASE_ID" ] && { echo "✗ 拿不到 Release id：$RESPONSE"; exit 1; }

  # 同名附件要先删掉，否则上传会 422（只删 assets 里的，别碰 Release 自己）
  ASSET_IDS="$(printf '%s' "$RESPONSE" \
    | plutil -extract assets json -o - - 2>/dev/null \
    | grep -o '"id": *[0-9]*' | grep -o '[0-9]*' || true)"
  for asset_id in $ASSET_IDS; do
    curl -sS -X DELETE -H "Authorization: Bearer $TOKEN" \
      "https://api.github.com/repos/$OWNER/$REPO/releases/assets/$asset_id" >/dev/null || true
  done
fi

echo "→ 上传 $ZIP"
UPLOAD_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary "@$ZIP" \
  "https://uploads.github.com/repos/$OWNER/$REPO/releases/$RELEASE_ID/assets?name=$(basename "$ZIP")")"

if [ "$UPLOAD_STATUS" != "201" ]; then
  echo "✗ 上传失败（HTTP $UPLOAD_STATUS）"
  exit 1
fi

echo
echo "✓ 已发布 https://github.com/$OWNER/$REPO/releases/tag/$TAG"
echo "  已装老版本的用户，下次打开 TopTab 就会收到更新提示。"
