#!/bin/bash

echo "Compiling Swift files..."
mkdir -p build

# Compile the Swift files into a macOS application
swiftc -o build/NetworkSpeedMonitor \
    src/SpeedMonitor.swift \
    src/main.swift \
    -framework AppKit # \
    # -enable-hardened-runtime

# Sign the application with entitlements
# codesign --force --sign - \
#     --entitlements NetworkSpeedMonitor.entitlements \
#     --options runtime \
#     build/NetworkSpeedMonitor

# Check if compilation and signing were successful
if [ $? -eq 0 ]; then
    echo "Compilation and signing successful!"
    echo "Running application..."
    
    # Run the application
    ./build/NetworkSpeedMonitor
else
    echo "Compilation or signing failed. Check for errors."
    exit 1
fi
