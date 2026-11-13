// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A guest image Linuxed publishes, as the menu and Add a guest describe it.
struct CatalogImage: Identifiable, Equatable {
    /// The file name in Documents, which is also how the image is downloaded.
    let file: String
    let name: String
    let desktop: String
    let tagline: String
    /// The download's size, to say before it starts.
    let bytes: Int64
    /// A bundled screenshot in Resources, if there is one.
    var screenshot: String?

    var id: String { file }
    var url: URL {
        URL(string: "https://github.com/Kelly-Inc/Linuxed/releases/download/\(release)/\(file)")!
    }

    /// The release the image's build attaches it to (tools/rootfs/starter).
    private var release: String {
        file.replacingOccurrences(of: "-13", with: "")
            .replacingOccurrences(of: ".erofs", with: "")
    }
}

enum GuestCatalog {
    static let images: [CatalogImage] = [
        CatalogImage(
            file: "debian-13-xfce.erofs",
            name: "Debian 13",
            desktop: "XFCE",
            tagline: "A light, classic desktop with windows and a panel",
            bytes: 243_941_376,
            screenshot: "debian.png"
        ),
        CatalogImage(
            file: "debian-13-phosh.erofs",
            name: "Debian 13",
            desktop: "Phosh",
            tagline: "A touch-first phone shell with an on-screen keyboard",
            bytes: 840_753_152,
            screenshot: "debian.png"
        ),
        CatalogImage(
            file: "debian-13-plasma-mobile.erofs",
            name: "Debian 13",
            desktop: "Plasma Mobile",
            tagline: "KDE's phone shell",
            bytes: 1_553_862_656,
            screenshot: "debian.png"
        ),
        CatalogImage(
            file: "debian-13-ztmetro.erofs",
            name: "Debian 13",
            desktop: "ztMETRO",
            tagline: "The Windows Phone–style Metro shell from ztOS",
            bytes: 310_784_000,
            screenshot: "debian.png"
        ),
    ]

    /// The catalog's description of a file in Documents, if it is one of them.
    static func entry(for file: String) -> CatalogImage? {
        images.first { $0.file == file }
    }
}
