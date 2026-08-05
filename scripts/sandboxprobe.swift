// What the screensaver's Options… sheet can actually do inside an App Sandbox.
//
// `make test-load` builds the real sheet, but in a plain command-line process
// with the run of the machine. The sheet the user gets is built inside
// `legacyScreenSaver.appex`, which is App Sandboxed — and "can it make an
// MTLDevice, compile a shader and write a cache in there" is not a question to
// answer by assuming.
//
// So this runs the same code in the same *kind* of process. `make sandbox-probe`
// wraps it in an .app bundle and ad-hoc signs it with the entitlements
// legacyScreenSaver itself carries (see scripts/SandboxProbe.entitlements,
// which is a transcription of
// `codesign -d --entitlements - /System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex`
// minus the `com.apple.private.*` ones, which no locally-signed binary may
// claim). It therefore gets a real sandbox container, a redirected
// `NSHomeDirectory()`, and a real denial when it reaches outside it.
//
//   sandboxprobe <path to Lerping@Home.saver>
//
// Every line it prints starts with `PROBE `, so the whole run is one grep.
import AppKit
import Metal
import ScreenSaver

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: sandboxprobe <path to Lerping@Home.saver>")
    exit(2)
}
setbuf(stdout, nil)

var failures: [String] = []
func report(_ name: String, _ ok: Bool, _ detail: String) {
    print("PROBE \(ok ? "yes" : "NO ") \(name): \(detail)")
    if !ok { failures.append(name) }
}

// MARK: - Which process is this

let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? ""
let home = NSHomeDirectory()
report("app-sandboxed", home != realHome && home.contains("/Library/Containers/"),
       "NSHomeDirectory() = \(home)")
print("PROBE     real home = \(realHome)")

// MARK: - Metal

