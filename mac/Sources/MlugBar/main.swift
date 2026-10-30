import AppKit
import MlugCore

/// Menu bar front end: lives in the status bar, no Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let server = DisplayServer()
    private let adb = AdbWatcher()
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private static let bitrates = [15, 30, 50, 80]

    func applicationDidFinishLaunching(_ note: Notification) {
        defaults.register(defaults: ["bitrateMbps": 30, "autoLaunch": true])
        server.bitrate = defaults.integer(forKey: "bitrateMbps") * 1_000_000
        adb.autoLaunch = defaults.bool(forKey: "autoLaunch")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.menu = menu

        server.onStateChange = { [weak self] _ in self?.refresh() }
        adb.onDevicesChange = { [weak self] _ in self?.refresh() }
        server.start()
        adb.start()
        refresh()
    }

    func applicationWillTerminate(_ note: Notification) {
        adb.stop()
        server.stop()
    }

    private func refresh() {
        let symbol: String
        switch server.state {
        case .connected: symbol = "rectangle.on.rectangle"
        case .failed: symbol = "exclamationmark.triangle"
        default: symbol = adb.devices.isEmpty ? "ipad.landscape" : "ipad.landscape.badge.play"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "mlug")
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: "mlug")
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let stateText: String
        switch server.state {
        case .stopped: stateText = "Stopped"
        case .waiting: stateText = adb.devices.isEmpty ? "Plug in your tablet via USB" : "Waiting for tablet app…"
        case let .connected(w, h): stateText = "Extended display active (\(w)×\(h))"
        case let .failed(msg): stateText = "Error: \(msg)"
        }
        menu.addItem(disabled(stateText))
        if adb.adbPath == nil {
            menu.addItem(disabled("adb not found — brew install android-platform-tools"))
        } else {
            for d in adb.devices { menu.addItem(disabled("USB device: \(d)")) }
        }
        menu.addItem(.separator())

        menu.addItem(item("Reconnect Tablet", #selector(reconnect)))
        menu.addItem(item("Display Settings…", #selector(openDisplaySettings)))
        menu.addItem(.separator())

        let quality = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = defaults.integer(forKey: "bitrateMbps")
        for mbps in Self.bitrates {
            let i = item("\(mbps) Mbps", #selector(setBitrate(_:)))
            i.tag = mbps
            i.state = mbps == current ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        sub.addItem(disabled("Applies on next connection"))
        quality.submenu = sub
        menu.addItem(quality)

        let auto = item("Open Tablet App on Connect", #selector(toggleAutoLaunch))
        auto.state = adb.autoLaunch ? .on : .off
        menu.addItem(auto)

        menu.addItem(item("Permissions…", #selector(openPermissions)))
        menu.addItem(.separator())
        menu.addItem(item("Quit mlug", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func reconnect() { adb.relaunch() }

    @objc private func setBitrate(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: "bitrateMbps")
        server.bitrate = sender.tag * 1_000_000
    }

    @objc private func toggleAutoLaunch() {
        adb.autoLaunch.toggle()
        defaults.set(adb.autoLaunch, forKey: "autoLaunch")
    }

    @objc private func openDisplaySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }

    @objc private func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
