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
# 证书 SHA-1 钉死：同名证书重新生成后哈希就变了，TCC 授权照样全部失效。
# 真要换证书（比如证书丢了），用 EXPECTED_CERT_SHA1=新哈希 ./build.sh 覆盖。
EXPECTED_CERT_SHA1="${EXPECTED_CERT_SHA1:-1A512BD00CC0BD31119D7FD79D267ECE5D41715C}"

# 签名身份不对就立刻停，别等编译完才发现
fail_signing() {
  echo "✗ $1" >&2
  cat >&2 <<EOF
  不会自动生成新证书，也不会退回 ad-hoc 签名 —— 那样签出来的 App
  在 macOS 看来是"另一个 App"，屏幕录制 / 辅助功能都要重新授权。
  · 在沙盒 / 别的会话里构建：改到能读 ~/Library/Keychains 的终端里跑
  · 换了电脑：把原证书导出成 .p12，导入到 $KEYCHAIN
  · 第一次在这台机器上建证书：./scripts/make-signing-identity.sh，
    再用 EXPECTED_CERT_SHA1=新哈希 覆盖
EOF
  exit 1
}

[ -f "$KEYCHAIN" ] || fail_signing "找不到签名 keychain：$KEYCHAIN"
# 自签名证书是 CSSMERR_TP_NOT_TRUSTED（未加入信任链），所以不能带 -v ——
# -v 只列"受信任"的身份。而 codesign 签名本身并不需要证书受信，
# 只要 keychain 里有私钥即可；TCC 记的是 designated requirement 里的证书哈希，
# 与信任状态无关。
security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
  | grep "\"$IDENTITY\"" | grep -q "$EXPECTED_CERT_SHA1" \
  || fail_signing "keychain 里没有哈希为 $EXPECTED_CERT_SHA1 的「$IDENTITY」"

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
printf 'APPL????' > "$APP/Contents/PkgInfo"

security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null || true
echo "→ codesign（固定身份）"
# 用哈希而不是名字指定身份：同名证书有多张时也不会签错
codesign --force --sign "$EXPECTED_CERT_SHA1" --keychain "$KEYCHAIN" \
  --identifier com.buzzzzzboy.xtopbar "$APP"
codesign --verify --strict "$APP"

# 最后一道检查：designated requirement 里的证书哈希必须是钉死的那张
EXPECTED_LOWER="$(printf '%s' "$EXPECTED_CERT_SHA1" | tr 'A-F' 'a-f')"
codesign -d -r- "$APP" 2>&1 | grep -q "H\"$EXPECTED_LOWER\"" \
  || fail_signing "签完的 App 证书哈希不是 $EXPECTED_CERT_SHA1"

xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "✓ Built: $APP"
echo "  签名: $(codesign -d -r- "$APP" 2>&1 | grep -m1 designated | sed 's/^# //')"
