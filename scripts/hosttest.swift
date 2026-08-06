// Does the real screensaver draw, and does it stop drawing when it should?
//
// `make test-load` drives the Options… sheet and `make sandbox-probe` drives it
// inside a sandbox; neither of them renders anything. This one loads the same
// `.saver` bundle as a *non-preview* host — the thing legacyScreenSaver builds
// — puts it in a window, and reads back, once a second, what the saver decided
// about itself through `renderStateSummary`.
//
// Two shapes, because those are the two legacyScreenSaver produces and telling
// them apart is the whole of `Sources/Saver`'s difficulty:
//
//   on-screen   a window nothing can be covering, at the screensaver level.
//               Must draw, must see its frames reach a display, and must never
//               park — not even while somebody is hammering the keyboard.
//   hidden      a full-screen window at the saver's own level, -2147483625,
//               which puts it behind the desktop picture. Must draw, and must
//               never see a frame reach a display.
//
// The on-screen phase puts a small window on screen for its duration. That is
// the point: a screensaver that cannot be seen rendering has not been tested.
//
// What this cannot do is *make* somebody work at the machine, so the park
// itself — which needs five consecutive seconds of real input — is reported
// when it happens and never asserted. Synthetic events do not count, by
// design: `CGEventSource.secondsSinceLastEventType` ignores posted events, so
// nothing a program does can talk the saver into going quiet.
//
//   hosttest <path to Lerping@Home.saver> [seconds per phase]
import AppKit
import Darwin
import ScreenSaver

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: hosttest <path to Lerping@Home.saver> [seconds per phase]")
    exit(2)
}
let bundlePath = arguments[1]
let phaseSeconds = Double(arguments.count > 2 ? arguments[2] : "20") ?? 20
setbuf(stdout, nil)

var failures: [String] = []
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  — " + detail)")
    if !ok { failures.append(name) }
}

/// CPU seconds this process has used. `proc_taskinfo` counts mach ticks, not
/// nanoseconds; skipping the timebase understates everything by 40x on Apple
/// silicon, which is how a previous measurement of this same code missed a
/// 5.5% burn entirely.
let tickSeconds: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1e9
}()
func cpuSeconds() -> Double {
    var info = proc_taskinfo()
    let size = MemoryLayout<proc_taskinfo>.size
    guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, Int32(size)) == Int32(size) else { return 0 }
    return Double(info.pti_total_user + info.pti_total_system) * tickSeconds
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let bundle = Bundle(path: bundlePath) else {
    print("FAIL no bundle at \(bundlePath)"); exit(1)
}
do { try bundle.loadAndReturnError() } catch {
    print("FAIL \(error)"); exit(1)
}
guard let principal = bundle.principalClass as? ScreenSaverView.Type else {
    print("FAIL principal class is not a ScreenSaverView"); exit(1)
}

struct Sample {
    let elapsed: Double
    let cpu: Double
    let summary: String
}

/// Runs one phase to completion, pumping the main run loop, and returns what
/// the saver said each second.
func run(phase: String, rect: NSRect, level: NSWindow.Level?) -> [Sample] {
    guard let view = principal.init(frame: NSRect(origin: .zero, size: rect.size), isPreview: false) else {
        print("FAIL \(phase): the principal class would not instantiate"); exit(1)
    }
    let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isOpaque = true
    window.backgroundColor = .black
    if let level { window.level = level }
    window.contentView = view
    view.frame = NSRect(origin: .zero, size: rect.size)
    window.orderFront(nil)

    print("--- \(phase): \(Int(rect.width))x\(Int(rect.height)) at level \(window.level.rawValue)")
    view.startAnimation()

    var samples: [Sample] = []
    let started = CACurrentMediaTime()
    let cpu0 = cpuSeconds()
    while CACurrentMediaTime() - started < phaseSeconds {
        let mark = CACurrentMediaTime() + 1
        while CACurrentMediaTime() < mark {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let sample = Sample(elapsed: CACurrentMediaTime() - started,
                            cpu: cpuSeconds() - cpu0,
                            summary: (view.value(forKey: "renderStateSummary") as? String) ?? "?")
        samples.append(sample)
        print(String(format: "    t=%4.0fs cpu=%5.2fs %@", sample.elapsed, sample.cpu, sample.summary))
    }
    view.stopAnimation()
    window.orderOut(nil)
    return samples
}

func cpuRate(_ samples: [Sample], from: Double, to: Double) -> Double? {
    guard let a = samples.first(where: { $0.elapsed >= from }),
          let b = samples.last(where: { $0.elapsed <= to }), b.elapsed > a.elapsed else { return nil }
    return (b.cpu - a.cpu) / (b.elapsed - a.elapsed) * 100
}

// MARK: - On screen

let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
let onScreen = run(phase: "on-screen",
                   rect: NSRect(x: screen.width - 500, y: 40, width: 460, height: 300),
                   level: .screenSaver)

check("an on-screen host draws", onScreen.allSatisfy { $0.summary.contains("rendering=1") })
let sawDisplay = onScreen.filter { !$0.summary.contains("lastDisplayedFrame=never") }.count
check("its frames reach a display", sawDisplay >= onScreen.count - 1,
      "\(sawDisplay) of \(onScreen.count) samples carried a scanned-out frame")
check("and it is never parked", onScreen.allSatisfy { $0.summary.contains("parked=no") },
      onScreen.first { !$0.summary.contains("parked=no") }?.summary ?? "not once")
if let rate = cpuRate(onScreen, from: 1, to: .infinity) {
    print(String(format: "     CPU while rendering: %.2f%%", rate))
}

// MARK: - Behind the desktop

let hidden = run(phase: "hidden",
                 rect: NSRect(x: 0, y: 0, width: screen.width, height: screen.height),
                 level: NSWindow.Level(rawValue: -2147483625))

check("a hidden host draws too, rather than going black",
      hidden.prefix(5).allSatisfy { $0.summary.contains("rendering=1") })
check("no frame of it ever reaches a display",
      hidden.allSatisfy { $0.summary.contains("lastDisplayedFrame=never") },
      "the signal the park verdict is vetoed by")
if let parked = hidden.first(where: { !$0.summary.contains("parked=no") }) {
    print(String(format: "     parked at t=%.0fs: %@", parked.elapsed, parked.summary))
    let before = cpuRate(hidden, from: 1, to: parked.elapsed - 1)
    // Only if the phase ran on long enough after the park to have a rate at
    // all; a park in the last second or two has nothing to average over.
    if let before, let after = cpuRate(hidden, from: parked.elapsed + 2, to: .infinity) {
        print(String(format: "     CPU %.2f%% rendering -> %.2f%% parked", before, after))
    } else {
        print("     parked too late in the phase to measure the saving; "
              + "raise HOSTTEST_SECONDS to see it")
    }
} else {
    // Not a failure: parking needs five consecutive seconds of somebody
    // actually working at the machine, and a test cannot arrange that.
    print("     never parked — nobody was working at the machine during this run")
    if let rate = cpuRate(hidden, from: 1, to: .infinity) {
        print(String(format: "     CPU while rendering: %.2f%%", rate))
    }
}

print(failures.isEmpty ? "PASS" : "FAIL \(failures.joined(separator: ", "))")
exit(failures.isEmpty ? 0 : 1)
