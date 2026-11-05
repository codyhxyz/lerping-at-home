import Foundation
import Metal
import os
import QuartzCore

/// Signpost intervals for the two things worth seeing on an Instruments
/// timeline: compiling a shader and encoding a frame. Same subsystem as every
/// other log line, so the os_signpost instrument filters on the name you
/// already know.
public enum LerpSignposts {
    /// `compile` intervals. A handful per session, so an ordinary category:
    /// they reach the log store and `log show --signpost` finds them after
    /// the fact.
    public static let signposter = OSSignposter(subsystem: LerpDefaults.productionModule,
                                                category: "performance")

    /// `encode` intervals, one per frame. `.dynamicTracing` is off unless
    /// Instruments is recording, and that is the point: in an ordinary
    /// category these were two log-store entries per frame — 120 a second
    /// from a screensaver that runs all night.
    public static let frames = OSSignposter(logHandle: OSLog(subsystem: LerpDefaults.productionModule,
                                                             category: .dynamicTracing))
}

/// What a look costs the GPU while it is on screen.
///
/// Every command buffer `LerpRenderer` encodes for a host that has said which
/// look is up gets a completed handler that reads `gpuEndTime - gpuStartTime`.
/// The samples accumulate per look and are summarised — frames, mean, p95, max
/// — in **one** log line when the look changes, never per frame. A screensaver
/// runs for hours; a per-frame line would be the loudest thing in the unified
/// log and the least read.
///
/// Nothing is measured until `begin(look:)` is called, so the offscreen paths
/// (gallery stills, `--snapshot`) pay for no handler and log nothing.
///
/// `.notice` for the same reason `playing …` is: info-level lines are
/// memory-only and gone within minutes, and the screensaver runs exactly when
/// nobody is watching a terminal.
public final class LerpGPUCost: @unchecked Sendable {
    static let log = Logger(subsystem: LerpDefaults.productionModule, category: "gpu")

    /// Enough for 18 minutes at 60 fps. Past it the mean and max stay exact and
    /// the p95 is taken over the first `sampleCap` frames.
    static let sampleCap = 1 << 16

    public struct Summary: CustomStringConvertible {
        public let look: String
        public let frames: Int
        public let meanMs: Double
        public let p95Ms: Double
        public let maxMs: Double
        public let width: Int
        public let height: Int
        /// Wall-clock seconds the look was the current one.
        public let seconds: Double

        public var description: String {
            String(format: "gpu %@ frames=%d mean=%.3fms p95=%.3fms max=%.3fms at %dx%d over %.1fs",
                   look, frames, meanMs, p95Ms, maxMs, width, height, seconds)
        }
    }

    /// The GPU time one command buffer added: its span, minus any part of it
    /// that overlapped the previous buffer's.
    ///
    /// Not plain `gpuEndTime - gpuStartTime`. Buffers queued back to back run
    /// overlapped on Apple GPUs, so each one's own span also covers the tail of
    /// the one before it — measured offscreen, a look that drew 70 4K frames in
    /// 0.97 s of wall clock reported 232 ms per frame. The same happens live
    /// whenever a look is slower than the display: exactly the looks this
    /// number exists to catch. Counting only the time past the previous end
    /// sums to the GPU's real busy time however deep the queue is.
    public static func busyMs(start: CFTimeInterval, end: CFTimeInterval,
                              previousEnd: CFTimeInterval) -> Double {
        max(0, end - max(start, previousEnd)) * 1000
    }

    /// The statistics, shared with `LerpPreview --bench` so a table on a
    /// terminal and a line in the log are the same arithmetic.
    public static func summarize(look: String, samplesMs: [Double], frames: Int? = nil,
                                 totalMs: Double? = nil, maxMs: Double? = nil,
                                 width: Int, height: Int, seconds: Double) -> Summary {
        let sorted = samplesMs.sorted()
        let count = frames ?? sorted.count
        let total = totalMs ?? sorted.reduce(0, +)
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        return Summary(look: look, frames: count,
                       meanMs: count > 0 ? total / Double(count) : 0,
                       p95Ms: p95, maxMs: maxMs ?? sorted.last ?? 0,
                       width: width, height: height, seconds: seconds)
    }

