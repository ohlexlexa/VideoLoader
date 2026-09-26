#!/bin/zsh
# Собирает DownMax.app и кладёт его в /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DownMax.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset

# Универсальная сборка: Apple Silicon и Intel
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target $arch-apple-macos14.0 \
    Sources/*.swift -o build/DownMax-$arch
done
lipo -create build/DownMax-arm64 build/DownMax-x86_64 -output "$APP/Contents/MacOS/DownMax"

swift scripts/make_icon.swift build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp build/icon.png "$APP/Contents/Resources/DockIcon.png"
cp -R chrome-extension "$APP/Contents/Resources/chrome-extension"
# aria2c для торрентов — свой, внутри приложения (как собран — vendor/build-aria2.sh)
mkdir -p "$APP/Contents/Helpers"
cp vendor/aria2c "$APP/Contents/Helpers/aria2c"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DownMax</string>
  <key>CFBundleDisplayName</key><string>DownMax</string>
  <key>CFBundleIdentifier</key><string>local.ohlexlexa.downmax</string>
  <key>CFBundleExecutable</key><string>DownMax</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>7</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>local.ohlexlexa.downmax</string>
      <key>CFBundleURLSchemes</key><array><string>downmax</string><string>videoloader</string></array>
    </dict>
    <dict>
      <key>CFBundleURLName</key><string>BitTorrent magnet</string>
      <key>CFBundleURLSchemes</key><array><string>magnet</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Торрент-файл</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>org.bittorrent.torrent</string></array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>org.bittorrent.torrent</string>
      <key>UTTypeDescription</key><string>Торрент-файл</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>torrent</string></array>
        <key>public.mime-type</key><array><string>application/x-bittorrent</string></array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Расширение для Safari (appex внутри приложения). Safari держит его включённым, только если
# оно подписано сертификатом разработчика (бесплатного аккаунта Xcode хватает, но подпись
# действует только на этом Mac). Нет сертификата — приложение собирается без Safari.
# NO_SAFARI=1 ./build.sh — сборка для релиза: без Safari, ad-hoc (личный сертификат на чужих Mac не работает
# и раскрывает почту из него). Только такая сборка обновляется из релизов (см. updater.swift).
IDENTITY=""
[[ -z "${NO_SAFARI:-}" ]] && IDENTITY=$(security find-identity -v -p codesigning | awk '/"Apple Development/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  EXT="$APP/Contents/PlugIns/DownMax Safari.appex"
  mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
  for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -swift-version 5 -target $arch-apple-macos14.0 -application-extension \
      -module-name DownMaxSafari safari/SafariWebExtensionHandler.swift \
      -Xlinker -e -Xlinker _NSExtensionMain -o build/Safari-$arch
  done
  lipo -create build/Safari-arm64 build/Safari-x86_64 -output "$EXT/Contents/MacOS/DownMaxSafari"
  cp -R chrome-extension/ "$EXT/Contents/Resources/"
  cat > "$EXT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DownMax</string>
  <key>CFBundleDisplayName</key><string>DownMax</string>
  <key>CFBundleIdentifier</key><string>local.ohlexlexa.downmax.safari</string>
  <key>CFBundleExecutable</key><string>DownMaxSafari</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>7</string>
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
  codesign --force --timestamp=none -s "$IDENTITY" "$APP/Contents/Helpers/aria2c"
  codesign --force --timestamp=none -s "$IDENTITY" "$APP"
else
  [[ -z "${NO_SAFARI:-}" ]] && echo "Нет сертификата Apple Development — собираю без расширения для Safari"
  codesign --force --deep -s - "$APP"
fi

# До 2.0 приложение называлось «Загрузка видео»
rm -rf "/Applications/Загрузка видео.app" "/Applications/DownMax.app"
cp -R "$APP" /Applications/
# «Своя» иконка ставится после подписи: подпись её не допускает, а macOS не затемняет её в тёмном режиме
swift scripts/set_icon.swift "/Applications/DownMax.app" build/icon.png
touch "/Applications/DownMax.app"
echo "Готово: /Applications/DownMax.app"
