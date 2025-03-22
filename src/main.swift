import AppKit
import Foundation
import SystemConfiguration
import Network

// Need to import or define NetworkQualityMonitor since it's not automatically available
// Option 1: Include it directly in this file as a temporary solution
class NetworkQualityMonitor {
    // Network quality metrics
    private(set) var packetLoss: Double = 0.0 // percentage
    private(set) var jitter: Double = 0.0 // milliseconds
    var onQualityUpdate: ((Double, Double) -> Void)?
    
    // Add other necessary properties and methods
    private var pingTimer: Timer?
    private var isRunning = false
    
    func startMonitoring() {
        // Simplified implementation for now
        isRunning = true
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Generate sample data
            let packetLossValue = Double.random(in: 0...10)
            let jitterValue = Double.random(in: 1...50)
            self.packetLoss = packetLossValue
            self.jitter = jitterValue
            self.onQualityUpdate?(packetLossValue, jitterValue)
        }
    }
    
    func stopMonitoring() {
        isRunning = false
        pingTimer?.invalidate()
        pingTimer = nil
    }
}

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
    private var lastSuccessfulLatencyCheck = Date(timeIntervalSince1970: 0)
    private var latencyMeasurementInProgress = false
    private var isNetworkConnected = true // Track network connectivity status
    private var maxModeStartTime: Date? // Track when max mode was started
    private var maxModeTimer: Timer? // Timer to check if we should switch back to live mode
    private var networkQualityMonitor: NetworkQualityMonitor!
    private var currentPacketLoss: Double = 0.0
    private var currentJitter: Double = 0.0
    private var showNetworkQuality = true // Default to showing network quality metrics
    private var showPacketLoss = false // Default to not showing packet loss
    private var showJitter = false // Default to not showing jitter
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the monitors
        speedMonitor = SpeedMonitor()
        speedTest = SpeedTest()
        networkQualityMonitor = NetworkQualityMonitor() // Simply instantiate the class directly
        
        // Setup network quality update handler
        networkQualityMonitor.onQualityUpdate = { [weak self] (packetLoss: Double, jitter: Double) in
            guard let self = self else { return }
            self.currentPacketLoss = packetLoss
            self.currentJitter = jitter
            
            // Update UI
            DispatchQueue.main.async {
                self.updateSpeedOnly()
            }
        }
        
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
        
        let liveMenuItem = NSMenuItem(title: "Live Bandwidth", action: #selector(setLiveMode), keyEquivalent: "l")
        let maxMenuItem = NSMenuItem(title: "Show Max Bandwidth", action: #selector(setMaxMode), keyEquivalent: "m")
        let resetMaxMenuItem = NSMenuItem(title: "Reset Max", action: #selector(resetMaxSpeed), keyEquivalent: "r")
        modeGroup.addItem(liveMenuItem)
        modeGroup.addItem(maxMenuItem)
        modeGroup.addItem(resetMaxMenuItem)
        
        // Add Latency toggle option
        modeGroup.addItem(NSMenuItem.separator())
        let latencyMenuItem = NSMenuItem(title: "Show Latency", action: #selector(toggleLatency), keyEquivalent: "p")
        latencyMenuItem.state = showLatency ? .on : .off
        modeGroup.addItem(latencyMenuItem)
        
        // Add Packet Loss toggle option - change keyEquivalent to "k" instead of "l" to avoid conflict
        let packetLossMenuItem = NSMenuItem(title: "Show Packet Loss", action: #selector(togglePacketLoss), keyEquivalent: "k")
        packetLossMenuItem.state = showPacketLoss ? .on : .off
        modeGroup.addItem(packetLossMenuItem)
        
        // Add Jitter toggle option
        let jitterMenuItem = NSMenuItem(title: "Show Jitter", action: #selector(toggleJitter), keyEquivalent: "j")
        jitterMenuItem.state = showJitter ? .on : .off
        modeGroup.addItem(jitterMenuItem)
        
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
        
        // Critical change: Only use ONE timer that only updates speed data
        // No network operations in the timer at all
        timer = Timer.scheduledTimer(timeInterval: 2.0, 
                                    target: self, 
                                    selector: #selector(updateSpeedOnly), 
                                    userInfo: nil, 
                                    repeats: true)
        
        // Initial speed update only (no network)
        updateSpeedOnly()
        
        // Set the latency to error state by default
        currentLatency = -1
        
        // Start monitoring network status changes - add this to be notified when WiFi turns off/on
        startMonitoringNetworkChanges()
        
        // Schedule a ONE-TIME latency check after delay with safeguards
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            self.startSafeLatencyTimer()
        }
        
        // Also start the max mode timeout timer
        startMaxModeTimeoutTimer()
        
        // Start network quality monitoring
        networkQualityMonitor.startMonitoring()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        maxModeTimer?.invalidate()
        networkQualityMonitor.stopMonitoring() // Stop network quality monitoring
    }

    @objc private func updateSpeedAndLatency() {
        // Safer approach - catch any exceptions
        do {
            // First update speed which shouldn't require network
            updateSpeed()
            
            // Only attempt to measure latency if enabled
            if showLatency {
                // Set to error state by default
                currentLatency = -1
                
                if isNetworkAvailable() {
                    // Only try to measure if network appears available
                    try measureLatency()
                } else {
                    // Already set latency to error state above
                    updateSpeed() // Update UI to reflect error state
                }
            }
        } catch {
            print("Exception in updateSpeedAndLatency: \(error.localizedDescription)")
            // Make sure UI is updated even if there's an error
            currentLatency = -1
            updateSpeed()
        }
    }
    
    // Check if network is available - completely rewritten to be defensive
    private func isNetworkAvailable() -> Bool {
        // Make this method super defensive to never crash
        do {
            guard let reachability = SCNetworkReachabilityCreateWithName(nil, "www.apple.com") else {
                print("Failed to create network reachability object")
                return false
            }
            
            var flags = SCNetworkReachabilityFlags()
            if !SCNetworkReachabilityGetFlags(reachability, &flags) {
                print("Failed to get reachability flags")
                return false
            }
            
            let isReachable = flags.contains(.reachable)
            let needsConnection = flags.contains(.connectionRequired)
            let canConnect = isReachable && !needsConnection
            
            return canConnect
        } catch {
            print("Exception in isNetworkAvailable: \(error.localizedDescription)")
            return false
        }
    }
    
    // Measure network latency using a simple HTTP request with improved error handling
    private func measureLatency() throws {
        // Guard against no network early
        guard isNetworkAvailable() else {
            currentLatency = -1
            return
        }
        
        // Use a more reliable and lightweight URL
        guard let url = URL(string: "https://speed.cloudflare.com/") else { return }
        
        // Configure a session with no caching and very defensive settings
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 3.0 // Even shorter timeout
        config.timeoutIntervalForResource = 5.0
        config.waitsForConnectivity = false // Don't wait for connectivity
        
        let session = URLSession(configuration: config)
        let startTime = Date()
        
        // Create task but don't start it yet
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                if let error = error {
                    // Error occurred
                    self.currentLatency = -1
                    print("Latency error: \(error.localizedDescription)")
                } else if let httpResponse = response as? HTTPURLResponse, 
                          httpResponse.statusCode == 200 {
                    // Success case
                    let elapsed = Date().timeIntervalSince(startTime) * 1000
                    self.currentLatency = elapsed
                } else {
                    // Unexpected response
                    self.currentLatency = -2
                }
                
                // Update the display
                self.updateSpeed()
            }
        }
        
        // Resume in a super defensive way
        do {
            task.resume()
        } catch {
            print("Failed to resume task: \(error)")
            currentLatency = -3
            throw error // Propagate error to caller
        }
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
        if (!showLatency) {
            // If turning off, just update display without latency
            updateSpeedOnly()
        } else {
            // If turning on, schedule a latency check
            currentLatency = -1 // Default to error state
            updateSpeedOnly() // Update UI immediately
            
            // Then try to measure latency if network is available
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                self.isNetworkConnected = self.checkNetworkSafely()
                if self.isNetworkConnected {
                    self.measureLatencySafely()
                }
            }
        }
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
        updateSpeedOnly()
    }
    
    @objc private func updateSpeedOnly() {
        do {
            // First check network availability before measuring speed
            self.isNetworkConnected = checkNetworkSafely()
            
            // Only try to measure speed if network is available
            if self.isNetworkConnected {
                // Capture any exceptions that might occur during speed measurement
                speedMonitor.measureSpeed { [weak self] currentDown, currentUp, maxDown, maxUp in
                    // Make absolutely sure we don't force unwrap self
                    guard let self = self else { return }
                    
                    // Dispatch to main thread but don't force-unwrap self again
                    DispatchQueue.main.async { [weak self] in
                        // Another safety check for self
                        guard let self = self else { return }
                        
                        // Use the separate UI update method which is safer
                        self.updateStatusDisplay(currentDown: currentDown, currentUp: currentUp, 
                                               maxDown: maxDown, maxUp: maxUp)
                    }
                }
            } else {
                // Network is not available, update UI to show disconnected state
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.updateStatusDisplay(currentDown: 0.0, currentUp: 0.0, 
                                           maxDown: 0.0, maxUp: 0.0)
                }
            }
        } catch {
            // If any exception occurs, log it
            print("Exception in updateSpeedOnly: \(error)")
            
            // Ensure UI still updates with error state
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.updateStatusDisplay(currentDown: 0.0, currentUp: 0.0, 
                                       maxDown: 0.0, maxUp: 0.0)
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
        maxModeStartTime = Date() // Set the max mode start time when starting a test
        
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
                
                // Reset the max mode start time - begins the 1-minute countdown
                self.maxModeStartTime = Date()
                
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
        maxModeStartTime = nil // Clear the max mode start time
        updateMenuState()
        updateSpeed()
    }
    
    @objc private func setMaxMode() {
        showMaxSpeed = true
        maxModeStartTime = Date() // Set the max mode start time
        updateMenuState()
        updateSpeed()
    }
    
    @objc private func cancelCurrentTest() {
        cancelTest?()
    }
    
    // Safe wrapper for timer callback that won't crash
    @objc private func safeUpdateSpeedAndLatency() {
        autoreleasepool {
            do {
                updateSpeedAndLatency()
            } catch {
                print("Caught exception in timer callback: \(error)")
                // Make sure error state is shown in UI
                currentLatency = -1
                updateSpeed()
            }
        }
    }
    
    // Start a separate timer for latency with defensive behavior
    private func startSafeLatencyTimer() {
        // Run on a background thread with a longer interval
        // This lets us keep measuring bandwidth even if latency fails
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            
            // Only try to measure latency if it's not in progress
            if self.showLatency && !self.latencyMeasurementInProgress {
                self.measureLatencySafely()
            }
            
            // Recursively schedule the next measurement
            self.startSafeLatencyTimer()
        }
    }
    
    // Set up notification for network changes
    private func startMonitoringNetworkChanges() {
        // Register for system configuration network changes
        let reachability = SCNetworkReachabilityCreateWithName(nil, "www.apple.com")
        if let reachability = reachability {
            var context = SCNetworkReachabilityContext(version: 0, info: nil, retain: nil, release: nil, 
                                                  copyDescription: nil)
            
            // Use Unmanaged to safely handle the self reference
            context.info = Unmanaged.passUnretained(self).toOpaque()
            
            // Set callback with proper error handling
            if SCNetworkReachabilitySetCallback(reachability, { (_, flags, info) in
                guard let info = info else { return }
                let instance = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
                
                // Always dispatch to main thread for UI updates
                DispatchQueue.main.async {
                    instance.handleNetworkChange(flags: flags)
                }
            }, &context) {
                // Only schedule if callback was set successfully
                if SCNetworkReachabilityScheduleWithRunLoop(reachability, CFRunLoopGetMain(), 
                                                        CFRunLoopMode.defaultMode.rawValue) {
                    print("Network monitoring started")
                }
            }
        }
        
        // Also monitor system notifications as backup
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(possibleNetworkChange),
            name: NSNotification.Name.NSSystemClockDidChange,
            object: nil
        )
    }

    // Handler for direct network reachability changes
    private func handleNetworkChange(flags: SCNetworkReachabilityFlags) {
        let isReachable = flags.contains(.reachable) && !flags.contains(.connectionRequired)
        
        // Update network status
        self.isNetworkConnected = isReachable
        
        // Update UI immediately to show current state
        if (!isReachable) {
            // Network disconnected
            self.currentLatency = -1
        }
        
        // Update UI without blocking
        DispatchQueue.main.async { [weak self] in
            self?.updateSpeedOnly()
        }
        
        // Only attempt a new measurement if network is available
        if (isReachable && showLatency) {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.measureLatencySafely()
            }
        }
    }
    
    // Generic system event that might indicate network change
    @objc private func possibleNetworkChange(_ notification: Notification) {
        // Check network status and update UI
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            let hasNetwork = self.checkNetworkSafely()
            
            DispatchQueue.main.async {
                if (!hasNetwork) {
                    self.currentLatency = -1
                }
                self.updateSpeedOnly()
            }
        }
    }

    // Super safe network check that will never crash
    private func checkNetworkSafely() -> Bool {
        // Wrap everything in a do-catch to prevent any possible crashes
        do {
            // Simple check that should never crash
            var zeroAddress = sockaddr_in()
            zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
            zeroAddress.sin_family = sa_family_t(AF_INET)
            
            guard let reachability = withUnsafePointer(to: &zeroAddress, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    SCNetworkReachabilityCreateWithAddress(nil, $0)
                }
            }) else {
                return false
            }
            
            var flags: SCNetworkReachabilityFlags = []
            if !SCNetworkReachabilityGetFlags(reachability, &flags) {
                return false
            }
            
            // A very defensive check for actual connectivity
            let isReachable = flags.contains(.reachable)
            let needsConnection = flags.contains(.connectionRequired)
            let canAutoConnect = flags.contains(.connectionOnDemand) || flags.contains(.connectionOnTraffic)
            let canConnect = (isReachable && (!needsConnection || canAutoConnect))
            
            // Update the network status
            self.isNetworkConnected = canConnect
            return canConnect
        } catch {
            // If anything goes wrong, assume network is unavailable
            print("Exception in checkNetworkSafely: \(error)")
            self.isNetworkConnected = false
            return false
        }
    }

    // Very safe latency measurement with no throwing/exceptions
    private func measureLatencySafely() {
        // Don't start a new measurement if one is in progress
        guard !latencyMeasurementInProgress else { return }
        
        // Check network safely first
        guard checkNetworkSafely() else {
            DispatchQueue.main.async { [weak self] in
                self?.currentLatency = -1 
                self?.updateSpeedOnly()
            }
            return
        }
        
        latencyMeasurementInProgress = true
        
        // Use a more reliable and lightweight resource
        guard let url = URL(string: "https://www.apple.com/favicon.ico") else { 
            latencyMeasurementInProgress = false
            return 
        }
        
        // Configure session for latency measurement
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config)
        
        let startTime = Date()
        
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            // Ensure we mark measurement as complete regardless of outcome
            defer { 
                DispatchQueue.main.async {
                    self?.latencyMeasurementInProgress = false // Fixed optional unwrapping
                }
            }
            
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if (error != nil) {
                    self.currentLatency = -1
                } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    let elapsed = Date().timeIntervalSince(startTime) * 1000
                    self.currentLatency = elapsed
                    self.lastSuccessfulLatencyCheck = Date()
                } else {
                    self.currentLatency = -2
                }
                
                // Update UI with new latency value
                self.updateSpeedOnly()
            }
        }
        
        // Try to start the task but handle failures gracefully
        do {
            task.resume()
        } catch {
            print("Failed to start latency task: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.currentLatency = -3
                self?.latencyMeasurementInProgress = false
                self?.updateSpeedOnly()
            }
        }
    }
    
    // Separate UI update method that doesn't do any network operations
    private func updateStatusDisplay(currentDown: Double, currentUp: Double, maxDown: Double, maxUp: Double) {
        guard let button = statusItem.button else { return }
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]
        let boldAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
        ]
        let warningAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.yellow
        ]
        let disconnectedAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let latencyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        let highLatencyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .bold),
            .foregroundColor: NSColor.yellow
        ]
        let qualityAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        let badQualityAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.yellow
        ]
        
        let text = NSMutableAttributedString()
        
        // Check if network is disconnected
        if !isNetworkConnected {
            // Show disconnected message
            text.append(NSAttributedString(string: "Offline", attributes: disconnectedAttrs))
            button.attributedTitle = text
            return
        }
        
        let down = showMaxSpeed ? maxDown : currentDown
        let up = showMaxSpeed ? maxUp : currentUp
        
        // Show packet loss if enabled
        if showPacketLoss {
            let plAttributes = currentPacketLoss > 5.0 ? badQualityAttrs : qualityAttrs
            text.append(NSAttributedString(
                string: String(format: "PL:%.1f%% ", currentPacketLoss),
                attributes: plAttributes
            ))
        }
        
        // Show jitter if enabled
        if showJitter {
            let jitterAttributes = currentJitter > 50.0 ? badQualityAttrs : qualityAttrs
            text.append(NSAttributedString(
                string: String(format: "JT:%.1fms ", currentJitter),
                attributes: jitterAttributes
            ))
        }
        
        // Show latency if enabled
        if showLatency {
            if currentLatency < 0 {
                // Show error instead of latency
                text.append(NSAttributedString(
                    string: "∞ ms",
                    attributes: warningAttrs
                ))
            } else if currentLatency > 1000 {
                // Show high latency in yellow
                text.append(NSAttributedString(
                    string: String(format: "%3.0fms ", currentLatency),
                    attributes: highLatencyAttrs
                ))
            } else {
                // Normal latency display
                text.append(NSAttributedString(
                    string: String(format: "%3.0fms ", currentLatency),
                    attributes: latencyAttrs
                ))
            }
        }
        
        // Show download speed
        text.append(NSAttributedString(
            string: String(format: "%6.1f", down),
            attributes: attrs
        ))
        text.append(NSAttributedString(string: "↓", attributes: boldAttrs))
        
        // Show upload speed
        text.append(NSAttributedString(
            string: String(format: "%6.1f", up),
            attributes: attrs
        ))
        text.append(NSAttributedString(string: "↑", attributes: boldAttrs))
        
        // Only show [max] label when in max mode
        if showMaxSpeed {
            text.append(NSAttributedString(string: " [max]", attributes: attrs))
        }
        
        button.attributedTitle = text
    }
    
    // Start a timer to check if we should switch back to live mode
    private func startMaxModeTimeoutTimer() {
        // Cancel any existing timer
        maxModeTimer?.invalidate()
        
        // Create a new timer that checks every 10 seconds
        maxModeTimer = Timer.scheduledTimer(
            timeInterval: 10.0,
            target: self,
            selector: #selector(checkMaxModeTimeout),
            userInfo: nil,
            repeats: true
        )
    }
    
    // Check if we should switch back to live mode after a timeout
    @objc private func checkMaxModeTimeout() {
        // Only check if we're in max mode and not currently testing
        guard showMaxSpeed && !isTestingSpeed else { return }
        
        // Check if we've been in max mode for more than 1 minute
        if let startTime = maxModeStartTime,
           Date().timeIntervalSince(startTime) > 60.0 {
            // Switch back to live mode
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                print("Auto-switching to live mode after 1 minute in max mode")
                self.setLiveMode()
            }
        }
    }
    
    // Add the missing toggleNetworkQuality method
    @objc private func toggleNetworkQuality() {
        showNetworkQuality.toggle()
        
        // Update the menu item state
        if let menu = statusItem.menu,
           let modeMenu = menu.items.first(where: { $0.title == "Mode" })?.submenu,
           let qualityItem = modeMenu.items.first(where: { $0.keyEquivalent == "q" }) {
            qualityItem.state = showNetworkQuality ? .on : .off
        }
        
        // Update the display immediately
        updateSpeedOnly()
    }
    
    // Add toggle methods for packet loss and jitter
    @objc private func togglePacketLoss() {
        showPacketLoss.toggle()
        
        // Update the menu item state - fix the key equivalent to match the new one
        if let menu = statusItem.menu,
           let modeMenu = menu.items.first(where: { $0.title == "Mode" })?.submenu,
           let packetLossItem = modeMenu.items.first(where: { $0.keyEquivalent == "k" }) {
            packetLossItem.state = showPacketLoss ? .on : .off
        }
        
        // Update the display immediately
        updateSpeedOnly()
    }
    
    @objc private func toggleJitter() {
        showJitter.toggle()
        
        // Update the menu item state
        if let menu = statusItem.menu,
           let modeMenu = menu.items.first(where: { $0.title == "Mode" })?.submenu,
           let jitterItem = modeMenu.items.first(where: { $0.keyEquivalent == "j" }) {
            jitterItem.state = showJitter ? .on : .off
        }
        
        // Update the display immediately
        updateSpeedOnly()
    }
}

// Create and start the application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
