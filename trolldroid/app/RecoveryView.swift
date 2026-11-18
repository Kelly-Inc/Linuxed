// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The launch screen: a recovery-style tile menu that manages the Android
/// images (`TrolldroidSlots`) and boots the chosen one. `boot` hands the scene
/// to the guest's own screens.
struct RecoveryView: View {
    let boot: () -> Void

    private enum Page: String {
        case main, install, wipe, backup, restore, images, reboot
    }

    @State private var page = Page.main
    @State private var slot = TrolldroidSlots.current
    @State private var log: [String] = ["Trolldroid recovery", "Image: \(TrolldroidSlots.current)"]
    @State private var importing = false
    @State private var newName = ""
    @State private var chosenBackup: String?
    @State private var refresh = 0

    private let background = Color(red: 0.09, green: 0.09, blue: 0.10)
    private let tile = Color(red: 0.17, green: 0.17, blue: 0.19)
    private let accent = Color(red: 0.36, green: 0.78, blue: 0.40)

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch page {
                case .main: mainPage
                case .install: installPage
                case .wipe: wipePage
                case .backup: backupPage
                case .restore: restorePage
                case .images: imagesPage
                case .reboot: rebootPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(16)
            console
            navigationBar
        }
        .background(background.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            install(result)
        }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(spacing: 4) {
            Text("Trolldroid Recovery").font(.headline).foregroundStyle(accent)
            HStack {
                Text("Image: \(slot)")
                Spacer()
                Text(TrolldroidSlots.usesCarriedSystem(slot) ? "Built-in system" : "Installed system")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .id(refresh)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tile)
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.enumerated()), id: \.offset) { index, line in
                        Text(line).id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: log.count) { proxy.scrollTo(log.count - 1) }
        }
        .font(.caption.monospaced())
        .foregroundStyle(accent)
        .padding(8)
        .frame(height: 110)
        .background(.black)
        .accessibilityLabel("Log")
    }

    private var navigationBar: some View {
        HStack {
            barButton("chevron.backward", "Back") { page = .main }
                .disabled(page == .main)
            barButton("house", "Home") { page = .main }
            barButton("power", "Reboot") { page = .reboot }
        }
        .padding(.vertical, 6)
        .background(tile)
    }

    private func barButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel(label)
    }

    // MARK: Pages

    private var mainPage: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            menuTile("Install", "square.and.arrow.down", .install)
            menuTile("Wipe", "trash", .wipe)
            menuTile("Backup", "externaldrive.badge.plus", .backup)
            menuTile("Restore", "clock.arrow.circlepath", .restore)
            menuTile("Images", "square.stack.3d.up", .images)
            menuTile("Reboot", "power", .reboot)
        }
    }

    private func menuTile(_ title: String, _ symbol: String, _ target: Page) -> some View {
        Button { page = target } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title)
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(tile, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var installPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install a system into \(slot)").font(.title3.bold())
            Text("Choose an extracted Android release folder: it holds release-manifest.json, boot/ and guest/. The image keeps its data.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Select release folder") { importing = true }
                .buttonStyle(.borderedProminent).tint(accent)
            if !TrolldroidSlots.usesCarriedSystem(slot) {
                Spacer().frame(height: 8)
                Text("Go back to the built-in system").font(.headline)
                SwipeToConfirm(label: "Swipe to remove installed system", accent: accent) {
                    run("Removing installed system") { try TrolldroidSlots.removeCustomSystem(slot) }
                }
            }
        }
    }

    private var wipePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Factory reset \(slot)").font(.title3.bold())
            Text("Deletes the image's data, apps and settings. Its backups and system stay.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Data: \(formatted(TrolldroidSlots.bytes(under: TrolldroidSlots.instance(slot))))")
                .font(.callout.monospaced()).id(refresh)
            SwipeToConfirm(label: "Swipe to wipe", accent: accent) {
                run("Wiping data of \(slot)") { try TrolldroidSlots.wipe(slot) }
            }
        }
    }

    private var backupPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Back up \(slot)").font(.title3.bold())
            Text("Copies the image's data. Boot it at least once first.")
                .font(.callout).foregroundStyle(.secondary)
            SwipeToConfirm(label: "Swipe to back up", accent: accent) {
                run("Backing up \(slot)") {
                    let stamp = try TrolldroidSlots.backup(slot)
                    log.append("Saved backup \(stamp)")
                }
            }
        }
    }

    private var restorePage: some View {
        let backups = TrolldroidSlots.backupNames(slot)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Restore \(slot)").font(.title3.bold())
            if backups.isEmpty {
                Text("No backups yet.").foregroundStyle(.secondary)
            }
            List(backups, id: \.self, selection: $chosenBackup) { stamp in
                Text(stamp).font(.body.monospaced())
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            run("Deleting backup \(stamp)") { try TrolldroidSlots.deleteBackup(slot, backup: stamp) }
                        }
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            if let stamp = chosenBackup {
                SwipeToConfirm(label: "Swipe to restore \(stamp)", accent: accent) {
                    run("Restoring \(stamp)") { try TrolldroidSlots.restore(slot, backup: stamp) }
                    chosenBackup = nil
                }
            }
        }
        .id(refresh)
    }

    private var imagesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Android images").font(.title3.bold())
            List {
                ForEach(TrolldroidSlots.names(), id: \.self) { name in
                    Button {
                        slot = name
                        TrolldroidSlots.current = name
                        log.append("Selected image \(name)")
                    } label: {
                        HStack {
                            Image(systemName: name == slot ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(accent)
                            Text(name)
                            Spacer()
                            Text(TrolldroidSlots.usesCarriedSystem(name) ? "built-in" : "installed")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if name != slot {
                            Button("Delete", role: .destructive) {
                                run("Deleting image \(name)") { try TrolldroidSlots.delete(name) }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .id(refresh)
            HStack {
                TextField("New image name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") {
                    let name = newName
                    run("Creating image \(name)") {
                        try TrolldroidSlots.create(name)
                        newName = ""
                    }
                }
                .buttonStyle(.borderedProminent).tint(accent)
                .disabled(newName.isEmpty)
            }
        }
    }

    private var rebootPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reboot").font(.title3.bold())
            Text("Starts \(slot). Choosing another image later needs Trolldroid to be closed and opened again.")
                .font(.callout).foregroundStyle(.secondary)
            SwipeToConfirm(label: "Swipe to boot \(slot)", accent: accent) {
                TrolldroidSlots.current = slot
                log.append("Booting \(slot)")
                boot()
            }
        }
    }

    // MARK: Actions

    private func run(_ title: String, _ action: () throws -> Void) {
        log.append("\(title)...")
        do {
            try action()
            log.append("Done.")
        } catch {
            log.append("Failed: \(error.localizedDescription)")
        }
        refresh += 1
    }

    private func install(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            log.append("Failed: \(error.localizedDescription)")
        case .success(let folder):
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            run("Installing \(folder.lastPathComponent) into \(slot)") {
                try TrolldroidSlots.install(slot, from: folder)
            }
        }
    }

    private func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

/// A slider that runs its action only once dragged to the end, so a
/// destructive step never follows a stray tap. VoiceOver activates it directly.
struct SwipeToConfirm: View {
    let label: String
    let accent: Color
    let action: () -> Void

    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let knob: CGFloat = 52
            let travel = max(geometry.size.width - knob - 8, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Text(label).font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .opacity(1 - Double(offset / travel))
                Capsule().fill(accent)
                    .frame(width: knob, height: knob)
                    .overlay(Image(systemName: "chevron.right.2").foregroundStyle(.black))
                    .offset(x: 4 + offset)
                    .gesture(
                        DragGesture()
                            .onChanged { offset = min(max(0, $0.translation.width), travel) }
                            .onEnded { _ in
                                if offset >= travel * 0.95 { action() }
                                withAnimation(.spring) { offset = 0 }
                            }
                    )
            }
        }
        .frame(height: 60)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

extension AndariumSceneDelegate {
    /// Shows the recovery menu in a window of its own; booting replaces it.
    func showRecovery(_ scene: UIWindowScene) {
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: RecoveryView { [weak self] in self?.boot(scene) })
        self.window = window
        window.makeKeyAndVisible()
    }
}
