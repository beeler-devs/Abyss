import Foundation

public struct WorkspacePolicy: Sendable {
    public let workspaceRoot: URL

    public init(workspaceRoot: URL) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
    }

    public func resolve(relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BridgeCoreError.workspaceViolation(relativePath)
        }

        guard !trimmed.hasPrefix("/") else {
            throw BridgeCoreError.workspaceViolation(relativePath)
        }

        let resolved = workspaceRoot
            .appendingPathComponent(trimmed)
            .standardizedFileURL

        if isAllowed(resolved) {
            return resolved
        }

        throw BridgeCoreError.workspaceViolation(relativePath)
    }

    public func resolveCWD(relativeCWD: String?) throws -> URL {
        guard let relativeCWD else {
            return workspaceRoot
        }

        let trimmed = relativeCWD.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." {
            return workspaceRoot
        }
        return try resolve(relativePath: trimmed)
    }

    public func readFile(path: String, maxBytes: Int) throws -> String {
        let url = try resolve(relativePath: path)
        let data = try Data(contentsOf: url)
        let string = String(data: data, encoding: .utf8) ?? ""
        return truncate(string, maxBytes: maxBytes)
    }

    private func isAllowed(_ url: URL) -> Bool {
        let rootPath = workspaceRoot.path
        let targetPath = url.path

        if targetPath == rootPath {
            return true
        }

        return targetPath.hasPrefix(rootPath + "/")
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
