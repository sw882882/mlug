import Foundation

/// Polls `adb devices`; for each newly attached device, sets up the USB tunnel
/// (`adb reverse`) and optionally launches the tablet app.
public final class AdbWatcher {
    public static let androidPackage = "dev.mlug"
    public static let androidActivity = "dev.mlug/.MainActivity"

    public var autoLaunch = true
    public var onDevicesChange: (([String]) -> Void)?
    public private(set) var devices: [String] = []

    private let port: UInt16
    private let adb: String?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "mlug.adb")
    private var prepared = Set<String>()

    public init(port: UInt16 = Wire.defaultPort) {
        self.port = port
        adb = AdbWatcher.findAdb()
    }

    public var adbPath: String? { adb }

    public static func findAdb() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["ANDROID_HOME"].map { "\($0)/platform-tools/adb" },
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func start() {
        guard adb != nil else { log("adb not found; install android-platform-tools"); return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }

    /// Re-run tunnel setup + launch for every attached device.
    public func relaunch() { queue.async { self.prepared.removeAll(); self.poll() } }

    private func poll() {
        guard let out = run(["devices"]) else { return }
        let serials = out.split(separator: "\n").dropFirst().compactMap { line -> String? in
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            return parts.count >= 2 && parts[1] == "device" ? String(parts[0]) : nil
        }
        prepared.formIntersection(serials)
        for s in serials where !prepared.contains(s) {
            _ = run(["-s", s, "reverse", "tcp:\(port)", "tcp:\(port)"])
            if autoLaunch {
                _ = run(["-s", s, "shell", "am", "start", "-n", AdbWatcher.androidActivity])
            }
            log("Prepared device \(s)")
            prepared.insert(s)
        }
        if serials != devices {
            devices = serials
            DispatchQueue.main.async { self.onDevicesChange?(serials) }
        }
    }

    @discardableResult
    func run(_ args: [String]) -> String? {
        guard let adb else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
