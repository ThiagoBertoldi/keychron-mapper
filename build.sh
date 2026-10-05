#!/bin/zsh
# Compila o KeychronMapper.app. Use "./build.sh install" para copiar para /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/KeychronMapper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos13 \
    -o "$APP/Contents/MacOS/KeychronMapper" Sources/main.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.keychron-mapper</string>
    <key>CFBundleName</key><string>KeychronMapper</string>
    <key>CFBundleExecutable</key><string>KeychronMapper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Necessário para corrigir o tipo de teclado (ANSI).</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "OK: $APP"

if [[ "${1:-}" == "install" ]]; then
    osascript -e 'quit app "KeychronMapper"' 2>/dev/null || true; sleep 1
    rm -rf /Applications/KeychronMapper.app
    cp -R "$APP" /Applications/
    open /Applications/KeychronMapper.app
    echo "Instalado em /Applications/KeychronMapper.app"
fi
