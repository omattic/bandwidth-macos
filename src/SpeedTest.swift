import Foundation

class SpeedTest {
    enum TestSize {
        case small    // 10MB
        case medium   // 100MB
        case large    // 1GB
        
        var byteCount: Int {
            switch self {
            case .small: return 10_000_00    // 10 MB
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
    
    private var currentTask: URLSessionDataTask?
    
    func cancelCurrentTest() {
        currentTask?.cancel()
        currentTask = nil
    }
    
    func startTest(
        size: TestSize,
        type: TestType,
        progress: @escaping (Double) -> Void,
        completion: @escaping ((download: Double?, upload: Double?)) -> Void
    ) {
        switch type {
        case .download, .upload:
            singleTest(size: size, type: type) { bytes, duration in
                guard let bytes = bytes, let duration = duration else {
                    completion((download: nil, upload: nil))
                    return
                }
                let speed = (Double(bytes) * 8.0) / (1_000_000.0 * duration)
                completion((download: type == .download ? speed : nil,
                          upload: type == .upload ? speed : nil))
            }
        case .combinedSerial:
            singleTest(size: size, type: .download) { bytes, duration in
                guard let downloadBytes = bytes, let downloadDuration = duration else {
                    completion((download: nil, upload: nil))
                    return
                }
                let downloadSpeed = (Double(downloadBytes) * 8.0) / (1_000_000.0 * downloadDuration)
                
                self.singleTest(size: size, type: .upload) { uploadBytes, uploadDuration in
                    guard let uploadBytes = uploadBytes, let uploadDuration = uploadDuration else {
                        completion((download: downloadSpeed, upload: nil))
                        return
                    }
                    let uploadSpeed = (Double(uploadBytes) * 8.0) / (1_000_000.0 * uploadDuration)
                    completion((download: downloadSpeed, upload: uploadSpeed))
                }
            }
        case .combinedParallel:
            let startTime = Date()
            var downloadBytes: Int?
            var uploadBytes: Int?
            let group = DispatchGroup()
            
            group.enter()
            singleTest(size: size, type: .download, startTime: startTime) { bytes, _ in
                downloadBytes = bytes
                group.leave()
            }
            
            group.enter()
            singleTest(size: size, type: .upload, startTime: startTime) { bytes, _ in
                uploadBytes = bytes
                group.leave()
            }
            
            group.notify(queue: .main) {
                let duration = Date().timeIntervalSince(startTime)
                let downloadSpeed = downloadBytes.map { Double($0) * 8.0 / (1_000_000.0 * duration) }
                let uploadSpeed = uploadBytes.map { Double($0) * 8.0 / (1_000_000.0 * duration) }
                completion((download: downloadSpeed, upload: uploadSpeed))
            }
        }
    }
    
    private func singleTest(
        size: TestSize,
        type: TestType,
        startTime: Date? = nil,
        completion: @escaping (_ bytes: Int?, _ duration: TimeInterval?) -> Void
    ) {
        let testStartTime = startTime ?? Date()
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
                completion(nil, nil)
                return
            }
            
            let duration = Date().timeIntervalSince(testStartTime)
            let bytesTransferred = type == .download ? data.count : size.byteCount
            completion(bytesTransferred, duration)
        }
        currentTask = task
        task.resume()
    }
}
