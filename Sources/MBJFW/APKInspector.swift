import CryptoKit
import Foundation

struct APKMetadata: Codable, Equatable, Sendable {
    let sha256: String
    let package: String
    let version: String
    let versionCode: UInt64
    let minimumSDK: Int
    let bytes: Int64
}

enum APKInspector {
    @MainActor
    static func inspect(_ url: URL, log: URL) async throws -> APKMetadata {
        let staging = FileManager.default.temporaryDirectory.appending(path: "apk-inspect-\(UUID())")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let entries = try await AndroidProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", url.path], environment: [:], logURL: log)
        let paths = entries.split(whereSeparator: \.isNewline)
        guard paths.contains("AndroidManifest.xml") else { throw APKError.invalid }
        let libraries = paths.filter { $0.hasPrefix("lib/") && $0.hasSuffix(".so") }
        guard libraries.isEmpty || libraries.contains(where: { $0.hasPrefix("lib/arm64-v8a/") }) else { throw APKError.abi }
        try await AndroidProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-q", url.path, "AndroidManifest.xml", "-d", staging.path], environment: [:], logURL: log)
        let manifest = try BinaryManifest(data: Data(contentsOf: staging.appending(path: "AndroidManifest.xml")))
        guard manifest.package == "com.mojang.minecraftpe" else { throw APKError.package }
        guard !manifest.split else { throw APKError.split }
        guard manifest.minimumSDK <= 35 else { throw APKError.sdk }
        let digest = try await Task.detached(priority: .utility) { try FileDigest.sha256(url) }.value
        let bytes = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return APKMetadata(sha256: digest, package: manifest.package, version: manifest.version, versionCode: manifest.versionCode, minimumSDK: manifest.minimumSDK, bytes: bytes)
    }
}

enum FileDigest {
    static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// Android's public ResXMLTree format. Bounds are checked before every read;
// imported archives are data and never supply commands or filesystem paths.
struct BinaryManifest {
    var package = ""
    var version = ""
    var versionCode: UInt64 = 0
    var minimumSDK = 1
    var split = false

    init(data: Data) throws {
        let reader = ManifestBytes(bytes: Array(data))
        guard try reader.u16(0) == 3, try reader.u32(4) <= data.count else { throw APKError.invalid }
        var strings: [String] = []
        var cursor = 8
        while cursor < data.count {
            let type = try reader.u16(cursor), header = try reader.u16(cursor + 2), size = try reader.u32(cursor + 4)
            guard header >= 8, size >= header, cursor <= data.count - size else { throw APKError.invalid }
            if type == 1 {
                let count = try reader.u32(cursor + 8), flags = try reader.u32(cursor + 16), start = try reader.u32(cursor + 20)
                guard count <= 100_000, header + count * 4 <= size else { throw APKError.invalid }
                strings = try (0..<count).map { index in
                    var offset = cursor + start + (try reader.u32(cursor + header + index * 4))
                    if flags & 0x100 != 0 {
                        _ = try reader.length8(&offset)
                        let bytes = try reader.length8(&offset)
                        return try reader.string(offset, count: bytes, encoding: .utf8)
                    }
                    let count = try reader.length16(&offset)
                    return try reader.string(offset, count: count * 2, encoding: .utf16LittleEndian)
                }
            } else if type == 0x102 {
                let element = try reader.pool(strings, reader.u32(cursor + 20))
                let start = try reader.u16(cursor + 24), stride = try reader.u16(cursor + 26), count = try reader.u16(cursor + 28)
                guard stride >= 20, 16 + start + stride * count <= size else { throw APKError.invalid }
                if element == "uses-split" { split = true }
                for index in 0..<count {
                    let attr = cursor + 16 + start + stride * index
                    let name = try reader.pool(strings, reader.u32(attr + 4))
                    let raw = try reader.u32(attr + 8), kind = try reader.u8(attr + 15), value = try reader.u32(attr + 16)
                    let text: String
                    if raw != Int(UInt32.max) { text = try reader.pool(strings, raw) }
                    else if kind == 3 { text = try reader.pool(strings, value) }
                    else { text = String(value) }
                    if element == "manifest" {
                        switch name {
                        case "package": package = text
                        case "versionName": version = text
                        case "versionCode": versionCode |= UInt64(value)
                        case "versionCodeMajor": versionCode |= UInt64(value) << 32
                        case "split": split = !text.isEmpty
                        default: break
                        }
                    } else if element == "uses-sdk", name == "minSdkVersion" { minimumSDK = Int(text) ?? 1000 }
                }
            }
            cursor += size
        }
        guard !package.isEmpty, !version.isEmpty else { throw APKError.invalid }
    }
}

private struct ManifestBytes {
    let bytes: [UInt8]
    func u8(_ i: Int) throws -> Int {
        guard bytes.indices.contains(i) else { throw APKError.invalid }; return Int(bytes[i])
    }
    func u16(_ i: Int) throws -> Int { try u8(i) | u8(i + 1) << 8 }
    func u32(_ i: Int) throws -> Int { try u16(i) | u16(i + 2) << 16 }
    func length8(_ offset: inout Int) throws -> Int {
        let first = try u8(offset); offset += 1
        if first & 0x80 == 0 { return first }
        let last = try u8(offset); offset += 1; return (first & 0x7f) << 8 | last
    }
    func length16(_ offset: inout Int) throws -> Int {
        let first = try u16(offset); offset += 2
        if first & 0x8000 == 0 { return first }
        let last = try u16(offset); offset += 2; return (first & 0x7fff) << 16 | last
    }
    func string(_ offset: Int, count: Int, encoding: String.Encoding) throws -> String {
        guard offset >= 0, count >= 0, offset <= bytes.count - count,
              let text = String(data: Data(bytes[offset..<offset + count]), encoding: encoding) else { throw APKError.invalid }
        return text
    }
    func pool(_ strings: [String], _ index: Int) throws -> String {
        guard strings.indices.contains(index) else { throw APKError.invalid }; return strings[index]
    }
}

enum APKError: LocalizedError {
    case invalid, package, abi, sdk, split
    var errorDescription: String? {
        switch self {
        case .invalid: "This file has no readable Android application manifest."
        case .package: "Choose a Minecraft Bedrock APK (com.mojang.minecraftpe)."
        case .abi: "This APK does not contain ARM64 Android libraries."
        case .sdk: "This build requires a newer Android version than this runtime."
        case .split: "This file is part of a split installation. Import a complete standalone APK."
        }
    }
}
