// The few AppKit/UIKit differences the shared views need, behind one set of names, so the rest of
// Shared/ (and the cross-platform App/ views) compile unchanged for macOS and iOS.

import SwiftUI
import CoreGraphics
#if os(macOS)
import AppKit

/// A decoded bitmap: `NSImage` on macOS, `UIImage` on iOS.
typealias PlatformImage = NSImage

extension PlatformImage {
    /// Wraps a decoded bitmap at one point per pixel (like the AppKit code always did).
    static func make(_ cg: CGImage) -> PlatformImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}

extension Color {
    /// The window background: halos behind map labels and the Standard widget style.
    static var platformBackground: Color { Color(nsColor: .windowBackgroundColor) }
}
#else
import UIKit

/// A decoded bitmap: `NSImage` on macOS, `UIImage` on iOS.
typealias PlatformImage = UIImage

extension PlatformImage {
    /// Wraps a decoded bitmap at one point per pixel, matching the macOS size semantics.
    static func make(_ cg: CGImage) -> PlatformImage { UIImage(cgImage: cg, scale: 1, orientation: .up) }
}

extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}

extension Color {
    /// The system background: halos behind map labels and the Standard widget style.
    static var platformBackground: Color { Color(uiColor: .systemBackground) }
}
#endif

/// What the app calls the device in user-facing copy ("stored only on this Mac / iPhone").
enum DeviceName {
    #if os(macOS)
    static let this = "this Mac"
    #else
    static let this = "this iPhone"
    #endif
}

extension View {
    /// A checkbox on macOS; the standard switch on iOS, which has no checkbox.
    @ViewBuilder func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.switch)
        #endif
    }

    /// A text link button on macOS; a borderless (tinted text) button on iOS.
    @ViewBuilder func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }
}
