import AppKit
import Metal

/// Preview stills for the rotation gallery: one per (shader, preset), rendered
/// offscreen through the same `LerpSnapshot` path the screensaver's wallpaper
/// handoff uses, cached on disk, and delivered to the UI as they arrive.
///
/// ## Why this is not just a loop
///
/// A 240×360 still costs ~65 ms, and there are 114 of them. Rendering them
/// serially on the main thread would take ~7 s with the window frozen, which is
/// not a thing a window is allowed to do. So:
///
/// - **Nothing blocks.** `start` returns immediately; tiles fill in as their
///   images land, in whatever order they land.
/// - **Disk first.** Every request checks the cache before it queues a render,
///   so the second launch draws the whole gallery without touching the GPU.
/// - **Then parallel.** The misses are grouped by shader and dealt round-robin
///   to a small pool of workers, each with a `ShaderLibrary` and `LerpRenderer`
///   of its own (neither is thread-safe; a `MTLDevice` is). Grouping by shader
///   matters: pipeline compilation dominates the cost, and one worker taking a
///   whole shader compiles it once for all of its presets.
///
/// ## Why the cache key is what it is
///
/// A frame is a pure function of (shader source, parameters, time, seed, size),
/// so the key is exactly that: the entry, a stable hash of the shader's *source
/// text*, and the recipe. Editing one `.metal` file changes that file's hash and
/// therefore misses only that shader's tiles — every other shader keeps its
/// cached stills. The hash is FNV-1a rather than `String.hashValue`, which is
/// seeded per process and would invalidate the whole cache on every launch.
///
/// The stills are rendered at a fixed `time` and `seed` so they are the same
/// pictures every time the gallery opens, and so two launches agree about what
/// a look looks like.
final class RotationThumbnails {

    /// Everything that goes into a still besides the shader itself. `version`
    /// exists so a change to how stills are made can invalidate the cache
    /// without anyone having to find and delete it.
    struct Recipe {
        var width = 240
        var height = 360
        /// Far enough in that nothing is still easing out of its t=0 pose.
        var time: Float = 6
        /// Fixed, so a tile is the same picture on every launch.
        var seed: Float = 0.37
        var version = 1

        var token: String { "\(width)x\(height)-t\(time)-s\(seed)-v\(version)" }
    }

    /// One thing to draw: the rotation entry and the shader it belongs to.
    struct Job {
        let entry: LerpRotationEntry
        let shader: LerpShader
    }

    let recipe: Recipe
    private let searchURLs: [URL]
    private let directory: URL

    /// Decoded stills, keyed the same way the files are. Held so a filter
    /// change or a window resize redraws instantly.
    private var memory: [String: NSImage] = [:]

    /// Bumped by every `start` and every `cancel`; a delivery from an older
    /// generation is dropped rather than painted over the new one.
    private var generation = 0

    /// Counted for the self-test and the status line: how many stills came off
    /// disk versus how many the GPU had to draw. A warm gallery is all hits.
    private(set) var diskHits = 0
    private(set) var memoryHits = 0
    private(set) var rendered = 0
    private(set) var failed: [String] = []
    /// Wall-clock seconds from `start` to the last delivery of the most recent
    /// run — the number the report calls "cold" or "warm".
    private(set) var lastRunSeconds: Double = 0

    private let queue = DispatchQueue(label: "lerping.rotation.thumbnails", qos: .userInitiated)
    private let lock = NSLock()

    init(searchURLs: [URL], recipe: Recipe = Recipe(), directory: URL? = nil) {
        self.searchURLs = searchURLs
        self.recipe = recipe
        self.directory = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Where the cache lives

    /// `~/Library/Caches/<bundle id>/RotationThumbnails`. The app-appropriate
    /// place for something regenerable, outside the repo, and per-bundle — so
    /// `--selftest` (a bundle identifier of its own) cannot evict the stills the
    /// user's gallery is showing, and vice versa.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let id = Bundle.main.bundleIdentifier ?? "com.hergenroeder.lerping.playground"
        return base.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("RotationThumbnails", isDirectory: true)
    }

    var cacheDirectory: URL { directory }

