import AppKit
import SwiftUI

struct AddVaultView: View {
    let add: (URL) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var destination: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add New Vault")
                    .font(.title2.bold())
                Text("Choose a destination folder. Its name will be the vault name.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(destination?.lastPathComponent ?? "Destination folder")
                        .fontWeight(.medium)
                    Text(destination?.path ?? "No folder selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("Choose…", action: chooseDestination)
            }

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Vault") {
                    guard let destination else { return }
                    do {
                        try add(destination)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Vault Folder"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            destination = url
            error = nil
        }
    }
}
