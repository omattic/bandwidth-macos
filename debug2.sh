#!/bin/bash
# Check if executable exists
if [ ! -f ./build/NetworkSpeedMonitor ]; then
    echo "Executable not found! Please build the project first."
    exit 1
fi

# Interactive menu for NetworkSpeedMonitor options
echo "Select an option:"
echo "1) Show total Traffic"
echo "2) Reset total traffic"
read -p "Enter option: " opt
case $opt in
    1)
        lldb ./build/NetworkSpeedMonitor --show-total
        ;;
    2)
        lldb ./build/NetworkSpeedMonitor --reset-total
        ;;
    *)
        echo "Invalid option"
        ;;
esac
