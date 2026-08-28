#!/bin/zsh
# Spike 03 build: hand-assembled FSKit module bundle (no Xcode project).
# Usage: build.sh <workdir> [signing-identity]   (identity defaults to "-", ad-hoc)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
W="${1:?usage: build.sh <workdir> [identity]}"
IDENTITY="${2:--}"
APP="$W/HealthFSHost.app"
APPEX="$APP/Contents/Extensions/HealthFS.appex"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APPEX/Contents/MacOS"

echo "== compiling extension =="
swiftc -parse-as-library -O \
  -target arm64-apple-macos26.0 -sdk "$SDK" \
  "$HERE/HealthFS.swift" -o "$APPEX/Contents/MacOS/HealthFS"

echo "== compiling host stub =="
echo 'print("HealthFSHost: extension container app")' > "$W/host.swift"
swiftc -O -target arm64-apple-macos26.0 -sdk "$SDK" \
  "$W/host.swift" -o "$APP/Contents/MacOS/HealthFSHost"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>HealthFSHost</string>
  <key>CFBundleIdentifier</key><string>com.epoch-overlay.healthfs-host</string>
  <key>CFBundleName</key><string>HealthFSHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

cat > "$APPEX/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>HealthFS</string>
  <key>CFBundleIdentifier</key><string>com.epoch-overlay.healthfs</string>
  <key>CFBundleName</key><string>HealthFS</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>EXAppExtensionAttributes</key><dict>
    <key>EXExtensionPointIdentifier</key><string>com.apple.fskit.fsmodule</string>
    <key>FSShortName</key><string>healthfs</string>
    <key>FSSupportsBlockResources</key><false/>
    <key>FSSupportsGenericURLResources</key><false/>
    <key>FSSupportsPathURLs</key><true/>
    <key>FSRequiresSecurityScopedPathURLResources</key><false/>
    <key>FSActivateOptionSyntax</key><dict>
      <key>shortOptions</key><string>o:</string>
    </dict>
    <key>FSMediaTypes</key><dict/>
    <key>FSPersonalities</key><dict/>
  </dict>
</dict></plist>
PLIST

cat > "$W/ext.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.developer.fskit.fsmodule</key><true/>
  <key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST

echo "== signing (identity: $IDENTITY) =="
codesign -f -s "$IDENTITY" --entitlements "$W/ext.entitlements" -o runtime "$APPEX"
codesign -f -s "$IDENTITY" -o runtime "$APP"

echo "== registering =="
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
pluginkit -a "$APPEX" || true
sleep 1
pluginkit -m -v -p com.apple.fskit.fsmodule | grep -i health || echo "NOT LISTED by pluginkit"
