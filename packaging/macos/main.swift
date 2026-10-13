// main.swift - NSApplication bootstrap for ScrcpyPicker.
// Must be named main.swift because Swift only allows top-level executable
// statements in a file called main.swift when compiling a multi-file target.
import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
