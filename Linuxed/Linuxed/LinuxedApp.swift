// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

@main
struct LinuxedApp: App {
    @UIApplicationDelegateAdaptor(LinuxedAppDelegate.self) private var appDelegate

    init() {
        // Before any display controller loads, so it can be taken to an
        // external screen that is already connected.
        _ = ExternalDisplay.shared
        // Before any view: the display and the terminal compile Metal
        // pipelines as they are created, and that reads the shader cache.
        MetalShaderCache.removeIfBloatedBeforeFirstUse()
        // Mesa would otherwise keep a disk cache of its own below
        // $HOME/.cache, which a device container does not let it create.
        // Give it a bounded home in the application's cache directory, here
        // and on a Mac alike.
        MesaShaderCache.configureBeforeFirstUse()
        // The host GL provider selects its driver through the environment
        // when it creates its display, on a runtime thread during boot. The
        // terminal's libghostty copied the environment at its first
        // initialization, so a variable added after that leaves its copy
        // pointing at freed memory and the next terminal configuration
        // crashes. Every process variable is set here, before any view.
        // The Simulator has no Metal 4 device, so its provider is Mesa's
        // llvmpipe rasterizer, which Mesa selects when software rendering
        // is forced.
        #if targetEnvironment(simulator)
        setenv("LIBGL_ALWAYS_SOFTWARE", "true", 1)
        #else
        setenv("MESA_LOADER_DRIVER_OVERRIDE", "zink", 1)
        #endif
    }

    /// The launcher reads the settings once, as it first starts, so the guest
    /// view is made only after the menu has saved the chosen image.
    /// A launch that names its image (automation, the hosted tests) boots at once.
    @State private var booted = ProcessInfo.processInfo.environment[RootfsImage.environmentKey] != nil
    @State private var splashVisible = ProcessInfo.processInfo.environment[RootfsImage.environmentKey] == nil
    @State private var logoVisible = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                if booted {
                    ContentView()
                        .statusBarHidden()
                        .persistentSystemOverlays(.hidden)
                } else {
                    MainMenuView { booted = true }
                }
                if splashVisible {
                    SplashView(logoVisible: logoVisible)
                        .transition(.opacity)
                        // Keeps the splash above the menu while it fades out.
                        .zIndex(1)
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: splashVisible)
            .task {
                guard splashVisible else { return }
                // Picks up a download that kept going after the last run.
                Downloads.shared.resume()
                // shortcut: fixed 1.8s; tie this to real loading when there is any.
                try? await Task.sleep(for: .seconds(1.8))
                logoVisible = false
                try? await Task.sleep(for: .seconds(0.6))
                withAnimation(.easeOut(duration: 0.5)) { splashVisible = false }
            }
        }
    }
}

private struct SplashView: View {
    let logoVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    @State private var beat = 0

    var body: some View {
        // shortcut: the wordmark stands in for a logo; swap in the logo image when there is one.
        Text("Linuxed")
            .font(.system(size: 34, weight: .bold).width(.expanded))
            .tracking(2)
            .foregroundStyle(Color(red: 0.933, green: 0.941, blue: 0.961))
            .scaleEffect(pulsing ? 1.02 : 0.98)
            .opacity(pulsing ? 1 : 0.8)
            .opacity(logoVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.6), value: logoVisible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.043, green: 0.051, blue: 0.078))
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
            // A soft heartbeat in step with the pulse (one beat per 0.8s swing).
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: beat)
            .task {
                while !Task.isCancelled {
                    beat += 1
                    try? await Task.sleep(for: .seconds(0.8))
                }
            }
            .onAppear {
                guard !reduceMotion else { return pulsing = true }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

