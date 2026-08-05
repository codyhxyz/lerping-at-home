import AppKit

/// `LerpPlayground --selftest` — drives the real window through the loop the
/// app exists for: load a shader, watch it render, edit it, break it, fix it.
///
/// It is a UI test, not a unit test: it opens the actual window, uses the actual
/// `LerpMetalView` display link, and asserts on frames that really got drawn.
/// The two behaviours it exists to protect are the compiler diagnostics mapping
/// back to the shader file's own line numbers, and the last-good pipeline
/// surviving a broken edit.
enum PlaygroundSelfTest {

    static func run() -> Never {
        setbuf(stdout, nil)   // unbuffered, so a hang still shows how far we got
        PlaygroundMain.boot(SelfTestDelegate())
    }
}

final class SelfTestDelegate: NSObject, NSApplicationDelegate {
    private var controller: PlaygroundWindowController!
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
        let script: [(TimeInterval, () -> Void)] = [
            (0.2, loaded), (1.8, rendering),
            (2.0, editValid), (2.9, editApplied),
            (3.1, editBroken), (4.0, errorReported), (5.3, stillRenderingWhileBroken),
            (5.5, restore), (6.3, recovered),
            (6.4, scaffold), (6.6, picksUpFilesOnDisk),
            (6.9, finish),
        ]
        for (delay, step) in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }
    }

    // MARK: Assertions

    private func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks += 1
        failures += passed ? 0 : 1
        print("\(passed ? "ok   " : "FAIL ") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    private var isCompiled: Bool {
        if case .ok = controller.compileState { return true }
        return false
    }

    private var stateDetail: String {
        switch controller.compileState {
        case .pending: return "pending"
        case let .ok(ms): return String(format: "ok in %.0f ms", ms)
        case let .failed(items): return items.map(\.display).joined(separator: " / ")
        }
    }

    // MARK: Steps

    private func loaded() {
        check("window opened with a shader", controller.window?.isVisible == true
                && controller.editor.text.contains("lerpMain"), controller.currentName)
        check("initial compile succeeded", isCompiled, stateDetail)
    }

    private func rendering() {
        let fps = controller.metalView.measuredFPS
        check("live view is drawing frames", fps > 1, String(format: "%.0f fps", fps))
    }

    private func editValid() {
        // A real edit: invert the shader's output. Compiles, looks different.
        controller.editor.replaceTextAsEdit(originalSource.replacingOccurrences(
            of: "return half4(half3(color), 1.0h);",
            with: "return half4(half3(1.0 - color), 1.0h);"))
    }

    private func editApplied() {
        check("hot reload recompiled the edit", isCompiled, stateDetail)
        check("editor holds the edited source", controller.editor.text.contains("1.0 - color"))

        // The edit inverted the output, so the pixels must move a long way.
        // Proves the buffer really is what reaches the GPU, not just that
        // something compiled.
        let before = meanLuma(of: originalSource)
        let after = meanLuma(of: controller.editor.text)
        check("rendered pixels changed", abs(before - after) > 0.2,
              String(format: "luma %.3f → %.3f", before, after))
    }

    /// Renders a source string offscreen through the same LerpCore path the
    /// live view uses, and returns its mean luminance.
    private func meanLuma(of source: String) -> Double {
        let library = controller.metalView.shaderLibrary
        guard let renderer = LerpRenderer(device: library.device) else { return -1 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lerp-selftest-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let shader = LerpShader(name: "selftest", source: source, isBuiltIn: false, url: nil)
        let result = LerpSnapshot.render(shader: shader, library: library, renderer: renderer,
                                         width: 320, height: 200, time: 3, seed: 0.5, to: url)
        return result.error == nil ? result.meanLuminance : -1
    }

    private func editBroken() {
        // Break line 3 exactly, so we can assert the reported line number.
        controller.editor.replaceTextAsEdit("""
        // deliberately broken shader (selftest)
        fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
            float3 color = thisFunctionDoesNotExist(pos, u);
            return half4(half3(color), 1.0h);
        }
        """)
    }

    private func errorReported() {
        guard case let .failed(items) = controller.compileState else {
            check("broken source reported as an error", false, stateDetail)
            return
        }
        check("broken source reported as an error", !items.isEmpty, stateDetail)
        // The prelude's trailing `#line 1` is what makes program_source line
        // numbers land on the shader file's own lines. This is that assertion.
        let first = items.first(where: \.isError)
        check("error line number is right", first?.line == 3,
              "expected 3, got \(first.map { String($0.line) } ?? "none")")
        check("app did not crash on a bad shader", controller.window?.isVisible == true)
    }

    private func stillRenderingWhileBroken() {
        let fps = controller.metalView.measuredFPS
        check("last good pipeline still rendering", fps > 1, String(format: "%.0f fps", fps))
    }

    private func restore() {
        controller.editor.replaceTextAsEdit(originalSource)
    }

    private func recovered() {
        check("recovered after fixing the source", isCompiled, stateDetail)
        check("editor is back to the on-disk source", controller.editor.text == originalSource)
    }

    /// The New-shader template has to be valid the moment it is written, so
    /// compile it the same way the app would.
    private func scaffold() {
        let stem = "selftest-scaffold"
        let draft = LerpShader(name: stem, source: ShaderScaffold.template(for: stem),
                               isBuiltIn: false, url: nil)
        do {
            _ = try controller.metalView.shaderLibrary.pipeline(for: draft)
            check("new-shader template compiles", true)
        } catch {
            let (items, raw) = ShaderDiagnostics.parse(error)
            check("new-shader template compiles", false, ShaderDiagnostics.summary(items: items, raw: raw))
        }
        check("name sanitizer", ShaderScaffold.sanitize(name: "  My Cool Shader!! ") == "my-cool-shader",
              ShaderScaffold.sanitize(name: "  My Cool Shader!! ") ?? "nil")
        check("new shaders target the repo's Sources/Shaders",
              ShaderPaths.newShaderDirectory.lastPathComponent == "Shaders",
              ShaderPaths.newShaderDirectory.path)
    }

    /// The picker has to notice shaders that appear while the app is running —
    /// a `git pull`, another editor, or a concurrent agent adding files. Uses
    /// the user drop folder so the repo's Sources/Shaders is never written to.
    private func picksUpFilesOnDisk() {
        let stem = "zz-selftest-temp"
        let url = ShaderPaths.customDirectory.appendingPathComponent(stem + ".metal")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try FileManager.default.createDirectory(at: ShaderPaths.customDirectory,
                                                    withIntermediateDirectories: true)
            try ShaderScaffold.template(for: stem).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            check("new file on disk appears in the picker", false, error.localizedDescription)
            return
        }
        let openShader = controller.currentName
        controller.pollDisk()
        check("new file on disk appears in the picker", controller.knownShaderNames.contains(stem))
        check("editor kept its shader while the list changed",
              controller.currentName == openShader && controller.editor.text == originalSource,
              controller.currentName)

        try? FileManager.default.removeItem(at: url)
        controller.pollDisk()
        check("deleted file leaves the picker", !controller.knownShaderNames.contains(stem))
    }

    private func finish() {
        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
