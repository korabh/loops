#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
kit=$(cd "$here/.." && pwd -P)
dest=${1:-$HOME/Applications}
repo_key=""
if [ -n "${LOOPS_REPO:-}" ]; then repo_key="  <key>LoopsRepo</key><string>$(cd "$LOOPS_REPO" && pwd -P)</string>"; fi

work="$here/.build/xcode"
plist="$work/Info.plist"
app="$here/.build/Loops.app"
icons="$here/.build/Loops.iconset"
mkdir -p "$work"
cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Loops</string>
  <key>CFBundleIdentifier</key><string>io.github.korabh.loops</string>
  <key>CFBundleName</key><string>Loops</string>
  <key>CFBundleDisplayName</key><string>Loops</string>
  <key>CFBundleIconFile</key><string>Loops</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>NSHumanReadableCopyright</key><string>Developed by Korab Hoxha</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
$repo_key
</dict>
</plist>
PLIST
xcodegen generate --quiet --spec "$here/project.yml" --project "$work"
xcodebuild -quiet -project "$work/Loops.xcodeproj" -scheme Loops -configuration Release -derivedDataPath "$work/derived" \
  -destination "platform=macOS,arch=$(uname -m)" LOOPS_INFO_PLIST="$plist" build
rm -rf "$app" "$icons"
mkdir -p "$icons"
cp -R "$work/derived/Build/Products/Release/Loops.app" "$app"
"$app/Contents/MacOS/Loops" --icon "$icons/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$icons/icon_512x512@2x.png" --out "$icons/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  [ "$s" = 512 ] || sips -z "$d" "$d" "$icons/icon_512x512@2x.png" --out "$icons/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$icons" -o "$app/Contents/Resources/Loops.icns"
mkdir -p "$app/Contents/Resources/bin"
cp "$kit"/plugins/loops/bin/* "$app/Contents/Resources/bin/"
chmod +x "$app/Contents/Resources/bin/"*
codesign --force --sign - "$app" >/dev/null 2>&1
mkdir -p "$dest"
rm -rf "$dest/Loops.app"
cp -R "$app" "$dest/Loops.app"
echo "$dest/Loops.app"
