import Foundation
import Network

class NetworkQualityMonitor {
    // Callback to be triggered when network quality metrics are updated
    var onQualityUpdate: ((Double, Double) -> Void)?
    
    private var monitorTimer: Timer?
    private var isMonitoring = false
    private let pingHost = "www.apple.com"
    private let pingInterval: TimeInterval = 10.0
    
    // Reference values for packet loss and jitter calculations
    private var packetsSent = 0
    private var packetsReceived = 0
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
            
            if error == nil, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                // Successful ping - thread-safe updates
                self.lock.lock()
                
                self.packetsReceived += 1
                
                // Calculate ping time
                let pingTime = Date().timeIntervalSince(startTime) * 1000 // in ms
                
                // Add to our ping times array
                self.pingTimes.append(pingTime)
                
                // Keep only the most recent values
                if self.pingTimes.count > self.maxPingTimesToKeep {
                    self.pingTimes.removeFirst()
                }
                
                // Calculate packet loss percentage
                let packetLoss = self.packetsSent > 0 ? 
                    min(Double(self.packetsSent - self.packetsReceived) / Double(self.packetsSent) * 100.0, 100.0) : 0.0
                
                // Calculate jitter (variation in ping times)
                let jitter = self.calculateJitter()
                
                // Reset counters after a while to ensure we're measuring recent performance
                if self.packetsSent > 50 {
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
            } else {
                // Failed ping - this counts as packet loss
                self.lock.lock()
                
                // Calculate packet loss percentage
                let packetLoss = self.packetsSent > 0 ? 
                    min(Double(self.packetsSent - self.packetsReceived) / Double(self.packetsSent) * 100.0, 100.0) : 0.0
                
                // Calculate jitter with the existing data
                let jitter = self.calculateJitter()
                
                self.lock.unlock()
                
                // Notify listeners with safe values
                let safeLoss = min(max(packetLoss, 0.0), 100.0)
                let safeJitter = max(jitter, 0.0)
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isMonitoring else { return }
                    self.onQualityUpdate?(safeLoss, safeJitter)
                }
            }
        }
        
        // Execute ping with error handling
        do {
            task.resume()
        } catch {
            print("Network quality monitoring error: \(error.localizedDescription)")
        }
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
