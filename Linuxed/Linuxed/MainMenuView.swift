// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// A page of the main menu: one bootable image in Documents, or the add page.
struct Guest: Identifiable {
    let name: String
    let tagline: String
    let specs: [(label: String, value: String)]
    /// A bundled screenshot in Resources (sources in Resources/CREDITS.md).
    var screenshot: String?
    var id: String { name }
    var image: Image? {
        screenshot.flatMap { UIImage(named: $0) }.map(Image.init(uiImage:))
    }

    /// The last page of the pager, which adds a guest instead of booting one.
    static let add = Guest(name: "Add a guest", tagline: "Import an image or download one", specs: [])

    /// Every image the launcher can boot, as the settings' picker lists them.
    static func available() -> [Guest] {
        RootfsImage.availableFilenames().map { name in
            let url = RootfsImage.documentsDirectory.appending(path: name)
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let changes = FileManager.default.fileExists(atPath: url.path + ".changes")
            return Guest(
                name: name,
                tagline: changes ? "Keeps its changes between boots" : "Not booted yet",
                specs: [
                    ("format", (name as NSString).pathExtension.lowercased()),
                    ("size", bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "unknown"),
                ],
                screenshot: screenshot(for: name)
            )
        }
    }

    /// shortcut: a screenshot by the name's distribution, when we bundle one.
    private static func screenshot(for name: String) -> String? {
        let lower = name.lowercased()
        return ["debian", "arch", "alpine"].first { lower.hasPrefix($0) }.map { "\($0).png" }
    }
}

/// One ink-tinted neutral ramp.
private enum Ink {
    static let page = Color(red: 0.043, green: 0.051, blue: 0.078)
    static let primary = Color(red: 0.933, green: 0.941, blue: 0.961)
    static let secondary = Color(red: 0.639, green: 0.663, blue: 0.722)
    static let muted = Color(red: 0.478, green: 0.510, blue: 0.588)
    static let hairline = primary.opacity(0.08)
}

struct MainMenuView: View {
    /// Boots the chosen image, which is already saved as the configured rootfs.
    var start: () -> Void = {}
    @State private var settingsPresented = false
    @State private var selection: Guest.ID?
    @State private var bootTaps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var addPresented = false
    @State private var imported = Guest.available()

    private var downloads = Downloads.shared

    private var guests: [Guest] { imported + [addPage] }

    /// The add page reports a running download in place of its tagline.
    private var addPage: Guest {
        var page = Guest.add
        if let active = downloads.active {
            page = Guest(
                name: page.name,
                tagline: "Downloading \(active) \(Int(downloads.fraction * 100))%",
                specs: []
            )
        }
        return page
    }

