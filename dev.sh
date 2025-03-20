#!/bin/bash

echo "Compiling Swift files..."
mkdir -p build

# Compile the Swift files into a macOS application
swiftc -o build/NetworkSpeedMonitor \
    src/SpeedMonitor.swift \
    src/main.swift \
    -framework AppKit

# Check if compilation was successful
if [ $? -eq 0 ]; then
    echo "Compilation successful!"
    echo "Running application..."
    
    # Run the application
    ./build/NetworkSpeedMonitor
else
    echo "Compilation failed. Check for errors."
    exit 1
fi
