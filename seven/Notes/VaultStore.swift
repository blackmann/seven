import Foundation
import Observation

struct Vault: Codable, Identifiable {
    let id: UUID
    var bookmark: Data
}

struct VaultFile: Identifiable, Equatable, Sendable {
    let relativePath: String
    let url: URL
    let createdAt: Date?
    let modifiedAt: Date?

    var id: String { relativePath }
    var name: String { url.lastPathComponent }
    var folderPrefix: String {
        let components = relativePath.split(separator: "/")
        return components.dropLast().isEmpty ? "" : components.dropLast().joined(separator: "/") + "/"
    }
}

@MainActor
@Observable
final class VaultStore {
    private static let vaultsKey = "notes.vaults"
    private static let selectionKey = "notes.selectedVaultID"

    private(set) var vaults: [Vault] = []
    private(set) var selectedID: UUID?
    private(set) var draft = ""
    private(set) var files: [VaultFile] = []
    private(set) var selectedFile: VaultFile?
    var error: String?

    private var activeURL: URL?
    private(set) var hasUnsavedFileChanges = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.vaultsKey) {
            do {
                vaults = try JSONDecoder().decode([Vault].self, from: data)
            } catch {
                self.error = "The saved vault list could not be read: \(error.localizedDescription)"
            }
        }

        if let id = defaults.string(forKey: Self.selectionKey).flatMap(UUID.init(uuidString:)),
           vaults.contains(where: { $0.id == id }) {
            select(id)
        }
    }

    var vaultURL: URL? { activeURL }

    var selectedVault: Vault? { vaults.first { $0.id == selectedID } }

    func name(for vault: Vault) -> String {
        (try? resolve(vault).lastPathComponent) ?? "Unavailable vault"
    }

    func add(_ folder: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VaultError.invalidFolder
        }
        let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        if let index = vaults.firstIndex(where: { (try? resolve($0).standardizedFileURL) == folder.standardizedFileURL }) {
            var updated = vaults
            updated[index].bookmark = bookmark
            defaults.set(try JSONEncoder().encode(updated), forKey: Self.vaultsKey)
            vaults = updated
            select(updated[index].id)
            if selectedID != updated[index].id { throw VaultError.accessDenied }
            return
        }

        let vault = Vault(id: UUID(), bookmark: bookmark)
        let updated = vaults + [vault]
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: Self.vaultsKey)
        vaults = updated
        select(vault.id)
        if selectedID != vault.id { throw VaultError.accessDenied }
    }

    func select(_ id: UUID?) {
        guard id != selectedID else { return }
        guard !hasUnsavedFileChanges else {
            error = "Save the current file before switching vaults."
            return
        }
        guard let id, let vault = vaults.first(where: { $0.id == id }) else {
            activeURL?.stopAccessingSecurityScopedResource()
            activeURL = nil
            selectedID = nil
            selectedFile = nil
            files = []
            draft = ""
            defaults.removeObject(forKey: Self.selectionKey)
            return
        }

        do {
            let url = try resolve(vault)
            let scoped = url.startAccessingSecurityScopedResource()
            guard scoped || FileManager.default.isReadableFile(atPath: url.path) else { throw VaultError.accessDenied }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                url.stopAccessingSecurityScopedResource()
                throw VaultError.invalidFolder
            }
            activeURL?.stopAccessingSecurityScopedResource()
            activeURL = url
            selectedID = id
            selectedFile = nil
            draft = defaults.string(forKey: draftKey(for: id)) ?? ""
            defaults.set(id.uuidString, forKey: Self.selectionKey)
            error = nil
            refreshFiles()
        } catch {
            self.error = "Could not open \(name(for: vault)): \(error.localizedDescription)"
        }
    }

    func updateDraft(_ value: String) {
        draft = value
        if let selectedFile {
            do {
                try value.write(to: selectedFile.url, atomically: true, encoding: .utf8)
                if let createdAt = selectedFile.createdAt {
                    try? FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: selectedFile.url.path)
                }
                let values = try? selectedFile.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let updatedFile = VaultFile(relativePath: selectedFile.relativePath, url: selectedFile.url,
                                            createdAt: selectedFile.createdAt ?? values?.creationDate,
                                            modifiedAt: values?.contentModificationDate ?? Date())
                self.selectedFile = updatedFile
                if let index = files.firstIndex(where: { $0.id == updatedFile.id }) {
                    files[index] = updatedFile
                }
                hasUnsavedFileChanges = false
                error = nil
            } catch {
                hasUnsavedFileChanges = true
                self.error = "Could not save \(selectedFile.name): \(error.localizedDescription)"
            }
        } else if let selectedID {
            defaults.set(value, forKey: draftKey(for: selectedID))
        }
    }

    @discardableResult
    func openDraft() -> Bool {
        guard !hasUnsavedFileChanges else {
            error = "Save the current file before opening the scratchpad."
            return false
        }
        guard let selectedID else { return false }
        selectedFile = nil
        draft = defaults.string(forKey: draftKey(for: selectedID)) ?? ""
        return true
    }

    func discardUnsavedChanges() {
        if let selectedFile {
            do {
                let data = try Data(contentsOf: selectedFile.url)
                guard let contents = String(data: data, encoding: .utf8) else { throw VaultError.unsupportedFormat }
                draft = contents
            } catch {
                self.error = "Could not reload \(selectedFile.name): \(error.localizedDescription)"
                return
            }
        }
        hasUnsavedFileChanges = false
        error = nil
    }

    func refreshFiles() {
        guard let root = activeURL else {
            files = []
            return
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            files = []
            error = "Could not read the files in this vault."
            return
        }

        let rootPath = root.standardizedFileURL.path + "/"
        files = enumerator.compactMap { item -> VaultFile? in
            guard let url = item as? URL,
                  url.standardizedFileURL.path.hasPrefix(rootPath),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            return VaultFile(relativePath: String(url.standardizedFileURL.path.dropFirst(rootPath.count)), url: url, createdAt: values.creationDate, modifiedAt: values.contentModificationDate)
        }
        .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    @discardableResult
    func createNote() -> Bool {
        guard !hasUnsavedFileChanges else {
            error = "Save the current file before creating another."
            return false
        }
        guard let root = activeURL else {
            error = "Select a vault before creating a note."
            return false
        }

        for number in 1...10_000 {
            let name = number == 1 ? "Untitled.md" : "Untitled \(number).md"
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { continue }

            do {
                try Data().write(to: url, options: .withoutOverwriting)
                refreshFiles()
                if let file = files.first(where: { $0.url == url }) { return open(file) }
                error = "The new note was created, but could not be opened."
                return false
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                self.error = "Could not create the note: \(error.localizedDescription)"
                return false
            }
        }

        error = "No available name was found for the new note."
        return false
    }

    @discardableResult
    func open(_ file: VaultFile) -> Bool {
        guard !hasUnsavedFileChanges else {
            error = "Save the current file before opening another."
            return false
        }
        guard let file = files.first(where: { $0.id == file.id && $0.url == file.url }) else { return false }
        do {
            let data = try Data(contentsOf: file.url)
            guard let contents = String(data: data, encoding: .utf8), !contents.contains("\0") else {
                throw VaultError.unsupportedFormat
            }
            selectedFile = file
            draft = contents
            error = nil
            return true
        } catch {
            self.error = "Could not open \(file.name): \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func renameSelectedFile(to proposedName: String) -> Bool {
        guard let file = selectedFile, let root = activeURL else { return false }
        guard !hasUnsavedFileChanges else {
            error = "Save the current file before renaming it."
            return false
        }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            error = "Enter a valid file name without slashes or colons."
            return false
        }
        guard name != file.name else { return true }

        let destination = file.url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "A file named \(name) already exists in this folder."
            return false
        }
        do {
            try FileManager.default.moveItem(at: file.url, to: destination)
            let relativePath = String(destination.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            let values = try? destination.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            selectedFile = VaultFile(relativePath: relativePath, url: destination,
                                     createdAt: values?.creationDate ?? file.createdAt,
                                     modifiedAt: values?.contentModificationDate ?? file.modifiedAt)
            refreshFiles()
            error = nil
            return true
        } catch {
            self.error = "Could not rename \(file.name): \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func delete(_ file: VaultFile) -> Bool {
        guard let file = files.first(where: { $0.id == file.id && $0.url == file.url }) else { return false }
        if selectedFile?.id == file.id, hasUnsavedFileChanges {
            error = "Save or discard your changes before deleting this file."
            return false
        }

        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            if selectedFile?.id == file.id {
                selectedFile = nil
                draft = selectedID.flatMap { defaults.string(forKey: draftKey(for: $0)) } ?? ""
                hasUnsavedFileChanges = false
            }
            refreshFiles()
            error = nil
            return true
        } catch {
            self.error = "Could not move \(file.name) to the Trash: \(error.localizedDescription)"
            return false
        }
    }

    private func draftKey(for id: UUID) -> String { "notes.vaultDraft.\(id.uuidString)" }

    private func resolve(_ vault: Vault) throws -> URL {
        var isStale = false
        // Read older security-scoped bookmarks as well as new portable bookmarks.
        if let scoped = try? URL(resolvingBookmarkData: vault.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return scoped
        }
        return try URL(resolvingBookmarkData: vault.bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}

private enum VaultError: LocalizedError {
    case invalidFolder, accessDenied, unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidFolder: "Choose an existing folder."
        case .accessDenied: "Access to this folder was denied. Choose it again to restore access."
        case .unsupportedFormat: "This file is not UTF-8 text and cannot be opened in the editor."
        }
    }
}
