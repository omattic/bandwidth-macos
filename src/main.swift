import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var speedMonitor: SpeedMonitor!
    private var speedTest: SpeedTest!
    private var timer: Timer?
    private var showMaxSpeed = false
    private var isTestingSpeed = false
    private var progressIndicator: NSProgressIndicator!
    private var cancelTest: (() -> Void)?
    private var showLatency = true // Default to showing latency
    private var currentLatency: Double = 0.0 // Store the current latency
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the monitors
        speedMonitor = SpeedMonitor()
        speedTest = SpeedTest()
        
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Remove progress indicator setup and leave only basic button setup
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
        
        // Mode switching group
        let modeGroup = NSMenu()
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeGroup
        
        let liveMenuItem = NSMenuItem(title: "Live Speed", action: #selector(setLiveMode), keyEquivalent: "l")
        let maxMenuItem = NSMenuItem(title: "Show Max Speed", action: #selector(setMaxMode), keyEquivalent: "m")
        let resetMaxMenuItem = NSMenuItem(title: "Reset Max", action: #selector(resetMaxSpeed), keyEquivalent: "r")
        modeGroup.addItem(liveMenuItem)
        modeGroup.addItem(maxMenuItem)
        modeGroup.addItem(resetMaxMenuItem)
        
        // Add Latency toggle option
        modeGroup.addItem(NSMenuItem.separator())
        let latencyMenuItem = NSMenuItem(title: "Show Latency", action: #selector(toggleLatency), keyEquivalent: "p")
        latencyMenuItem.state = showLatency ? .on : .off
        modeGroup.addItem(latencyMenuItem)
        
        menu.addItem(modeItem)
        menu.addItem(NSMenuItem.separator())
        
        // Speed Test group
        let speedTestMenu = NSMenu()
        let speedTestItem = NSMenuItem(title: "Speed Test", action: nil, keyEquivalent: "")
        speedTestItem.submenu = speedTestMenu
        
        // Quick test at the top
        speedTestMenu.addItem(NSMenuItem(title: "Quick Test", action: #selector(startQuickTest), keyEquivalent: "t"))
        speedTestMenu.addItem(NSMenuItem.separator())
        
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
        
        // Cancel test item (hidden by default)
        let cancelTestMenuItem = NSMenuItem(title: "Cancel Test", action: #selector(cancelCurrentTest), keyEquivalent: "c")
        cancelTestMenuItem.isHidden = true
        menu.addItem(cancelTestMenuItem)
        
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
        
        // Set initial state
        updateMenuState()
        
        // Start the timer to update speed every second and measure latency
        timer = Timer.scheduledTimer(timeInterval: 2.0, target: self, selector: #selector(updateSpeedAndLatency), userInfo: nil, repeats: true)
        
        // Initial latency measurement
        measureLatency()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    @objc private func updateSpeedAndLatency() {
        updateSpeed()
        measureLatency()
    }
    
    // Measure network latency using a simple HTTP request
    private func measureLatency() {
        guard let url = URL(string: "https://www.apple.com") else { return }
        
        let startTime = Date()
        let task = URLSession.shared.dataTask(with: url) { [weak self] _, _, error in
            guard let self = self, error == nil else { return }
            
            let elapsed = Date().timeIntervalSince(startTime) * 1000 // Convert to ms
            DispatchQueue.main.async {
                self.currentLatency = elapsed
                self.updateSpeed() // Refresh display to show new latency
            }
        }
        task.resume()
    }
    
    @objc private func toggleLatency() {
        showLatency.toggle()
        
        // Update the menu item state
        if let menu = statusItem.menu,
           let modeMenu = menu.items.first(where: { $0.title == "Mode" })?.submenu,
           let latencyItem = modeMenu.items.first(where: { $0.keyEquivalent == "p" }) {
            latencyItem.state = showLatency ? .on : .off
        }
        
        // Update the display immediately
        updateSpeed()
    }
    
    @objc private func toggleMode() {
        showMaxSpeed.toggle()
        
        guard let menu = statusItem.menu else { return }
        let liveItem = menu.items.first { $0.keyEquivalent == "l" }
        let maxItem = menu.items.first { $0.keyEquivalent == "m" }
        let resetItem = menu.items.first { $0.keyEquivalent == "r" }
        
        // Toggle visibility
        liveItem?.isHidden = !showMaxSpeed
        maxItem?.isHidden = showMaxSpeed
        resetItem?.isHidden = !showMaxSpeed
        
        // Update display immediately
        updateSpeed()
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
                    
                    // Show latency if enabled
                    if self.showLatency {
                        text.append(NSAttributedString(
                            string: String(format: "%3.0fms ", self.currentLatency),
                            attributes: attrs
                        ))
                    }
                    
                    // Always show current mode
                    let modeLabel = self.showMaxSpeed ? "[max] " : "[live] "
                    text.append(NSAttributedString(string: modeLabel, attributes: attrs))
                    
                    if !self.isTestingSpeed {
                        if self.showMaxSpeed {
                            text.append(NSAttributedString(string: "max:", attributes: attrs))
                        }
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
        showMaxSpeed = true
        
        updateMenuState()
        
        if let button = statusItem.button {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
            let text = "Testing speed..."
            button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        }
        
        speedTest.startTest(size: size, type: type) { progress in
            // Update progress if needed
        } completion: { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isTestingSpeed = false
                self.cancelTest = nil
                self.updateMenuState()
                self.updateSpeed()
                
                // ...existing completion code...
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
            self?.updateMenuState()
            self?.updateSpeed()  // Fix: use optional chaining here
        }
    }
    
    private func updateMenuState() {
        guard let menu = statusItem.menu else { return }
        
        // Update mode items
        let modeMenu = menu.items.first(where: { $0.title == "Mode" })?.submenu
        let liveItem = modeMenu?.items.first { $0.keyEquivalent == "l" }
        let maxItem = modeMenu?.items.first { $0.keyEquivalent == "m" }
        let resetItem = modeMenu?.items.first { $0.keyEquivalent == "r" }
        
        // Live is always enabled when not testing
        liveItem?.isEnabled = !isTestingSpeed
        
        // Max and reset are enabled when in max mode and not testing
        maxItem?.isEnabled = !isTestingSpeed
        resetItem?.isEnabled = showMaxSpeed && !isTestingSpeed
        
        // Show current mode selection
        liveItem?.state = !showMaxSpeed ? .on : .off
        maxItem?.state = showMaxSpeed ? .on : .off
        
        // Update test items
        let speedTestItem = menu.items.first { $0.title == "Speed Test" }
        speedTestItem?.isEnabled = !isTestingSpeed
        
        // Show/hide cancel test
        let cancelItem = menu.items.first { $0.keyEquivalent == "c" }
        cancelItem?.isHidden = !isTestingSpeed
    }
    
    @objc private func setLiveMode() {
        showMaxSpeed = false
        updateMenuState()
        updateSpeed()
    }
    
    @objc private func setMaxMode() {
        showMaxSpeed = true
        updateMenuState()
        updateSpeed()
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
