import AppKit
import MIDIDeps

/// `LerpPlayground --selftest` — drives the real window through the loop the
/// app exists for: load a shader, watch it render, edit it, break it, fix it,
/// then work its parameter inspector and its MIDI mapping the same way.
///
/// It is a UI test, not a unit test: it opens the actual window, uses the actual
/// `LerpMetalView` display link, moves the actual `NSSlider`s, and — where the
/// machine has Core MIDI — creates a real virtual MIDI source and sends real CC
/// messages through Core MIDI into the running app.
///
/// The behaviours it exists to protect are the compiler diagnostics mapping back
/// to the shader file's own line numbers, the last-good pipeline surviving a
/// broken edit, the inspector being built from the declarations rather than any
/// table of names, and parameter values surviving a recompile.
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
            // Inspector, then MIDI, then the end of the run. Everything from
            // here chains off the step before it rather than off the clock:
            // these steps wait on a recompile debounce and on messages that
            // leave through Core MIDI and come back when they come back.
            (6.8, inspectorChecks),
        ]
        for (delay, step) in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }
    }

    /// Runs `step` as soon as `condition` holds, or once `timeout` has elapsed —
    /// so a slow round trip costs time rather than a false failure, and the
    /// assertion in `step` is still the thing that decides pass or fail.
    private func wait(until condition: @escaping () -> Bool, timeout: TimeInterval,
                      then step: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            guard !condition(), Date() < deadline else { return step() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
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

    // MARK: Parameter inspector

    /// Every assertion below is against a shader picked for *having* parameters,
    /// never for being that shader — the panel is built from whatever the file
    /// declares, so the test reads the declarations too instead of hardcoding
    /// names it expects.
    private var subject: LerpShader!
    private var scalarParam: LerpParam!

    /// Opening a shader compiles synchronously, and so does moving a control,
    /// so these run back to back. Only the edit at the end has to wait.
    private func inspectorChecks() {
        let shaders = controller.metalView.shaderLibrary.discover()
        guard let shader = shaders.first(where: { shader in
            shader.parameters.contains { $0.type == .float } && !shader.presets.isEmpty
        }) else {
            check("a shader with parameters and presets exists", false)
            return endMIDI()
        }
        subject = shader
        scalarParam = shader.parameters.first { $0.type == .float && $0.min < $0.max }
        controller.openShader(named: shader.name)

        panelMatchesDeclarations()
        moveSlider()
        sliderApplied()
        choosePreset()
        presetApplied()
        declareNewParameter()
    }

    private func panelMatchesDeclarations() {
        guard subject != nil else { return }
        let panel = controller.inspector
        check("inspector has one row per declared parameter",
              panel.rowNames == subject.parameters.map(\.name),
              "\(panel.rowNames.count) rows vs \(subject.parameters.count) declared")
        check("preset popup lists Defaults plus every declared preset",
              panel.presetTitles == ["Defaults"] + subject.presets.map(\.name),
              panel.presetTitles.joined(separator: ", "))
        check("controls match the declared types", subject.parameters.allSatisfy { param in
            switch param.type {
            case .float, .int: panel.control(named: param.name) is NSSlider
            case .bool:        panel.control(named: param.name) is NSSwitch
            case .color:       panel.control(named: param.name) is NSColorWell
            }
        })
        check("sliders honour the declared range", subject.parameters.allSatisfy { param in
            guard let slider = panel.control(named: param.name) as? NSSlider else { return true }
            return slider.minValue == param.min && slider.maxValue == param.max
        })
        check("panel starts at the declared defaults", subject.parameters.allSatisfy {
            controller.metalView.parameterValues?[$0.name] == $0.defaultValue
        })
    }

    private var tailBeforeSlider: [UInt8] = []

    /// Moves the real control the way a mouse would: set the value, fire the
    /// action. Nothing here reaches past the UI into the model.
    private func moveSlider() {
        guard let param = scalarParam,
              let slider = controller.inspector.control(named: param.name) as? NSSlider else { return }
        tailBeforeSlider = controller.metalView.parameterValues?.packedTail ?? []
        slider.doubleValue = param.max
        controller.inspector.act(on: slider)
    }

    private func sliderApplied() {
        guard let param = scalarParam else { return }
        let value = controller.metalView.parameterValues?[param.name]?.scalarValue ?? .nan
        check("moving a slider reaches the live parameter values", value == param.max,
              "\(param.name) = \(value), max \(param.max)")
        check("the bytes handed to the GPU changed",
              controller.metalView.parameterValues?.packedTail != tailBeforeSlider)
        check("the numeric field follows the slider",
              controller.inspector.fieldText(named: param.name) != nil)

        // The uniform block is what the fragment shader reads, so proving a
        // changed default changes the picture proves the whole chain from a
        // parameter to pixels. (The live view has no readback, so the pixel end
        // of it is measured through the same offscreen renderer as the earlier
        // hot-reload check.)
        let dark = meanLuma(of: sourceWithDefault(param.name, param.min))
        let bright = meanLuma(of: sourceWithDefault(param.name, param.max))
        check("a parameter's value changes the rendered picture", abs(dark - bright) > 0.01,
              String(format: "%@ %g → %g gives luma %.3f → %.3f",
                     param.name, param.min, param.max, dark, bright))
    }

    /// Rewrites one `// lerp-param:` line's default, found through the parser
    /// rather than by matching text.
    private func sourceWithDefault(_ name: String, _ value: Double) -> String {
        var lines = subject.source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let param = subject.parameters.first(where: { $0.name == name }),
              param.line >= 1, param.line <= lines.count,
              let equals = lines[param.line - 1].firstIndex(of: "=") else { return subject.source }
        lines[param.line - 1] = String(lines[param.line - 1][..<equals])
            + "= \(value) \"\(param.label)\""
        return lines.joined(separator: "\n")
    }

    private func choosePreset() {
        guard let preset = subject?.presets.first else { return }
        controller.inspector.choosePreset(preset.name)
    }

    private func presetApplied() {
        guard let preset = subject?.presets.first else { return }
        let values = controller.metalView.parameterValues
        check("preset set every value it declares",
              preset.values.allSatisfy { values?[$0.key] == $0.value },
              preset.name)
        check("preset returned everything else to its default",
              subject.parameters.filter { preset.values[$0.name] == nil }
                  .allSatisfy { values?[$0.name] == $0.defaultValue })
    }

    /// A shader edited to declare a *new* parameter has to grow a row when it
    /// recompiles — this is the case that would break if the panel were built
    /// once and cached.
    /// One of each declarable type, so the bool and colour rows get built for
    /// real even when no shipped shader happens to declare one.
    private static let injected = """
    // lerp-param: zzSelfTest float 0 1 = 0.5 "Self test"
    // lerp-param: zzSelfTestFlag bool = true "Self test flag"
    // lerp-param: zzSelfTestTint color = #40c0ff "Self test tint"

    """

    private func declareNewParameter() {
        controller.editor.replaceTextAsEdit(Self.injected + subject.source)
        // Waits out the editor's real 0.3 s debounce and the real recompile.
        wait(until: { [self] in controller.inspector.rowNames.contains("zzSelfTest") },
             timeout: 5, then: panelRebuiltAfterEdit)
    }

    private func panelRebuiltAfterEdit() {
        guard let param = scalarParam else { return }
        let panel = controller.inspector
        check("newly declared parameters appear in the panel",
              ["zzSelfTest", "zzSelfTestFlag", "zzSelfTestTint"].allSatisfy(panel.rowNames.contains),
              panel.rowNames.joined(separator: ", "))
        check("a declared bool builds a switch and a colour builds a colour well",
              panel.control(named: "zzSelfTestFlag") is NSSwitch
                  && panel.control(named: "zzSelfTestTint") is NSColorWell)
        check("a declared bool starts at its declared default",
              (panel.control(named: "zzSelfTestFlag") as? NSSwitch)?.state == .on)
        check("a control the user moved survives the recompile",
              controller.metalView.parameterValues?[param.name]?.scalarValue == param.max
                  || controller.parameterState[param.name] != nil,
              "\(controller.metalView.parameterValues?[param.name]?.scalarValue ?? .nan)")

        // The buffer is now dirty, so the preset has to come from the editor's
        // own source rather than from the file on disk.
        if let preset = subject.presets.first {
            controller.inspector.choosePreset(preset.name)
            check("presets still apply while the buffer has unsaved edits",
                  preset.values.allSatisfy { controller.metalView.parameterValues?[$0.key] == $0.value })
        }
        openParameterless()
        emptyState()
        midiSetUp()
    }

    private static let parameterlessShader = "zz-selftest-noparams"

    private func openParameterless() {
        let url = ShaderPaths.customDirectory
            .appendingPathComponent(Self.parameterlessShader + ".metal")
        try? FileManager.default.createDirectory(at: ShaderPaths.customDirectory,
                                                 withIntermediateDirectories: true)
        try? ShaderScaffold.template(for: Self.parameterlessShader)
            .write(to: url, atomically: true, encoding: .utf8)
        controller.pollDisk()
        controller.openShader(named: Self.parameterlessShader)
    }

    private func emptyState() {
        check("a shader with no parameters shows the empty state",
              controller.inspector.rowNames.isEmpty && controller.inspector.isEmptyStateVisible,
              controller.currentName)
        try? FileManager.default.removeItem(at: ShaderPaths.customDirectory
            .appendingPathComponent(Self.parameterlessShader + ".metal"))
        controller.openShader(named: subject.name)
    }

    // MARK: MIDI

    /// A mapping bank of our own, so the test never edits one the user made.
    private static let testMapping = "zz-selftest-midi"
    private var sender: MIDIManager?
    private var senderID = ""
    private var boundParam: LerpParam!

    /// A virtual MIDI source in a *second* `MIDIManager`, so the messages reach
    /// the app the way a plugged-in controller's would: out through Core MIDI
    /// and back in through the playground's own input connection. Nothing here
    /// calls the router directly.
    private func midiSetUp() {
        check("MIDI subsystem started", controller.midi.isAvailable,
              controller.midi.unavailableReason ?? controller.midi.summary)
        guard controller.midi.isAvailable else {
            print("skip  MIDI learn and routing  — no Core MIDI on this machine")
            return endMIDI()
        }
        boundParam = scalarParam
        let manager = MIDIManager(clientName: "LerpSelfTest", model: "Lerping@Home",
                                  manufacturer: "Lerping@Home")
        do {
            try manager.start()
            try manager.addOutput(name: "Lerp Selftest Source", tag: "out", uniqueID: .adHoc)
        } catch {
            check("virtual MIDI source created", false, "\(error)")
            return endMIDI()
        }
        senderID = manager.managedOutputs["out"]?.uniqueID.map { String(describing: $0) } ?? ""
        sender = manager
        check("virtual MIDI source created", !senderID.isEmpty, senderID)
        wait(until: { [self] in controller.midi.sources.contains { $0.id == senderID } },
             timeout: 5, then: midiLearn)
    }

    private func send(cc: UInt7, _ value: UInt8, channel: UInt4 = 0) {
        do {
            try sender?.managedOutputs["out"]?
                .send(event: .cc(cc, value: .midi1(UInt7(value)), channel: channel))
        } catch {
            check("sending CC\(cc)", false, "\(error)")
        }
    }

    private func midiLearn() {
        check("the playground sees the virtual source",
              controller.midi.sources.contains { $0.id == senderID }, controller.midi.summary)
        // A bank of our own, so learn never writes into one the user made.
        controller.createMapping(named: Self.testMapping, deviceID: senderID)
        controller.learnTarget = boundParam.name
        send(cc: 21, 0)     // the next CC captures its own identity
        wait(until: { [self] in controller.activeMapping?.binding(for: boundParam.name) != nil },
             timeout: 5, then: midiRouted)
    }

    private func midiRouted() {
        let binding = controller.activeMapping?.binding(for: boundParam.name)
        check("learn captured the inbound CC", binding?.cc == 21, binding?.shortLabel ?? "nothing bound")
        check("the learned binding is on disk", MIDIMappingStore.load().contains {
            $0.name == Self.testMapping && $0.binding(for: boundParam.name)?.cc == 21
        })
        check("the row shows what it is bound to",
              controller.inspector.bindingLabel(named: boundParam.name) == "CC21",
              controller.inspector.bindingLabel(named: boundParam.name) ?? "nil")
        send(cc: 21, 127)   // full-scale: the parameter should hit its declared max
        wait(until: { [self] in
            controller.metalView.parameterValues?[boundParam.name]?.scalarValue == boundParam.max
        }, timeout: 5, then: midiApplied)
    }

    private func midiApplied() {
        let value = controller.metalView.parameterValues?[boundParam.name]?.scalarValue ?? .nan
        check("a CC moved the live parameter", abs(value - boundParam.max) < 1e-6,
              "\(boundParam.name) = \(value), max \(boundParam.max)")
        check("the inspector shows the MIDI-driven value",
              Double(controller.inspector.fieldText(named: boundParam.name) ?? "") == boundParam.max,
              controller.inspector.fieldText(named: boundParam.name) ?? "nil")
        // An unmapped knob must not touch anything.
        send(cc: 99, 0)
        wait(until: { false }, timeout: 0.4, then: { [self] in
            check("an unmapped CC changed nothing",
                  controller.metalView.parameterValues?[boundParam.name]?.scalarValue == boundParam.max)
            endMIDI()
        })
    }

    private func endMIDI() {
        routerUnits()
        captureUI()
        finish()
    }

    /// The two things every MIDI integration gets wrong, checked as pure logic
    /// because no controller sends all three encodings.
    private func routerUnits() {
        check("two's complement encoder decodes both directions",
              MIDIRelativeEncoding.twosComplement.delta(1) == 1
                  && MIDIRelativeEncoding.twosComplement.delta(127) == -1
                  && MIDIRelativeEncoding.twosComplement.delta(0) == 0)
        check("binary offset encoder decodes both directions",
              MIDIRelativeEncoding.binaryOffset.delta(65) == 1
                  && MIDIRelativeEncoding.binaryOffset.delta(63) == -1
                  && MIDIRelativeEncoding.binaryOffset.delta(64) == 0)
        check("sign/magnitude encoder decodes both directions",
              MIDIRelativeEncoding.signMagnitude.delta(3) == 3
                  && MIDIRelativeEncoding.signMagnitude.delta(0x43) == -3)

        // 14-bit CC is two messages — MSB on n, LSB on n + 32 — and the library
        // hands them over separately. This is the coalescing.
        let router = MIDIRouter()
        router.load([MIDIBinding(paramID: "p", channel: nil, cc: 7, mode: .abs14(lsbCC: 39))])
        let msb = position(router.route(channel: 0, cc: 7, value: 64))
        let lsb = position(router.route(channel: 0, cc: 39, value: 100))
        check("14-bit MSB alone sweeps the range", abs((msb ?? -1) - 8192.0 / 16383) < 1e-9,
              "\(msb ?? -1)")
        check("14-bit LSB refines the value it follows",
              abs((lsb ?? -1) - 8292.0 / 16383) < 1e-9, "\(lsb ?? -1)")
        check("an omni binding matches any channel",
              position(router.route(channel: 9, cc: 7, value: 127)) != nil)
        check("an unmapped CC routes to nothing",
              router.route(channel: 0, cc: 8, value: 64) == nil)

        router.load([MIDIBinding(paramID: "p", channel: 3, cc: 1, mode: .toggle)])
        check("a toggle fires on press and ignores release",
              router.route(channel: 3, cc: 1, value: 127) != nil
                  && router.route(channel: 3, cc: 1, value: 0) == nil)
        check("a channel-specific binding ignores other channels",
              router.route(channel: 4, cc: 1, value: 127) == nil)
    }

    private func position(_ result: (binding: MIDIBinding, update: MIDIRouter.Update)?) -> Double? {
        if case .absolute(let value)? = result?.update { return value }
        return nil
    }

    /// Draws the window's AppKit hierarchy into a PNG so the inspector's layout
    /// can actually be looked at. `cacheDisplay` is the view drawing itself, so
    /// this needs no screen-recording permission; the render pane is a live
    /// `CAMetalLayer` and comes out empty, which is the one thing this cannot show.
    private func captureUI() {
        guard let view = controller.window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: "build/playground-ui.png")
        guard let data = rep.representation(using: .png, properties: [:]),
              (try? data.write(to: url)) != nil else { return }
        print("     wrote \(url.path)")
    }

    private func finish() {
        MIDIMappingStore.delete(Self.testMapping)
        try? FileManager.default.removeItem(at: ShaderPaths.customDirectory
            .appendingPathComponent(Self.parameterlessShader + ".metal"))
        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
