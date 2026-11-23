import Foundation

/// Optional *remote* overlay index. Windows stores base metadata in
/// .sg_base_version/.sg_base_meta.json and uses _overlay/manifest.json locally;
/// those findings do not establish that the remote service publishes this URL.
/// This decoder intentionally treats an absent/unknown manifest as no verified
/// updates, rather than assuming every existing baseline resource is outdated.
struct ResourceVersionManifest {
    struct Entry: Equatable {
        let path: String
        let sha256: String?
        let size: Int64?
        var verified: Bool { sha256 != nil }
    }

    enum ManifestError: Error, LocalizedError {
        case invalidJSON, missingVersion, invalidVersion, malformedFiles, invalidFile(String), duplicateFile(String), tooManyFiles
        var errorDescription: String? {
            switch self {
            case .invalidJSON: return "远端清单不是 JSON 对象"
            case .missingVersion: return "远端清单没有更新版本字段"
            case .invalidVersion: return "远端资源版本标识非法"
            case .malformedFiles: return "远端资源清单文件列表格式不受支持"
            case .invalidFile(let path): return "远端清单包含非法资源或哈希：\(path)"
            case .duplicateFile(let path): return "远端清单有重复的资源路径：\(path)"
            case .tooManyFiles: return "远端清单资源条目超过安全上限"
            }
        }
    }

    let version: String
    let baseVersion: String?
    let basePackName: String?
    let baseHint: String?
    let requireBase: Bool
    let entries: [Entry]

    static func safeLabel(_ input: String) -> String? {
        guard !input.isEmpty, input.count <= 80,
              input.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
                                     ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 || $0 == 95 }),
              input != ".", input != ".." else { return nil }
        return input
    }

    /// Top-level version.swf is a legacy KP/PVM container, not an ordinary SWF.
    static func allowedFile(_ path: String) -> Bool {
        ResourceHotUpdater.isAllowedResource(path) || path == "Client.swf" || path == "version.swf"
    }

    static func parse(_ data: Data) throws -> ResourceVersionManifest {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManifestError.invalidJSON
        }
        // baseVersion is the *required baseline*, not the remote overlay revision.
        guard let rawVersion = (object["version"] ?? object["resourceVersion"] ?? object["overlayVersion"]) as? String else {
            throw ManifestError.missingVersion
        }
        guard let version = safeLabel(rawVersion) else { throw ManifestError.invalidVersion }
        let required = object["requireBase"] as? Bool ?? false
        let baseVersion = object["baseVersion"] as? String
        if let baseVersion, safeLabel(baseVersion) == nil { throw ManifestError.invalidVersion }
        let rawEntries = object["overlayFiles"] ?? object["files"] ?? []
        guard let source = rawEntries as? [Any] else { throw ManifestError.malformedFiles }
        guard source.count <= 20_000 else { throw ManifestError.tooManyFiles }
        var entries: [Entry] = []
        var seen = Set<String>()
        for item in source {
            let path: String
            var digest: String?
            var size: Int64?
            if let string = item as? String {
                path = string
            } else if let object = item as? [String: Any],
                      let p = (object["path"] ?? object["file"] ?? object["name"]) as? String {
                path = p
                digest = (object["sha256"] ?? object["hash"]) as? String
                if let number = object["size"] as? NSNumber { size = number.int64Value }
            } else { throw ManifestError.malformedFiles }
            guard allowedFile(path) else { throw ManifestError.invalidFile(path) }
            if let digest {
                let normalized = digest.lowercased()
                guard normalized.count == 64,
                      normalized.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
                    throw ManifestError.invalidFile(path)
                }
                if let size, size <= 0 || size > ResourceHotUpdater.maxAssetBytes {
                    throw ManifestError.invalidFile(path)
                }
                if !seen.insert(path).inserted { throw ManifestError.duplicateFile(path) }
                entries.append(Entry(path: path, sha256: normalized, size: size))
            } else {
                if size != nil { throw ManifestError.invalidFile(path) }
                if !seen.insert(path).inserted { throw ManifestError.duplicateFile(path) }
                entries.append(Entry(path: path, sha256: nil, size: nil))
            }
        }
        return ResourceVersionManifest(version: version, baseVersion: baseVersion,
                                       basePackName: object["basePackName"] as? String,
                                       baseHint: object["baseHint"] as? String,
                                       requireBase: required, entries: entries)
    }
}
