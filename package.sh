#!/bin/bash

APP_NAME="NetworkSpeedMonitor"
APP_BUNDLE="$APP_NAME.app"
CONTENTS_DIR="build/$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Creating app bundle structure..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# First compile the application
swiftc -o "$MACOS_DIR/$APP_NAME" \
    src/NetworkQualityMonitor.swift \
    src/SpeedMonitor.swift \
    src/SpeedTest.swift \
    src/main.swift \
    -framework AppKit

if [ $? -ne 0 ]; then
    echo "Compilation failed. Aborting."
    exit 1
fi

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.carlos.networkspeedmonitor</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Create empty icon file (you can replace with a real icon later)
touch "$RESOURCES_DIR/AppIcon.icns"

echo "Setting executable permissions..."
chmod +x "$MACOS_DIR/$APP_NAME"

echo "App bundle successfully created at build/$APP_BUNDLE"
echo "You can now copy this to your Applications folder:"
echo "cp -r build/$APP_BUNDLE /Applications/"
