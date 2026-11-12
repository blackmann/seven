import Foundation

enum NotesPreferencesMigration {
    /// Reuse W's folder bookmarks and scratchpads. Documents stay in their vaults.
    static func importWIfNeeded(into defaults: UserDefaults = .standard, legacy: [String: Any]? = nil) {
        guard defaults.object(forKey: "notes.vaults") == nil else { return }
        var values = legacy ?? defaults.persistentDomain(forName: "uk.co.degreat.W") ?? [:]
        if legacy == nil, values["vaults"] == nil {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/uk.co.degreat.W/Data/Library/Preferences/uk.co.degreat.W.plist")
            if let data = try? Data(contentsOf: url),
               let saved = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                values = saved
            }
        }
        guard let data = values["vaults"] as? Data,
              (try? JSONDecoder().decode([Vault].self, from: data)) != nil else { return }
        for (key, value) in values where key == "vaults" || key == "selectedVaultID" || key.hasPrefix("vaultDraft.") {
            defaults.set(value, forKey: "notes." + key)
        }
    }
}
