// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The Android images Trolldroid keeps. Each image is a directory in
/// `Library/Guests/<name>/`: `instance/` is the guest's own files (the data
/// disk among them), `system/` an installed release that replaces the one the
/// application carries, and `backups/<stamp>/` copies of `instance/`. A name
/// is part of a disk path the kernel receives, so it is limited to letters,
/// digits, `-` and `_`.
enum TrolldroidSlots {
    static let defaultName = "Android"
    private static let key = "trolldroid.slot"
    private static var files: FileManager { .default }

    static var root: URL {
        let library = (try? files.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? files.temporaryDirectory
        return library.appendingPathComponent("Guests", isDirectory: true)
    }

    static var current: String {
        get {
            let stored = UserDefaults.standard.string(forKey: key) ?? defaultName
            return isValid(stored) ? stored : defaultName
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 32 && name.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    static func directory(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    static func instance(_ name: String) -> URL {
        directory(name).appendingPathComponent("instance", isDirectory: true)
    }

    static func system(_ name: String) -> URL {
        directory(name).appendingPathComponent("system", isDirectory: true)
    }

    static func backups(_ name: String) -> URL {
        directory(name).appendingPathComponent("backups", isDirectory: true)
    }

    /// The image's own release, or nil for the one the application carries.
    static func systemFolder(_ name: String) -> URL? {
        let folder = system(name)
        return files.fileExists(atPath: folder.appendingPathComponent(SystemFolder.manifest).path) ? folder : nil
    }

    static func names() -> [String] {
        let entries = (try? files.contentsOfDirectory(atPath: root.path)) ?? []
        let names = Set(entries.filter(isValid)).union([current])
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func create(_ name: String) throws {
        guard isValid(name) else { throw SlotError.badName }
        try files.createDirectory(at: instance(name), withIntermediateDirectories: true)
    }

    static func delete(_ name: String) throws {
        try removeIfPresent(directory(name))
        if current == name { current = names().first ?? defaultName }
    }

    /// Deletes the guest's own files; the next boot is a first boot.
    static func wipe(_ name: String) throws {
        try removeIfPresent(instance(name))
        try files.createDirectory(at: instance(name), withIntermediateDirectories: true)
    }

    static func backupNames(_ name: String) -> [String] {
        ((try? files.contentsOfDirectory(atPath: backups(name).path)) ?? []).sorted().reversed()
    }

    /// Copies the guest's files; APFS clones them, so a backup costs only what
    /// the guest writes after it.
    @discardableResult
    static func backup(_ name: String) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: Date())
        try files.createDirectory(at: backups(name), withIntermediateDirectories: true)
        try files.copyItem(at: instance(name), to: backups(name).appendingPathComponent(stamp))
        return stamp
    }

    static func restore(_ name: String, backup stamp: String) throws {
        let source = backups(name).appendingPathComponent(stamp)
        guard files.fileExists(atPath: source.path) else { throw SlotError.missing(stamp) }
        try removeIfPresent(instance(name))
        try files.copyItem(at: source, to: instance(name))
    }

    static func deleteBackup(_ name: String, backup stamp: String) throws {
        try removeIfPresent(backups(name).appendingPathComponent(stamp))
    }

    /// Installs an extracted release folder as the image's system. The guest's
    /// data stays; the application's own update rules decide at the next boot
    /// what an update to it does.
    static func install(_ name: String, from folder: URL) throws {
        let required = [SystemFolder.manifest, SystemFolder.commandLine, SystemFolder.layout, SystemFolder.systemDisk]
        for file in required where !files.fileExists(atPath: folder.appendingPathComponent(file).path) {
            throw SlotError.notARelease(file)
        }
        try files.createDirectory(at: directory(name), withIntermediateDirectories: true)
        let staging = directory(name).appendingPathComponent("system.partial", isDirectory: true)
        try removeIfPresent(staging)
        try files.copyItem(at: folder, to: staging)
        try removeIfPresent(system(name))
        try files.moveItem(at: staging, to: system(name))
    }

    static func usesCarriedSystem(_ name: String) -> Bool { systemFolder(name) == nil }

    static func removeCustomSystem(_ name: String) throws {
        try removeIfPresent(system(name))
    }

    static func bytes(under url: URL) -> UInt64 {
        guard let walker = files.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walker {
            total += UInt64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func removeIfPresent(_ url: URL) throws {
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }
}

enum SlotError: LocalizedError {
    case badName
    case missing(String)
    case notARelease(String)

    var errorDescription: String? {
        switch self {
        case .badName: "Use up to 32 letters, digits, - or _."
        case .missing(let name): "\(name) does not exist."
        case .notARelease(let file): "The folder is not an Android release: \(file) is missing."
        }
    }
}
