// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Adds a guest image to Documents, from a file or from a URL.
struct AddGuestView: View {
    /// Called with the new file's name once it is in Documents.
    var added: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var importerPresented = false
    @State private var address = ""
    @State private var failure: String?
    private var downloads = Downloads.shared

    /// Only web addresses are downloaded.
    private var url: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil
        else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("From this device") {
                    Button("Choose a file", systemImage: "folder") {
                        importerPresented = true
                    }
                }

                Section("From a URL") {
                    TextField("https://example.com/guest.erofs", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(downloads.active != nil)

                    if let active = downloads.active {
                        ProgressView(value: downloads.fraction) {
                            Text("Downloading \(active) \(Int(downloads.fraction * 100))%")
                                .font(.footnote.monospacedDigit())
                        }
                        if let note = downloads.activityNote {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        Button("Cancel download", role: .destructive) {
                            downloads.cancel()
                        }
                    } else {
                        Button("Download", systemImage: "arrow.down.circle") {
                            if let url { downloads.start(url) }
                        }
                        .disabled(url == nil)
                    }

                    Text(
                        "The download continues in the background, with its " +
                            "progress on the Lock Screen. You can close this sheet."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if let failure = failure ?? downloads.failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text(
                        "Images are copied into Linuxed's Documents folder; " +
                            ".erofs and .ext4 images can be booted. Remove them " +
                            "in the Files app."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add a guest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            // Guest images have no registered type, so any file or bundle is offered.
            .fileImporter(isPresented: $importerPresented, allowedContentTypes: [.item, .folder]) { result in
                do {
                    let source = try result.get()
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    finish(try GuestStore.store(source, named: source.lastPathComponent, move: false))
                } catch {
                    failure = error.localizedDescription
                }
            }
        }
    }

    private func finish(_ name: String) {
        added(name)
        dismiss()
    }
}
