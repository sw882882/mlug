import CoreGraphics
import CoreMedia
import Foundation

/// Accepts one tablet at a time. While a tablet is connected, a matching virtual
/// display exists and its contents are streamed to the tablet.
public final class DisplayServer {
    public enum State: Equatable {
        case stopped
        case waiting
        case connected(width: Int, height: Int)
        case failed(String)
    }

    public var bitrate = 30_000_000
    public var fps = 60
    public var onStateChange: ((State) -> Void)?
    public private(set) var state: State = .stopped {
        didSet { let s = state; DispatchQueue.main.async { self.onStateChange?(s) } }
    }

    private let port: UInt16
    private var listener: Listener?
    private var running = false

    public init(port: UInt16 = Wire.defaultPort) { self.port = port }

    public func start() {
        guard !running else { return }
        do {
            listener = try Listener(port: port)
        } catch {
            state = .failed("Port \(port) unavailable: \(error.localizedDescription)")
            return
        }
        running = true
        state = .waiting
        if !InputInjector.ensureTrusted(prompt: true) {
            log("Accessibility access not granted yet; touch input will be ignored until it is.")
        }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    public func stop() {
        running = false
        listener?.close()
        listener = nil
        currentSession?.connection.shutdownNow()
        state = .stopped
    }

    private var currentSession: ClientSession?

    private func acceptLoop() {
        while running, let conn = listener?.accept() {
            let session = ClientSession(connection: conn, bitrate: bitrate, fps: fps) { [weak self] s in
                self?.state = s
            }
            currentSession = session
            session.run()   // blocks until the tablet disconnects
            currentSession = nil
            if running { state = .waiting }
        }
    }
}

/// One connected tablet: owns the virtual display, capture, encoder and input.
private final class ClientSession {
    let connection: Connection
    private let bitrate: Int
    private let fps: Int
    private let setState: (DisplayServer.State) -> Void

    private var display: VirtualDisplay?
    private var injector: InputInjector?
    private var capturer: Capturer?
    private var encoder: Encoder?
    private var streamSize = (width: 0, height: 0)
    private let pipelineQueue = DispatchQueue(label: "mlug.pipeline", qos: .userInteractive)

    // Touched only on the capture queue / encoder callback.
    private var lastBuffer: CVPixelBuffer?
    private var lastPTS = CMTime.zero
    private var awaitingKeyframe = false
    private let dropLock = NSLock()

    init(connection: Connection, bitrate: Int, fps: Int, setState: @escaping (DisplayServer.State) -> Void) {
        self.connection = connection
        self.bitrate = bitrate
        self.fps = fps
        self.setState = setState
    }

    func run() {
        guard let hello = connection.receive(), hello.type == Wire.hello else {
            log("Client did not say hello; dropping.")
            return
        }
        var r = ByteReader(hello.payload)
        guard let version = r.u32(), let w = r.u32(), let h = r.u32(), let dpi = r.u32(), w > 0, h > 0 else { return }
        if version != Wire.version { log("Protocol version mismatch (tablet \(version), mac \(Wire.version)); continuing anyway.") }
        let width = Int(max(w, h)), height = Int(min(w, h))
        log("Tablet connected: \(width)x\(height) @ \(dpi) dpi")

        let created = DispatchQueue.main.sync {
            VirtualDisplay(name: "mlug Tablet", width: width, height: height, ppi: Double(max(dpi, 100)))
        }
        guard let display = created else {
            setState(.failed("Could not create virtual display"))
            return
        }
        self.display = display
        injector = InputInjector(bounds: { [weak display] in display?.bounds ?? .zero }, tabletWidth: width)
        setState(.connected(width: width, height: height))

        let reconfigToken = DisplayReconfigObserver.shared.add { [weak self] id in
            guard let self, id == self.display?.displayID else { return }
            self.pipelineQueue.async { self.restartPipelineIfNeeded() }
        }
        pipelineQueue.async { self.restartPipelineIfNeeded() }

        readLoop()

        DisplayReconfigObserver.shared.remove(reconfigToken)
        let done = DispatchSemaphore(value: 0)
        pipelineQueue.async {
            self.stopPipeline()
            done.signal()
        }
        done.wait()
        DispatchQueue.main.sync { self.display = nil }   // releasing it removes the monitor
        log("Tablet disconnected")
    }

