import Foundation
import Network

class NetworkQualityMonitor {
    // Network quality metrics
    private(set) var packetLoss: Double = 0.0 // percentage
    private(set) var jitter: Double = 0.0 // milliseconds
    
    // Configuration
    private let pingInterval: TimeInterval = 1.0 // seconds between pings
    private let pingTimeout: TimeInterval = 2.0 // seconds to wait for ping response
    private let pingHistorySize = 10 // number of pings to keep for calculations
    
    // Tracking
    private var pingTimer: Timer?
    private var pingSentCount = 0
    private var pingReceivedCount = 0
    private var pingLatencies: [TimeInterval] = []
    private var isRunning = false
    private var lastPingTime: Date?
    
    // Endpoint for pings
    private let pingHost = "1.1.1.1" // Cloudflare DNS
    private let pingPort = 443 // HTTPS port
    
    // Callbacks for updates
    var onQualityUpdate: ((Double, Double) -> Void)? // packetLoss, jitter

    init() {
        // Initialize empty latency history
        pingLatencies = []
    }

    deinit {
        stopMonitoring()
    }
    
    func startMonitoring() {
        guard !isRunning else { return }
        isRunning = true
        
        // Reset metrics
        resetMetrics()
        
        // Start the ping timer
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
        
        // Send initial ping immediately
        sendPing()
    }
    
    func stopMonitoring() {
        isRunning = false
        pingTimer?.invalidate()
        pingTimer = nil
    }
    
    private func resetMetrics() {
        packetLoss = 0.0
        jitter = 0.0
        pingSentCount = 0
        pingReceivedCount = 0
        pingLatencies.removeAll()
    }
    
    private func sendPing() {
        guard isRunning else { return }
        
        // Increment sent count
        pingSentCount += 1
        lastPingTime = Date()
        
        // Set up the connection to the host
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(pingHost), port: NWEndpoint.Port(integerLiteral: UInt16(pingPort)))
        let connection = NWConnection(to: endpoint, using: .tcp)
        
        // Set up state handler
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                // Connection established successfully - record this as a successful ping
                if let sentTime = self.lastPingTime {
                    let latency = Date().timeIntervalSince(sentTime) * 1000 // convert to ms
                    self.recordSuccessfulPing(latency: latency)
                    connection.cancel() // Close the connection after success
                }
                
            case .failed, .cancelled:
                // Connection failed - record as packet loss
                self.recordFailedPing()
                
            default:
                // Other states - waiting for ready or failed
                break
            }
        }
        
        // Set up receive handler (we don't actually need to receive data)
        connection.receiveMessage { _, _, isComplete, error in
            if let error = error {
                print("Ping receive error: \(error)")
            }
        }
        
        // Start the connection
        connection.start(queue: .global())
        
        // Set up a timeout for the ping
        DispatchQueue.global().asyncAfter(deadline: .now() + pingTimeout) {
            // If the connection is not ready by now, consider it failed
            if connection.state != .ready {
                connection.cancel()
            }
        }
    }
    
    private func recordSuccessfulPing(latency: TimeInterval) {
        pingReceivedCount += 1
        
        // Add to latency history
        pingLatencies.append(latency)
        
        // Keep only the most recent pings
        if pingLatencies.count > pingHistorySize {
            pingLatencies.removeFirst()
        }
        
        // Update metrics
        updateMetrics()
    }
    
    private func recordFailedPing() {
        // Update metrics (packet loss calculation will use sent vs received counts)
        updateMetrics()
    }
    
    private func updateMetrics() {
        // Calculate packet loss as percentage
        packetLoss = pingSentCount > 0 ? 100.0 * Double(pingSentCount - pingReceivedCount) / Double(pingSentCount) : 0.0
        
        // Calculate jitter (average variation between consecutive latencies)
        if pingLatencies.count > 1 {
            var totalVariation = 0.0
            var previousLatency = pingLatencies[0]
            
            for i in 1..<pingLatencies.count {
                let currentLatency = pingLatencies[i]
                let variation = abs(currentLatency - previousLatency)
                totalVariation += variation
                previousLatency = currentLatency
            }
            
            jitter = totalVariation / Double(pingLatencies.count - 1)
        } else {
            jitter = 0.0
        }
        
        // Notify listeners
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onQualityUpdate?(self.packetLoss, self.jitter)
        }
    }
}
