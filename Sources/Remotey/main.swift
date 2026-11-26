import AppKit

let app = NSApplication.shared
// Held here: the application keeps only a weak reference to its delegate.
let delegate: NSApplicationDelegate = Headless.on ? Headless() : AppDelegate()
app.delegate = delegate
// Headless: no Dock icon, no menu bar, never the active app.
app.setActivationPolicy(Headless.on ? .prohibited : .accessory)
app.run()