    private func readLoop() {
        while let msg = connection.receive() {
            var r = ByteReader(msg.payload)
            switch msg.type {
            case Wire.pointer:
                if let a = r.u8(), let b = r.u8(), let x = r.f32(), let y = r.f32() {
                    injector?.pointer(action: a, button: b, x: x, y: y)
                }
            case Wire.scroll:
                if let dx = r.f32(), let dy = r.f32() { injector?.scroll(dx: dx, dy: dy) }
            case Wire.keyframe:
                pipelineQueue.async { self.resendKeyframe() }
            default:
                break
            }
        }
    }

    // MARK: pipeline (pipelineQueue only)

    private func restartPipelineIfNeeded() {
        guard let display else { return }
        let size = display.currentPixelSize
        guard size != streamSize || encoder == nil else { return }
        stopPipeline()
        streamSize = size
        log("Streaming \(size.width)x\(size.height)")

        var cfg = Data()
        cfg.appendBE(UInt32(size.width))
        cfg.appendBE(UInt32(size.height))
        connection.send(type: Wire.config, payload: cfg)

        do {
            encoder = try Encoder(width: size.width, height: size.height, bitrate: bitrate, fps: fps) { [weak self] data, key, pts in
                self?.sendFrame(data, keyframe: key, pts: pts)
            }
        } catch {
            setState(.failed("Encoder: \(error)"))
            return
        }
        let capturer = Capturer(onFrame: { [weak self] buf, pts in
            guard let self else { return }
            self.dropLock.withLock { self.lastBuffer = buf; self.lastPTS = pts }
            self.encoder?.encode(buf, pts: pts)
        }, onStop: { [weak self] err in
            if let err { log("Capture stopped: \(err.localizedDescription)") }
            self?.connection.shutdownNow()
        })
        self.capturer = capturer
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                try await capturer.start(displayID: display.displayID, width: size.width, height: size.height, fps: fps)
            } catch {
                self.setState(.failed("Screen capture: \(error.localizedDescription). Grant Screen Recording permission and reconnect."))
                self.connection.shutdownNow()
            }
            sem.signal()
        }
        sem.wait()
    }

    private func stopPipeline() {
        if let capturer {
            let sem = DispatchSemaphore(value: 0)
            Task { await capturer.stop(); sem.signal() }
            sem.wait()
        }
        capturer = nil
        encoder?.invalidate()
        encoder = nil
        dropLock.withLock { lastBuffer = nil }
    }

    private func resendKeyframe() {
        guard let encoder else { return }
        encoder.requestKeyframe()
        let (buf, pts) = dropLock.withLock { (lastBuffer, lastPTS) }
        if let buf { encoder.encode(buf, pts: CMTimeAdd(pts, CMTime(value: 1, timescale: 1000))) }
    }

    private func sendFrame(_ data: Data, keyframe: Bool, pts: UInt64) {
        let drop = dropLock.withLock { () -> Bool in
            if keyframe { awaitingKeyframe = false }
            if awaitingKeyframe { return true }
            // Never queue more than a couple of frames: latency matters more than smoothness.
            if connection.backlog >= 3 { awaitingKeyframe = true; return true }
            return false
        }
        if drop {
            if !keyframe { pipelineQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.resendKeyframeIfStalled() } }
            return
        }
        var payload = Data(capacity: data.count + 9)
        payload.append(keyframe ? 1 : 0)
        payload.appendBE(pts)
        payload.append(data)
        connection.send(type: Wire.frame, payload: payload, isFrame: true)
    }

    private func resendKeyframeIfStalled() {
        let stalled = dropLock.withLock { awaitingKeyframe }
        guard stalled else { return }
        if connection.backlog >= 3 {
            pipelineQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.resendKeyframeIfStalled() }
        } else {
            resendKeyframe()
        }
    }
}

/// Fan-out for CGDisplayRegisterReconfigurationCallback (which takes a C function pointer).
final class DisplayReconfigObserver {
    static let shared = DisplayReconfigObserver()
    private var handlers: [UUID: (CGDirectDisplayID) -> Void] = [:]
    private let lock = NSLock()

    private init() {
        CGDisplayRegisterReconfigurationCallback({ id, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DisplayReconfigObserver.shared.fire(id)
        }, nil)
    }

    func add(_ h: @escaping (CGDirectDisplayID) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { handlers[id] = h }
        return id
    }
    func remove(_ id: UUID) { _ = lock.withLock { handlers.removeValue(forKey: id) } }
    private func fire(_ display: CGDirectDisplayID) {
        for h in lock.withLock({ Array(handlers.values) }) { h(display) }
    }
}

func log(_ s: String) {
    FileHandle.standardError.write(Data("[mlug] \(s)\n".utf8))
}
