import Foundation
import SystemConfiguration

class SpeedMonitor {
    // Constants for network interface monitoring
    private let defaultInterface = "en0"
    private let fallbackInterfaces = ["en1", "en2", "pdp_ip0", "pdp_ip1", "pdp_ip2"]
    
    // Data tracking
    private var lastBytesIn: UInt64 = 0
    private var lastBytesOut: UInt64 = 0
    private var lastCheckTime = Date()
    
    // Speed tracking
    private var maxDownloadSpeed: Double = 0.0
    private var maxUploadSpeed: Double = 0.0
    
    // Latency tracking
    private var currentLatency: Double = 0.0
    private var avgLatency: Double = 0.0
    private var latencySamples: [Double] = []
    private let maxLatencySamples = 5
    private let pingHosts = ["8.8.8.8", "1.1.1.1", "9.9.9.9"]
    
    // Thread safety
    private let lock = NSLock()
    
    init() {
        // Initialize with zero values to avoid undefined state
        resetStats()
    }
    
    func resetStats() {
        lock.lock()
        defer { lock.unlock() }
        
        lastBytesIn = 0
        lastBytesOut = 0
        lastCheckTime = Date()
        currentLatency = 0.0
        avgLatency = 0.0
        latencySamples = []
    }
    
    func resetMaxSpeeds() {
        lock.lock()
        defer { lock.unlock() }
        
        maxDownloadSpeed = 0.0
        maxUploadSpeed = 0.0
    }
    
    /// Safely measures network speed with error handling to prevent crashes
    func measureSpeed(completion: @escaping (Double, Double, Double, Double, Double, Double) -> Void) {
        // Measure latency first
        measureLatency { [weak self] latency, avgLatency in
            guard let self = self else {
                DispatchQueue.main.async {
                    completion(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
                }
                return
            }
            
            // Then measure bandwidth
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else {
                    // Safety: if self is deallocated, return zero values
                    DispatchQueue.main.async {
                        completion(0.0, 0.0, 0.0, 0.0, latency, avgLatency)
                    }
                    return
                }
                
                // Get current network statistics with error handling
                do {
                    let (bytesIn, bytesOut) = try self.getInterfaceBytes()
                    let now = Date()
                    
                    // Safely calculate speeds with thread safety
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    
                    // Calculate time difference, with safety check
                    let elapsed = now.timeIntervalSince(self.lastCheckTime)
                    guard elapsed > 0 else {
                        // Avoid division by zero
                        DispatchQueue.main.async {
                            completion(0.0, 0.0, self.maxDownloadSpeed, self.maxUploadSpeed, latency, avgLatency)
                        }
                        return
                    }
                    
                    // Safe calculation of download speed with bounds checking
                    let downloadSpeed: Double
                    if bytesIn >= self.lastBytesIn {
                        let byteDiff = Double(bytesIn - self.lastBytesIn)
                        downloadSpeed = (byteDiff * 8.0) / (elapsed * 1_000_000.0) // Convert to Mbps
                    } else {
                        // Counter reset case
                        downloadSpeed = 0.0
                    }
                    
                    // Safe calculation of upload speed with bounds checking
                    let uploadSpeed: Double
                    if bytesOut >= self.lastBytesOut {
                        let byteDiff = Double(bytesOut - self.lastBytesOut)
                        uploadSpeed = (byteDiff * 8.0) / (elapsed * 1_000_000.0) // Convert to Mbps
                    } else {
                        // Counter reset case
                        uploadSpeed = 0.0
                    }
                    
                    // Update max speeds if needed, with sanity checks
                    if downloadSpeed > self.maxDownloadSpeed && downloadSpeed < 100000.0 { // Upper bound check
                        self.maxDownloadSpeed = downloadSpeed
                    }
                    
                    if uploadSpeed > self.maxUploadSpeed && uploadSpeed < 100000.0 { // Upper bound check
                        self.maxUploadSpeed = uploadSpeed
                    }
                    
                    // Store current values for next measurement
                    self.lastBytesIn = bytesIn
                    self.lastBytesOut = bytesOut
                    self.lastCheckTime = now
                    
                    // Pass results to main thread with bounds checking
                    let safeDownload = min(max(downloadSpeed, 0), 99999.9)
                    let safeUpload = min(max(uploadSpeed, 0), 99999.9)
                    let safeMaxDown = min(max(self.maxDownloadSpeed, 0), 99999.9)
                    let safeMaxUp = min(max(self.maxUploadSpeed, 0), 99999.9)
                    
                    DispatchQueue.main.async {
                        completion(safeDownload, safeUpload, safeMaxDown, safeMaxUp, latency, avgLatency)
                    }
                } catch {
                    // Log error and return zeros in case of failure
                    print("❌ Network measurement error: \(error)")
                    DispatchQueue.main.async {
                        completion(0.0, 0.0, self.maxDownloadSpeed, self.maxUploadSpeed, latency, avgLatency)
                    }
                }
            }
        }
    }
    
