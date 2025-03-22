#!/bin/bash

echo "Compiling Swift files..."
mkdir -p build

# Register default preferences if needed
defaults write com.carlos.networkspeedmonitor showLatency -bool true
defaults write com.carlos.networkspeedmonitor showPacketLoss -bool true
defaults write com.carlos.networkspeedmonitor showJitter -bool true

# Compile the Swift files into a macOS application
swiftc -o build/NetworkSpeedMonitor \
    src/NetworkQualityMonitor.swift \
    src/SpeedMonitor.swift \
    src/SpeedTest.swift \
    src/main.swift \
    -framework AppKit # \
    # -enable-hardened-runtime

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
