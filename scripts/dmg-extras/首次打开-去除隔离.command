#!/bin/bash
# 本 fork 的 DMG 为 ad-hoc 签名（无 Apple Developer ID 公证）。
# 从浏览器下载后，macOS 可能报「已损坏 / 无法打开」。
# 双击本脚本即可去掉隔离属性；也可在终端手动执行同类命令。

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_IN_DMG="$HERE/Glint.app"
APP_IN_APPS="/Applications/Glint.app"

echo "========================================"
echo "  Glint（二开）— 去除隔离 / 首次打开"
echo "========================================"
echo ""
echo "本包未使用 Apple 公证，系统可能误报「已损坏」。"
echo "正在清除 com.apple.quarantine …"
echo ""

cleared=0

if [[ -d "$APP_IN_APPS" ]]; then
  xattr -dr com.apple.quarantine "$APP_IN_APPS" 2>/dev/null || true
  echo "✓ 已处理: $APP_IN_APPS"
  cleared=1
fi

if [[ -d "$APP_IN_DMG" ]]; then
  xattr -dr com.apple.quarantine "$APP_IN_DMG" 2>/dev/null || true
  echo "✓ 已处理: $APP_IN_DMG"
  cleared=1
fi

# 若用户从「下载」直接挂载，DMG 本身有时也带隔离
for dmg in "$HOME"/Downloads/Glint-*.dmg; do
  if [[ -f "$dmg" ]]; then
    xattr -dr com.apple.quarantine "$dmg" 2>/dev/null || true
    echo "✓ 已处理: $dmg"
  fi
done

if [[ "$cleared" -eq 0 ]]; then
  echo "未找到 Glint.app。"
  echo "请先把 Glint.app 拖到「应用程序」文件夹，再双击本脚本。"
  echo ""
  echo "或在终端手动执行："
  echo "  xattr -dr com.apple.quarantine /Applications/Glint.app"
  echo ""
  read -r -p "按回车关闭…"
  exit 1
fi

echo ""
echo "完成。正在尝试打开应用…"
if [[ -d "$APP_IN_APPS" ]]; then
  open "$APP_IN_APPS" || true
elif [[ -d "$APP_IN_DMG" ]]; then
  open "$APP_IN_DMG" || true
fi

echo ""
echo "若仍无法打开：系统设置 → 隐私与安全性 → 仍要打开"
echo "或右键 Glint.app → 打开。"
echo ""
read -r -p "按回车关闭…"
