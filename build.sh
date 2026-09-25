#!/bin/zsh
# Собирает «Загрузка видео.app» и кладёт его в /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Загрузка видео.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset

# Универсальная сборка: Apple Silicon и Intel
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target $arch-apple-macos14.0 \
    main.swift -o build/VideoLoader-$arch
done
lipo -create build/VideoLoader-arm64 build/VideoLoader-x86_64 -output "$APP/Contents/MacOS/VideoLoader"

swift make_icon.swift build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp build/icon.png "$APP/Contents/Resources/DockIcon.png"
cp -R chrome-extension "$APP/Contents/Resources/chrome-extension"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Загрузка видео</string>
  <key>CFBundleDisplayName</key><string>Загрузка видео</string>
  <key>CFBundleIdentifier</key><string>local.ohlexlexa.videoloader</string>
  <key>CFBundleExecutable</key><string>VideoLoader</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.3</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>local.ohlexlexa.videoloader</string>
      <key>CFBundleURLSchemes</key><array><string>videoloader</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Расширение для Safari (appex внутри приложения). Safari держит его включённым, только если
# оно подписано сертификатом разработчика (бесплатного аккаунта Xcode хватает, но подпись
# действует только на этом Mac). Нет сертификата — приложение собирается без Safari.
# NO_SAFARI=1 ./build.sh — сборка для релиза: без Safari и без личного сертификата в подписи.
IDENTITY=""
[[ -z "${NO_SAFARI:-}" ]] && IDENTITY=$(security find-identity -v -p codesigning | awk '/"Apple Development/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  EXT="$APP/Contents/PlugIns/VideoLoader Safari.appex"
  mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
  for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -swift-version 5 -target $arch-apple-macos14.0 -application-extension \
      -module-name VideoLoaderSafari safari/SafariWebExtensionHandler.swift \
      -Xlinker -e -Xlinker _NSExtensionMain -o build/Safari-$arch
  done
  lipo -create build/Safari-arm64 build/Safari-x86_64 -output "$EXT/Contents/MacOS/VideoLoaderSafari"
  cp -R chrome-extension/ "$EXT/Contents/Resources/"
  cat > "$EXT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Загрузка видео</string>
  <key>CFBundleDisplayName</key><string>Загрузка видео</string>
  <key>CFBundleIdentifier</key><string>local.ohlexlexa.videoloader.safari</string>
  <key>CFBundleExecutable</key><string>VideoLoaderSafari</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>1.3</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.Safari.web-extension</string>
    <key>NSExtensionPrincipalClass</key><string>SafariWebExtensionHandler</string>
  </dict>
</dict>
</plist>
PLIST
  cat > build/safari.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
</dict>
</plist>
PLIST
  codesign --force --timestamp=none --entitlements build/safari.entitlements -s "$IDENTITY" "$EXT"
  codesign --force --timestamp=none -s "$IDENTITY" "$APP"
else
  [[ -z "${NO_SAFARI:-}" ]] && echo "Нет сертификата Apple Development — собираю без расширения для Safari"
  codesign --force --deep -s - "$APP"
fi

rm -rf "/Applications/Загрузка видео.app"
cp -R "$APP" /Applications/
# «Своя» иконка ставится после подписи: подпись её не допускает, а macOS не затемняет её в тёмном режиме
swift set_icon.swift "/Applications/Загрузка видео.app" build/icon.png
touch "/Applications/Загрузка видео.app"
echo "Готово: /Applications/Загрузка видео.app"
