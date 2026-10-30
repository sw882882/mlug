import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation

/// A macOS virtual monitor backed by the private CGVirtualDisplay API.
/// The display exists for as long as this object is alive.
public final class VirtualDisplay {
    private let display: CGVirtualDisplay
    public let pixelWidth: Int
    public let pixelHeight: Int

    public var displayID: CGDirectDisplayID { display.displayID }

    /// - Parameters:
    ///   - width/height: native panel resolution in pixels (landscape).
    ///   - ppi: physical density, used so macOS picks sensible default scaling.
    public init?(name: String, width: Int, height: Int, ppi: Double, refreshRate: Double = 60) {
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.name = name
        desc.maxPixelsWide = UInt32(width)
        desc.maxPixelsHigh = UInt32(height)
        let mmPerInch = 25.4
        desc.sizeInMillimeters = CGSize(width: Double(width) / ppi * mmPerInch,
                                        height: Double(height) / ppi * mmPerInch)
        desc.vendorID = 0x6D6C   // "ml"
        desc.productID = 0x7567  // "ug"
        // Stable serial per resolution so macOS remembers arrangement/scaling.
        desc.serialNum = UInt32(truncatingIfNeeded: width &* 10_000 &+ height)
        desc.terminationHandler = { _, _ in }

        display = CGVirtualDisplay(descriptor: desc)
        pixelWidth = width
        pixelHeight = height

        let settings = CGVirtualDisplaySettings()
        // HiDPI halves the usable area, so only offer it on panels dense enough to afford it.
        settings.hiDPI = width >= 2000 ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: refreshRate)]
        if settings.hiDPI == 1 {
            settings.modes.append(CGVirtualDisplayMode(width: UInt32(width / 2), height: UInt32(height / 2), refreshRate: refreshRate))
        }
        guard display.displayID != 0, display.apply(settings) else { return nil }
        selectPreferredMode(hiDPI: settings.hiDPI == 1)
    }

    /// macOS often defaults a new display to some smaller "standard" mode; pick native
    /// (or 2x HiDPI on dense panels) instead. Modes can take a moment to appear.
    private func selectPreferredMode(hiDPI: Bool, attempt: Int = 0) {
        let wantPoints = hiDPI ? pixelWidth / 2 : pixelWidth
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] ?? []
        if let mode = modes.first(where: { $0.pixelWidth == pixelWidth && $0.width == wantPoints }) {
            if CGDisplayCopyDisplayMode(displayID).map({ $0.ioDisplayModeID != mode.ioDisplayModeID }) ?? true {
                var config: CGDisplayConfigRef?
                CGBeginDisplayConfiguration(&config)
                CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
                CGCompleteDisplayConfiguration(config, .forSession)
            }
        } else if attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.selectPreferredMode(hiDPI: hiDPI, attempt: attempt + 1)
            }
        }
    }

    /// Size of the framebuffer for the currently selected mode, in pixels.
    public var currentPixelSize: (width: Int, height: Int) {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return (pixelWidth, pixelHeight) }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    /// Display rect in global (top-left origin) points, as used by CGEvent.
    public var bounds: CGRect { CGDisplayBounds(displayID) }
}
