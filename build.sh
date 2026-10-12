#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

NAME="Xtopbar"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
APP="$(pwd)/${NAME}.app"
MIN_OS="14.0"

# 固定签名身份：目标目录固定 + 签名不变 → 屏幕录制/辅助功能授权不会被重置
KEYCHAIN="$HOME/Library/Keychains/xtopbar-signing.keychain-db"
IDENTITY="Xtopbar Self-Signed"
KEYCHAIN_PASS="xtopbar"
# 正式发版的证书 SHA-1 钉死：同名证书重新生成后哈希就变了，用户的 TCC 授权会全部失效。
RELEASE_CERT_SHA1="1A512BD00CC0BD31119D7FD79D267ECE5D41715C"
#
# 选哪张证书：
#   · EXPECTED_CERT_SHA1=哈希 ./build.sh   —— 只认这张（真要换正式证书时用）
#   · XTOPBAR_RELEASE=1 ./build.sh         —— 只认正式证书（make-release.sh 会设）
#   · 都没设（平常开发）                    —— 有正式证书就用；这台没有的话，自动改用
#     本机 keychain 里那张同名证书签开发版，不用每次手打哈希。这样签的包不能拿去发版
#
#   ./build.sh --check-signing             —— 只检查签名身份，不编译（发版脚本先用它把关）
CHECK_ONLY=0
[ "${1:-}" = "--check-signing" ] && CHECK_ONLY=1
DEV_FALLBACK=0

# 签名身份不对就立刻停，别等编译完才发现
fail_signing() {
  echo "✗ $1" >&2
  cat >&2 <<EOF
  不会自动生成新证书，也不会退回 ad-hoc 签名 —— 那样签出来的 App
  在 macOS 看来是"另一个 App"，屏幕录制 / 辅助功能都要重新授权。
  · 在沙盒 / 别的会话里构建：改到能读 ~/Library/Keychains 的终端里跑
  · 换了电脑 / 另一台电脑没这张证书：在有证书的那台跑
      ./scripts/sync-signing-cert.sh export
    把 .p12 搬过来后在这台跑
      ./scripts/sync-signing-cert.sh import <文件.p12>
  · 第一次在这台机器上建证书：./scripts/make-signing-identity.sh
    （之后开发版会自动用它；发版仍然只认正式证书）
EOF
  exit 1
}

[ -f "$KEYCHAIN" ] || fail_signing "找不到签名 keychain：$KEYCHAIN"
# 自签名证书是 CSSMERR_TP_NOT_TRUSTED（未加入信任链），所以不能带 -v ——
# -v 只列"受信任"的身份。而 codesign 签名本身并不需要证书受信，
# 只要 keychain 里有私钥即可；TCC 记的是 designated requirement 里的证书哈希，
# 与信任状态无关。
# keychain 里「Xtopbar Self-Signed」的所有证书哈希（大写）
AVAILABLE="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
  | grep "\"${IDENTITY}\"" | awk '{print toupper($2)}' | sort -u)"
has_cert() { printf '%s\n' "$AVAILABLE" | grep -qx "$1"; }

if [ -n "${EXPECTED_CERT_SHA1:-}" ]; then
  EXPECTED_CERT_SHA1="$(printf '%s' "${EXPECTED_CERT_SHA1}" | tr 'a-f' 'A-F')"
  has_cert "${EXPECTED_CERT_SHA1}" \
    || fail_signing "keychain 里没有哈希为 ${EXPECTED_CERT_SHA1} 的「${IDENTITY}」"
elif has_cert "${RELEASE_CERT_SHA1}"; then
  EXPECTED_CERT_SHA1="${RELEASE_CERT_SHA1}"
elif [ "${XTOPBAR_RELEASE:-0}" = "1" ]; then
  fail_signing "发版必须用正式证书 ${RELEASE_CERT_SHA1}，这台的 keychain 里没有"
else
  EXPECTED_CERT_SHA1="$(printf '%s\n' "$AVAILABLE" | grep -m1 . || true)"
  [ -n "${EXPECTED_CERT_SHA1}" ] \
    || fail_signing "keychain 里没有任何「${IDENTITY}」证书"
  DEV_FALLBACK=1
  echo "⚠ 这台没有正式证书，改用本机证书 ${EXPECTED_CERT_SHA1} 签开发版（不能拿来发版）"
fi

if [ "$CHECK_ONLY" = "1" ]; then
  echo "✓ 签名身份：${EXPECTED_CERT_SHA1}"
  exit 0
fi

rm -rf "$APP" build
mkdir -p build

echo "→ 生成 App 图标"
xcrun swiftc -O -sdk "$SDK" -o "build/make-icons" scripts/make-icons.swift
"build/make-icons" build Resources/Logo.png

for arch in arm64 x86_64; do
  echo "→ compiling ${arch}"
  xcrun swiftc -O -sdk "$SDK" -target "${arch}-apple-macosx${MIN_OS}" \
    -parse-as-library \
    -framework AppKit -framework SwiftUI -framework ApplicationServices \
    -framework ScreenCaptureKit \
    -o "build/${NAME}_${arch}" \
    Sources/*.swift
done

echo "→ lipo"
xcrun lipo -create -output "build/${NAME}" "build/${NAME}_arm64" "build/${NAME}_x86_64"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/${NAME}" "$APP/Contents/MacOS/${NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "build/Xtopbar.icns" "$APP/Contents/Resources/Xtopbar.icns"
cp Resources/Logo.png "$APP/Contents/Resources/Logo.png"
cp Resources/Emoji.tsv "$APP/Contents/Resources/Emoji.tsv"
cp Resources/SymbolNames.tsv "$APP/Contents/Resources/SymbolNames.tsv"
printf 'APPL????' > "$APP/Contents/PkgInfo"

security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null || true
echo "→ codesign（固定身份）"
# 用哈希而不是名字指定身份：同名证书有多张时也不会签错
codesign --force --sign "${EXPECTED_CERT_SHA1}" --keychain "$KEYCHAIN" \
  --identifier com.buzzzzzboy.xtopbar "$APP"
codesign --verify --strict "$APP"

# 最后一道检查：designated requirement 里的证书哈希必须是钉死的那张
EXPECTED_LOWER="$(printf '%s' "${EXPECTED_CERT_SHA1}" | tr 'A-F' 'a-f')"
codesign -d -r- "$APP" 2>&1 | grep -q "H\"$EXPECTED_LOWER\"" \
  || fail_signing "签完的 App 证书哈希不是 ${EXPECTED_CERT_SHA1}"

xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "✓ Built: $APP"
echo "  签名: $(codesign -d -r- "$APP" 2>&1 | grep -m1 designated | sed 's/^# //')"
if [ "$DEV_FALLBACK" = "1" ]; then
  echo "  ⚠ 开发版：用的是本机证书，不是正式证书 ${RELEASE_CERT_SHA1}，别拿这个包发版"
fi
