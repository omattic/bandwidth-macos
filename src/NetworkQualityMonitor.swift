import Foundation
import Network

class NetworkQualityMonitor {
    // Callback to be triggered when network quality metrics are updated
    var onQualityUpdate: ((Double, Double) -> Void)?
    
    private var monitorTimer: Timer?
    private var isMonitoring = false
    private let pingHost = "www.apple.com"
    // Reduce the ping interval for more frequent updates
    private let pingInterval: TimeInterval = 5.0
    
    // Reference values for packet loss and jitter calculations
    private var packetsSent = 0
    private var packetsReceived = 0
    
    // Add sliding window structures for more responsive measurements
    private var recentResults: [(sent: Bool, timestamp: Date)] = []
    private let windowSize = 20 // Keep track of last 20 ping attempts
    private let recentWindowSize = 5 // Give more weight to the most recent pings
    
    private var pingTimes: [TimeInterval] = []
    private let maxPingTimesToKeep = 10
    
    // Add thread safety
    private let lock = NSLock()
    
    // Add operation queue for network requests to prevent overload
    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "NetworkQualityMonitorQueue"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    deinit {
        stopMonitoring()
    }
    
    func startMonitoring() {
        // Make thread-safe
        lock.lock()
        defer { lock.unlock() }
        
        guard !isMonitoring else { return }
        isMonitoring = true
        
        // Clear any existing measurements for a fresh start
        recentResults.removeAll()
        packetsSent = 0
        packetsReceived = 0
        
        // Use DispatchSourceTimer instead of Timer for better reliability
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Start with a delayed measurement to avoid startup issues
            self.monitorTimer = Timer.scheduledTimer(
                withTimeInterval: self.pingInterval,
                repeats: true
            ) { [weak self] _ in
                guard let self = self, self.isMonitoring else { return }
                
                // Queue the check on a background thread
                self.operationQueue.addOperation {
                    self.checkNetworkQuality()
                }
            }
            
            // Make timer more tolerant
            self.monitorTimer?.tolerance = 1.0
            
            // Schedule initial measurement with a delay
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, self.isMonitoring else { return }
                self.checkNetworkQuality()
            }
        }
    }
    
    func stopMonitoring() {
        // Make thread-safe
        lock.lock()
        defer { lock.unlock() }
        
        // Cancel all pending operations
        operationQueue.cancelAllOperations()
        
        monitorTimer?.invalidate()
        monitorTimer = nil
        isMonitoring = false
    }
    
    @objc private func checkNetworkQuality() {
        // Add safety check
        guard isMonitoring else { return }
        
        // Ensure we're on a background thread
        if Thread.isMainThread {
            operationQueue.addOperation { [weak self] in
                self?.measurePacketLossAndJitter()
            }
        } else {
            measurePacketLossAndJitter()
        }
    }
    
    private func measurePacketLossAndJitter() {
        // Add extra safety to prevent app crashes
        guard isMonitoring else { return }
        
        // Use a safer host for pinging
        guard let url = URL(string: "https://\(pingHost)/favicon.ico") else { return }
        
        let startTime = Date()
        
        // Thread-safe increment
        lock.lock()
        packetsSent += 1
        // Add this attempt to our recent results
        recentResults.append((sent: true, timestamp: Date()))
        
        // Maintain the sliding window size
        if recentResults.count > windowSize {
            recentResults.removeFirst()
        }
        lock.unlock()
        
        // Configure session for quick ping
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config)
        
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            // Verify we're still monitoring
            guard self.isMonitoring else { return }
            
            self.lock.lock()
            
            if error == nil, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                // Successful ping - thread-safe updates
                self.packetsReceived += 1
                
                // Update the most recent ping attempt as successful
                if let lastIndex = self.recentResults.indices.last {
                    // Mark as received
                    let timestamp = self.recentResults[lastIndex].timestamp
                    self.recentResults[lastIndex] = (sent: false, timestamp: timestamp)
                }
                
                // Calculate ping time
                let pingTime = Date().timeIntervalSince(startTime) * 1000 // in ms
                
                // Add to our ping times array
                self.pingTimes.append(pingTime)
                
                // Keep only the most recent values
                if self.pingTimes.count > self.maxPingTimesToKeep {
                    self.pingTimes.removeFirst()
                }
            } else {
                // Failed ping - leave the entry as sent but not received
                // The lastIndex is already marked as sent=true
            }
            
            // Calculate packet loss with recent bias
            let packetLoss = self.calculatePacketLoss()
            
            // Calculate jitter (variation in ping times)
            let jitter = self.calculateJitter()
            
            // Reset counters more frequently to be more responsive to changes
            if self.packetsSent > 30 {
                self.packetsSent = max(self.packetsSent / 2, 1)
                self.packetsReceived = max(self.packetsReceived / 2, 0)
            }
            
            // Release lock before UI callback
            self.lock.unlock()
            
            // Notify listeners with safe values
            let safeLoss = min(max(packetLoss, 0.0), 100.0)
            let safeJitter = max(jitter, 0.0)
            
            // Switch to main thread for UI updates
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isMonitoring else { return }
                self.onQualityUpdate?(safeLoss, safeJitter)
            }
        }
        
        // Execute ping with error handling
        do {
            task.resume()
        } catch {
            print("Network quality monitoring error: \(error.localizedDescription)")
        }
    }
    
    // New method for more responsive packet loss calculation
    private func calculatePacketLoss() -> Double {
        // If we don't have enough data yet, use the traditional method
        if recentResults.count < 3 {
            return packetsSent > 0 ? 
                min(Double(packetsSent - packetsReceived) / Double(packetsSent) * 100.0, 100.0) : 0.0
        }
        
        // Calculate loss using sliding window with bias toward recent results
        
        // First get the overall window packet loss
        let lostPackets = recentResults.filter { $0.sent }.count - packetsReceived
        let windowLoss = recentResults.count > 0 ? 
            Double(lostPackets) / Double(recentResults.count) * 100.0 : 0.0
        
        // Then calculate recent window packet loss (more weight to recent packets)
        let recentWindow = recentResults.suffix(min(recentWindowSize, recentResults.count))
        let recentLostPackets = recentWindow.filter { $0.sent }.count - 
                               recentWindow.filter { !$0.sent }.count
        let recentLoss = recentWindow.count > 0 ? 
            Double(recentLostPackets) / Double(recentWindow.count) * 100.0 : 0.0
        
        // Combine with bias toward recent measurements (70% recent, 30% overall)
        let weightedLoss = (recentLoss * 0.7) + (windowLoss * 0.3)
        
        // Ensure the value is in valid range
        return min(max(weightedLoss, 0.0), 100.0)
    }
    
    private func calculateJitter() -> Double {
        // Thread safety should be handled by caller
        
        guard pingTimes.count >= 2 else {
            return 0.0
        }
        
        // Calculate average of absolute differences between consecutive ping times
        // Use a more stable algorithm
        var totalJitter = 0.0
        var count = 0
        
        for i in 1..<pingTimes.count {
            let diff = abs(pingTimes[i] - pingTimes[i-1])
            // Filter out extreme outliers that could cause instability
            if diff < 1000 { // Ignore differences over 1 second
                totalJitter += diff
                count += 1
            }
        }
        
        return count > 0 ? (totalJitter / Double(count)) : 0.0
    }
}
