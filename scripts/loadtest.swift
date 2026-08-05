// Verifies Lerping@Home.saver loads the way legacyScreenSaver will load it:
// NSBundle -> principal class -> instantiate a ScreenSaverView.
import AppKit
import ScreenSaver

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: loadtest <path to Lerping@Home.saver>")
    exit(2)
}
guard let bundle = Bundle(path: arguments[1]) else {
    print("FAIL: no bundle at \(arguments[1])")
    exit(1)
}
do {
    try bundle.loadAndReturnError()
} catch {
    print("FAIL: bundle load error: \(error)")
    exit(1)
}
guard let principal = bundle.principalClass as? ScreenSaverView.Type else {
    print("FAIL: principal class is \(String(describing: bundle.principalClass)), not a ScreenSaverView")
    exit(1)
}
guard let view = principal.init(frame: NSRect(x: 0, y: 0, width: 400, height: 250), isPreview: true) else {
    print("FAIL: could not instantiate \(principal)")
    exit(1)
}
print("OK: loaded \(principal), instantiated \(type(of: view)), hasConfigureSheet=\(view.hasConfigureSheet)")
exit(0)
