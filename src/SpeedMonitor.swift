import Foundation

class SpeedMonitor {
    private var previousTotalBytesReceived: UInt64 = 0
    private var previousTotalBytesSent: UInt64 = 0
    private var lastMeasurementTime: Date?
    
    func measureSpeed(completion: @escaping (Double, Double) -> Void) {
        print("Measuring network speed...")
        
        // Get network statistics
        let (bytesIn, bytesOut) = getNetworkBytes()
        print("Current bytes - In: \(bytesIn), Out: \(bytesOut)")
        
        let currentTime = Date()
        
        if let lastTime = lastMeasurementTime,
           previousTotalBytesReceived > 0,
           previousTotalBytesSent > 0 {
            
            let timeInterval = currentTime.timeIntervalSince(lastTime)
            print("Time interval since last measurement: \(timeInterval) seconds")
            
            // Calculate bytes per second
            let downloadSpeed = Double(bytesIn - previousTotalBytesReceived) / timeInterval / 1024 // KB/s
            let uploadSpeed = Double(bytesOut - previousTotalBytesSent) / timeInterval / 1024 // KB/s
            
            print("Calculated speeds - Download: \(downloadSpeed) KB/s, Upload: \(uploadSpeed) KB/s")
            completion(downloadSpeed, uploadSpeed)
        } else {
            // First measurement, no speed calculation possible yet
            print("First measurement, no speed calculation yet")
            completion(0, 0)
        }
        
        // Store values for next calculation
        previousTotalBytesReceived = bytesIn
        previousTotalBytesSent = bytesOut
        lastMeasurementTime = currentTime
    }
    
    private func getNetworkBytes() -> (UInt64, UInt64) {
        print("Getting network bytes...")
        
        // Initialize counters
        var totalBytesReceived: UInt64 = 0
        var totalBytesSent: UInt64 = 0
        
        // Get network interfaces
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        let result = getifaddrs(&ifaddr)
        
        guard result == 0 else {
            print("Failed to get network interfaces, error code: \(result)")
            return (0, 0)
        }
        
        guard let firstAddr = ifaddr else {
            print("No network interfaces found")
            return (0, 0)
        }
        
        defer { freeifaddrs(ifaddr) }
        
        // Iterate through network interfaces
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while ptr != nil {
            let interface = ptr!.pointee
            
            defer { ptr = interface.ifa_next }
            
            let flags = Int32(interface.ifa_flags)
            
            // Skip loopback interfaces and interfaces that are down
            guard (flags & IFF_LOOPBACK) != IFF_LOOPBACK && (flags & IFF_UP) == IFF_UP else {
                continue
            }
            
            // Get interface name
            guard let name = String(validatingUTF8: interface.ifa_name) else {
                continue
            }
            
            // Skip interfaces we're not interested in (e.g., lo0, utun)
            guard name != "lo0" && !name.starts(with: "utun") else {
                continue
            }
            
            // Get network statistics for this interface
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_LINK),
               let networkData = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                let data = networkData.pointee
                totalBytesReceived += UInt64(data.ifi_ibytes)
                totalBytesSent += UInt64(data.ifi_obytes)
            }
        }
        
        print("Total bytes - Received: \(totalBytesReceived), Sent: \(totalBytesSent)")
        return (totalBytesReceived, totalBytesSent)
    }
}