// Both of these are things the shipped screensaver already does inside this
// sandbox — it compiles every shader from source at runtime, and the wallpaper
// handoff renders full-screen stills — but the gallery does them from the
// *configure sheet*, so they are worth establishing rather than inheriting.
let device = MTLCreateSystemDefaultDevice()
report("metal-device", device != nil, device?.name ?? "MTLCreateSystemDefaultDevice() returned nil")
if let device {
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    fragment half4 probeMain(float4 pos [[position]]) { return half4(1); }
    """
    let started = CFAbsoluteTimeGetCurrent()
    do {
        _ = try device.makeLibrary(source: source, options: nil)
        report("metal-compile-from-source", true,
               String(format: "%.0f ms for a trivial fragment shader", (CFAbsoluteTimeGetCurrent() - started) * 1000))
    } catch {
        report("metal-compile-from-source", false, String(describing: error))
    }
}

// MARK: - The filesystem

func canWrite(_ directory: URL) -> (Bool, String) {
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent(".probe")
        try Data("x".utf8).write(to: probe)
        try? FileManager.default.removeItem(at: probe)
        return (true, directory.path)
    } catch {
        return (false, directory.path + " — " + error.localizedDescription)
    }
}

let containerCaches = URL(fileURLWithPath: home)
    .appendingPathComponent("Library/Caches/com.hergenroeder.lerping/RotationThumbnails")
let realCaches = URL(fileURLWithPath: realHome)
    .appendingPathComponent("Library/Caches/com.hergenroeder.lerping/RotationThumbnails")
let (containerOK, containerDetail) = canWrite(containerCaches)
report("write-container-caches", containerOK, containerDetail)
let (realOK, realDetail) = canWrite(realCaches)
// Not a failure either way — it is the measurement that decides where the cache
// goes. A host that *can* write the real home is unsandboxed, which the first
// check has already said.
print("PROBE \(realOK ? "yes" : "NO ") write-real-home-caches: \(realDetail)")

let customShaders = URL(fileURLWithPath: realHome)
    .appendingPathComponent("Library/Application Support/Lerping/Shaders")
let customFiles = (try? FileManager.default.contentsOfDirectory(at: customShaders,
                                                                includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension == "metal" }
print("PROBE \(customFiles != nil ? "yes" : "NO ") read-real-custom-shaders: "
      + "\(customFiles?.count.description ?? "denied") in \(customShaders.path)")

let bundlePath = arguments[1]
let bundledStills = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Resources/Thumbnails")
let bundledCount = ((try? FileManager.default.contentsOfDirectory(at: bundledStills,
                                                                  includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "png" }.count
report("read-bundled-stills", bundledCount > 0, "\(bundledCount) PNGs in \(bundledStills.path)")

// MARK: - The real sheet

_ = NSApplication.shared
guard let bundle = Bundle(path: bundlePath) else {
    report("load-saver-bundle", false, "no bundle at \(bundlePath)")
    exit(1)
}
do {
    try bundle.loadAndReturnError()
} catch {
    report("load-saver-bundle", false, String(describing: error))
    exit(1)
}
guard let principal = bundle.principalClass as? ScreenSaverView.Type,
      let view = principal.init(frame: NSRect(x: 0, y: 0, width: 400, height: 250), isPreview: true) else {
    report("load-saver-bundle", false, "principal class would not instantiate")
    exit(1)
}
report("load-saver-bundle", true, "\(principal) — library validation permits an ad-hoc signed .saver")

func allSubviews(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + allSubviews($0) } }
func named(_ root: NSView, _ id: String) -> NSView? {
    allSubviews(root).first { $0.identifier?.rawValue == id }
}

let coldStarted = CFAbsoluteTimeGetCurrent()
guard let panel = view.configureSheet, let content = panel.contentView else {
    report("build-configure-sheet", false, "configureSheet returned nil")
    exit(1)
}
let coldBuild = CFAbsoluteTimeGetCurrent() - coldStarted
content.layoutSubtreeIfNeeded()
guard let gallery = named(content, "rotation-gallery") else {
    report("build-configure-sheet", false, "no rotation gallery in the sheet")
    exit(1)
}
let tiles = allSubviews(gallery).filter { ($0.identifier?.rawValue ?? "").hasPrefix("entry:") }
report("build-configure-sheet", coldBuild < 1.0,
       String(format: "%d tiles, %.0f ms — and it did not block on a single picture",
              tiles.count, coldBuild * 1000))

func missing() -> Int { (gallery.value(forKey: "stillsMissing") as? Int) ?? -1 }
let fillStarted = CFAbsoluteTimeGetCurrent()
let deadline = Date().addingTimeInterval(120)
while missing() != 0 && Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    usleep(2000)
}
let coldFill = CFAbsoluteTimeGetCurrent() - fillStarted
let summary = (view.value(forKey: "rotationStillsSummary") as? String) ?? "no summary"
report("fill-the-gallery", missing() == 0, String(format: "%.2f s — %@", coldFill, summary))

// Reopening: the stills stay decoded on the view, so the second open should
// touch neither the disk nor the GPU.
if let cancel = allSubviews(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }),
   let action = cancel.action {
    _ = cancel.target?.perform(action, with: cancel)
}
let warmStarted = CFAbsoluteTimeGetCurrent()
if let second = view.configureSheet, let secondContent = second.contentView {
    secondContent.layoutSubtreeIfNeeded()
    let secondGallery = named(secondContent, "rotation-gallery")
    let warmDeadline = Date().addingTimeInterval(30)
    while (secondGallery?.value(forKey: "stillsMissing") as? Int) != 0 && Date() < warmDeadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        usleep(2000)
    }
    let warm = CFAbsoluteTimeGetCurrent() - warmStarted
    let warmSummary = (view.value(forKey: "rotationStillsSummary") as? String) ?? ""
    report("reopen-from-memory", warmSummary.contains("rendered=0") && warmSummary.contains("bundle=0"),
           String(format: "%.0f ms — %@", warm * 1000, warmSummary))
}

print("PROBE \(failures.isEmpty ? "PASS" : "FAIL \(failures.joined(separator: ", "))")")
exit(failures.isEmpty ? 0 : 1)