    /// Measures network latency by pinging common servers
    func measureLatency(completion: @escaping (Double, Double) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    completion(0.0, 0.0)
                }
                return
            }
            
            // Randomly select one host to ping
            guard let host = self.pingHosts.randomElement() else {
                DispatchQueue.main.async {
                    completion(0.0, 0.0)
                }
                return
            }
            
            let pingTask = Process()
            let pipe = Pipe()
            
            pingTask.executableURL = URL(fileURLWithPath: "/sbin/ping")
            pingTask.arguments = ["-c", "1", "-t", "1", host]
            pingTask.standardOutput = pipe
            
            do {
                try pingTask.run()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    // Extract time from ping output
                    if let timeRange = output.range(of: "time=\\d+\\.\\d+", options: .regularExpression) {
                        let timeString = output[timeRange].replacingOccurrences(of: "time=", with: "")
                        if let pingTime = Double(timeString) {
                            self.lock.lock()
                            defer { self.lock.unlock() }
                            
                            // Update current latency
                            self.currentLatency = pingTime
                            
                            // Update latency samples for average calculation
                            self.latencySamples.append(pingTime)
                            if self.latencySamples.count > self.maxLatencySamples {
                                self.latencySamples.removeFirst()
                            }
                            
                            // Calculate average latency
                            if !self.latencySamples.isEmpty {
                                self.avgLatency = self.latencySamples.reduce(0, +) / Double(self.latencySamples.count)
                            }
                            
                            DispatchQueue.main.async {
                                completion(self.currentLatency, self.avgLatency)
                            }
                            return
                        }
                    }
                }
                
                // If we couldn't extract the latency, return current values
                DispatchQueue.main.async {
                    completion(self.currentLatency, self.avgLatency)
                }
                
            } catch {
                print("❌ Latency measurement error: \(error)")
                DispatchQueue.main.async {
                    completion(self.currentLatency, self.avgLatency)
                }
            }
        }
    }
    
    /// Get bytes in/out with proper error handling
    private func getInterfaceBytes() throws -> (UInt64, UInt64) {
        // Try primary interface first
        if let (inBytes, outBytes) = try? getBytesForInterface(defaultInterface) {
            return (inBytes, outBytes)
        }
        
        // If primary fails, try fallbacks
        for interface in fallbackInterfaces {
            if let (inBytes, outBytes) = try? getBytesForInterface(interface) {
                return (inBytes, outBytes)
            }
        }
        
        // If all interfaces fail, throw an error
        throw NSError(domain: "SpeedMonitor", code: 1, 
                     userInfo: [NSLocalizedDescriptionKey: "Failed to get network statistics"])
    }
    
    /// Safe implementation to get bytes for a specific interface
    private func getBytesForInterface(_ interfaceName: String) throws -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            throw NSError(domain: "SpeedMonitor", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to get interface addresses"])
        }
        defer { freeifaddrs(ifaddr) }
        
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var interfaceFound = false
        
        var ptr = ifaddr
        while ptr != nil {
            guard let interface = ptr?.pointee else {
                ptr = ptr?.pointee.ifa_next
                continue
            }
            
            // Safely get C string as Swift string
            guard let interfaceCStr = interface.ifa_name else {
                ptr = interface.ifa_next
                continue
            }
            
            let name = String(cString: interfaceCStr)
            if name == interfaceName {
                interfaceFound = true
                
                // Check if this is the right interface type for stats
                if interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) {
                    var data = if_data()
                    
                    // Safely extract data with bounds checking
                    if let addr = interface.ifa_data {
                        // Copy only the needed bytes to avoid buffer overruns
                        let addrPtr = addr.assumingMemoryBound(to: if_data.self)
                        data = addrPtr.pointee
                        
                        // Extract values with bounds checking
                        bytesIn = UInt64(data.ifi_ibytes)
                        bytesOut = UInt64(data.ifi_obytes)
                        break
                    }
                }
            }
            ptr = interface.ifa_next
        }
        
        if !interfaceFound {
            throw NSError(domain: "SpeedMonitor", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Interface \(interfaceName) not found"])
        }
        
        return (bytesIn, bytesOut)
    }
}
