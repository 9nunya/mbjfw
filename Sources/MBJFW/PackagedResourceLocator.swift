import Foundation

/// SwiftPM's generated `Bundle.module` accessor traps when a copied resource
/// folder is missing a platform bundle manifest. Resolve files directly so a
/// packaging mistake becomes a recoverable setup error instead of a crash.
enum PackagedResourceLocator {
    static let resourceBundleName = "MBJFW_MBJFW.bundle"

    static func url(forResource name: String, withExtension fileExtension: String? = nil) -> URL? {
        let filename = fileExtension.map { "\(name).\($0)" } ?? name
        var roots = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        if let moduleResources = Bundle(for: ResourceBundleAnchor.self).resourceURL {
            roots.append(moduleResources)
        }
        roots.append(Bundle(for: ResourceBundleAnchor.self).bundleURL)
        for root in roots.compactMap({ $0 }) {
            if let resource = url(named: filename, inResourceDirectory: root) { return resource }
        }
        return nil
    }

    static func url(named filename: String, inResourceDirectory resources: URL) -> URL? {
        let bundle = resources.appending(path: resourceBundleName, directoryHint: .isDirectory)
        for directory in [bundle.appending(path: "Contents/Resources"), bundle] {
            let candidate = directory.appending(path: filename)
            if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

private final class ResourceBundleAnchor: NSObject {}
