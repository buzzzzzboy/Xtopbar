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

rm -rf "$APP" build
mkdir -p build

echo "→ 生成 App 图标"
xcrun swiftc -O -sdk "$SDK" -o "build/make-icons" scripts/make-icons.swift
"build/make-icons" build

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
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 自签名证书是 CSSMERR_TP_NOT_TRUSTED（未加入信任链），所以不能带 -v —— 
# -v 只列"受信任"的身份。而 codesign 签名本身并不需要证书受信，
# 只要 keychain 里有私钥即可；TCC 记的是 designated requirement 里的证书哈希，
# 与信任状态无关。
has_identity() {
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"
}

if [ ! -f "$KEYCHAIN" ] || ! has_identity; then
  ./scripts/make-signing-identity.sh || true
fi

if has_identity; then
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null || true
  echo "→ codesign（固定身份）"
  codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" \
    --identifier com.buzzzzzboy.xtopbar "$APP"
  codesign --verify --strict "$APP"
else
  echo "⚠ 未找到自签名身份，退回 ad-hoc 签名（重建后需重新授权屏幕录制）"
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "✓ Built: $APP"
echo "  签名: $(codesign -d -r- "$APP" 2>&1 | grep -m1 designated | sed 's/^# //')"
