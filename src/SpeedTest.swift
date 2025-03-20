import Foundation

class SpeedTest {
    enum TestSize {
        case small    // 10MB
        case medium   // 100MB
        case large    // 1GB
        
        var byteCount: Int {
            switch self {
            case .small: return 10_000_000    // 10 MB
            case .medium: return 100_000_000  // 100 MB
            case .large: return 1_000_000_000 // 1 GB
            }
        }
        
        var url: URL {
            // Use Cloudflare's speed test endpoint with specific byte size
            let base = "https://speed.cloudflare.com/__down"
            let urlString = "\(base)?bytes=\(byteCount)"
            return URL(string: urlString)!
        }
        
        var description: String {
            switch self {
            case .small: return "10 MB"
            case .medium: return "100 MB"
            case .large: return "1 GB"
            }
        }
    }
    
    enum TestType {
        case download
        case upload
        case combinedSerial
        case combinedParallel
    }
    
    func startTest(
        size: TestSize,
        type: TestType,
        progress: @escaping (Double) -> Void,
        completion: @escaping ((download: Double?, upload: Double?)) -> Void
    ) {
        switch type {
        case .download, .upload:
            singleTest(size: size, type: type) { speed in
                completion((download: type == .download ? speed : nil,
                          upload: type == .upload ? speed : nil))
            }
        case .combinedSerial:
            singleTest(size: size, type: .download) { downloadSpeed in
                self.singleTest(size: size, type: .upload) { uploadSpeed in
                    completion((download: downloadSpeed, upload: uploadSpeed))
                }
            }
        case .combinedParallel:
            var downloadResult: Double?
            var uploadResult: Double?
            let group = DispatchGroup()
            
            group.enter()
            singleTest(size: size, type: .download) { speed in
                downloadResult = speed
                group.leave()
            }
            
            group.enter()
            singleTest(size: size, type: .upload) { speed in
                uploadResult = speed
                group.leave()
            }
            
            group.notify(queue: .main) {
                completion((download: downloadResult, upload: uploadResult))
            }
        }
    }
    
    private func singleTest(
        size: TestSize,
        type: TestType,
        completion: @escaping (Double?) -> Void
    ) {
        let startTime = Date()
        let url = type == .download ? size.url : URL(string: "https://speed.cloudflare.com/__up")!
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpMethod = type == .download ? "GET" : "POST"
        
        if type == .upload {
            let dummyData = Data(repeating: 0, count: size.byteCount)
            request.httpBody = dummyData
        }
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data else {
                print("Error: \(error?.localizedDescription ?? "Unknown error")")
                print("Status code: \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
                completion(nil)
                return
            }
            
            let duration = Date().timeIntervalSince(startTime)
            let bytesTransferred = type == .download ? data.count : size.byteCount
            
            // Convert to Mbps (megabits per second)
            let speedMbps = (Double(bytesTransferred) * 8.0) / (1_000_000.0 * duration)
            completion(speedMbps)
        }
        
        task.resume()
    }
}
