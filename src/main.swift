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
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        
        // Start the timer to update speed every second
        timer = Timer.scheduledTimer(timeInterval: 2.0, target: self, selector: #selector(updateSpeed), userInfo: nil, repeats: true)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }
    
    @objc private func updateSpeed() {
        speedMonitor.measureSpeed { downloadSpeed, uploadSpeed in
            DispatchQueue.main.async {
                if let button = self.statusItem.button {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                    ]
                    let boldAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
                    ]
                    
                    let text = NSMutableAttributedString(
                        string: String(format: "%6.1f", downloadSpeed),
                        attributes: attrs
                    )
                    text.append(NSAttributedString(string: "↓", attributes: boldAttrs))
                    text.append(NSAttributedString(
                        string: String(format: "%6.1f", uploadSpeed),
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
