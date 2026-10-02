import CryptoKit
import Foundation

// Uploads a recording's .tar to the receiver (server/receive.py) with an HTTP PUT; the receiver checks the SHA-256 and keeps the file.
final class Uploader: NSObject, URLSessionTaskDelegate {
    private var session: URLSession!
    private var progress: [Int: (Double) -> Void] = [:]

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { handle.closeFile() }
        var hasher = SHA256()
        // Each chunk is released before the next is read: a file of several GB would otherwise stay in memory until iOS stops the app.
        while autoreleasepool(invoking: { () -> Bool in
            let chunk = handle.readData(ofLength: 8 << 20)
            hasher.update(data: chunk)
            return !chunk.isEmpty
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func upload(file: URL, server: String, onProgress: @escaping (Double) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let digest: String
            do { digest = try Uploader.sha256(of: file) } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            DispatchQueue.main.async {
                let base = server.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let url = URL(string: "\(base)/upload/\(file.lastPathComponent)") else {
                    completion(.failure(RecorderError("bad server URL")))
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "PUT"
                request.setValue(Secrets.uploadToken, forHTTPHeaderField: "X-Upload-Token")
                request.setValue(digest, forHTTPHeaderField: "X-Content-SHA256")
                request.setValue("application/x-tar", forHTTPHeaderField: "Content-Type")
                let task = self.session.uploadTask(with: request, fromFile: file) { data, response, error in
                    if let error = error as NSError? {
                        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " [\($0.domain) \($0.code)]" } ?? ""
                        return completion(.failure(RecorderError("\(error.localizedDescription) (\(error.domain) \(error.code))\(underlying)")))
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    if status == 200 {
                        completion(.success(body))
                    } else {
                        completion(.failure(RecorderError("server replied \(status): \(body)")))
                    }
                }
                self.progress[task.taskIdentifier] = onProgress
                task.resume()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress[task.taskIdentifier]?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
