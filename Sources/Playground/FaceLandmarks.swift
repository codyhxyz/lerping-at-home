import AppKit
import os
import WebKit

/// The camera through MediaPipe Face Landmarker, for `HeadTracker`.
///
/// MediaPipe's face model is the detector this year's head-coupled demos share
/// (every one of them pairs it with a Kooima off-axis camera and a 1€ filter;
/// see `HeadPoseFilter`). It beats Vision here for two reasons. Its VIDEO mode
/// *tracks*: each frame starts from where the face was in the last one, so a
/// still head does not drop in and out the way per-frame detection does — and
/// every drop was the view lurching while the watcher sat still. And its mesh
/// has iris centres (points 468 and 473), a steadier eye position than
/// Vision's pupil estimate.
///
/// Like hand control (`HandControl`), it is MediaPipe's JavaScript build in an
/// embedded web view, the page and its worker in `Hands/` beside the hand
/// page, served from the bundle; only numbers cross back. The page owns the
/// camera (`getUserMedia`), so the app's camera permission must already be
/// granted — `HeadTracker.requestAccess` asks first.
///
/// **Where the page lives.** WebKit pauses a page whose window cannot be seen,
/// and the head is wanted exactly when the playground's window may not be: in
/// Desktop Mode, behind other apps. So the page gets a window of its own — two
/// transparent, click-through points at desktop level on every space — and
/// WebKit's occlusion check is switched off for it, so being covered by other
/// windows does not pause it either. When nothing that follows the head is on
/// screen, `DesktopMode` pauses it explicitly.
final class FaceLandmarks: NSObject {
    /// One frame's result. Main thread.
    struct Frame {
        /// The face in Vision's convention (normalised, origin bottom left),
        /// or nil when the frame had none.
        var face: FaceSample?
        /// The frame's width over its height.
        var aspect: Float
        /// How long ago, in seconds, the frame was captured.
        var age: Double
    }

    var onFrame: ((Frame) -> Void)?
    /// The camera's name, once it is streaming.
    var onStarted: ((String) -> Void)?
    /// It stopped by itself: refused, unplugged, or the model would not load.
    var onFailure: ((String) -> Void)?

    private var window: NSWindow?
    private var webView: WKWebView?

    /// `category:head` in the unified log: start, failure, and every 10 s how
    /// many frames had a face — the loss rate, read off the real camera.
    static let log = Logger(subsystem: LerpDefaults.productionModule, category: "head")
    private var tally = (frames: 0, faces: 0, since: CACurrentMediaTime())

    static let scheme = "lerp-face"

    private static var root: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Hands", isDirectory: true)
    }

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    func start() throws {
        guard let root = Self.root,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("face.html").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("models/face_landmarker.task").path)
        else { throw Unavailable(description: "this build has no face model") }

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        config.userContentController.add(WeakFaceHandler(self), name: "face")
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.uiDelegate = self
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard web.responds(to: occlusion) else {
            throw Unavailable(description: "this WebKit cannot keep a covered page running")
        }
        // Passing nil is passing NO.
        web.perform(occlusion, with: nil)

        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2), styleMask: .borderless,
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.isOpaque = false
        host.backgroundColor = .clear
        host.hasShadow = false
        host.ignoresMouseEvents = true
        host.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        host.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        host.contentView = web
        host.orderFrontRegardless()

        window = host
        webView = web
        web.load(URLRequest(url: URL(string: "\(Self.scheme)://app/face.html")!))
    }

    /// Lets the camera go (its light goes off); `resume` takes it back.
    func pause() { webView?.evaluateJavaScript("lerpFace.disable()") }
    func resume() { webView?.evaluateJavaScript("lerpFace.enable()") }

    /// The camera off first, then the page and its window.
    func close() {
        guard let webView, let window else { return }
        self.webView = nil
        self.window = nil
        webView.evaluateJavaScript("lerpFace.disable()") { _, _ in
            webView.removeFromSuperview()
            window.close()
        }
    }

    fileprivate func received(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "face":
            tally.frames += 1
            if body["face"] is [String: Any] { tally.faces += 1 }
            let now = CACurrentMediaTime()
            if now - tally.since >= 10 {
                Self.log.notice("head: face in \(self.tally.faces, privacy: .public)/\(self.tally.frames, privacy: .public) frames over \(Int(now - self.tally.since), privacy: .public) s")
                tally = (0, 0, now)
            }
            let width = (body["width"] as? Double) ?? 640, height = (body["height"] as? Double) ?? 480
            onFrame?(Frame(face: (body["face"] as? [String: Any]).flatMap(Self.sample),
                           aspect: Float(width / max(1, height)),
                           age: max(0, (body["age"] as? Double) ?? 0)))
        case "step":
            Self.log.notice("head: \((body["message"] as? String) ?? "", privacy: .public)")
        case "started":
            let camera = (body["camera"] as? String) ?? "Camera"
            Self.log.notice("head: Face Landmarker streaming from \(camera, privacy: .public)")
            tally = (0, 0, CACurrentMediaTime())
            onStarted?(camera)
        case "error":
            let why = (body["message"] as? String) ?? "face tracking stopped"
            Self.log.error("head: \(why, privacy: .public)")
            onFailure?(why)
        default:
            break
        }
    }

    /// The page's face (origin top left) as a `FaceSample` (origin bottom left).
    private static func sample(_ face: [String: Any]) -> FaceSample? {
        guard let irises = face["irises"] as? [[Double]], irises.count == 2,
              irises.allSatisfy({ $0.count == 2 }),
              let box = face["box"] as? [Double], box.count == 4 else { return nil }
        func flip(_ p: [Double]) -> SIMD2<Float> { SIMD2(Float(p[0]), Float(1 - p[1])) }
        return FaceSample(box: CGRect(x: box[0], y: 1 - box[3], width: box[2] - box[0], height: box[3] - box[1]),
                          eyes: (flip(irises[0]), flip(irises[1])),
                          yaw: (face["yaw"] as? Double).map(Float.init))
    }
}

extension FaceLandmarks: WKURLSchemeHandler, WKUIDelegate {
    private static let types = ["html": "text/html", "js": "text/javascript", "mjs": "text/javascript",
                                "css": "text/css", "wasm": "application/wasm"]

    /// Serves `Contents/Resources/Hands/` as `lerp-face://app/`, as
    /// `HandControl` serves it for hands: WebKit will not `fetch()` a file:
    /// URL, and a custom scheme is a secure context, which `getUserMedia` needs.
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

    /// macOS has already been asked (`HeadTracker.requestAccess`); this is
    /// WebKit's own per-page question, and the only page is ours.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.protocol == Self.scheme && type == .camera ? .grant : .deny)
    }
}

/// `WKUserContentController` retains its handlers; this keeps it from keeping
/// a closed `FaceLandmarks` alive.
private final class WeakFaceHandler: NSObject, WKScriptMessageHandler {
    weak var target: FaceLandmarks?
    init(_ target: FaceLandmarks) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let target, let body = message.body as? [String: Any] else { return }
        target.received(body)
    }
}
