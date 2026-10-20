import Foundation

struct DownloadProgress: Equatable {
    let fraction: Double
    let detail: String

    static func curl(_ line: String) -> DownloadProgress? {
        let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard columns.count >= 12, let percent = Double(columns[0]), percent >= 0, percent <= 100,
              let total = quantity(columns[1]), let received = quantity(columns[3]), total > 0 else { return nil }
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)
        let expected = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        var detail = "\(bytes) of \(expected)"
        if let speed = quantity(columns[11]), speed > 0 {
            detail += " · \(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s"
        }
        if columns[10] != "--:--:--" { detail += " · \(columns[10]) remaining" }
        return DownloadProgress(fraction: percent / 100, detail: detail)
    }

    private static func quantity(_ text: String) -> Double? {
        let units: [Character: Double] = ["k": 1024, "K": 1024, "M": 1_048_576, "G": 1_073_741_824, "T": 1_099_511_627_776]
        if let suffix = text.last, let scale = units[suffix], let number = Double(text.dropLast()) { return number * scale }
        return Double(text)
    }
}
