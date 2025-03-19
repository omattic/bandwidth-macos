import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the status item in the menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.title = "hello"
            
            // Create the menu that appears when right-clicking
            let menu = NSMenu()
            
            // Add a quit option
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q"))
            
            // Set the menu
            statusItem?.menu = menu
        }
    }
    
    @objc func quit(_ sender: Any?) {
        NSApplication.shared.terminate(self)
    }
}

// Create the application and delegate
let app = NSApplication.shared
let delegate = AppDelegate()