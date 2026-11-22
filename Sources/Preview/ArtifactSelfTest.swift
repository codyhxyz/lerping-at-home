import Foundation

enum ArtifactSelfTest {
    static func run(_ extraSearch: [URL]) {
        if let error = ArtifactLedger.selfTest() { PreviewMain.fail("artifacts: \(error)") }
        let (renderer, library) = PreviewMain.makeLibrary(extraSearch)
        guard let shader = library.discover().first(where: { $0.name == "life-artifacts" }) else {
            PreviewMain.fail("artifacts: missing life-artifacts")
        }
        guard shader.category == "Artifacts", shader.parameterErrors.isEmpty else {
            PreviewMain.fail("artifacts: wrong shelf or invalid parameters")
        }
        guard shader.presets.count >= 6 else { PreviewMain.fail("artifacts: missing relic presets") }
        do { _ = try library.pipeline(for: shader, pixelFormat: .bgra8Unorm) }
        catch { PreviewMain.fail("artifacts: pipeline: \(error)") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-selftest-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = LerpSnapshot.render(shader: shader, library: library, renderer: renderer,
                                        width: 640, height: 400, time: 12, seed: 0.42, to: url)
        if let error = result.error { PreviewMain.fail("artifacts: snapshot: \(error)") }
        guard let bytes = try? Data(contentsOf: url), bytes.count > 100, result.meanLuminance > 0 else {
            PreviewMain.fail("artifacts: empty snapshot")
        }
        print("OK    artifacts: ledger, shelf, presets, pipeline and 640x400 snapshot")
    }
}