    private var current: Guest {
        guests.first { $0.id == selection } ?? guests[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 16)
            pager
            Spacer(minLength: 16)
            footer
        }
        .background { backdrop }
        // Haptics: a tick per page, a thud on Boot, a light tap opening Settings.
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.impact(weight: .medium), trigger: bootTaps)
        .sensoryFeedback(.impact(weight: .light), trigger: settingsPresented) { _, shown in shown }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $settingsPresented, onDismiss: refresh) {
            EmulatorSettingsView()
        }
        .onAppear(perform: refresh)
        // A finished download becomes a page, wherever it finished.
        .onChange(of: downloads.finished) { _, name in
            imported = Guest.available()
            if addPresented { addPresented = false }
            selection = name
        }
        .sheet(isPresented: $addPresented) {
            AddGuestView { name in
                imported = Guest.available()
                selection = name
            }
        }
    }

    /// Lists Documents again and lands on the configured image.
    private func refresh() {
        imported = Guest.available()
        let configured = EmulatorConfiguration.load().rootfsFilename
        if selection == nil || !guests.contains(where: { $0.id == selection }) {
            selection = imported.contains { $0.id == configured } ? configured : guests.first?.id
        }
    }

    private func boot(_ guest: Guest) {
        var configuration = EmulatorConfiguration.load()
        configuration.rootfsFilename = guest.name
        configuration.save()
        start()
    }

    private var header: some View {
        HStack {
            Text("Linuxed")
                // Expanded is the widest cut the system font has; tracking adds the rest.
                .font(.system(.title2, weight: .bold).width(.expanded))
                .tracking(1.5)
                .foregroundStyle(Ink.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                settingsPresented = true
            } label: {
                // The glass is part of the label, so the whole circle (and a
                // 44pt square around it) takes the tap, not only the glyph.
                Image(systemName: "gearshape")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.leading, 32)
        // The 44pt tap square overhangs the 32pt circle by 6 on each side.
        .padding(.trailing, 26)
        .padding(.vertical, 2)
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(guests) { guest in
                    GuestPage(guest: guest)
                        .onTapGesture {
                            if guest.id == Guest.add.id { addPresented = true }
                        }
                        .frame(maxWidth: 720)
                        .containerRelativeFrame(.horizontal)
                        .scrollTransition { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.94)
                                .opacity(phase.isIdentity ? 1 : 0.4)
                        }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 32, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $selection)
        .scrollIndicators(.hidden)
    }

    private var footer: some View {
        VStack(spacing: 16) {
            Button {
                bootTaps += 1
                if current.id == Guest.add.id { addPresented = true } else { boot(current) }
            } label: {
                Text(current.id == Guest.add.id ? "Add a guest" : "Boot \(current.name)")
                    .lineLimit(1)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            // The one primary action: an off-white pill with dark text.
            .buttonStyle(.glassProminent)
            .tint(Ink.primary)
            .foregroundStyle(Ink.page)
            .buttonBorderShape(.capsule)
            .frame(maxWidth: 480)

            HStack(spacing: 8) {
                ForEach(guests) { guest in
                    Capsule()
                        .fill(guest.id == current.id ? Ink.primary : Ink.muted.opacity(0.5))
                        .frame(width: guest.id == current.id ? 20 : 6, height: 6)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.2), value: current.id)
    }

    /// The selected guest's screenshot, zoomed in, blurred and dimmed. It drifts
    /// slowly, so the wallpaper's light and dark areas wander behind the page.
    private var backdrop: some View {
        Ink.page
            .overlay {
                // Driven by the clock rather than a repeating animation, which
                // did not run here. Paused under Reduce Motion.
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(guests) { guest in
                            guest.image?.resizable()
                                .opacity(guest.id == current.id ? 1 : 0)
                        }
                    }
                    .scaleEffect(2.6 + 0.4 * sin(t / 5))
                    .rotationEffect(.degrees(30 * sin(t / 11)))
                    .offset(x: 120 * sin(t / 7), y: 90 * cos(t / 9))
                    // Soft enough to lose the detail, not so soft the motion disappears.
                    .blur(radius: 50, opaque: true)
                    .opacity(0.5)
                }
                .animation(.easeOut(duration: 0.4), value: current.id)
            }
            .clipped()
            .ignoresSafeArea()
    }
}

private struct GuestPage: View {
    let guest: Guest
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        let compact = verticalSizeClass == .compact
        // Landscape phones put the screenshot beside the spec sheet.
        let layout = compact
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 32))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))

        layout {
            if let image = guest.image {
                image
                    .resizable()
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(Ink.primary.opacity(0.12), lineWidth: 1) }
                    // A floating window over the backdrop keeps a soft neutral shadow.
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                    .accessibilityLabel("\(guest.name) desktop")
            } else {
                // No screenshot: an empty slot, dashed for the add page.
                let adding = guest.id == Guest.add.id
                shape
                    .fill(Ink.primary.opacity(0.04))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        shape.strokeBorder(
                            Ink.primary.opacity(adding ? 0.3 : 0.12),
                            style: StrokeStyle(lineWidth: 1, dash: adding ? [6, 6] : [])
                        )
                    }
                    .overlay {
                        Image(systemName: adding ? "plus" : "externaldrive")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(Ink.secondary)
                    }
                    .contentShape(shape)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: compact ? 12 : 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(guest.name)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .font(.system(size: compact ? 28 : 40, weight: .semibold))
                        .tracking(compact ? -0.4 : -0.8)
                        .foregroundStyle(Ink.primary)
                    if !compact {
                        Text(guest.tagline)
                            .font(.subheadline)
                            .foregroundStyle(Ink.secondary)
                    }
                }

                // The spec sheet, set like a system-info readout.
                VStack(spacing: 0) {
                    ForEach(guest.specs, id: \.label) { spec in
                        HStack {
                            Text(spec.label).foregroundStyle(Ink.muted)
                            Spacer()
                            Text(spec.value).foregroundStyle(Ink.primary)
                        }
                        .font(.footnote.monospaced())
                        .frame(height: compact ? 28 : 36)
                        .overlay(alignment: .top) {
                            Ink.hairline.frame(height: 1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    MainMenuView()
}
