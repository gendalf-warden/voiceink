import AppKit
import VoiceInkLib

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

signal(SIGINT) { _ in
    NSApplication.shared.terminate(nil)
}
signal(SIGTERM) { _ in
    NSApplication.shared.terminate(nil)
}

log("Starting...")
app.run()
