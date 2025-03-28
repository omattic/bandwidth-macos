import AppKit
import Foundation
import SystemConfiguration
import Network

// Add preference keys
struct PreferenceKeys {
    static let showMaxSpeed = "showMaxSpeed"
    static let showLatency = "showLatency"
    static let showPacketLoss = "showPacketLoss"
    static let showJitter = "showJitter"
    static let showNetworkQuality = "showNetworkQuality"
    static let showTotalTraffic = "showTotalTraffic"  // NEW
}

// Improved NetworkMonitor with better thread safety and error handling
class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitorQueue")
    private(set) var isConnected = false
    private var statusChangeHandler: ((Bool) -> Void)?
    private let lock = NSLock() // Add thread safety
    
    init() {
        // Start with a safe default value
        isConnected = false
        
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            // Thread-safe update of state
            self.lock.lock()
            let newConnectionState = path.status == .satisfied
            let stateChanged = self.isConnected != newConnectionState
            self.isConnected = newConnectionState
            self.lock.unlock()
            
            // Only notify when there's an actual change
            if stateChanged {
                print("📶 Network status changed: \(newConnectionState ? "Connected" : "Disconnected")")
                
                // Always dispatch to main thread for UI updates
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    // Get the handler safely
                    var handler: ((Bool) -> Void)?
                    self.lock.lock()
                    handler = self.statusChangeHandler
                    self.lock.unlock()
                    
                    // Call handler on main thread
                    handler?(newConnectionState)
                }
            }
        }
        
        // Start monitoring on background queue
        monitor.start(queue: queue)
    }
    
    deinit {
        stopMonitoring()
    }
    
    func startMonitoring(statusChanged: @escaping (Bool) -> Void) {
        lock.lock()
        statusChangeHandler = statusChanged
        lock.unlock()
        
        // Immediately notify with current state
        DispatchQueue.main.async {
            statusChanged(self.checkIsConnected())
        }
    }
    
    func stopMonitoring() {
        lock.lock()
        statusChangeHandler = nil
        lock.unlock()
        
        // Cancel the monitor
        monitor.cancel()
    }
    
    func checkIsConnected() -> Bool {
        lock.lock()
        let result = isConnected
        lock.unlock()
        return result
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // Modify status item to be an array of items
    private var speedStatusItem: NSStatusItem!
    private var latencyStatusItem: NSStatusItem?
    private var qualityStatusItem: NSStatusItem?
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
    private var showPacketLoss = true // Default to showing packet loss
    private var showJitter = true // Default to showing jitter
    private var networkMonitor: NetworkMonitor!
    private var showTotalTraffic = true  // NEW
    
    // Add adaptive display properties
    private var adaptiveDisplayEnabled = true // Always enabled now
    private var lastMeasuredWidth: CGFloat = 0 // Last measured width
    private var maxStatusBarWidth: CGFloat = 400 // Maximum reasonable width for status bar items
    private var isWidthConstrained = false // Are we currently width-constrained?
    private var widthConstraintThreshold: CGFloat = 300 // When to start condensing (changed from 'let' to 'var')
    
    // Add variables to detect screen and status bar changes
    private var screenObserver: Any?
    private var statusBarWatcher: Timer?
    private var lastScreenWidth: CGFloat = 0
    private var lastMenuBarItems: Int = 0
    
    // Create enum to represent different status item types
    private enum StatusItemType: Int {
        case bandwidth = 0
        case latency = 1
        case quality = 2
    }
    
    // Add a dictionary to map menus to their types
    private var menuTypeMap = [NSMenu: StatusItemType]()
    
    private var totalTrafficGB: Double = 0.0  // New property for tracking total traffic used
    // Add traffic status item property
    private var trafficStatusItem: NSStatusItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Move the NetworkMonitor initialization to the top
        networkMonitor = NetworkMonitor()
        
        // Load user preferences first
        loadPreferences()
        
        // Create the monitors with more defensive approach
        speedMonitor = SpeedMonitor()
        speedTest = SpeedTest()
        
        // Use safe instantiation for NetworkQualityMonitor
        networkQualityMonitor = NetworkQualityMonitor()
        
        // Setup network quality update handler with additional safety
        networkQualityMonitor.onQualityUpdate = { [weak self] (packetLoss: Double, jitter: Double) in
            guard let self = self else { return }
            
            // Ensure values are in safe ranges
            let safeLoss = min(max(packetLoss, 0.0), 100.0)
            let safeJitter = max(jitter, 0.0)
            
            // Limit debug printing frequency to reduce console spam
            if Int(safeLoss * 10) % 10 == 0 || Int(safeJitter * 10) % 10 == 0 {
                print("📊 Network quality update: Loss=\(safeLoss)%, Jitter=\(safeJitter)ms")
            }
            
            // Update stored values atomically
            self.currentPacketLoss = safeLoss
            self.currentJitter = safeJitter
            
            // Update UI only from main thread
            if Thread.isMainThread {
                self.updateSpeedOnly()
            } else {
                DispatchQueue.main.async {
                    self.updateSpeedOnly()
                }
            }
        }
        
        // Create multiple status bar items instead of just one
        setupStatusBarItems()
        
        // Create the menu
        let menu = NSMenu()
        
        // Mode switching group
        let modeGroup = NSMenu()
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeGroup
        
        let liveMenuItem = NSMenuItem(title: "Live Bandwidth", action: #selector(setLiveMode), keyEquivalent: "l")
        let maxMenuItem = NSMenuItem(title: "Max Bandwidth", action: #selector(setMaxMode), keyEquivalent: "m")
        let resetMaxMenuItem = NSMenuItem(title: "Reset Max", action: #selector(resetMaxSpeed), keyEquivalent: "r")
        modeGroup.addItem(liveMenuItem)
        modeGroup.addItem(maxMenuItem)
        modeGroup.addItem(resetMaxMenuItem)
        
        // Add Latency toggle option
        modeGroup.addItem(NSMenuItem.separator())
        let latencyMenuItem = NSMenuItem(title: "Show Latency", action: #selector(toggleLatency), keyEquivalent: "p")
        latencyMenuItem.state = showLatency ? .on : .off
        modeGroup.addItem(latencyMenuItem)
        
        // Add Packet Loss toggle option with fixed key equivalent
        let packetLossMenuItem = NSMenuItem(title: "Show Packet Loss", action: #selector(togglePacketLoss), keyEquivalent: "k")
        packetLossMenuItem.state = showPacketLoss ? .on : .off
        modeGroup.addItem(packetLossMenuItem)
        
        // Add Jitter toggle option
        let jitterMenuItem = NSMenuItem(title: "Show Jitter", action: #selector(toggleJitter), keyEquivalent: "j")
        jitterMenuItem.state = showJitter ? .on : .off
        modeGroup.addItem(jitterMenuItem)
        
        // NEW: Add "Show Total Traffic" toggle with key equivalent "g"
        modeGroup.addItem(NSMenuItem.separator())
        let trafficMenuItem = NSMenuItem(title: "Show Total Traffic", action: #selector(toggleTraffic), keyEquivalent: "g")
        trafficMenuItem.state = showTotalTraffic ? .on : .off
        modeGroup.addItem(trafficMenuItem)
        
        // Remove Adaptive Display toggle - feature is always enabled now
        
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
        
        speedStatusItem.menu = menu
        
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
        
        // Start monitoring network status changes using modern API
        startMonitoringNetworkChanges()
        
        // Schedule a ONE-TIME latency check after delay with safeguards
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            self.startSafeLatencyTimer()
        }
        
        // Also start the max mode timeout timer
        startMaxModeTimeoutTimer()
        
        // Start network quality monitoring with a delay
        print("📱 Starting network quality monitoring")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            self.networkQualityMonitor.startMonitoring()
        }
        
        // Don't load adaptive display preference - always enabled
    }
    
    // Load user preferences from UserDefaults
    private func loadPreferences() {
        let defaults = UserDefaults.standard
        
        // Load display preferences with fallback to default values
        showMaxSpeed = defaults.bool(forKey: PreferenceKeys.showMaxSpeed)
        showLatency = defaults.object(forKey: PreferenceKeys.showLatency) as? Bool ?? true
        showPacketLoss = defaults.object(forKey: PreferenceKeys.showPacketLoss) as? Bool ?? true
        showJitter = defaults.object(forKey: PreferenceKeys.showJitter) as? Bool ?? true
        showNetworkQuality = defaults.object(forKey: PreferenceKeys.showNetworkQuality) as? Bool ?? true
        showTotalTraffic = defaults.object(forKey: PreferenceKeys.showTotalTraffic) as? Bool ?? true  // NEW
        
        print("📋 Loaded preferences: Max=\(showMaxSpeed), Latency=\(showLatency), Loss=\(showPacketLoss), Jitter=\(showJitter), Traffic=\(showTotalTraffic)")
    }
    
    // Save current preferences to UserDefaults
    private func savePreferences() {
        let defaults = UserDefaults.standard
        
        defaults.set(showMaxSpeed, forKey: PreferenceKeys.showMaxSpeed)
        defaults.set(showLatency, forKey: PreferenceKeys.showLatency)
        defaults.set(showPacketLoss, forKey: PreferenceKeys.showPacketLoss)
        defaults.set(showJitter, forKey: PreferenceKeys.showJitter)
        defaults.set(showNetworkQuality, forKey: PreferenceKeys.showNetworkQuality)
        defaults.set(showTotalTraffic, forKey: PreferenceKeys.showTotalTraffic)  // NEW
        // Remove adaptive display setting - it's always enabled now
        
        // Synchronize to ensure data is saved immediately
        defaults.synchronize()
        
        print("💾 Saved preferences: Max=\(showMaxSpeed), Latency=\(showLatency), Loss=\(showPacketLoss), Jitter=\(showJitter), Traffic=\(showTotalTraffic)")
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
    
    // Toggle methods for network quality display
    @objc private func toggleNetworkQuality() {
        showNetworkQuality.toggle()
        
        // Update the menu item state
        if let menu = speedStatusItem.menu,
           let modeMenu = menu.items.first(where: { $0.title == "Mode" })?.submenu,
           let qualityItem = modeMenu.items.first(where: { $0.keyEquivalent == "q" }) {
            qualityItem.state = showNetworkQuality ? .on : .off
        }
        
        // Update the display immediately
        updateSpeedOnly()
        savePreferences() // Save the new preference
    }
    
    // Add toggle methods for packet loss and jitter
    @objc private func togglePacketLoss() {
        showPacketLoss.toggle()
        
        // Update the menu item state - fix the key equivalent to match the new one
        if let menu = speedStatusItem.menu,
           let modeMenu = menu.items.first(where: { $0.title == "Mode" })?.submenu,
           let packetLossItem = modeMenu.items.first(where: { $0.keyEquivalent == "k" }) {
            packetLossItem.state = showPacketLoss ? .on : .off
        }
        
        // Update the display immediately
        updateSpeedOnly()
        savePreferences() // Save the new preference
    }
    
    @objc private func toggleJitter() {
        showJitter.toggle()
        
        // Update the menu item state
        if let menu = speedStatusItem.menu,
           let modeMenu = menu.items.first(where: { $0.title == "Mode" })?.submenu,
           let jitterItem = modeMenu.items.first(where: { $0.keyEquivalent == "j" }) {
            jitterItem.state = showJitter ? .on : .off
        }
        
        // Update the display immediately
        updateSpeedOnly()
        savePreferences() // Save the new preference
    }
    
    @objc private func toggleTraffic() {
        showTotalTraffic.toggle()
        updateMenuItemState(keyEquivalent: "g", state: showTotalTraffic ? .on : .off)
        if showTotalTraffic {
            if trafficStatusItem == nil, let menu = speedStatusItem.menu {
                createTrafficStatusItem(withMenu: menu)
            }
        } else {
            if let item = trafficStatusItem {
                NSStatusBar.system.removeStatusItem(item)
                trafficStatusItem = nil
            }
        }
        updateSpeedOnly()
        savePreferences()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Save preferences before termination
        savePreferences()
        
        // Properly cleanup all resources
        networkMonitor.stopMonitoring() // Stop this first
        
        timer?.invalidate()
        timer = nil
        
        maxModeTimer?.invalidate()
        maxModeTimer = nil
        
        // Stop network quality monitoring safely
        networkQualityMonitor.stopMonitoring()
        
        // Clean up our observers
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        statusBarWatcher?.invalidate()
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
    
    // Check if network is available - completely rewritten to use modern APIs
    private func isNetworkAvailable() -> Bool {
        return networkMonitor.checkIsConnected()
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
        
        // Resume task without unreachable catch block
        task.resume()
    }
    
    @objc private func toggleLatency() {
        showLatency.toggle()
        
        // Update the menu item state in all menus
        updateMenuItemState(keyEquivalent: "p", state: showLatency ? .on : .off)
        
        // Add or remove the latency status item
        if showLatency {
            if (latencyStatusItem == nil) {
                // Create latency menu and status item
                let latencyMenu = createMenu(for: .latency)
                createLatencyStatusItem(withMenu: latencyMenu)
            }
            
            // Schedule measurement
            if self.isNetworkConnected {
                self.measureLatencySafely()
            }
        } else {
            removeLatencyStatusItem()
        }
        
        savePreferences() // Save the new preference
        updateSpeedOnly() // Update the display
    }
    
    @objc private func toggleMode() {
        showMaxSpeed.toggle()
        
        guard let menu = speedStatusItem.menu else { return }
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
        // First check network availability before measuring speed
        self.isNetworkConnected = checkNetworkSafely()
        
        // If network is available, measure actual speeds
        if self.isNetworkConnected {
            // Use the speedMonitor to get actual bandwidth values
            speedMonitor.measureSpeed { [weak self] currentDown, currentUp, maxDown, maxUp in
                guard let self = self else { return }
                // Increment traffic counter (assumes update interval is 2 sec)
                let trafficIncrement = (currentDown + currentUp) * 0.00025  // (GB) estimate
                self.totalTrafficGB += trafficIncrement
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.updateSpeedDisplay(currentDown: currentDown, currentUp: currentUp, maxDown: maxDown, maxUp: maxUp)
                    self.updateLatencyDisplay()
                    self.updateQualityDisplay()
                    // Update traffic display after other metrics
                    self.updateTrafficDisplay()
                }
            }
        } else {
            // Network is not available, update UI to show disconnected state
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.updateSpeedDisplay(currentDown: 0.0, currentUp: 0.0, 
                                         maxDown: 0.0, maxUp: 0.0)
                self.updateLatencyDisplay()
                self.updateQualityDisplay()
                // Also update traffic display even if offline
                self.updateTrafficDisplay()
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
        
        if let button = speedStatusItem.button {
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
        guard let menu = speedStatusItem.menu else { return }
        
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
        savePreferences() // Save the new preference
    }
    
    @objc private func setMaxMode() {
        showMaxSpeed = true
        maxModeStartTime = Date() // Set the max mode start time
        updateMenuState()
        updateSpeed()
        savePreferences() // Save the new preference
    }
    
    @objc private func cancelCurrentTest() {
        cancelTest?()
    }
    
    // Safe wrapper for timer callback that won't crash
    @objc private func safeUpdateSpeedAndLatency() {
        autoreleasepool {
            // No need for try-catch here if updateSpeedAndLatency doesn't throw
            updateSpeedAndLatency()
            // If it fails, UI will still show error state since we set 
            // currentLatency = -1 as fallback in updateSpeedAndLatency
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
        // Use the safer NWPathMonitor through our wrapper
        networkMonitor.startMonitoring { [weak self] isConnected in
            guard let self = self else { return }
            
            // Already on main thread
            // Update network status safely
            self.isNetworkConnected = isConnected
            
            if !isConnected {
                // When network is lost, reset these values
                self.currentLatency = -1
                self.currentPacketLoss = 0.0
                self.currentJitter = 0.0
            }
            
            // Update UI
            self.updateSpeedOnly()
            
            if isConnected && self.showLatency {
                // Schedule a latency check when network returns
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self else { return }
                    if self.isNetworkConnected && self.showLatency {
                        self.measureLatencySafely()
                    }
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

    // Super safe network check that will never crash - use modern API
    private func checkNetworkSafely() -> Bool {
        return networkMonitor.checkIsConnected()
    }

    // Very safe latency measurement with no throwing/exceptions
    private func measureLatencySafely() {
        // Don't start a new measurement if one is in progress
        guard !latencyMeasurementInProgress else { return }
        
        // Extra safety: verify network before even trying
        guard isNetworkConnected && checkNetworkSafely() else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.currentLatency = -1 
                self.updateSpeedOnly()
            }
            return
        }
        
        // Mark as in progress
        latencyMeasurementInProgress = true
        
        // Use a very reliable and lightweight resource
        guard let url = URL(string: "https://www.apple.com/favicon.ico") else { 
            latencyMeasurementInProgress = false
            return 
        }
        
        // Super defensive configuration
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 5.0
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.waitsForConnectivity = false
        
        let session = URLSession(configuration: config)
        let startTime = Date()
        
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            // Always ensure we mark measurement as complete
            defer { 
                DispatchQueue.main.async { [weak self] in
                    self?.latencyMeasurementInProgress = false
                }
            }
            
            // Extra check for self and network status
            guard let self = self, self.isNetworkConnected else {
                return
            }
            
            DispatchQueue.main.async {
                guard self.isNetworkConnected else {
                    self.currentLatency = -1
                    return
                }
                
                if error != nil {
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
        
        task.resume()
    }
    
    // Measure width of attributed string
    private func measureWidth(of attributedString: NSAttributedString) -> CGFloat {
        let textStorage = NSTextStorage(attributedString: attributedString)
        let textContainer = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        let layoutManager = NSLayoutManager()
        
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        
        layoutManager.glyphRange(forBoundingRect: CGRect(origin: .zero, size: textContainer.size), in: textContainer)
        return layoutManager.usedRect(for: textContainer).width
    }
    
    // Separate UI update method that doesn't do any network operations
    private func updateStatusDisplay(currentDown: Double, currentUp: Double, maxDown: Double, maxUp: Double) {
        guard let button = speedStatusItem.button else { return }
        
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
        
        // Change from 'let' to 'var' to make text mutable
        var text = NSMutableAttributedString()
        
        // Check if network is disconnected - always show even when space is limited
        if !isNetworkConnected {
            // Show disconnected message
            text.append(NSAttributedString(string: "Offline", attributes: disconnectedAttrs))
            button.attributedTitle = text
            return
        }
        
        let down = showMaxSpeed ? maxDown : currentDown
        let up = showMaxSpeed ? maxUp : currentUp  // Fix: was using currentDown incorrectly
        
        // First, build the complete text with all enabled metrics
        let fullText = NSMutableAttributedString()
        
        // Add packet loss if enabled
        if showPacketLoss {
            let safeLoss = min(max(currentPacketLoss, 0.0), 100.0)
            var plAttributes = qualityAttrs
            if safeLoss > 10.0 {
                plAttributes = badQualityAttrs
            } else if safeLoss > 5.0 {
                plAttributes = warningAttrs
            }
            
            fullText.append(NSAttributedString(
                string: String(format: "L%.1f%% ", safeLoss),
                attributes: plAttributes
            ))
        }
        
        // Add jitter if enabled
        if showJitter {
            let safeJitter = max(currentJitter, 0.0)
            var jitterAttributes = qualityAttrs
            if safeJitter > 50.0 {
                jitterAttributes = badQualityAttrs
            } else if safeJitter > 20.0 {
                jitterAttributes = warningAttrs
            }
            
            fullText.append(NSAttributedString(
                string: String(format: "J%.1f ", safeJitter),
                attributes: jitterAttributes
            ))
        }
        
        // Add latency if enabled
        if showLatency {
            if currentLatency < 0 {
                fullText.append(NSAttributedString(
                    string: "∞ ms ",
                    attributes: warningAttrs
                ))
            } else if currentLatency > 1000 {
                fullText.append(NSAttributedString(
                    string: String(format: "%3.0fms ", currentLatency),
                    attributes: highLatencyAttrs
                ))
            } else {
                fullText.append(NSAttributedString(
                    string: String(format: "%3.0fms ", currentLatency),
                    attributes: latencyAttrs
                ))
            }
        }
        
        // Add the speed data (always shown)
        let speedText = NSMutableAttributedString()
        speedText.append(NSAttributedString(
            string: String(format: "%6.1f", down),
            attributes: attrs
        ))
        speedText.append(NSAttributedString(string: "↓", attributes: boldAttrs))
        
        speedText.append(NSAttributedString(
            string: String(format: "%6.1f", up),
            attributes: attrs
        ))
        speedText.append(NSAttributedString(string: "↑", attributes: boldAttrs))
        
        // Add max mode indicator if needed
        if showMaxSpeed {
            speedText.append(NSAttributedString(string: " [max]", attributes: attrs))
        }
        
        // Add speed text to the full text
        fullText.append(speedText)
        
        // Measure the width of the full text
        let fullWidth = measureWidth(of: fullText)
        
        // If there's enough space, show everything
        if (fullWidth < widthConstraintThreshold) {
            text.append(fullText)
            isWidthConstrained = false
            
            // Set the final display text and update length
            button.attributedTitle = text
            lastMeasuredWidth = measureWidth(of: text)
            speedStatusItem.length = lastMeasuredWidth + 8  // Fix: speedStatusItem instead of statusItem
            return
        }
        
        // We need to be selective about what to show
        isWidthConstrained = true
        
        // Start with just the speed text (always shown)
        let adaptiveText = NSMutableAttributedString(attributedString: speedText)
        var remainingWidth = widthConstraintThreshold - measureWidth(of: speedText)
        
        // Create a dictionary of metrics and their widths
        var metricsToDisplay: [(metric: NSAttributedString, width: CGFloat, priority: Int)] = []
        
        // Add latency if enabled (highest priority)
        if showLatency {
            let latencyText = NSMutableAttributedString()
            if currentLatency < 0 {
                latencyText.append(NSAttributedString(string: "∞ ms ", attributes: warningAttrs))
            } else if currentLatency > 1000 {
                latencyText.append(NSAttributedString(
                    string: String(format: "%3.0fms ", currentLatency),
                    attributes: highLatencyAttrs
                ))
            } else {
                latencyText.append(NSAttributedString(
                    string: String(format: "%3.0fms ", currentLatency),
                    attributes: latencyAttrs
                ))
            }
            let width = measureWidth(of: latencyText)
            metricsToDisplay.append((latencyText, width, 1)) // Priority 1 (highest)
        }
        
        // Add packet loss if enabled (medium priority)
        if showPacketLoss {
            let safeLoss = min(max(currentPacketLoss, 0.0), 100.0)
            var plAttributes = qualityAttrs
            if safeLoss > 10.0 {
                plAttributes = badQualityAttrs
            } else if safeLoss > 5.0 {
                plAttributes = warningAttrs
            }
            
            let lossText = NSAttributedString(
                string: String(format: "L%.1f%% ", safeLoss),
                attributes: plAttributes
            )
            let width = measureWidth(of: lossText)
            metricsToDisplay.append((lossText, width, 2)) // Priority 2
        }
        
        // Add jitter if enabled (lowest priority)
        if showJitter {
            let safeJitter = max(currentJitter, 0.0)
            var jitterAttributes = qualityAttrs
            if safeJitter > 50.0 {
                jitterAttributes = badQualityAttrs
            } else if safeJitter > 20.0 {
                jitterAttributes = warningAttrs
            }
            
            let jitterText = NSAttributedString(
                string: String(format: "J%.1f ", safeJitter),
                attributes: jitterAttributes
            )
            let width = measureWidth(of: jitterText)
            metricsToDisplay.append((jitterText, width, 3)) // Priority 3 (lowest)
        }
        
        // Sort metrics by priority
        metricsToDisplay.sort { $0.priority < $1.priority }
        
        // Space for ellipsis if needed
        let ellipsisAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
        ]
        let ellipsisText = NSAttributedString(string: "... ", attributes: ellipsisAttrs)
        let ellipsisWidth = measureWidth(of: ellipsisText)
        
        // Add as many metrics as will fit
        var displayedMetrics: [NSAttributedString] = []
        var willHideMetrics = false
        
        for (metric, width, _) in metricsToDisplay {
            // Check if we need to reserve space for ellipsis
            let spaceNeeded = width + (willHideMetrics ? ellipsisWidth : 0)
            
            if remainingWidth >= spaceNeeded {
                // We have space for this metric
                displayedMetrics.append(metric)
                remainingWidth -= width
            } else {
                // Can't fit this metric
                willHideMetrics = true
            }
        }
        
        // Add ellipsis if we're hiding metrics
        let finalText = NSMutableAttributedString()
        if (willHideMetrics) {
            finalText.append(ellipsisText)
        }
        
        // Add all displayed metrics
        for metric in displayedMetrics {
            finalText.append(metric)
        }
        
        // Add the speed data
        finalText.append(speedText)
        
        // Now we can assign to text since it's a variable
        text = finalText
        button.attributedTitle = text
        
        // Update width tracking
        lastMeasuredWidth = measureWidth(of: text)
        speedStatusItem.length = lastMeasuredWidth + 8 // Fix: speedStatusItem instead of statusItem
    }
    
    // Setup observers for changes that might affect status bar space
    private func setupScreenChangeObservers() {
        // Watch for screen changes
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.handlePossibleStatusBarSizeChange()
        }
        
        // Start a timer to occasionally check status bar contents
        statusBarWatcher = Timer.scheduledTimer(
            withTimeInterval: 5.0, // Check every 5 seconds
            repeats: true
        ) { [weak self] _ in
            guard let self = self else { return }
            self.detectStatusBarChanges()
        }
        
        // Initial capture of screen state
        lastScreenWidth = NSScreen.main?.visibleFrame.width ?? 0
        detectStatusBarChanges()
        
        // Also check visibility periodically
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkStatusItemVisibility()
        }
    }
    
    // Detect changes in status bar that might affect available space
    private func detectStatusBarChanges() {
        // Get the screen width - we can't directly access status items
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 0
        
        // If screen size changed significantly
        if abs(lastScreenWidth - screenWidth) > 10 {
            handlePossibleStatusBarSizeChange()
            
            // Update our tracking variable
            lastScreenWidth = screenWidth
        }
    }
    
    // Handle potential changes in available space
    private func handlePossibleStatusBarSizeChange() {
        // When the environment changes, adjust our threshold
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 0
        
        // Use a percentage of screen width as our heuristic
        // instead of trying to count status items (which we can't access)
        let estimatedAvailableWidth = min(screenWidth / 6, 300)  // Assume ~6 items in status bar
        
        // Update our threshold dynamically
        let newThreshold = max(estimatedAvailableWidth, 120) // Never go below 120
        
        // Log if the threshold changed significantly
        if abs(widthConstraintThreshold - newThreshold) > 10 {
            print("Status bar environment changed - adjusted width threshold from \(widthConstraintThreshold) to \(newThreshold)")
        }
        
        // Update our threshold
        widthConstraintThreshold = newThreshold
        
        // Update display with the new width calculation
        self.updateSpeedOnly()
    }
    
    // Add a method to check for visibility based on menu display
    private func checkStatusItemVisibility() {
        // Used to test if our status item is potentially visible
        let originalLength = speedStatusItem.length  // Fix: speedStatusItem instead of statusItem
        let testLength = originalLength - 1
        
        // Temporarily adjust length - if this would cause the item to
        // become hidden, the OS might discard the change
        speedStatusItem.length = testLength  // Fix: speedStatusItem instead of statusItem
        
        // Check if length changed successfully (indicating potential visibility)
        let wasChanged = speedStatusItem.length == testLength  // Fix: speedStatusItem instead of statusItem
        
        // Restore original length
        speedStatusItem.length = originalLength  // Fix: speedStatusItem instead of statusItem
        
        // If length doesn't change, it might be hidden already
        if !wasChanged {
            print("Status item may be hidden by system")
            
            // Make the item more compact to increase chances of visibility
            widthConstraintThreshold = 120 // Very compact mode
            updateSpeedOnly()
            
            // Schedule a check to see if we can restore normal size
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.checkForRestoreNormalSize()
            }
        }
    }
    
    private func checkForRestoreNormalSize() {
        // Try to restore to normal size if screen size allows
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 0
        let estimatedAvailableWidth = min(screenWidth / 6, 300)
        
        // Carefully restore size if reasonable
        if estimatedAvailableWidth > 150 {
            widthConstraintThreshold = estimatedAvailableWidth
            updateSpeedOnly()
        }
    }
    
    private func setupStatusBarItems() {
        // Create the main speed display item (highest priority, always visible if possible)
        speedStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = speedStatusItem.button {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
            let boldAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
            ]
            
            let initialText = NSMutableAttributedString()
            initialText.append(NSAttributedString(string: "0.0", attributes: attrs))
            initialText.append(NSAttributedString(string: "↓", attributes: boldAttrs))
            initialText.append(NSAttributedString(string: "0.0", attributes: attrs))
            initialText.append(NSAttributedString(string: "↑", attributes: boldAttrs))
            
            button.attributedTitle = initialText
        }
        
        // Create individual menus for each status item
        let bandwidthMenu = createMenu(for: .bandwidth)
        let latencyMenu = createMenu(for: .latency)
        let qualityMenu = createMenu(for: .quality)
        
        // Assign menus to status items
        speedStatusItem.menu = bandwidthMenu
        
        // Create separate item for latency if enabled
        if showLatency {
            createLatencyStatusItem(withMenu: latencyMenu)
        }
        
        // Create separate item for network quality if enabled
        if showPacketLoss || showJitter {
            createQualityStatusItem(withMenu: qualityMenu)
        }
        
        // Create traffic status item to display total traffic used
        if let menu = speedStatusItem.menu, showTotalTraffic {
            createTrafficStatusItem(withMenu: menu)  // NEW: Only create if enabled
        }
    }
    
    private func createLatencyStatusItem(withMenu menu: NSMenu) {
        latencyStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = latencyStatusItem?.button {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
            
            button.attributedTitle = NSAttributedString(string: "∞ ms", attributes: attrs)
            
            
            // Directly assign the menu
            latencyStatusItem?.menu = menu
        }
    }
    
    private func createQualityStatusItem(withMenu menu: NSMenu) {
        qualityStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = qualityStatusItem?.button {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
            
            let text = showPacketLoss && showJitter ? "L0.0% J0.0" : 
                      showPacketLoss ? "L0.0%" : "J0.0"
            
            button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
            
            // No need for action method anymore
            // button.action = #selector(statusItemClicked(_:))
            // button.target = self
            
            // Directly assign the menu
            qualityStatusItem?.menu = menu
        }
    }
    
    // New helper to create the traffic status item
    private func createTrafficStatusItem(withMenu menu: NSMenu) {
        trafficStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = trafficStatusItem?.button {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
            let text = String(format: "%.2fGB", totalTrafficGB)
            button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        }
        // Removed menu assignment to avoid interference:
        // trafficStatusItem?.menu = menu
        // Set a fixed length to ensure the traffic status item is visible
        // trafficStatusItem?.length = 130
    }
    
    // New helper to update the traffic display
    private func updateTrafficDisplay() {
        guard let button = trafficStatusItem?.button else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]
        let text = String(format: "%.2fGB", totalTrafficGB)
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }
    
    // Create individual menus for each status item type
    private func createMenu(for type: StatusItemType) -> NSMenu {
        let menu = NSMenu()
        
        // Set delegate and tag to identify menu type
        menu.delegate = self
        menu.autoenablesItems = true
        
        // Store the type in our dictionary instead of using representedObject
        menuTypeMap[menu] = type
        
        // Create menu items based on status item type
        let modeGroup = NSMenu()
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeGroup
        
        let liveMenuItem = NSMenuItem(title: "Live Bandwidth", action: #selector(setLiveMode), keyEquivalent: "l")
        let maxMenuItem = NSMenuItem(title: "Max Bandwidth", action: #selector(setMaxMode), keyEquivalent: "m")
        let resetMaxMenuItem = NSMenuItem(title: "Reset Max", action: #selector(resetMaxSpeed), keyEquivalent: "r")
        modeGroup.addItem(liveMenuItem)
        modeGroup.addItem(maxMenuItem)
        modeGroup.addItem(resetMaxMenuItem)
        
        // Add Latency toggle option
        modeGroup.addItem(NSMenuItem.separator())
        let latencyMenuItem = NSMenuItem(title: "Show Latency", action: #selector(toggleLatency), keyEquivalent: "p")
        latencyMenuItem.state = showLatency ? .on : .off
        modeGroup.addItem(latencyMenuItem)
        
        let packetLossMenuItem = NSMenuItem(title: "Show Packet Loss", action: #selector(togglePacketLoss), keyEquivalent: "k")
        packetLossMenuItem.state = showPacketLoss ? .on : .off
        modeGroup.addItem(packetLossMenuItem)
        
        let jitterMenuItem = NSMenuItem(title: "Show Jitter", action: #selector(toggleJitter), keyEquivalent: "j")
        jitterMenuItem.state = showJitter ? .on : .off
        modeGroup.addItem(jitterMenuItem)
        
        // NEW: Add "Show Total Traffic" toggle with key equivalent "g"
        modeGroup.addItem(NSMenuItem.separator())
        let trafficMenuItem = NSMenuItem(title: "Show Total Traffic", action: #selector(toggleTraffic), keyEquivalent: "g")
        trafficMenuItem.state = showTotalTraffic ? .on : .off
        modeGroup.addItem(trafficMenuItem)
        
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
        
        return menu
    }
    
    private func updateSpeedDisplay(currentDown: Double, currentUp: Double, maxDown: Double, maxUp: Double) {
        guard let button = speedStatusItem.button else { return }
        
        if !isNetworkConnected {
            // Show disconnected indicator
            button.attributedTitle = NSAttributedString(string: "Offline", attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.white
            ])
            return
        }
        
        let down = showMaxSpeed ? maxDown : currentDown
        let up = showMaxSpeed ? maxUp : currentUp
        
        // Create speed text (simpler now, no additional metrics)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]
        let boldAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
        ]
        
        let speedText = NSMutableAttributedString()
        speedText.append(NSAttributedString(
            string: String(format: "%.1f", down),
            attributes: attrs
        ))
        speedText.append(NSAttributedString(string: "↓", attributes: boldAttrs))
        
        speedText.append(NSAttributedString(
            string: String(format: "%.1f", up),
            attributes: attrs
        ))
        speedText.append(NSAttributedString(string: "↑", attributes: boldAttrs))
        
        // Add max mode indicator if needed
        if showMaxSpeed {
            speedText.append(NSAttributedString(string: " [max]", attributes: attrs))
        }
        
        button.attributedTitle = speedText
    }
    
    private func updateLatencyDisplay() {
        // If latency is disabled or network is disconnected, remove the item
        if !showLatency || !isNetworkConnected {
            removeLatencyStatusItem()
            return
        }
        
        // Create item if needed
        if latencyStatusItem == nil {
            createLatencyStatusItem(withMenu: speedStatusItem.menu!)
        }
        
        // Exit if we don't have a valid button (after potential creation)
        guard let button = latencyStatusItem?.button else { return }
        
        // Set appropriate attributes based on latency value
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]
        
        let latencyText: String
        
        if currentLatency < 0 {
            latencyText = "∞ ms"
            attrs[.foregroundColor] = NSColor.yellow
        } else if currentLatency > 1000 {
            latencyText = String(format: "%3.0fms", currentLatency)
            attrs[.foregroundColor] = NSColor.yellow
            attrs[.font] = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        } else {
            latencyText = String(format: "%3.0fms", currentLatency)
        }
        
        button.attributedTitle = NSAttributedString(string: latencyText, attributes: attrs)
    }
    
    private func updateQualityDisplay() {
        // Only update if quality metrics are enabled
        if !showPacketLoss && !showJitter || !isNetworkConnected {
            removeQualityStatusItem()
            return
        }
        
        // Create item if needed
        if qualityStatusItem == nil {
            createQualityStatusItem(withMenu: speedStatusItem.menu!)
        }
        
        guard let button = qualityStatusItem?.button else { return }
        
        let qualityText = NSMutableAttributedString()
        
        // Add packet loss if enabled
        if showPacketLoss {
            let safeLoss = min(max(currentPacketLoss, 0.0), 100.0)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
            
            if safeLoss > 10.0 {
                attrs[.foregroundColor] = NSColor.yellow
            } else if safeLoss > 5.0 {
                attrs[.foregroundColor] = NSColor.yellow
            }
            
            qualityText.append(NSAttributedString(
                string: String(format: "L%.1f%%", safeLoss),
                attributes: attrs
            ))
            
            // Add separator if we'll also show jitter
            if showJitter {
                qualityText.append(NSAttributedString(string: " ", attributes: attrs))
            }
        }
        
        // Add jitter if enabled
        if showJitter {
            let safeJitter = max(currentJitter, 0.0)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
            
            if safeJitter > 50.0 {
                attrs[.foregroundColor] = NSColor.yellow
            } else if safeJitter > 20.0 {
                attrs[.foregroundColor] = NSColor.yellow
            }
            
            qualityText.append(NSAttributedString(
                string: String(format: "J%.1f", safeJitter),
                attributes: attrs
            ))
        }
        
        button.attributedTitle = qualityText
    }
    
    private func removeLatencyStatusItem() {
        if let item = latencyStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            latencyStatusItem = nil
        }
    }
    
    private func removeQualityStatusItem() {
        if let item = qualityStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            qualityStatusItem = nil
        }
    }
    
    // Helper method to update menu item states in all menus
    private func updateMenuItemState(keyEquivalent: String, state: NSControl.StateValue) {
        // Update the state in all three menus
        [speedStatusItem.menu, latencyStatusItem?.menu, qualityStatusItem?.menu].forEach { menu in
            if let modeMenu = menu?.items.first(where: { $0.title == "Mode" })?.submenu,
               let item = modeMenu.items.first(where: { $0.keyEquivalent == keyEquivalent }) {
                item.state = state
            }
        }
    }
}
    
// MARK: - NSMenuDelegate methods

// Conform to NSMenuDelegate to customize menu before it opens
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Remove any previous header
        if let firstItem = menu.items.first, firstItem.isSeparatorItem == false && firstItem.isEnabled == false {
            menu.removeItem(at: 0)
        }
        
        // Determine which item was clicked based on our menuTypeMap
        let itemType = menuTypeMap[menu] ?? .bandwidth
        
        var headerTitle: String
        
        switch itemType {
        case .bandwidth:
            headerTitle = showMaxSpeed ? "Max Bandwidth" : "Bandwidth"
        case .latency:
            headerTitle = "Latency (Ping Time)"
        case .quality:
            if showPacketLoss && showJitter {
                headerTitle = "Network Quality"
            } else if showPacketLoss {
                headerTitle = "Packet Loss"
            } else {
                headerTitle = "Jitter"
            }
        }
        
        // Add the header as a disabled menu item
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        
        // Apply custom attributes to make it stand out
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.gray
        ]
        headerItem.attributedTitle = NSAttributedString(string: headerTitle, attributes: attributes)
        
        // Insert at the beginning of the menu
        menu.insertItem(headerItem, at: 0)
        
        // Add a separator after the header
        menu.insertItem(NSMenuItem.separator(), at: 1)
    }
}

// Create and start the application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
