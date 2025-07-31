#!/bin/bash
# Check if executable exists
if [ ! -f ./build/NetworkSpeedMonitor ]; then
    echo "Executable not found! Please build the project first."
    exit 1
fi

# Launch lldb with the executable
lldb ./build/NetworkSpeedMonitor