    /// Deterministic 64-bit FNV-1a. `String.hashValue` is seeded per process, so
    /// using it here would mean a cold cache on every single launch.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", value)
    }

    /// The cache key for a look: what it is, what its shader's source says, and
    /// how the still is made. Any of the three changing is a different picture.
    func key(entry: LerpRotationEntry, source: String) -> String {
        Self.hash(entry.key + "\u{1}" + source + "\u{1}" + recipe.token)
    }

    /// `voronoi-Molten-4f0c….png` — the hash is what makes it unique; the
    /// readable part is so the cache directory can be looked at by a human.
    func url(entry: LerpRotationEntry, source: String) -> URL {
        let stem = Self.slug(entry.shader) + "-" + Self.slug(entry.preset ?? "defaults")
        return directory.appendingPathComponent(stem + "-" + key(entry: entry, source: source) + ".png")
    }

    private static func slug(_ text: String) -> String {
        let out = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(out).prefix(28))
    }

    // MARK: - Lookup

    /// The still for a look if it is already decoded, without touching the disk.
    func image(entry: LerpRotationEntry, source: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return memory[key(entry: entry, source: source)]
    }

    // MARK: - Running

    /// Fills in every job's still, cheapest source first, without blocking.
    ///
    /// `onImage` and `onFinished` are called on the main queue. Calling `start`
    /// again supersedes the run in flight.
    func start(_ jobs: [Job],
               onImage: @escaping (LerpRotationEntry, NSImage) -> Void,
               onProgress: @escaping (_ done: Int, _ total: Int) -> Void,
               onFinished: @escaping () -> Void) {
        lock.lock()
        generation += 1
        let run = generation
        diskHits = 0; memoryHits = 0; rendered = 0; failed = []
        // Deliver what is already decoded before anything touches the disk, so
        // a filter change or a reopen paints instantly.
        var pending: [Job] = []
        var warm: [(LerpRotationEntry, NSImage)] = []
        for job in jobs {
            if let image = memory[key(entry: job.entry, source: job.shader.source)] {
                warm.append((job.entry, image))
            } else {
                pending.append(job)
            }
        }
        memoryHits = warm.count
        lock.unlock()

        let total = jobs.count
        var done = warm.count
        let started = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            guard self.isCurrent(run) else { return }
            warm.forEach { onImage($0.0, $0.1) }
            onProgress(done, total)
            if pending.isEmpty {
                self.finish(run: run, started: started, onFinished: onFinished)
            }
        }
        guard !pending.isEmpty else { return }

        /// One delivery. Counts, then hands the image to the UI.
        func deliver(_ entry: LerpRotationEntry, _ image: NSImage) {
            DispatchQueue.main.async {
                guard self.isCurrent(run) else { return }
                done += 1
                onImage(entry, image)
                onProgress(done, total)
            }
        }

        queue.async {
            // Phase 1 — the disk. A whole warm gallery lands here.
            var misses: [Job] = []
            for job in pending {
                guard self.isCurrent(run) else { return }
                let key = self.key(entry: job.entry, source: job.shader.source)
                let url = self.url(entry: job.entry, source: job.shader.source)
                guard FileManager.default.fileExists(atPath: url.path),
                      let image = NSImage(contentsOf: url), image.isValid else {
                    // A half-written file from an interrupted run reads as a
                    // miss and is drawn again, rather than as a broken tile.
                    try? FileManager.default.removeItem(at: url)
                    misses.append(job)
                    continue
                }
                self.store(image, forKey: key)
                self.countDiskHit()
                deliver(job.entry, image)
            }

            // Phase 2 — the GPU, in parallel, a shader at a time.
            self.render(misses, run: run, deliver: deliver)

            self.prune(expected: Set(jobs.map {
                self.url(entry: $0.entry, source: $0.shader.source).lastPathComponent
            }))
            DispatchQueue.main.async {
                self.finish(run: run, started: started, onFinished: onFinished)
            }
        }
    }

    /// Drops any run in flight. Deliveries already queued are discarded.
    func cancel() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    /// Forgets every still, on disk and in memory, so the next `start` redraws
    /// all of them. What the gallery's Regenerate button does.
    func evictAll() {
        cancel()
        lock.lock()
        memory.removeAll()
        lock.unlock()
        let directory = self.directory
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension == "png" {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Internals

    private func isCurrent(_ run: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == run
    }

    private func store(_ image: NSImage, forKey key: String) {
        lock.lock(); memory[key] = image; lock.unlock()
    }

    private func countDiskHit() { lock.lock(); diskHits += 1; lock.unlock() }
    private func countRender() { lock.lock(); rendered += 1; lock.unlock() }

    private func finish(run: Int, started: CFAbsoluteTime, onFinished: () -> Void) {
        guard isCurrent(run) else { return }
        lastRunSeconds = CFAbsoluteTimeGetCurrent() - started
        onFinished()
    }

    /// Renders the misses across a small pool. Each worker owns its own library
    /// and renderer — `ShaderLibrary` caches pipelines in a plain dictionary and
    /// `LerpRenderer` owns a command queue, so neither may be shared — while the
    /// `MTLDevice` underneath them is shared and thread-safe.
    private func render(_ jobs: [Job], run: Int,
                        deliver: (LerpRotationEntry, NSImage) -> Void) {
        guard !jobs.isEmpty else { return }
        // Grouped by shader, in first-seen order, so a worker that takes a
        // shader compiles its pipeline once and reuses it for every preset.
        var order: [String] = []
        var groups: [String: [Job]] = [:]
        for job in jobs {
            if groups[job.shader.name] == nil { order.append(job.shader.name) }
            groups[job.shader.name, default: []].append(job)
        }
        let workers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        DispatchQueue.concurrentPerform(iterations: min(workers, order.count)) { slot in
            guard let renderer = LerpRenderer() else { return }
            let library = ShaderLibrary(device: renderer.device, extraSearchURLs: searchURLs)
            var index = slot
            while index < order.count {
                guard isCurrent(run) else { return }
                for job in groups[order[index]] ?? [] {
                    guard isCurrent(run) else { return }
                    var values = job.shader.defaultParameterValues()
                    if let name = job.entry.preset, let preset = job.shader.preset(named: name) {
                        values.apply(preset)
                    }
                    let url = url(entry: job.entry, source: job.shader.source)
                    let result = LerpSnapshot.render(shader: job.shader, library: library,
                                                     renderer: renderer,
                                                     width: recipe.width, height: recipe.height,
                                                     time: recipe.time, seed: recipe.seed,
                                                     params: values, to: url)
                    guard result.error == nil, let image = NSImage(contentsOf: url), image.isValid else {
                        lock.lock()
                        failed.append(job.entry.key + ": " + (result.error ?? "unreadable PNG"))
                        lock.unlock()
                        continue
                    }
                    store(image, forKey: key(entry: job.entry, source: job.shader.source))
                    countRender()
                    deliver(job.entry, image)
                }
                index += workers
            }
        }
    }

    /// Drops cache files no current look claims — which is how a shader that was
    /// edited stops paying rent for the still of the version before the edit.
    private func prune(expected: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "png" && !expected.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
