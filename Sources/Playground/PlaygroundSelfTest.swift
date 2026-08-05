import AppKit

/// `LerpPlayground --selftest` — drives the real window through the loop the
/// app exists for: load a shader, watch it render, edit it, break it, fix it.
///
/// It is a UI test, not a unit test: it opens the actual window, uses the
/// actual `LerpMetalView` display link, and asserts on frames that really got
/// drawn. `LerpPreview --snapshot` plays the same role for the shaders; this
/// plays it for the editor.
enum PlaygroundSelfTest {

    static func run() {
        setbuf(stdout, nil)   // unbuffered, so a hang still shows how far we got
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .darkAqua)
        let delegate = SelfTestDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class SelfTestDelegate: NSObject, NSApplicationDelegate {
    private var controller: PlaygroundWindowController?
    private var failures = 0
    private var checks = 0
    private var originalSource = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let controller = PlaygroundWindowController.make() else {
            print("FAIL  no Metal device")
            exit(1)
        }
        self.controller = controller
        controller.showAndStart()
        NSApp.activate(ignoringOtherApps: true)
        originalSource = controller.editor.text

        // Timings are wall-clock on purpose — the point is to observe the real
        // 0.3 s edit debounce and the real display link, not to mock them.
        after(0.2) { self.step1Loaded() }
        after(1.8) { self.step2Rendering() }
        after(2.0) { self.step3ValidEdit() }
        after(2.9) { self.step4EditApplied() }
        after(3.1) { self.step5BrokenEdit() }
        after(4.0) { self.step6ErrorReported() }
        after(5.3) { self.step7StillRenderingWhileBroken() }
        after(5.5) { self.step8Restore() }
        after(6.3) { self.step9Recovered() }
        after(6.4) { self.step10Scaffold() }
        after(6.6) { self.step11PicksUpNewFilesOnDisk() }
        after(6.9) { self.finish() }
    }

    private func after(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }

    // MARK: Assertions

