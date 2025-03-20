import Foundation

class PingMonitor {
    private var timer: Timer?
    private var currentLatency: Double = 0
    private let host = "1.1.1.1" // Cloudflare DNS for reliable ping
    
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.measureLatency()
        }
        timer?.fire()
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    func getCurrentLatency() -> Double {
        return currentLatency
    }
    
    private func measureLatency() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-W", "1", host]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try? process.run()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            if let timeStr = output.components(separatedBy: "time=").last?.components(separatedBy: " ").first,
               let time = Double(timeStr) {
                currentLatency = time
            }
        }
        
        process.waitUntilExit()
    }
}
