import AppKit
import MIDIDeps
import WebKit

/// Hands as a MIDI controller.
///
/// The tracking is coding cube's MediaPipe hand control, run the way Torin
/// Blankensmith's TouchDesigner plugin runs it for Kat Zhang's pieces: MediaPipe's
/// JavaScript build in an embedded browser, with only the results crossing into
/// the host. There is no native MediaPipe for macOS, and the cube's controller —
/// open-hand arming, a calibrated pinch, One Euro smoothing, the two-hand pinch —
/// is already written and already worked, in JavaScript. `Hands/app/` is that
/// code, with the camera and the model loaded from this app's bundle.
///
/// What comes out is the cube's gesture, nothing more: a pinch drags, and a
/// second hand pinching too makes it a two-hand pinch whose span is a third
/// axis. Each axis is sent as a relative CC on its own channel, so everything
/// else — Learn, banks, ranges, saving, the binding labels — is the MIDI code,
/// unchanged. A pinch is the clutch: values move only while it is held, and
/// letting go leaves them where they are, as an endless encoder does.
///
/// The page is also the feedback: a transparent, click-through web view laid
/// over the render, drawing the cube's cursors and saying what it is waiting
/// for ("Show an open hand", "Ready — pinch to grab").
final class HandControl: NSObject {

    /// The CCs the three axes are sent on. 102–104 are "undefined" in the MIDI
    /// spec and channel 16 is the last one, so a hardware knob landing here by
    /// accident is about as unlikely as MIDI allows.
    enum Axis: UInt8, CaseIterable {
        case x = 102, y = 103, spread = 104

        static let channel: UInt4 = 15

        var cc: UInt7 { UInt7(rawValue) }

        var label: String {
            switch self {
            case .x: "Hand X"
            case .y: "Hand Y"
            case .spread: "Hand Spread"
            }
        }

        init?(channel: UInt4?, cc: UInt7) {
            guard channel == Self.channel, let axis = Self(rawValue: UInt8(cc)) else { return nil }
            self = axis
        }
    }

    static let sourceID = "lerp-hands"
    static let sourceName = "Hands"

    /// Half the camera's view sweeps a parameter end to end: the 128 ticks an
    /// absolute knob has, over a comfortable arm's movement at a desk.
    private static let ticksPerFrame = 256.0
    /// Learn binds the first message it sees, and a pinch moved up also drifts
    /// a little sideways. While learning, an axis has to have clearly won.
    private static let learnTicks = 12.0

    /// Main thread, like `MIDIController.onMessage`; both go to the same place.
    var onMessage: ((MIDIController.Message) -> Void)?
    /// What the hand controller is waiting for, and whether the camera is on.
    var onStatus: ((String, Bool) -> Void)?
    /// Whether a parameter's Learn is armed.
    var isLearning: () -> Bool = { false }

    private var webView: WKWebView?
    /// Sub-tick movement carried to the next frame, so a slow drag still moves.
    private var remainder: [Axis: Double] = [:]
    /// Ticks each axis has travelled in this pinch, while Learn is armed.
    private var learnTravel: [Axis: Double] = [:]

    private static var root: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Hands", isDirectory: true)
    }

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// Lays the tracking page over `view`. Camera permission is the caller's
    /// (`withCamera`, shared with head tracking); the page's own request is
    /// granted in `requestMediaCapturePermissionFor`.
    func start(over view: NSView) throws {
        guard let root = Self.root,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) else {
            throw Unavailable(description: "this build has no Hands folder")
        }
        attach(to: view)
    }

    func stop() {
        guard let webView else { return }
        self.webView = nil
        // Stop the camera from the page first, so the green light goes out with
        // the cube's own teardown rather than whenever the process does.
        webView.evaluateJavaScript("lerpHands.disable()") { _, _ in webView.removeFromSuperview() }
        remainder.removeAll()
        learnTravel.removeAll()
    }

    var isRunning: Bool { webView != nil }

    private func attach(to view: NSView) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(self, forURLScheme: "lerp-hands")
        config.userContentController.add(WeakMessageHandler(self), name: "hands")
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = ClickThroughWebView(frame: view.bounds, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.uiDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        web.load(URLRequest(url: URL(string: "lerp-hands://app/index.html")!))
        webView = web
    }

    // MARK: - Gesture → CCs

    func received(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "status":
            onStatus?(body["status"] as? String ?? "", body["active"] as? Bool ?? false)
        case "grab", "release":
            remainder.removeAll()
            learnTravel.removeAll()
        case "move":
            let moved: [(Axis, Double)] = [(.x, body["x"]), (.y, body["y"]), (.spread, body["spread"])]
                .map { ($0, ($1 as? Double) ?? 0) }
            for (axis, frames) in moved where frames != 0 { move(axis, by: frames * Self.ticksPerFrame) }
        default:
            break
        }
    }

    private func move(_ axis: Axis, by ticks: Double) {
        if isLearning() {
            learnTravel[axis, default: 0] += abs(ticks)
            let travel = learnTravel[axis]!
            guard travel >= Self.learnTicks,
                  learnTravel.allSatisfy({ $0.key == axis || $0.value * 1.5 <= travel }) else { return }
            learnTravel.removeAll()
            return send(axis, ticks: ticks < 0 ? -1 : 1)
        }
        let total = remainder[axis, default: 0] + ticks
        let whole = total.rounded(.towardZero)
        remainder[axis] = total - whole
        guard whole != 0 else { return }
        send(axis, ticks: Int(max(-63, min(63, whole))))
    }

    /// One relative CC, two's complement — the encoding Learn records for this
    /// source, and the most common one on real encoders.
    private func send(_ axis: Axis, ticks: Int) {
        onMessage?(MIDIController.Message(
            channel: Axis.channel, cc: axis.cc, value: UInt8(truncatingIfNeeded: ticks) & 0x7F,
            sourceID: Self.sourceID, sourceName: Self.sourceName,
            learnChannel: Axis.channel, learnMode: .relative(.twosComplement)))
    }
}

// MARK: - The page's files, and the camera prompt

extension HandControl: WKURLSchemeHandler, WKUIDelegate {

    private static let types = ["html": "text/html", "js": "text/javascript", "mjs": "text/javascript",
                                "css": "text/css", "wasm": "application/wasm"]

    /// Serves `Contents/Resources/Hands/` as `lerp-hands://app/`. A custom
    /// scheme rather than `loadFileURL` because WebKit will not `fetch()` a
    /// file: URL, and MediaPipe fetches its wasm and its model; WebKit treats
    /// the scheme as a secure context, which `getUserMedia` requires.
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = Self.root?.standardizedFileURL else {
            return task.didFailWithError(URLError(.badURL))
        }
        let file = root.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            return task.didFinish()
        }
        let type = Self.types[file.pathExtension] ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": type,
                                                       "Content-Length": String(data.count)])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// macOS has already been asked for the camera (`withCamera`); this is
    /// WebKit's own per-page question, and the only page is ours.
    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.protocol == "lerp-hands" && type == .camera ? .grant : .deny)
    }
}

/// `WKUserContentController` retains its handlers, which would keep a stopped
/// HandControl alive for as long as the web view lingers.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: HandControl?
    init(_ target: HandControl) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let target, let body = message.body as? [String: Any] else { return }
        target.received(body)
    }
}

/// The overlay draws; the render under it keeps every click.
private final class ClickThroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
