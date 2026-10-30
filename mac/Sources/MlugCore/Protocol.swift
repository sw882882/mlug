import Foundation

/// Wire protocol, shared with the Android app (see android/.../Protocol.kt).
/// Every message is: u8 type, u32 big-endian payload length, payload.
public enum Wire {
    public static let defaultPort: UInt16 = 38281
    public static let version: UInt32 = 1

    // Mac -> tablet
    public static let config: UInt8 = 1     // u32 width, u32 height
    public static let frame: UInt8 = 2      // u8 flags (bit0 = keyframe), u64 ptsMicros, Annex-B H.264

    // Tablet -> Mac
    public static let hello: UInt8 = 1      // u32 version, u32 width px, u32 height px, u32 dpi
    public static let pointer: UInt8 = 2    // u8 action (0 move, 1 down, 2 up), u8 button (0 left, 1 right), f32 x, f32 y (0..1)
    public static let scroll: UInt8 = 3     // f32 dx, f32 dy (tablet pixels)
    public static let keyframe: UInt8 = 4   // empty
}

struct ByteReader {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }

    mutating func u8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }
    mutating func u32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(data[data.startIndex + offset + i]) }
        offset += 4
        return v
    }
    mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }
}
