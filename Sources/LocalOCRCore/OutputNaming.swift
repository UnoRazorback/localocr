import Foundation

public enum OutputNaming {
    public static func searchablePDFURL(for source: URL, fileExists: (URL) -> Bool) -> URL {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let baseName = "\(stem)_searchable"

        var suffix = 1
        while true {
            let name = suffix == 1 ? baseName : "\(baseName)_\(suffix)"
            let candidate = directory.appending(path: name).appendingPathExtension("pdf")
            guard !fileExists(candidate) else {
                suffix += 1
                continue
            }
            return candidate
        }
    }
}
