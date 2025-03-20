import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var speedMonitor: SpeedMonitor!
    private var speedTest: SpeedTest!
    private var timer: Timer?
    private var showMaxSpeed = false
    private var isTestingSpeed = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the speed monitor
        speedMonitor = SpeedMonitor()
        speedTest = SpeedTest()
        
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
            let boldAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
            ]
            
            let initialText = NSMutableAttributedString()
            initialText.append(NSAttributedString(string: "   0.0", attributes: attrs))
            initialText.append(NSAttributedString(string: "↓", attributes: boldAttrs))
            initialText.append(NSAttributedString(string: "   0.0", attributes: attrs))
            initialText.append(NSAttributedString(string: "↑", attributes: boldAttrs))
            
            button.attributedTitle = initialText
        }
        
        // Create the menu
        let menu = NSMenu()
        
        // Add Speed Test submenu
        let speedTestMenu = NSMenu()
        let speedTestItem = NSMenuItem(title: "Speed Test", action: nil, keyEquivalent: "")
        speedTestItem.submenu = speedTestMenu
        
        speedTestMenu.addItem(NSMenuItem(title: "Test (10 MB)", action: #selector(startSpeedTest_small), keyEquivalent: "1"))
        speedTestMenu.addItem(NSMenuItem(title: "Test (100 MB)", action: #selector(startSpeedTest_medium), keyEquivalent: "2"))
        speedTestMenu.addItem(NSMenuItem(title: "Test (1 GB)", action: #selector(startSpeedTest_large), keyEquivalent: "3"))
        
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
        menu.addItem(speedTestItem)
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
                    
                    let text = NSMutableAttributedString()
                    
                    if self.showMaxSpeed {
                        text.append(NSAttributedString(string: "speed:", attributes: attrs))
                    }
                    
                    text.append(NSAttributedString(
                        string: String(format: "%6.1f", down),
                        attributes: attrs
                    ))
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
    
    @objc private func startSpeedTest_small() { startSpeedTest(size: .small) }
    @objc private func startSpeedTest_medium() { startSpeedTest(size: .medium) }
    @objc private func startSpeedTest_large() { startSpeedTest(size: .large) }
    
    private func startSpeedTest(size: SpeedTest.TestSize) {
        guard !isTestingSpeed else { return }
        isTestingSpeed = true
        
        // Switch to max speed mode
        if !showMaxSpeed {
            showMaxSpeed = true
            if let menuItem = statusItem.menu?.items.first {
                menuItem.title = "Show Live Speed"
            }
        }
        
        if let button = statusItem.button {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
            button.attributedTitle = NSAttributedString(string: "Testing...", attributes: attrs)
        }
        
        speedTest.startTest(size: size) { progress in
            // Update progress if needed
        } completion: { speed in
            DispatchQueue.main.async {
                self.isTestingSpeed = false
                if let speed = speed {
                    print("Test completed: \(speed) Mbps")
                } else {
                    print("Test failed")
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