    private func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks += 1
        if passed {
            print("ok    \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        } else {
            failures += 1
            print("FAIL  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }
    }

    private var isCompiled: Bool {
        if case .ok = controller?.compileState { return true }
        return false
    }

    private var diagnostics: [ShaderDiagnostic] {
        if case let .failed(items) = controller?.compileState { return items }
        return []
    }

    // MARK: Steps

    private func step1Loaded() {
        guard let controller else { return }
        check("window opened", controller.window?.isVisible == true)
        check("shader loaded", !controller.currentName.isEmpty, controller.currentName)
        check("source in editor", controller.editor.text.contains("lerpMain"),
              "\(controller.editor.text.count) chars")
        check("initial compile succeeded", isCompiled)
    }

    private func step2Rendering() {
        guard let controller else { return }
        let fps = controller.metalView.measuredFPS
        check("live view is drawing frames", fps > 1, String(format: "%.0f fps", fps))
    }

    private func step3ValidEdit() {
        guard let controller else { return }
        // A real edit: invert the shader's output. Compiles, looks different.
        let edited = originalSource.replacingOccurrences(
            of: "return half4(half3(color), 1.0h);",
            with: "return half4(half3(1.0 - color), 1.0h);")
        check("edit is a real change", edited != originalSource)
        controller.editor.replaceTextAsEdit(edited)
    }

    private func step4EditApplied() {
        check("hot reload recompiled the edit", isCompiled, statusDetail())
        check("editor holds the edited source",
              controller?.editor.text.contains("1.0 - color") == true)

        // The edit inverted the output, so the pixels must move a long way.
        // Proves the buffer really is what reaches the GPU, not just that
        // something compiled.
        let before = meanLuma(of: originalSource)
        let after = meanLuma(of: controller?.editor.text ?? "")
        check("rendered pixels changed", abs(before - after) > 0.2,
              String(format: "luma %.3f → %.3f", before, after))
    }

    /// Renders a source string offscreen through the same LerpCore path the
    /// live view uses, and returns its mean luminance.
    private func meanLuma(of source: String) -> Double {
        guard let controller, let renderer = LerpRenderer(device: controller.metalView.shaderLibrary.device)
        else { return -1 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lerp-selftest-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let shader = LerpShader(name: "selftest", source: source, isBuiltIn: false, url: nil)
        let result = LerpSnapshot.render(shader: shader, library: controller.metalView.shaderLibrary,
                                         renderer: renderer, width: 320, height: 200,
                                         time: 3, seed: 0.5, to: url)
        return result.error == nil ? result.meanLuminance : -1
    }

    private func step5BrokenEdit() {
        guard let controller else { return }
        // Break line 3 exactly, so we can assert the reported line number.
        let broken = """
        // deliberately broken shader (selftest)
        fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
            float3 color = thisFunctionDoesNotExist(pos, u);
            return half4(half3(color), 1.0h);
        }
        """
        controller.editor.replaceTextAsEdit(broken)
    }

    private func step6ErrorReported() {
        guard let controller else { return }
        let items = diagnostics
        check("broken source reported as an error", !items.isEmpty, statusDetail())
        check("error line number is right",
              items.first(where: \.isError)?.line == 3,
              "expected 3, got \(items.first(where: \.isError).map { String($0.line) } ?? "none")")
        check("app did not crash on a bad shader", controller.window?.isVisible == true)
    }

    private func step7StillRenderingWhileBroken() {
        guard let controller else { return }
        let fps = controller.metalView.measuredFPS
        check("last good pipeline still rendering", fps > 1, String(format: "%.0f fps", fps))
    }

    private func step8Restore() {
        controller?.editor.replaceTextAsEdit(originalSource)
    }

    private func step9Recovered() {
        check("recovered after fixing the source", isCompiled, statusDetail())
        check("editor is back to the on-disk source",
              controller?.editor.text == originalSource)
    }

    /// The New-shader template has to be valid the moment it is written, so
    /// compile it the same way the app would.
    private func step10Scaffold() {
        guard let controller else { return }
        let stem = "selftest-scaffold"
        let source = ShaderScaffold.template(for: stem)
        let draft = LerpShader(name: stem, source: source, isBuiltIn: false, url: nil)
        do {
            _ = try controller.metalView.shaderLibrary.pipeline(for: draft)
            check("new-shader template compiles", true)
        } catch {
            let (items, raw) = ShaderDiagnostics.parse(error)
            check("new-shader template compiles", false, ShaderDiagnostics.summary(items: items, raw: raw))
        }
        check("name sanitizer", ShaderScaffold.sanitize(name: "  My Cool Shader!! ") == "my-cool-shader",
              ShaderScaffold.sanitize(name: "  My Cool Shader!! ") ?? "nil")
        check("symbol prefix", ShaderScaffold.symbolPrefix(for: "smoke-ring") == "SR")

        // New shaders land in the repo's Sources/Shaders when we can find it.
        let repo = ShaderPaths.repoShaderDirectory()
        check("repo shader directory resolved", repo != nil, repo?.path ?? "not found")
        check("new shaders target Sources/Shaders",
              ShaderPaths.newShaderDirectory().lastPathComponent == "Shaders",
              ShaderPaths.newShaderDirectory().path)

        // Write + rediscover round trip, in a temp directory so the repo's
        // shader folder is left alone.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lerp-selftest-shaders-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try source.write(to: scratch.appendingPathComponent(stem + ".metal"),
                             atomically: true, encoding: .utf8)
            let library = ShaderLibrary(device: controller.metalView.shaderLibrary.device,
                                        extraSearchURLs: [scratch])
            let found = library.discover().first { $0.name == stem }
            check("scaffolded file is discovered and compiles",
                  found != nil && ((try? library.pipeline(for: found!)) != nil))
        } catch {
            check("scaffolded file is discovered and compiles", false, error.localizedDescription)
        }
    }

    /// The picker has to notice shaders that appear while the app is running —
    /// a `git pull`, another editor, or the concurrent agent adding files.
    /// Uses the user shader drop folder so the repo's Sources/Shaders is
    /// never written to.
    private func step11PicksUpNewFilesOnDisk() {
        guard let controller else { return }
        let stem = "zz-selftest-temp"
        let directory = ShaderPaths.customDirectory
        let url = directory.appendingPathComponent(stem + ".metal")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ShaderScaffold.template(for: stem).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            check("new file on disk appears in the picker", false, error.localizedDescription)
            return
        }
        controller.pollDisk()
        check("new file on disk appears in the picker",
              controller.knownShaderNames.contains(stem))
        check("editor kept its shader while the list changed",
              controller.currentName == "aurora" && controller.editor.text == originalSource,
              controller.currentName)

        try? FileManager.default.removeItem(at: url)
        controller.pollDisk()
        check("deleted file leaves the picker", !controller.knownShaderNames.contains(stem))
    }

    private func statusDetail() -> String {
        switch controller?.compileState {
        case .none, .some(.pending): return "pending"
        case let .some(.ok(ms)): return String(format: "ok in %.0f ms", ms)
        case let .some(.failed(items)): return items.map(\.display).joined(separator: " / ")
        }
    }

    private func finish() {
        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
