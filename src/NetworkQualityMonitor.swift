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
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        // Start a timer that executes quality checks
        monitorTimer = Timer.scheduledTimer(
            timeInterval: pingInterval,
            target: self,
            selector: #selector(checkNetworkQuality),
            userInfo: nil,
            repeats: true
        )
        
        // Trigger first check immediately
        checkNetworkQuality()
    }
    
    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        isMonitoring = false
    }
    
    @objc private func checkNetworkQuality() {
        measurePacketLossAndJitter()
    }
    
    private func measurePacketLossAndJitter() {
        // Use a safer host for pinging
        guard let url = URL(string: "https://\(pingHost)/favicon.ico") else { return }
        
        let startTime = Date()
        packetsSent += 1
        
        // Configure session for quick ping
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config)
        
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if error == nil, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                // Successful ping
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
                    Double(self.packetsSent - self.packetsReceived) / Double(self.packetsSent) * 100.0 : 0.0
                
                // Calculate jitter (variation in ping times)
                let jitter = self.calculateJitter()
                
                // Reset counters after a while to ensure we're measuring recent performance
                if self.packetsSent > 100 {
                    self.packetsSent = self.packetsSent / 2
                    self.packetsReceived = self.packetsReceived / 2
                }
                
                // Notify listeners
                DispatchQueue.main.async {
                    self.onQualityUpdate?(packetLoss, jitter)
                }
            } else {
                // Failed ping - this counts as packet loss
                
                // Calculate packet loss percentage
                let packetLoss = self.packetsSent > 0 ? 
                    Double(self.packetsSent - self.packetsReceived) / Double(self.packetsSent) * 100.0 : 0.0
                
                // Calculate jitter with the existing data
                let jitter = self.calculateJitter()
                
                // Notify listeners
                DispatchQueue.main.async {
                    self.onQualityUpdate?(packetLoss, jitter)
                }
            }
        }
        
        // Execute ping
        task.resume()
    }
    
    private func calculateJitter() -> Double {
        guard pingTimes.count >= 2 else {
            return 0.0
        }
        
        // Calculate average of absolute differences between consecutive ping times
        var totalJitter = 0.0
        for i in 1..<pingTimes.count {
            totalJitter += abs(pingTimes[i] - pingTimes[i-1])
        }
        
        return totalJitter / Double(pingTimes.count - 1)
    }
}
