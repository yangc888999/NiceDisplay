#!/bin/bash
# build.sh — 构建 NiceDisplay.app（菜单栏应用 + 内置 dlite 引擎 + Metro 图标），并做 ad-hoc 签名
set -e
cd "$(dirname "$0")"

APP="NiceDisplay.app"
SRC="dlite.c"
APPSRC="DliteApp.m"
ICONSRC="mkicon.m"

echo "==> 清理旧产物"
rm -rf "$APP" dmg_stage
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译引擎 dlite"
clang -O2 -o "$APP/Contents/MacOS/dlite" "$SRC" \
    -framework CoreGraphics -framework IOKit -framework Foundation

echo "==> 编译菜单栏应用 NiceDisplay"
clang -O2 -fobjc-arc -o "$APP/Contents/MacOS/NiceDisplay" "$APPSRC" \
    -framework Cocoa -framework Carbon -framework CoreAudio -framework CoreGraphics -framework ApplicationServices

echo "==> 生成 Metro 图标"
clang -O2 -fobjc-arc -o /tmp/mkicon "$ICONSRC" -framework ApplicationServices
rm -rf /tmp/nicedisplay.iconset
/tmp/mkicon /tmp/nicedisplay.iconset
mkdir -p "$APP/Contents/Resources"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" /tmp/nicedisplay.iconset
echo "    AppIcon.icns 已生成"

echo "==> 写入 Info.plist"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> 签名"
# 只用 ad-hoc（--sign -）。
# ⚠️ 绝对不要再换成自签名证书：证书只在本机登录钥匙串受信任，而 TCC 按系统级信任链校验，
#    会导致勾了辅助功能也对不上身份（AXIsProcessTrusted 恒为 0）。
# ⚠️ 任何重新签名都会让已授予的辅助功能授权作废，必须重新勾选 —— 所以非必要不要重新签名/重编译。
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -print0 2>/dev/null | xargs -0 xattr -c 2>/dev/null || true
codesign --force --sign - "$APP/Contents/MacOS/dlite" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# ---- 打包 DMG（拖拽式安装盘：app + 安装说明 + 「应用程序」快捷方式）----
DMG="NiceDisplay-1.0.dmg"
echo "==> 打包 $DMG"
mkdir -p dmg_stage
cp -R "$APP" dmg_stage/
[ -f 安装说明.txt ] && cp 安装说明.txt dmg_stage/
ln -s /Applications "dmg_stage/应用程序"
hdiutil create -volname "NiceDisplay" -srcfolder dmg_stage -ov -format UDZO "$DMG" >/dev/null
rm -rf dmg_stage

echo "==> 完成"
echo "    app : $(pwd)/$APP"
echo "    dmg : $(pwd)/$DMG"
echo "    安装: 打开 dmg，把 NiceDisplay.app 拖进「应用程序」"
echo "    重装: sudo rm -rf /Applications/Dlite.app /Applications/NiceDisplay.app && cp -R $APP /Applications/"
echo "    自检: $APP/Contents/MacOS/NiceDisplay --selftest"