    private struct State {
        var look: String?
        /// Bumped by every `begin`, so a frame still in flight when the look
        /// changed is dropped rather than counted against the next one.
        var generation = 0
        var started: CFTimeInterval = 0
        var samples: [Double] = []
        var frames = 0
        var totalMs = 0.0
        var maxMs = 0.0
        var width = 0
        var height = 0
        /// `gpuEndTime` of the last buffer counted. Survives `begin`, because
        /// the queue does not know the look changed.
        var lastEnd: CFTimeInterval = 0
        /// The newest `recentCap` frames of this look since the last
        /// `restartRecent()`, oldest first: what `LerpMetalView`'s pacing reads.
        var recent: [Double] = []

        func summary(now: CFTimeInterval) -> Summary? {
            guard let look, frames > 0 else { return nil }
            return LerpGPUCost.summarize(look: look, samplesMs: samples, frames: frames,
                                         totalMs: totalMs, maxMs: maxMs,
                                         width: width, height: height, seconds: now - started)
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Two seconds at 60 fps: long enough that one slow frame is not a verdict,
    /// short enough that a look which got heavier is caught within a few
    /// seconds.
    static let recentCap = 120

    /// p95 of the current look's most recent frames, or nil before `minimum`
    /// of them have completed since the look began or the window restarted.
    public func recentP95(minimum: Int = 45) -> Double? {
        state.withLock { state in
            guard state.look != nil, state.recent.count >= minimum else { return nil }
            let sorted = state.recent.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        }
    }

    /// Forgets the recent window (not the look's summary): after a crossfade,
    /// whose frames drew two looks, or a frame-rate change.
    public func restartRecent() {
        state.withLock { $0.recent.removeAll(keepingCapacity: true) }
    }

    public init() {}

    deinit { finish() }

    /// The look on screen changed. Logs the outgoing look's summary, if it drew
    /// anything, and starts counting for `look`. Showing the look that is
    /// already up (a recompile, a re-show) keeps counting rather than logging.
    @discardableResult
    public func begin(look: String) -> Summary? {
        let now = CACurrentMediaTime()
        let finished: Summary? = state.withLock { state in
            guard state.look != look else { return nil }
            let summary = state.summary(now: now)
            state = State(look: look, generation: state.generation + 1, started: now,
                          lastEnd: state.lastEnd)
            return summary
        }
        if let finished { Self.log.notice("\(finished.description, privacy: .public)") }
        return finished
    }

    /// Logs the current look's summary and stops measuring.
    @discardableResult
    public func finish() -> Summary? {
        let now = CACurrentMediaTime()
        let finished: Summary? = state.withLock { state in
            let summary = state.summary(now: now)
            state = State(look: nil, generation: state.generation + 1, lastEnd: state.lastEnd)
            return summary
        }
        if let finished { Self.log.notice("\(finished.description, privacy: .public)") }
        return finished
    }

    /// Called by `LerpRenderer` for every command buffer it encodes.
    func attach(to commandBuffer: MTLCommandBuffer, width: Int, height: Int) {
        guard let generation = state.withLock({ $0.look == nil ? nil : $0.generation }) else { return }
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard buffer.status == .completed, buffer.gpuEndTime > 0, let self else { return }
            let start = buffer.gpuStartTime, end = buffer.gpuEndTime
            self.state.withLock { state in
                let ms = Self.busyMs(start: start, end: end, previousEnd: state.lastEnd)
                state.lastEnd = max(state.lastEnd, end)
                guard state.generation == generation, ms > 0 else { return }
                state.frames += 1
                state.totalMs += ms
                state.maxMs = max(state.maxMs, ms)
                if state.samples.count < Self.sampleCap { state.samples.append(ms) }
                if state.recent.count >= Self.recentCap { state.recent.removeFirst() }
                state.recent.append(ms)
                state.width = width
                state.height = height
            }
        }
    }
}
