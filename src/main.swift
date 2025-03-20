import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var speedMonitor: SpeedMonitor!
    private var timer: Timer?
    private var showMaxSpeed = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the speed monitor
        speedMonitor = SpeedMonitor()
        
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
            let boldAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
            ]
            
            let initialText = NSMutableAttributedString(string: "   0.0", attributes: attrs)
            initialText.append(NSAttributedString(string: "↓", attributes: boldAttrs))
            initialText.append(NSAttributedString(string: "   0.0", attributes: attrs))
            initialText.append(NSAttributedString(string: "↑", attributes: boldAttrs))
            
            button.attributedTitle = initialText
        }
        
        // Create the menu
        let menu = NSMenu()
        let modeMenuItem = NSMenuItem(
            title: "Show Max Speed",
            action: #selector(toggleMode),
            keyEquivalent: "m"
        )
        let resetMaxMenuItem = NSMenuItem(
            title: "Reset Max Speed",
            action: #selector(resetMaxSpeed),
            keyEquivalent: "r"
        )
        menu.addItem(modeMenuItem)
        menu.addItem(resetMaxMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        
        // Start the timer to update speed every second
        timer = Timer.scheduledTimer(timeInterval: 2.0, target: self, selector: #selector(updateSpeed), userInfo: nil, repeats: true)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }
    
    @objc private func toggleMode() {
        showMaxSpeed.toggle()
        if let menuItem = statusItem.menu?.items.first {
            menuItem.title = showMaxSpeed ? "Show Live Speed" : "Show Max Speed"
        }
    }
    
    @objc private func resetMaxSpeed() {
        speedMonitor.resetMaxSpeeds()
    }
    
    @objc private func updateSpeed() {
        speedMonitor.measureSpeed { currentDown, currentUp, maxDown, maxUp in
            DispatchQueue.main.async {
                if let button = self.statusItem.button {
                    let down = self.showMaxSpeed ? maxDown : currentDown
                    let up = self.showMaxSpeed ? maxUp : currentUp
                    
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                    ]
                    let boldAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
                    ]
                    
                    let text = NSMutableAttributedString(
                        string: String(format: "%6.1f", down),
                        attributes: attrs
                    )
                    text.append(NSAttributedString(string: "↓", attributes: boldAttrs))
                    text.append(NSAttributedString(
                        string: String(format: "%6.1f", up),
                        attributes: attrs
                    ))
                    text.append(NSAttributedString(string: "↑", attributes: boldAttrs))
                    
                    button.attributedTitle = text
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
