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
    static let showTotalTraffic = "showTotalTraffic"
    static let totalTrafficValue = "totalTrafficValue"  // NEW: Key for storing the total traffic value
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
        
        // NEW: Add "Reset Total Traffic" option with key equivalent "e" (not "r" which is already used for "Reset Max")
        let resetTrafficMenuItem = NSMenuItem(title: "Reset Total Traffic", action: #selector(resetTotalTraffic), keyEquivalent: "e")
        modeGroup.addItem(resetTrafficMenuItem)
        
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            self.networkQualityMonitor.startMonitoring()
        }
        
        // Start with saved total traffic count instead of resetting to 0
        totalTrafficGB = UserDefaults.standard.double(forKey: PreferenceKeys.totalTrafficValue)
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
        showTotalTraffic = defaults.object(forKey: PreferenceKeys.showTotalTraffic) as? Bool ?? true
        
        // Load the total traffic value with a default of 0.0
        totalTrafficGB = defaults.double(forKey: PreferenceKeys.totalTrafficValue)
        
        print("📋 Loaded preferences: Max=\(showMaxSpeed), Latency=\(showLatency), Loss=\(showPacketLoss), Jitter=\(showJitter), Traffic=\(showTotalTraffic), TrafficValue=\(totalTrafficGB)GB")
    }
    
    // Save current preferences to UserDefaults
    private func savePreferences() {
        let defaults = UserDefaults.standard
        
        defaults.set(showMaxSpeed, forKey: PreferenceKeys.showMaxSpeed)
        defaults.set(showLatency, forKey: PreferenceKeys.showLatency)
        defaults.set(showPacketLoss, forKey: PreferenceKeys.showPacketLoss)
        defaults.set(showJitter, forKey: PreferenceKeys.showJitter)
        defaults.set(showNetworkQuality, forKey: PreferenceKeys.showNetworkQuality)
        defaults.set(showTotalTraffic, forKey: PreferenceKeys.showTotalTraffic)
        
        // Save the current total traffic value - using exactly the current value in memory
        defaults.set(totalTrafficGB, forKey: PreferenceKeys.totalTrafficValue)
        
        // Ensure values are written to disk immediately
        defaults.synchronize()
        
        print("💾 Saved preferences: Max=\(showMaxSpeed), Latency=\(showLatency), Loss=\(showPacketLoss), Jitter=\(showJitter), Traffic=\(showTotalTraffic), TrafficValue=\(totalTrafficGB)GB")
    }
    
    @objc private func updateSpeedOnly() {
        // First check network availability before measuring speed
        self.isNetworkConnected = checkNetworkSafely()
        
        // If network is available, measure actual speeds
        if self.isNetworkConnected {
            // Add defensive error handling around speedMonitor.measureSpeed
            do {
                // Use the speedMonitor to get actual bandwidth values
                speedMonitor.measureSpeed { [weak self] currentDown, currentUp, maxDown, maxUp, currentLatency, avgLatency in
                    guard let self = self else { return }
                    
                    // Add defensive bounds checking
                    let safeCurrentDown = max(0, isFinite(currentDown) ? currentDown : 0)
                    let safeCurrentUp = max(0, isFinite(currentUp) ? currentUp : 0)
                    let safeMaxDown = max(0, isFinite(maxDown) ? maxDown : 0)
                    let safeMaxUp = max(0, isFinite(maxUp) ? maxUp : 0)
                    
                    // Safely increment traffic counter (assumes update interval is 2 sec)
                    if safeCurrentDown >= 0 && safeCurrentUp >= 0 {
                        let trafficIncrement = (safeCurrentDown + safeCurrentUp) * 0.00025  // (GB) estimate
                        if trafficIncrement >= 0 && trafficIncrement < 1000 { // Sanity check
                            self.totalTrafficGB += trafficIncrement
                            
                            // Save traffic value periodically (not every time to reduce disk I/O)
                            // Only save every ~60 seconds (30 updates at 2-sec intervals) - less frequent saves
                            if Int.random(in: 0...29) == 0 {
                                UserDefaults.standard.set(self.totalTrafficGB, forKey: PreferenceKeys.totalTrafficValue)
                            }
                        }
                    }
                    
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.updateSpeedDisplay(currentDown: safeCurrentDown, 
                                                currentUp: safeCurrentUp, 
                                                maxDown: safeMaxDown, 
                                                maxUp: safeMaxUp)
                        self.updateLatencyDisplay()
                        self.updateQualityDisplay()
                        // Update traffic display after other metrics
                        self.updateTrafficDisplay()
                    }
                }
            } catch {
                // Handle errors from measureSpeed
                print("Error measuring speed: \(error.localizedDescription)")
                
                // Update UI with zeros on error
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.updateSpeedDisplay(currentDown: 0.0, currentUp: 0.0, maxDown: 0.0, maxUp: 0.0)
                    self.updateLatencyDisplay()
                    self.updateQualityDisplay()
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
    
    // Add a helper function to check if a Double is finite
    private func isFinite(_ value: Double) -> Bool {
        return value.isFinite && !value.isNaN
    }
    
    private func updateTrafficDisplay() {
        guard let button = trafficStatusItem?.button else { return }
        
        // Use more defensive formatting with bounds checking
        let safeTraffic = max(0, min(totalTrafficGB, Double.greatestFiniteMagnitude / 2))
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]
        
        // Format differently based on size to avoid very long numbers
        let text: String
        if safeTraffic < 0.01 {
            text = "0.00GB"
        } else if safeTraffic < 100 {
            text = String(format: "%.2fGB", safeTraffic)
        } else if safeTraffic < 1000 {
            text = String(format: "%.1fGB", safeTraffic)
        } else {
            text = String(format: "%.1fTB", safeTraffic / 1000)
        }
        
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }
    
    @objc private func resetTotalTraffic() {
        // Set value to exactly zero
        totalTrafficGB = 0.0
        
        // Remove any stored value with removeObject instead of potentially setting a floating point value
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: PreferenceKeys.totalTrafficValue)
        defaults.set(0.0, forKey: PreferenceKeys.totalTrafficValue)
        
        // Force synchronization
        defaults.synchronize()
        
        // Update UI
        updateTrafficDisplay()
        
        // Log the reset
        print("🔄 Total traffic counter reset to 0.0 GB and persisted to disk")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Only save preferences through the proper method to avoid double-saving
        savePreferences()
        
        // Clean up resources
        networkMonitor.stopMonitoring() 
        
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
    
    // MARK: - UI Setup Methods
    
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
        
        // Create latency status item if enabled
        if showLatency {
            latencyStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            
            if let button = latencyStatusItem?.button {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                ]
                button.attributedTitle = NSAttributedString(string: "-- ms", attributes: attrs)
            }
        }
        
        // Create quality status item if packet loss or jitter is enabled
        if showPacketLoss || showJitter {
            qualityStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            
            if let button = qualityStatusItem?.button {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                ]
                button.attributedTitle = NSAttributedString(string: "0% loss", attributes: attrs)
            }
        }
        
        // Create separate item for traffic if enabled
        if showTotalTraffic {
            trafficStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            
            if let button = trafficStatusItem?.button {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                ]
                button.attributedTitle = NSAttributedString(string: "0.00GB", attributes: attrs)
            }
        }
    }
    
    private func updateLatencyDisplay() {
        // First check if latency display should be shown
        if showLatency {
            // Create the latency item if it doesn't exist
            if latencyStatusItem == nil {
                latencyStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
            
            // Update the display
            if let button = latencyStatusItem?.button {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                ]
                
                let displayText: String
                
                if !isNetworkConnected {
                    displayText = "-- ms"
                } else if currentLatency < 0 {
                    displayText = "-- ms"
                } else {
                    displayText = String(format: "%.0f ms", currentLatency)
                }
                
                button.attributedTitle = NSAttributedString(string: displayText, attributes: attrs)
            }
        } else {
            // Remove the status item if it exists
            if let item = latencyStatusItem {
                NSStatusBar.system.removeStatusItem(item)
                latencyStatusItem = nil
            }
        }
    }
    
    private func updateQualityDisplay() {
        // Check if we should show packet loss or jitter
        if showPacketLoss || showJitter {
            // Create the quality item if it doesn't exist
            if qualityStatusItem == nil {
                qualityStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
            
            // Update the display
            if let button = qualityStatusItem?.button {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                ]
                
                let displayText: String
                
                if !isNetworkConnected {
                    displayText = "-- loss"
                } else {
                    // Decide what to display based on what's enabled
                    if showPacketLoss && showJitter {
                        displayText = String(format: "%.1f%% / %.0fms", currentPacketLoss, currentJitter)
                    } else if showPacketLoss {
                        displayText = String(format: "%.1f%% loss", currentPacketLoss)
                    } else if showJitter {
                        displayText = String(format: "%.0fms jtr", currentJitter)
                    } else {
                        displayText = "--"
                    }
                }
                
                button.attributedTitle = NSAttributedString(string: displayText, attributes: attrs)
            }
        } else {
            // Remove the status item if it exists and we're not showing either metric
            if let item = qualityStatusItem {
                NSStatusBar.system.removeStatusItem(item)
                qualityStatusItem = nil
            }
        }
    }
    
    // MARK: - Network Monitoring Methods
    
    private func startMonitoringNetworkChanges() {
        networkMonitor.startMonitoring { [weak self] isConnected in
            guard let self = self else { return }
            
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
    }
    
    private func checkNetworkSafely() -> Bool {
        return networkMonitor.checkIsConnected()
    }
    
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
    
    // MARK: - UI Update Methods
    
    private func updateMenuState() {
        guard let menu = speedStatusItem.menu else { return }
        
        // Update mode items
        if let modeMenu = menu.items.first(where: { $0.title == "Mode" })?.submenu {
            let liveItem = modeMenu.items.first { $0.keyEquivalent == "l" }
            let maxItem = modeMenu.items.first { $0.keyEquivalent == "m" }
            let resetItem = modeMenu.items.first { $0.keyEquivalent == "r" }
            
            // Live is always enabled when not testing
            liveItem?.isEnabled = !isTestingSpeed
            
            // Max and reset are enabled when in max mode and not testing
            maxItem?.isEnabled = !isTestingSpeed
            resetItem?.isEnabled = showMaxSpeed && !isTestingSpeed
            
            // Show current mode selection
            liveItem?.state = !showMaxSpeed ? .on : .off
            maxItem?.state = showMaxSpeed ? .on : .off
        }
        
        // Update test items
        let speedTestItem = menu.items.first { $0.title == "Speed Test" }
        speedTestItem?.isEnabled = !isTestingSpeed
        
        // Show/hide cancel test
        let cancelItem = menu.items.first { $0.keyEquivalent == "c" }
        cancelItem?.isHidden = !isTestingSpeed
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
    
    // MARK: - Mode Control Actions
    
    @objc private func setLiveMode() {
        showMaxSpeed = false
        maxModeStartTime = nil // Clear the max mode start time
        updateMenuState()
        updateSpeedOnly()
        savePreferences() // Save the new preference
    }
    
    @objc private func setMaxMode() {
        showMaxSpeed = true
        maxModeStartTime = Date() // Set the max mode start time
        updateMenuState()
        updateSpeedOnly()
        savePreferences() // Save the new preference
    }
    
    @objc private func resetMaxSpeed() {
        speedMonitor.resetMaxSpeeds()
        updateSpeedOnly()
    }
    
    // MARK: - Display Toggle Actions
    
    @objc private func toggleLatency() {
        showLatency.toggle()
        
        // Update the menu item state in all menus
        updateMenuItemState(keyEquivalent: "p", state: showLatency ? .on : .off)
        
        // Create or remove the latency status item
        if showLatency {
            if latencyStatusItem == nil {
                latencyStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                updateLatencyDisplay()
            }
        } else {
            if let item = latencyStatusItem {
                NSStatusBar.system.removeStatusItem(item)
                latencyStatusItem = nil
            }
        }
        
        updateSpeedOnly()
        savePreferences() // Save the new preference
    }
    
    @objc private func togglePacketLoss() {
        showPacketLoss.toggle()
        
        // Update the menu item state
        updateMenuItemState(keyEquivalent: "k", state: showPacketLoss ? .on : .off)
        
        // Create or remove the quality status item as needed
        updateQualityStatusItem()
        
        // Update the display immediately
        updateSpeedOnly()
        savePreferences() // Save the new preference
    }
    
    @objc private func toggleJitter() {
        showJitter.toggle()
        
        // Update the menu item state
        updateMenuItemState(keyEquivalent: "j", state: showJitter ? .on : .off)
        
        // Create or remove the quality status item as needed
        updateQualityStatusItem()
        
        // Update the display immediately
        updateSpeedOnly()
        savePreferences() // Save the new preference
    }
    
    @objc private func toggleTraffic() {
        showTotalTraffic.toggle()
        updateMenuItemState(keyEquivalent: "g", state: showTotalTraffic ? .on : .off)
        
        if showTotalTraffic {
            if trafficStatusItem == nil {
                setupTrafficStatusItem()
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
    
    private func setupTrafficStatusItem() {
        trafficStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateTrafficDisplay()
    }
    
    private func updateMenuItemState(keyEquivalent: String, state: NSControl.StateValue) {
        // Update the state in all menus
        if let menu = speedStatusItem.menu,
           let modeMenu = menu.items.first(where: { $0.title == "Mode" })?.submenu,
           let item = modeMenu.items.first(where: { $0.keyEquivalent == keyEquivalent }) {
            item.state = state
        }
    }
    
    // Helper method to update quality status item
    private func updateQualityStatusItem() {
        if showPacketLoss || showJitter {
            if qualityStatusItem == nil {
                qualityStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                updateQualityDisplay()
            } else {
                updateQualityDisplay()
            }
        } else {
            if let item = qualityStatusItem {
                NSStatusBar.system.removeStatusItem(item)
                qualityStatusItem = nil
            }
        }
    }
    
    // MARK: - Speed Test Actions
    
    @objc private func startQuickTest() {
        startSpeedTest(size: .medium, type: .combinedSerial)
    }
    
    @objc private func startDownloadTest_small() { startSpeedTest(size: .small, type: .download) }
    @objc private func startDownloadTest_medium() { startSpeedTest(size: .medium, type: .download) }
    @objc private func startDownloadTest_large() { startSpeedTest(size: .large, type: .download) }
    
    @objc private func startUploadTest_small() { startSpeedTest(size: .small, type: .upload) }
    @objc private func startUploadTest_medium() { startSpeedTest(size: .medium, type: .upload) }
    @objc private func startUploadTest_large() { startSpeedTest(size: .large, type: .upload) }
    
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
                self.updateSpeedOnly()
                
                // Reset the max mode start time - begins the 1-minute countdown
                self.maxModeStartTime = Date()
                
                // Show result based on test type
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
            self?.updateSpeedOnly()
        }
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
