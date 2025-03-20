import AppKit
import Foundation

// First define PingMonitor class before using it
class PingMonitor {
    private var timer: Timer?
    private var currentLatency: Double = 0
    private let host = "1.1.1.1" // Cloudflare DNS for reliable ping
    
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.measureLatency()
        }
        timer?.fire()
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    func getCurrentLatency() -> Double {
        return currentLatency
    }
    
    private func measureLatency() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-W", "1", host]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try? process.run()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            if let timeStr = output.components(separatedBy: "time=").last?.components(separatedBy: " ").first,
               let time = Double(timeStr) {
                currentLatency = time
            }
        }
        
        process.waitUntilExit()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var speedMonitor: SpeedMonitor!
    private var speedTest: SpeedTest!
    private var pingMonitor: PingMonitor!
    private var timer: Timer?
    private var showMaxSpeed = false
    private var isTestingSpeed = false
    private var progressIndicator: NSProgressIndicator!
    private var cancelTest: (() -> Void)?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the monitors
        speedMonitor = SpeedMonitor()
        speedTest = SpeedTest()
        pingMonitor = PingMonitor()
        pingMonitor.start()
        
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Create and configure progress indicator
        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.isHidden = true
        progressIndicator.frame = NSRect(x: 2, y: 2, width: 16, height: 16)
        
        if let button = statusItem.button {
            button.frame = NSRect(x: 0, y: 0, width: button.frame.width + 20, height: button.frame.height)
            button.addSubview(progressIndicator)
            
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
        
        // Mode switching and control items
        let liveMenuItem = NSMenuItem(title: "Show Live", action: #selector(toggleMode), keyEquivalent: "l")
        let maxMenuItem = NSMenuItem(title: "Show Max", action: #selector(toggleMode), keyEquivalent: "m")
        let resetMaxMenuItem = NSMenuItem(title: "Reset Max", action: #selector(resetMaxSpeed), keyEquivalent: "r")
        let cancelTestMenuItem = NSMenuItem(title: "Cancel Test", action: #selector(cancelCurrentTest), keyEquivalent: "c")
        cancelTestMenuItem.isHidden = true
        
        menu.addItem(liveMenuItem)
        menu.addItem(maxMenuItem)
        menu.addItem(resetMaxMenuItem)
        menu.addItem(cancelTestMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        // Quick Test item
        let quickTestItem = NSMenuItem(title: "Quick Test", action: #selector(startQuickTest), keyEquivalent: "q")
        menu.addItem(quickTestItem)
        menu.addItem(NSMenuItem.separator())
        
        // Add Speed Test submenu
        let speedTestMenu = NSMenu()
        let speedTestItem = NSMenuItem(title: "Speed Test", action: nil, keyEquivalent: "")
        speedTestItem.submenu = speedTestMenu
        
        // Download tests
        let downloadMenu = NSMenu()
        let downloadItem = NSMenuItem(title: "Download Test", action: nil, keyEquivalent: "")
        downloadItem.submenu = downloadMenu
        downloadMenu.addItem(NSMenuItem(title: "Test (10 MB)", action: #selector(startDownloadTest_small), keyEquivalent: "1"))
        downloadMenu.addItem(NSMenuItem(title: "Test (100 MB)", action: #selector(startDownloadTest_medium), keyEquivalent: "2"))
        downloadMenu.addItem(NSMenuItem(title: "Test (1 GB)", action: #selector(startDownloadTest_large), keyEquivalent: "3"))
        
        // Upload tests
        let uploadMenu = NSMenu()
        let uploadItem = NSMenuItem(title: "Upload Test", action: nil, keyEquivalent: "")
        uploadItem.submenu = uploadMenu
        uploadMenu.addItem(NSMenuItem(title: "Test (10 MB)", action: #selector(startUploadTest_small), keyEquivalent: "4"))
        uploadMenu.addItem(NSMenuItem(title: "Test (100 MB)", action: #selector(startUploadTest_medium), keyEquivalent: "5"))
        uploadMenu.addItem(NSMenuItem(title: "Test (1 GB)", action: #selector(startUploadTest_large), keyEquivalent: "6"))
        
        speedTestMenu.addItem(downloadItem)
        speedTestMenu.addItem(uploadItem)
        speedTestMenu.addItem(NSMenuItem.separator())
        
        // Combined tests
        let combinedMenu = NSMenu()
        let combinedItem = NSMenuItem(title: "Combined Test", action: nil, keyEquivalent: "")
        combinedItem.submenu = combinedMenu
        
        combinedMenu.addItem(NSMenuItem(title: "Serial Test (10 MB)", action: #selector(startCombinedSerialTest_small), keyEquivalent: "7"))
        combinedMenu.addItem(NSMenuItem(title: "Serial Test (100 MB)", action: #selector(startCombinedSerialTest_medium), keyEquivalent: "8"))
        combinedMenu.addItem(NSMenuItem(title: "Serial Test (1 GB)", action: #selector(startCombinedSerialTest_large), keyEquivalent: "9"))
        combinedMenu.addItem(NSMenuItem.separator())
        combinedMenu.addItem(NSMenuItem(title: "Parallel Test (10 MB)", action: #selector(startCombinedParallelTest_small), keyEquivalent: ""))
        combinedMenu.addItem(NSMenuItem(title: "Parallel Test (100 MB)", action: #selector(startCombinedParallelTest_medium), keyEquivalent: ""))
        combinedMenu.addItem(NSMenuItem(title: "Parallel Test (1 GB)", action: #selector(startCombinedParallelTest_large), keyEquivalent: ""))
        
        speedTestMenu.addItem(combinedItem)
        
        menu.addItem(speedTestItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "Q"))
        statusItem.menu = menu
        
        // Update initial menu state
        maxMenuItem.isHidden = true  // Start in live mode
        updateMenuItemsEnabled(isTestRunning: false)
        
        // Start the timer to update speed every second
        timer = Timer.scheduledTimer(timeInterval: 2.0, target: self, selector: #selector(updateSpeed), userInfo: nil, repeats: true)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        pingMonitor.stop()
    }
    
    @objc private func toggleMode() {
        showMaxSpeed.toggle()
        if let modeMenuItem = statusItem.menu?.items.first(where: { $0.keyEquivalent == "m" }) {
            modeMenuItem.title = showMaxSpeed ? "Show Live" : "Show Max"
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
                    
                    // Always show current mode
                    let modeLabel = self.showMaxSpeed ? "[max] " : "[live] "
                    text.append(NSAttributedString(string: modeLabel, attributes: attrs))
                    
                    if !self.isTestingSpeed {
                        if self.showMaxSpeed {
                            text.append(NSAttributedString(string: "max:", attributes: attrs))
                        }
                    }
                    
                    // Add latency if available
                    let latency = self.pingMonitor.getCurrentLatency()
                    if latency > 0 {
                        text.append(NSAttributedString(string: String(format: "%3.0fms ", latency), attributes: attrs))
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
    
    @objc private func startQuickTest() {
        startSpeedTest(size: .medium, type: .combinedSerial)
    }
    
    @objc private func startDownloadTest_small() { startSpeedTest(size: SpeedTest.TestSize.small, type: SpeedTest.TestType.download) }
    @objc private func startDownloadTest_medium() { startSpeedTest(size: SpeedTest.TestSize.medium, type: SpeedTest.TestType.download) }
    @objc private func startDownloadTest_large() { startSpeedTest(size: SpeedTest.TestSize.large, type: SpeedTest.TestType.download) }
    
    @objc private func startUploadTest_small() { startSpeedTest(size: SpeedTest.TestSize.small, type: SpeedTest.TestType.upload) }
    @objc private func startUploadTest_medium() { startSpeedTest(size: SpeedTest.TestSize.medium, type: SpeedTest.TestType.upload) }
    @objc private func startUploadTest_large() { startSpeedTest(size: SpeedTest.TestSize.large, type: SpeedTest.TestType.upload) }
    
    @objc private func startCombinedSerialTest_small() { startSpeedTest(size: .small, type: .combinedSerial) }
    @objc private func startCombinedSerialTest_medium() { startSpeedTest(size: .medium, type: .combinedSerial) }
    @objc private func startCombinedSerialTest_large() { startSpeedTest(size: .large, type: .combinedSerial) }
    
    @objc private func startCombinedParallelTest_small() { startSpeedTest(size: .small, type: .combinedParallel) }
    @objc private func startCombinedParallelTest_medium() { startSpeedTest(size: .medium, type: .combinedParallel) }
    @objc private func startCombinedParallelTest_large() { startSpeedTest(size: .large, type: .combinedParallel) }
    
    private func startSpeedTest(size: SpeedTest.TestSize, type: SpeedTest.TestType) {
        guard !isTestingSpeed else { return }
        isTestingSpeed = true
        
        // Update menu state
        updateMenuItemsEnabled(isTestRunning: true)
        
        // Show and start progress indicator
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        
        // Switch to max speed mode
        if !showMaxSpeed {
            showMaxSpeed = true
            if let modeMenuItem = statusItem.menu?.items.first(where: { $0.keyEquivalent == "m" }) {
                modeMenuItem.title = "Show Live"
            }
        }
        
        if let button = statusItem.button {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
            let suffix = switch type {
                case .download: "↓..."
                case .upload: "↑..."
                case .combinedSerial: "↓↑..."
                case .combinedParallel: "⇅..."
            }
            let testingText = "speedtest: " + suffix
            button.attributedTitle = NSAttributedString(string: testingText, attributes: attrs)
        }
        
        speedTest.startTest(size: size, type: type) { progress in
            // Update progress if needed
        } completion: { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isTestingSpeed = false
                self.cancelTest = nil
                self.updateMenuItemsEnabled(isTestRunning: false)
                
                // Hide and stop progress indicator
                self.progressIndicator.stopAnimation(nil)
                self.progressIndicator.isHidden = true
                self.showMaxSpeed = true
                if let menuItem = self.statusItem.menu?.items.first {
                    menuItem.title = "Show Live Speed"
                }
                // The next updateSpeed call will show "max:" prefix
                
                switch type {
                case .download, .upload:
                    if let speed = result.download ?? result.upload {
                        print("Test completed: \(speed) Mbps")
                    } else {
                        print("Test failed")
                    }
                case .combinedSerial, .combinedParallel:
                    print("Download: \(result.download ?? -1) Mbps")
                    print("Upload: \(result.upload ?? -1) Mbps")
                }
            }
        }
        
        // Store cancel handler
        cancelTest = { [weak self] in
            self?.speedTest.cancelCurrentTest()
            self?.isTestingSpeed = false
            self?.updateMenuItemsEnabled(isTestRunning: false)
        }
    }
    
    private func updateMenuItemsEnabled(isTestRunning: Bool) {
        guard let menu = statusItem.menu else { return }
        
        // Find our control items
        let liveItem = menu.items.first { $0.keyEquivalent == "l" }
        let maxItem = menu.items.first { $0.keyEquivalent == "m" }
        let resetItem = menu.items.first { $0.keyEquivalent == "r" }
        let cancelItem = menu.items.first { $0.keyEquivalent == "c" }
        
        // Update visibility based on mode
        liveItem?.isHidden = !showMaxSpeed
        maxItem?.isHidden = showMaxSpeed
        
        // Update enabled state based on test status
        let testItems = menu.items.filter { $0.action == #selector(startQuickTest) || $0.submenu != nil }
        testItems.forEach { $0.isEnabled = !isTestRunning }
        
        // Show/hide cancel button
        cancelItem?.isHidden = !isTestRunning
        
        // Reset button is enabled only in max mode and when not testing
        resetItem?.isEnabled = showMaxSpeed && !isTestRunning
    }
    
    @objc private func cancelCurrentTest() {
        cancelTest?()
    }
}

// Create and start the application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
