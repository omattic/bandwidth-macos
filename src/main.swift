import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var speedMonitor: SpeedMonitor!
    private var timer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the speed monitor
        speedMonitor = SpeedMonitor()
        
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.title = "↑000↓000"
        }
        
        // Create the menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        
        // Start the timer to update speed every second
        timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(updateSpeed), userInfo: nil, repeats: true)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }
    
    @objc private func updateSpeed() {
        speedMonitor.measureSpeed { downloadSpeed, uploadSpeed in
            DispatchQueue.main.async {
                let downloadSpeedFormatted = String(format: "%.1f", downloadSpeed)
                let uploadSpeedFormatted = String(format: "%.1f", uploadSpeed)
                if let button = self.statusItem.button {
                    button.title = "↑\(uploadSpeedFormatted) ↓\(downloadSpeedFormatted) KB/s"
                }
            }
        }
    }
}

// Create and start the application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
