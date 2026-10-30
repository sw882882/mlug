import Foundation
import MlugCore

// Command-line front end, handy for development. The menu bar app wraps the same core.
var args = CommandLine.arguments.dropFirst()
let server = DisplayServer()
let adb = AdbWatcher()
while let a = args.popFirst() {
    switch a {
    case "--bitrate": if let v = args.popFirst().flatMap(Int.init) { server.bitrate = v * 1_000_000 }
    case "--fps": if let v = args.popFirst().flatMap(Int.init) { server.fps = v }
    case "--no-launch": adb.autoLaunch = false
    default:
        print("usage: mlug [--bitrate MBPS] [--fps N] [--no-launch]")
        exit(2)
    }
}
server.onStateChange = { print("state:", $0) }
server.start()
adb.start()
signal(SIGINT) { _ in exit(0) }
dispatchMain()
