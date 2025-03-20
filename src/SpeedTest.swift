import Foundation

class SpeedTest {
    enum TestSize {
        case small    // 10MB
        case medium   // 100MB
        case large    // 1GB
        
        var url: URL {
            let base = "https://speed.cloudflare.com/__down"
            switch self {
            case .small:  return URL(string: "\(base)?bytes=10000000")!
            case .medium: return URL(string: "\(base)?bytes=100000000")!
            case .large:  return URL(string: "\(base)?bytes=1000000000")!
            }
        }
        
        var description: String {
            switch self {
            case .small: return "10 MB"
            case .medium: return "100 MB"
            case .large: return "1 GB"
            }
        }
    }
    
    func startTest(size: TestSize, progress: @escaping (Double) -> Void, completion: @escaping (Double?) -> Void) {
        let startTime = Date()
        var totalBytes: Int64 = 0
        
        let task = URLSession.shared.dataTask(with: size.url) { _, response, error in
            guard error == nil,
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else {
                completion(nil)
                return
            }
            
            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)
            let bytesPerSecond = Double(totalBytes) / duration
            let speedMbps = (bytesPerSecond * 8) / 1_000_000 // Convert to Mbps
            completion(speedMbps)
        }
        
        // Configure the task to report progress
        task.resume()
    }
}
