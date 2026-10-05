import CryptoKit
import Foundation

// Uploads a finished recording to the receiver (server/receive.py) with one HTTP PUT whose body is the recording's archive, built from its directory as it is sent (Tar), followed by the archive's SHA-256 as 64 lowercase hex characters, hashed from the bytes sent; the receiver checks the hash and keeps the archive.
final class Uploader: NSObject, URLSessionDataDelegate {
    private var session: URLSession!
    // Owned by the main queue, the session's delegate queue: the uploads in flight by task identifier.
    private var uploads: [Int: Upload] = [:]

    private struct Upload {
        let files: [URL]
        let root: String
        let onProgress: (Double) -> Void
        let completion: (Result<String, Error>) -> Void
        // The server's reply as it arrives.
        var reply = Data()
        // Why the archive could not be sent, when the upload was cancelled for it.
        var failure: Error?
    }

    // A write into a body stream found it closed or failed: the task ended or asked for a new body stream.
    private struct BodyStreamClosed: Error {}

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    // Called on the main queue, which onProgress and completion are called on.
    func upload(_ info: RecordingInfo, server: String, onProgress: @escaping (Double) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        let base = server.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/upload/\(info.id).tar") else { return completion(.failure(RecorderError("bad server URL"))) }
        let files = info.members
        let size: Int
        do { size = try Tar.size(of: files) } catch { return completion(.failure(error)) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(Secrets.uploadToken, forHTTPHeaderField: "X-Upload-Token")
        request.setValue("application/x-tar", forHTTPHeaderField: "Content-Type")
        // The archive and its 64 hex characters, set explicitly so the streamed body is sent with its length instead of in chunks.
        request.setValue(String(size + 64), forHTTPHeaderField: "Content-Length")
        let task = session.uploadTask(withStreamedRequest: request)
        uploads[task.taskIdentifier] = Upload(files: files, root: info.id, onProgress: onProgress, completion: completion)
        task.resume()
    }

    // Asked for when the task starts and whenever it must send its body anew: a new producer writes the body from its first byte into a new pair of bound streams.
    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        guard let upload = uploads[task.taskIdentifier] else { preconditionFailure("a body stream asked for by a task this uploader did not start") }
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 1 << 20, inputStream: &input, outputStream: &output)
        guard let input, let output else { preconditionFailure("no bound stream pair") }
        Thread { self.produce(upload, into: output, for: task) }.start()
        completionHandler(input)
    }

    // Runs on a thread of its own: writes the archive, then its SHA-256 in hex, into the unscheduled output, each write blocking while the stream is full; stops once the stream is closed or fails, and cancels the task when the archive cannot be read.
    private func produce(_ upload: Upload, into output: OutputStream, for task: URLSessionTask) {
        output.open()
        var hasher = SHA256()
        do {
            try Tar.stream(upload.files, root: upload.root) { chunk in
                hasher.update(data: chunk)
                try Self.write(chunk, to: output)
            }
            try Self.write(Data(hasher.finalize().map { String(format: "%02x", $0) }.joined().utf8), to: output)
        } catch is BodyStreamClosed {
            // Nothing reads this stream anymore; a new body stream, if the task asked for one, has a producer of its own.
        } catch {
            DispatchQueue.main.async {
                self.uploads[task.taskIdentifier]?.failure = error
                task.cancel()
            }
        }
        output.close()
    }

    // Writes all of data, blocking while the stream is full.
    private static func write(_ data: Data, to output: OutputStream) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let written = output.write(bytes.bindMemory(to: UInt8.self).baseAddress! + offset, maxLength: bytes.count - offset)
                guard written > 0 else { throw BodyStreamClosed() }
                offset += written
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        uploads[task.taskIdentifier]?.onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        uploads[dataTask.taskIdentifier]?.reply.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let upload = uploads.removeValue(forKey: task.taskIdentifier) else { preconditionFailure("a task this uploader did not start completed") }
        if let failure = upload.failure { return upload.completion(.failure(failure)) }
        if let error = error as NSError? {
            let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " [\($0.domain) \($0.code)]" } ?? ""
            return upload.completion(.failure(RecorderError("\(error.localizedDescription) (\(error.domain) \(error.code))\(underlying)")))
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: upload.reply, as: UTF8.self)
        upload.completion(status == 200 ? .success(body) : .failure(RecorderError("server replied \(status): \(body)")))
    }
}
