#!/bin/bash

# Create the app bundle structure
mkdir -p HelloMenuBar.app/Contents/MacOS
mkdir -p HelloMenuBar.app/Contents/Resources

# Copy the Info.plist
cp Info.plist HelloMenuBar.app/Contents/

# Compile the Swift code
swiftc -o HelloMenuBar.app/Contents/MacOS/HelloMenuBar main.swift

# Make the binary executable
chmod +x HelloMenuBar.app/Contents/MacOS/HelloMenuBar

echo "App compiled successfully. Run with: open HelloMenuBar.app"
