#!/usr/bin/env bash
# 自用测试打包：用户明确允许无开发者证书、无内置翻译密钥（2026-11-23）。
# 独立身份 + ad-hoc 签名；只输出 DMG / ZIP / 校验和，不调用正式发布脚本、不创建更新清单或 Release。
set -euo pipefail

ARCH="${ARCH:-arm64}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "ARCH 只能是 arm64 或 x86_64" >&2; exit 1 ;;
esac

M="$(cd "$(dirname "$0")" && pwd)"
OUT="$M/build/test-package"
NAME="Kitty Tools Test"
TEST_ID="com.yy.kitty-tools.native.test"
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kitty-test-package.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# 命令行的空值优先于可选的本地 Secrets.xcconfig；无需生成或读取任何密钥文件。
# Xcode 26.6 / Swift 6.3.3 在现有 NSHostingView 子类的 EarlyPerfInliner 上崩溃（Actions #1）。
# 自用包只验证功能，关闭优化；正式 Release 配置不变，后续换编译器后再验证优化构建。
# 只覆盖 APP_PRODUCT_NAME，不能覆盖 PRODUCT_NAME：后者会把 XPC / 扩展 target 也改成同名。
xcodebuild archive \
  -project "$M/KittyTools.xcodeproj" -scheme KittyTools -configuration Release \
  -destination 'generic/platform=macOS' -jobs 2 \
  -archivePath "$WORK/KittyTools.xcarchive" -derivedDataPath "$WORK/DerivedData" \
  ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
  SWIFT_OPTIMIZATION_LEVEL=-Onone \
  APP_PRODUCT_NAME="$NAME" BUNDLE_ID_SUFFIX=.test \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ZHIPU_BUILTIN_KEY= -quiet

APP="$WORK/KittyTools.xcarchive/Products/Applications/$NAME.app"
PLIST="$APP/Contents/Info.plist"
[[ -d "$APP" ]] || { echo "没有生成测试 App" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == "$TEST_ID" ]] \
  || { echo "测试包的 Bundle ID 没有隔离" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
COMMIT="$(git -C "$M" rev-parse --short=12 HEAD)"
BASE="KittyTools-Test_${VERSION}_${COMMIT}_${ARCH}"

# 删除整个键，而非留下空值或未展开的占位符；测试版不能带内置服务凭据。
/usr/bin/plutil -remove KittyBuiltinZhipuKey "$PLIST"

# Finder 菜单的双向通信只信任原作者签名。测试包不嵌入这项扩展，不放宽正式版的信任边界。
rm -rf "$APP/Contents/PlugIns/KittyToolsFinder.appex"
NP="$APP/Contents/XPCServices/KittyToolsNowPlaying.xpc"
[[ -d "$NP" ]] || { echo "缺少正在播放服务" >&2; exit 1; }

for BIN in "$APP/Contents/MacOS/$NAME" "$NP/Contents/MacOS/KittyToolsNowPlaying"; do
  [[ "$(lipo -archs "$BIN")" == "$ARCH" ]] \
    || { echo "可执行文件的架构与安装包不一致" >&2; exit 1; }
done

# 从里往外签名；保留录音、日历、Apple Events 的应用权利，不生成 get-task-allow。
# 若 Xcode 嵌入了 Swift 兼容库，也要一起签，不能靠 --deep 把主 App 的 entitlements 灌进子进程。
while IFS= read -r -d '' LIBRARY; do
  codesign --force --sign - --timestamp=none "$LIBRARY"
done < <(find "$APP" -type f -name '*.dylib' -print0)
codesign --force --sign - --timestamp=none --options runtime "$NP"
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$M/Config/KittyTools.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
SIGNATURE="$(codesign -dv "$APP" 2>&1)"
[[ "$SIGNATURE" == *Signature=adhoc* ]] \
  || { echo "测试包应当使用 ad-hoc 签名" >&2; exit 1; }
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
[[ "$ENTITLEMENTS" != *get-task-allow* ]] \
  || { echo "测试包不应带 get-task-allow" >&2; exit 1; }

mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/$NAME.app"
ln -s /Applications "$WORK/dmg/Applications"
cp "$M/TEST-PACKAGE.md" "$OUT/README.md"
cp "$M/TEST-PACKAGE.md" "$WORK/dmg/README.md"
hdiutil create -volname "$NAME" -srcfolder "$WORK/dmg" -format UDZO -ov "$OUT/$BASE.dmg"
hdiutil verify "$OUT/$BASE.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$BASE.zip"

# ZIP 内保留可执行权限；解出来再验签，上传 Artifacts 的是归档而不是裸 .app 目录。
ditto -x -k "$OUT/$BASE.zip" "$WORK/unpacked"
codesign --verify --deep --strict "$WORK/unpacked/$NAME.app"
(
  cd "$OUT"
  shasum -a 256 "$BASE.dmg" "$BASE.zip" > "$BASE.sha256"
)
{
  printf 'App: %s\nBundle ID: %s\nVersion: %s\nArchitecture: %s\n' "$NAME" "$TEST_ID" "$VERSION" "$ARCH"
  printf 'Commit: %s\n' "$(git -C "$M" rev-parse HEAD)"
  printf 'Optimization: -Onone (functional testing only)\nSigning: ad-hoc (no developer certificate, no notarization)\nBuiltin translation key: absent\nFinder extension: omitted\n'
  xcodebuild -version
  xcrun swift --version
} > "$OUT/BUILD-INFO.txt"
printf '测试包已生成：\n%s\n%s\n' "$OUT/$BASE.dmg" "$OUT/$BASE.zip"
