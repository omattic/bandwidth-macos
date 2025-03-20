import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var speedMonitor: SpeedMonitor!
    private var speedTextField: NSTextField!
    private var timer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the speed monitor
        speedMonitor = SpeedMonitor()
        
        // Create a window
        let windowRect = NSRect(x: 100, y: 100, width: 400, height: 150)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Network Speed Monitor"
        window.center()
        
        // Set up the content view
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        
        // Add a text field to display the speed
        speedTextField = NSTextField(frame: NSRect(x: 20, y: 60, width: 360, height: 60))
        speedTextField.isEditable = false
        speedTextField.isBezeled = false
        speedTextField.drawsBackground = false
        speedTextField.alignment = .center
        speedTextField.font = NSFont.systemFont(ofSize: 14)
        speedTextField.stringValue = "Measuring network speed..."
        contentView.addSubview(speedTextField)
        
        // Add a quit button
        let quitButton = NSButton(frame: NSRect(x: 150, y: 20, width: 100, height: 30))
        quitButton.title = "Quit"
        quitButton.bezelStyle = .rounded
        quitButton.target = NSApp
        quitButton.action = #selector(NSApplication.terminate(_:))
        contentView.addSubview(quitButton)
        
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        
        // Start the timer to update speed every second
        timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(updateSpeed), userInfo: nil, repeats: true)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Invalidate timer when application is terminating
        timer?.invalidate()
    }
    
    @objc private func updateSpeed() {
        speedMonitor.measureSpeed { downloadSpeed, uploadSpeed in
            // Update UI on the main thread
            DispatchQueue.main.async {
                let downloadSpeedFormatted = String(format: "%.2f", downloadSpeed)
                let uploadSpeedFormatted = String(format: "%.2f", uploadSpeed)
                self.speedTextField.stringValue = "Download: \(downloadSpeedFormatted) KB/s\nUpload: \(uploadSpeedFormatted) KB/s"
            }
        }
    }
}

// Create and start the application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
