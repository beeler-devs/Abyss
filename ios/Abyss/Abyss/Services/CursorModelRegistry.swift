import Foundation

struct CursorModelEntry: Codable, Sendable {
    let displayName: String
    let modelId: String
}

/// Loads the Cursor model display-name → API model ID map from CursorModels.json.
/// Edit CursorModels.json to add/remove/update models without touching Swift code.
final class CursorModelRegistry: @unchecked Sendable {
    static let shared = CursorModelRegistry()

    private(set) var models: [CursorModelEntry] = []

    private init() {
        load()
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "CursorModels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CursorModelsFile.self, from: data) else {
            models = [CursorModelEntry(displayName: "Default", modelId: "")]
            return
        }
        models = decoded.models
    }

    /// Returns the model ID for a given display name, or nil if using Cursor's default.
    func modelId(for displayName: String) -> String? {
        guard let entry = models.first(where: { $0.displayName == displayName }),
              !entry.modelId.isEmpty else {
            return nil
        }
        return entry.modelId
    }

    /// Returns the display name for a stored model ID.
    func displayName(for modelId: String) -> String {
        if modelId.isEmpty {
            return models.first?.displayName ?? "Default"
        }
        return models.first(where: { $0.modelId == modelId })?.displayName ?? modelId
    }
}

private struct CursorModelsFile: Codable {
    let models: [CursorModelEntry]
}
