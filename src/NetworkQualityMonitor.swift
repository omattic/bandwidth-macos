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
    private var activeConnections = Set<NWConnection>() // Track active connections to prevent early deallocation
    
    // Endpoint for pings
    private let pingHost = "1.1.1.1" // Cloudflare DNS
    private let pingPort = 443 // HTTPS port
    
    // Callbacks for updates
    var onQualityUpdate: ((Double, Double) -> Void)? // packetLoss, jitter
    
    // Thread safety
    private let queue = DispatchQueue(label: "com.networkquality.monitor", qos: .utility)

    init() {
        // Initialize empty latency history
        pingLatencies = []
    }

    deinit {
        stopMonitoring()
    }
    
    func startMonitoring() {
        queue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }
            self.isRunning = true
            
            // Reset metrics
            self.resetMetrics()
            
            // Start the ping timer on the main thread
            DispatchQueue.main.async {
                self.pingTimer = Timer.scheduledTimer(withTimeInterval: self.pingInterval, repeats: true) { [weak self] _ in
                    self?.queue.async {
                        self?.sendPing()
                    }
                }
                
                // Send initial ping immediately
                self.queue.async {
                    self.sendPing()
                }
            }
        }
    }
    
    func stopMonitoring() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = nil
        }
        
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = false
            
            // Cancel all active connections
            for connection in self.activeConnections {
                connection.cancel()
            }
            self.activeConnections.removeAll()
        }
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
        
        // Add to active connections
        activeConnections.insert(connection)
        
        // Set up state handler
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self else { return }
            
            self.queue.async {
                switch state {
                case .ready:
                    // Connection established successfully - record this as a successful ping
                    if let sentTime = self.lastPingTime {
                        let latency = Date().timeIntervalSince(sentTime) * 1000 // convert to ms
                        self.recordSuccessfulPing(latency: latency)
                    }
                    
                    // Close the connection after success
                    if let connection = connection {
                        connection.cancel()
                        self.activeConnections.remove(connection)
                    }
                    
                case .failed, .cancelled:
                    // Connection failed - record as packet loss
                    self.recordFailedPing()
                    
                    // Remove from active connections
                    if let connection = connection {
                        self.activeConnections.remove(connection)
                    }
                    
                default:
                    // Other states - waiting for ready or failed
                    break
                }
            }
        }
        
        // Start the connection with a specific dispatch queue to avoid blocking
        connection.start(queue: DispatchQueue.global(qos: .utility))
        
        // Set up a timeout for the ping
        queue.asyncAfter(deadline: .now() + pingTimeout) { [weak self, weak connection] in
            guard let self = self, let connection = connection, self.activeConnections.contains(connection) else { return }
            
            // If the connection is not ready by now, consider it failed
            if connection.state != .ready {
                connection.cancel()
                self.activeConnections.remove(connection)
                self.recordFailedPing()
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
        
        // Clone the values to avoid any threading issues
        let currentPacketLoss = packetLoss
        let currentJitter = jitter
        
        // Notify listeners on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.onQualityUpdate?(currentPacketLoss, currentJitter)
        }
    }
}
