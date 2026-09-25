#!/usr/bin/env bash
# 创建 Xtopbar 的自签名代码签名身份。
#
# 为什么需要：ad-hoc 签名（codesign --sign -）的指定要求里带的是这次构建的
# cdhash，每次重编译哈希都变，macOS 就当成"另一个 App"，屏幕录制 / 辅助功能
# 授权全部失效，要重新授权一次。
#
# 换成固定证书后，指定要求变成
#   identifier "com.buzzzzzboy.xtopbar" and certificate leaf = H"xxxx"
# 证书不变 → 哈希不变 → 授权一直有效。
#
# 证书放在独立的 keychain 里（不是 login keychain），配合
# set-key-partition-list，codesign 调用时不会弹钥匙串授权对话框，可无人值守构建。
set -euo pipefail

IDENTITY="Xtopbar Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/xtopbar-signing.keychain-db"
KEYCHAIN_PASS="xtopbar"

if [ -f "$KEYCHAIN" ] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "✓ 签名身份已存在：$IDENTITY"
  exit 0
fi

echo "→ 生成自签名代码签名证书：$IDENTITY"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$IDENTITY/OU=Xtopbar/O=Xtopbar" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# OpenSSL 3（如 Homebrew 版）默认用 AES/PBKDF2 加密 p12，macOS security 导入不了，需 -legacy
PKCS12_LEGACY=""
if openssl version | grep -q '^OpenSSL 3'; then PKCS12_LEGACY="-legacy"; fi

openssl pkcs12 -export $PKCS12_LEGACY -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$IDENTITY" -passout "pass:$KEYCHAIN_PASS" 2>/dev/null

if [ ! -f "$KEYCHAIN" ]; then
  security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
fi
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null

echo "→ keychain 中的可用身份："
security find-identity -p codesigning "$KEYCHAIN"
echo "✓ 完成：$KEYCHAIN"
