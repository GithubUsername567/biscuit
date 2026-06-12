import Foundation

/// Lightweight file log at ~/Library/Logs/Biscuit/biscuit.log (plus NSLog).
/// The unified log redacts NSLog content as <private>, which makes field
/// debugging impossible — this keeps a readable trail. Log events, errors,
/// and counts; never user speech content.
enum BLog {
    private static let queue = DispatchQueue(label: "biscuit.log", qos: .utility)
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Biscuit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("biscuit.log")
    }()
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        NSLog("%@", message)
        queue.async {
            guard let data = "\(stamp.string(from: Date())) \(message)\n".data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
