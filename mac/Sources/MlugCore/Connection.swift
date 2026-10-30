import Foundation

/// Minimal blocking TCP server for a single tablet over `adb reverse`.
/// Binds to loopback only; the USB tunnel is the only way in.
public final class Listener {
    private let fd: Int32
    public let port: UInt16

    public init(port: UInt16) throws {
        self.port = port
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0, listen(fd, 1) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: err) ?? .EADDRINUSE)
        }
    }

    /// Blocks until a client connects.
    public func accept() -> Connection? {
        let c = Darwin.accept(fd, nil, nil)
        guard c >= 0 else { return nil }
        return Connection(fd: c)
    }

    public func close() { Darwin.close(fd) }
}

public final class Connection {
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "mlug.write")
    private let lock = NSLock()
    private var pendingFrames = 0
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        var yes: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var buf: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Frames queued but not yet written. Used to drop frames instead of building latency.
    public var backlog: Int { lock.withLock { pendingFrames } }

    public func send(type: UInt8, payload: Data, isFrame: Bool = false) {
        var msg = Data(capacity: payload.count + 5)
        msg.append(type)
        msg.appendBE(UInt32(payload.count))
        msg.append(payload)
        if isFrame { lock.withLock { pendingFrames += 1 } }
        writeQueue.async { [self] in
            writeAll(msg)
            if isFrame { lock.withLock { pendingFrames -= 1 } }
        }
    }

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { if errno == EINTR { continue }; shutdownNow(); return }
                off += n
            }
        }
    }

    /// Blocks until a full message arrives; nil on disconnect.
    public func receive() -> (type: UInt8, payload: Data)? {
        guard let header = readExactly(5) else { return nil }
        var r = ByteReader(header)
        guard let type = r.u8(), let len = r.u32(), len < 1 << 20 else { return nil }
        guard let payload = readExactly(Int(len)) else { return nil }
        return (type, payload)
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var off = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            while off < count {
                let n = Darwin.read(fd, raw.baseAddress! + off, count - off)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
        return ok ? data : nil
    }

    public func shutdownNow() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.shutdown(fd, SHUT_RDWR)
        }
    }

    deinit { Darwin.close(fd) }
}
