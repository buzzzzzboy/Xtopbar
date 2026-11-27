#!/usr/bin/env bash
# 工作列小工具的纯逻辑测试（不碰 AppKit，独立编译一支小程序跑）
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macosx26.0 \
  -o build/test-widgets Sources/TaskbarWidgets.swift Sources/SystemStats.swift scripts/tests/widgets/main.swift
./build/test-widgets
