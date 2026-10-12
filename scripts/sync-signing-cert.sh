#!/usr/bin/env bash
# 在多台电脑之间同步 Xtopbar 的签名证书（build.sh 钉死的那张）。
#
# 为什么需要：TCC（屏幕录制 / 辅助功能）认的是签名证书的哈希。
# 两台电脑各用各的证书，签出来的 App 在 macOS 看来是两个不同的 App，
# 用户装了另一台发的版本就得重新授权。把同一张证书（含私钥）搬过去，
# 两台签出来就完全一样。
#
# 用法：
#   有证书的电脑：  ./scripts/sync-signing-cert.sh export [输出.p12]
#   要补证书的电脑：./scripts/sync-signing-cert.sh import <文件.p12>
#
# .p12 里有私钥：设一个传输密码，用 AirDrop / U 盘搬，导入完就删掉，别提交进 git。
set -euo pipefail
cd "$(dirname "$0")/.."

KEYCHAIN="${XTOPBAR_KEYCHAIN:-$HOME/Library/Keychains/xtopbar-signing.keychain-db}"
KEYCHAIN_PASS="xtopbar"
# 和 build.sh 的 EXPECTED_CERT_SHA1 一致（从那里读，免得两处不同步）
SHA1="${EXPECTED_CERT_SHA1:-$(sed -n 's/^EXPECTED_CERT_SHA1="\${EXPECTED_CERT_SHA1:-\([0-9A-Fa-f]*\)}"$/\1/p' build.sh)}"
[ -n "$SHA1" ] || { echo "✗ 读不到 build.sh 里的 EXPECTED_CERT_SHA1" >&2; exit 1; }
SHA1="$(printf '%s' "$SHA1" | tr 'a-f' 'A-F')"

has_cert() {
  [ -f "$KEYCHAIN" ] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$SHA1"
}

ask_password() {
  local p1 p2
  read -r -s -p "$1" p1; echo >&2
  read -r -s -p "再输入一次：" p2; echo >&2
  [ "$p1" = "$p2" ] || { echo "✗ 两次密码不一样" >&2; exit 1; }
  [ -n "$p1" ] || { echo "✗ 密码不能为空" >&2; exit 1; }
  printf '%s' "$p1"
}

cmd="${1:-}"
case "$cmd" in
  export)
    OUT="${2:-$HOME/Desktop/xtopbar-signing.p12}"
    has_cert || { echo "✗ 这台电脑的 $KEYCHAIN 里没有 ${SHA1}，没法导出" >&2; exit 1; }
    PASS="$(ask_password "设定 .p12 传输密码：")"
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    # 独立 keychain 里只放 Xtopbar 的签名身份，整个导出即可
    security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$PASS" -o "$OUT"
    chmod 600 "$OUT"
    echo "✓ 已导出：$OUT"
    echo "  把它搬到另一台电脑后执行：./scripts/sync-signing-cert.sh import \"<路径>\""
    echo "  导入完记得删掉这个文件。"
    ;;

  import)
    IN="${2:-}"
    [ -f "$IN" ] || { echo "用法：$0 import <文件.p12>" >&2; exit 1; }
    if has_cert; then
      echo "✓ 已经有 ${SHA1}，不用导入"
      exit 0
    fi
    read -r -s -p ".p12 传输密码：" PASS; echo
    if [ ! -f "$KEYCHAIN" ]; then
      security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    fi
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security import "$IN" -k "$KEYCHAIN" -P "$PASS" -f pkcs12 \
      -T /usr/bin/codesign -T /usr/bin/security -A
    # 让 codesign 用私钥时不弹钥匙串授权框（无人值守构建）
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
    if has_cert; then
      echo "✓ 已导入 ${SHA1}，现在可以直接 ./build.sh / ./scripts/make-release.sh"
      echo "  记得删掉 $IN"
    else
      echo "✗ 导入了，但 keychain 里还是找不到 $SHA1 —— 这个 .p12 可能不是那张证书" >&2
      security find-identity -p codesigning "$KEYCHAIN" >&2
      exit 1
    fi
    ;;

  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
