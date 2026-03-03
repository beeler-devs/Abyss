import Foundation
import Darwin

public struct WorkspacePolicy: Sendable {
    public let workspaceRoots: [URL]
    public let denylistPatterns: [String]

    public init(workspaceRoot: URL) {
        self.init(workspaceRoots: [workspaceRoot])
    }

    public init(
        workspaceRoots: [URL],
        denylistPatterns: [String] = [
            ".env",
            "*.pem",
            "id_rsa",
            "**/.env",
            "**/*.pem",
            "**/id_rsa",
            "node_modules/**",
        ]
    ) {
        let normalized = workspaceRoots.map { $0.standardizedFileURL }
        if normalized.isEmpty {
            self.workspaceRoots = [FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL]
        } else {
            var deduped: [URL] = []
            for root in normalized where !deduped.contains(root) {
                deduped.append(root)
            }
            self.workspaceRoots = deduped
        }
        self.denylistPatterns = denylistPatterns
    }

    public var primaryWorkspaceRoot: URL {
        workspaceRoots[0]
    }

    public func resolve(relativePath: String, forWrite: Bool = false) throws -> URL {
        return try resolve(path: relativePath, relativeTo: primaryWorkspaceRoot, forWrite: forWrite)
    }

    public func resolve(path: String, relativeTo baseRoot: URL, forWrite: Bool = false) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BridgeCoreError.workspaceViolation(path)
        }

        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed).standardizedFileURL
        } else {
            candidate = baseRoot.appendingPathComponent(trimmed).standardizedFileURL
        }

        try assertAllowed(candidate, forWrite: forWrite)
        return candidate
    }

    public func resolveCWD(relativeCWD: String?) throws -> URL {
        guard let relativeCWD else {
            return primaryWorkspaceRoot
        }

        let trimmed = relativeCWD.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." {
            return primaryWorkspaceRoot
        }
        return try resolve(relativePath: trimmed)
    }

    public func resolveSearchRoot(_ root: String?) throws -> URL {
        guard let root else {
            return primaryWorkspaceRoot
        }

        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." {
            return primaryWorkspaceRoot
        }

        if trimmed.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: trimmed).standardizedFileURL
            try assertAllowed(absolute, forWrite: false)
            return absolute
        }

        return try resolve(path: trimmed, relativeTo: primaryWorkspaceRoot, forWrite: false)
    }

    public func readFile(path: String, maxBytes: Int) throws -> String {
        let url = try resolve(relativePath: path)
        let data = try Data(contentsOf: url)
        let string = String(data: data, encoding: .utf8) ?? ""
        return truncate(string, maxBytes: maxBytes)
    }

    public func readRange(path: String, startLine: Int, endLine: Int, maxBytes: Int) throws -> String {
        guard startLine >= 1, endLine >= startLine else {
            throw BridgeCoreError.invalidPayload("startLine and endLine must be >= 1 and endLine >= startLine")
        }

        let url = try resolve(relativePath: path)
        let data = try Data(contentsOf: url)
        let full = String(data: data, encoding: .utf8) ?? ""
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false)

        let lower = min(startLine - 1, lines.count)
        let upper = min(endLine, lines.count)
        if lower >= upper {
            return ""
        }

        let slice = lines[lower..<upper].joined(separator: "\n")
        return truncate(String(slice), maxBytes: maxBytes)
    }

    public func relativePath(for absoluteURL: URL) -> String? {
        let standardized = absoluteURL.standardizedFileURL.path
        for root in workspaceRoots {
            let rootPath = root.path
            if standardized == rootPath {
                return "."
            }
            if standardized.hasPrefix(rootPath + "/") {
                return String(standardized.dropFirst(rootPath.count + 1))
            }
        }
        return nil
    }

    public func isPathAllowed(_ absoluteURL: URL, forWrite: Bool = false) -> Bool {
        do {
            try assertAllowed(absoluteURL, forWrite: forWrite)
            return true
        } catch {
            return false
        }
    }

    public func assertAllowed(_ absoluteURL: URL, forWrite: Bool) throws {
        let standardized = absoluteURL.standardizedFileURL
        guard isInsideWorkspaceRoots(standardized) else {
            throw BridgeCoreError.workspaceViolation(standardized.path)
        }

        guard let relative = relativePath(for: standardized), relative != "." else {
            return
        }

        if isDenied(relativePath: relative) {
            let reason = forWrite ? "write denied by policy" : "read denied by policy"
            throw BridgeCoreError.permissionDenied("\(reason): \(relative)")
        }
    }

    public func isDenied(relativePath: String) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        if normalized == "." {
            return false
        }

        if normalized == ".env"
            || normalized.hasSuffix("/.env")
            || normalized == "id_rsa"
            || normalized.hasSuffix("/id_rsa")
            || normalized == "node_modules"
            || normalized.hasPrefix("node_modules/")
            || normalized.contains("/node_modules/") {
            return true
        }

        let baseName = URL(fileURLWithPath: normalized).lastPathComponent
        for pattern in denylistPatterns {
            if globMatch(pattern: pattern, target: normalized) || globMatch(pattern: pattern, target: baseName) {
                return true
            }
        }

        return false
    }

    private func isInsideWorkspaceRoots(_ url: URL) -> Bool {
        for root in workspaceRoots {
            let rootPath = root.path
            let targetPath = url.path
            if targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") {
                return true
            }
        }
        return false
    }
}

private func globMatch(pattern: String, target: String) -> Bool {
    return pattern.withCString { patternCString in
        target.withCString { targetCString in
            fnmatch(patternCString, targetCString, FNM_PATHNAME) == 0
        }
    }
}

public func truncate(_ value: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else {
        return ""
    }

    let data = Data(value.utf8)
    if data.count <= maxBytes {
        return value
    }

    let limited = data.prefix(maxBytes)
    let string = String(decoding: limited, as: UTF8.self)
    return string + "\n...[truncated]"
}
