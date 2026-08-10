import Foundation
import Metal

/// CPU side of `game-of-life`: ten bounded cellular-automaton stories, handed
/// to the fragment shader as one texel per cell.
///
/// Iterative simulation cannot be random-access, so every story repeats after a
/// story-sized epoch. Reaching any clock time therefore costs at most one story,
/// and a cached generation is only stepped forward when its complete input key
/// still matches. Canonical finite patterns use dead edges and a sparse set;
/// full-screen soups use the toroidal dense grid.
public final class LifeData: LerpDataProvider {

    // MARK: - Stories and rules

    private enum Story: Int, Hashable {
        case chaos, gliderGun, rPentomino, highLife, gliderLogic
        case maze, dayAndNight, seeds, lifeWithoutDeath, comparison

        /// Kept in step with `golEpoch` in game-of-life.metal. Maze gets a
        /// longer clock because its seed-specific simulation usually settles
        /// early and spends the rest of the story revealing the finished field.
        var epochLength: Int {
            switch self {
            case .chaos:            return 256
            case .gliderGun:        return 320
            case .rPentomino:       return 1120 // includes the generation-1,103 finish
            case .highLife:         return 240
            case .gliderLogic:      return 320
            case .maze:             return 64
            case .dayAndNight:      return 192
            case .seeds:            return 64
            case .lifeWithoutDeath: return 96
            case .comparison:       return 160
            }
        }

        /// R-pentomino traverses its canonical history. Maze instead advances
        /// to the measured settling generation during the first part of its arc.
        func generation(at phase: Float, mazeCompletionGeneration: Int? = nil) -> Int {
            if self == .rPentomino {
                if phase < 0.10 { return 0 }
                if phase < 0.65 {
                    return Int(((phase - 0.10) / 0.55 * 500).rounded(.down))
                }
                if phase < 0.88 {
                    return 500 + Int(((phase - 0.65) / 0.23 * 603).rounded(.down))
                }
                return 1103
            }
            if self == .maze {
                let last = mazeCompletionGeneration ?? epochLength - 1
                let progress = min(1, max(0, phase / 0.36))
                return min(last, Int((progress * Float(last)).rounded(.down)))
            }
            return min(epochLength - 1, Int((phase * Float(epochLength)).rounded(.down)))
        }

        var finite: Bool {
            switch self {
            case .gliderGun, .rPentomino, .highLife, .gliderLogic: return true
            default: return false
            }
        }

        /// Finite scenes get a stable mathematical board and a fitted camera,
        /// independent of display shape. The R-pentomino needs this much room to
        /// finish its famous 1,103-generation run without touching an edge.
        var fixedGrid: (cols: Int, rows: Int)? {
            switch self {
            case .gliderGun, .gliderLogic: return (144, 96)
            case .rPentomino:              return (640, 640)
            case .highLife:                return (256, 256)
            default:                       return nil
            }
        }

        var trailDecay: Float { self == .rPentomino ? 0.98 : LifeData.trailDecay }

        var rule: Rule {
            switch self {
            case .highLife:         return .highLife
            case .maze:             return .maze
            case .dayAndNight:      return .dayAndNight
            case .seeds:            return .seeds
            case .lifeWithoutDeath: return .lifeWithoutDeath
            default:                return .conway
            }
        }
    }

    private struct Rule {
        let birth: Int
        let survival: Int

        func next(wasAlive: Bool, neighbours: Int) -> Bool {
            let mask = wasAlive ? survival : birth
            return mask & (1 << neighbours) != 0
        }

        static let conway = Rule(birth: 1 << 3,
                                 survival: (1 << 2) | (1 << 3))                 // B3/S23
        static let highLife = Rule(birth: (1 << 3) | (1 << 6),
                                   survival: (1 << 2) | (1 << 3))              // B36/S23
        static let maze = Rule(birth: 1 << 3,
                               survival: (1 << 1) | (1 << 2) | (1 << 3)
                                       | (1 << 4) | (1 << 5))                  // B3/S12345
        static let dayAndNight = Rule(birth: (1 << 3) | (1 << 6) | (1 << 7) | (1 << 8),
                                      survival: (1 << 3) | (1 << 4) | (1 << 6)
                                              | (1 << 7) | (1 << 8))           // B3678/S34678
        static let seeds = Rule(birth: 1 << 2, survival: 0)                    // B2/S
        static let lifeWithoutDeath = Rule(birth: 1 << 3, survival: 0x1ff)     // B3/S012345678
    }

    // MARK: - Tunables

    static let solidityGens = 4
    static let solidityFloor: Float = 0.45
    static let trailDecay: Float = 0.72
    static let maxCellsPerAxis = 1024
    static let mazeFinalCellScale: Float = 0.60
    static let mazeCompletionLimit = 160
    static let mazeQuietGenerations = 3

    // MARK: - Canonical patterns

    private static let rPentomino = [(1, 0), (2, 0), (0, 1), (1, 1), (1, 2)]

    /// Nathan Thompson's 12-cell HighLife replicator. After twelve generations
    /// it is two copies of itself.
    private static let replicator = [
        (2, 0), (3, 0), (4, 0), (1, 1), (4, 1), (0, 2),
        (4, 2), (0, 3), (3, 3), (0, 4), (1, 4), (2, 4),
    ]

    /// Gosper's period-30 glider gun, 36 live cells in a 36×9 box.
    private static let gosperGun = [
        (24, 0), (22, 1), (24, 1), (12, 2), (13, 2), (20, 2), (21, 2),
        (34, 2), (35, 2), (11, 3), (15, 3), (20, 3), (21, 3), (34, 3),
        (35, 3), (0, 4), (1, 4), (10, 4), (16, 4), (20, 4), (21, 4),
        (0, 5), (1, 5), (10, 5), (14, 5), (16, 5), (17, 5), (22, 5),
        (24, 5), (10, 6), (16, 6), (24, 6), (11, 7), (15, 7), (12, 8),
        (13, 8),
    ]

    // MARK: - State (a cache whose key is its whole input)

    private struct Key: Hashable {
        var seed: UInt32
        var cols: Int
        var rows: Int
        var epoch: Int
        var density: Float
        var story: Story
    }

    private let device: MTLDevice
    private var key: Key?
    private var generation = 0
    private var mazeCompletionGeneration = 0

    // Full-screen soups: a dense toroidal board.
    private var alive: [UInt8] = []
    private var scratch: [UInt8] = []
    private var age: [UInt8] = []
    private var trail: [UInt8] = []

    // Canonical patterns: sparse, bounded, and therefore cheap even on the
    // R-pentomino's 640×640 plane at generation 1,103.
    private var sparseAlive = Set<Int>()
    private var sparseAge: [Int: UInt8] = [:]
    private var sparseTrail: [Int: UInt8] = [:]

    private var texture: MTLTexture?
    private var textureGeneration = -1

    public init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - LerpDataProvider

    public var metalPrelude: String { LifeData.metalSource }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    public func bind(to encoder: MTLRenderCommandEncoder,
                     uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        let rawStory = Int(scalar(params, "story", 0).rounded())
        let story = Story(rawValue: rawStory) ?? .chaos
        let cellSize = max(4, scalar(params, "size", 8))
        let (cols, rows) = dimensions(story: story, resolution: uniforms.resolution,
                                      cellSize: cellSize)

        // Float arithmetic deliberately matches the shader's camera clock.
        let rate = max(0, scalar(params, "speed", 32))
        let cyclePosition = rate > 0
            ? max(0, uniforms.time) * rate / Float(story.epochLength) : 0
        let epoch = Int(cyclePosition.rounded(.down))
        let phase = cyclePosition - Float(epoch)

        let wanted = Key(seed: uniforms.seed.bitPattern,
                         cols: cols, rows: rows, epoch: epoch,
                         density: min(1, max(0, scalar(params, "density", 0.42))),
                         story: story)

        if key != wanted {
            reseed(wanted)
            mazeCompletionGeneration = story == .maze
                ? detectMazeCompletion(cols: cols, rows: rows) : 0
            key = wanted
            generation = 0
        }
        let target = story.generation(at: phase,
                                      mazeCompletionGeneration: mazeCompletionGeneration)
        if target < generation {
            reseed(wanted)
            generation = 0
        }
        while generation < target {
            step(wanted)
            generation += 1
        }

        if texture == nil || texture?.width != cols || texture?.height != rows {
            texture = LifeData.makeTexture(device: device, width: cols, height: rows)
            textureGeneration = -1
        }
        guard let texture else { return }
        if textureGeneration != generation {
            upload(into: texture, key: wanted)
            textureGeneration = generation
        }
        encoder.setFragmentTexture(texture, index: 1)
    }

    private func dimensions(story: Story, resolution: SIMD2<Float>, cellSize: Float)
        -> (Int, Int) {
        if let fixed = story.fixedGrid { return fixed }
        let finalCellSize = story == .maze
            ? max(4, cellSize * Self.mazeFinalCellScale) : cellSize
        var cols = axis(resolution.x, finalCellSize)
        let rows = axis(resolution.y, finalCellSize)
        if story == .dayAndNight, cols % 2 != 0 { cols = min(cols + 1, Self.maxCellsPerAxis) }
        if story == .comparison { cols = max(12, cols - cols % 3) }
        return (cols, rows)
    }

    private func axis(_ pixels: Float, _ cellSize: Float) -> Int {
        let n = Int((max(1, pixels) / cellSize).rounded(.up))
        return min(Self.maxCellsPerAxis, max(8, n))
    }

    private func scalar(_ params: LerpParameterValues?, _ name: String, _ fallback: Float) -> Float {
        guard let value = params?[name]?.scalarValue else { return fallback }
        return Float(value)
    }

    // MARK: - Initial conditions

    private func reseed(_ key: Key) {
        alive.removeAll(keepingCapacity: true)
        scratch.removeAll(keepingCapacity: true)
        age.removeAll(keepingCapacity: true)
        trail.removeAll(keepingCapacity: true)
        sparseAlive.removeAll(keepingCapacity: true)
        sparseAge.removeAll(keepingCapacity: true)
        sparseTrail.removeAll(keepingCapacity: true)
        textureGeneration = -1

        if key.story.finite {
            seedFinite(key)
            return
        }

        let count = key.cols * key.rows
        alive = [UInt8](repeating: 0, count: count)
        scratch = [UInt8](repeating: 0, count: count)
        age = [UInt8](repeating: 0, count: count)
        trail = [UInt8](repeating: 0, count: count)
        let salt = key.seed &+ UInt32(truncatingIfNeeded: key.epoch &* 0x9E3779B9)

        switch key.story {
        case .chaos, .maze, .seeds:
            seedRandom(key, salt: salt)
        case .lifeWithoutDeath:
            seedCoral(key, salt: salt)
        case .dayAndNight:
            seedComplements(key, salt: salt)
        case .comparison:
            seedComparison(key, salt: salt)
        default:
            break
        }
    }

    private func seedFinite(_ key: Key) {
        switch key.story {
        case .gliderGun:
            add(Self.gosperGun, atX: 16, y: 12, cols: key.cols, rows: key.rows)
        case .rPentomino:
            add(Self.rPentomino, atX: key.cols / 2 - 1, y: key.rows / 2 - 1,
                cols: key.cols, rows: key.rows)
        case .highLife:
            add(Self.replicator, atX: key.cols / 2 - 2, y: key.rows / 2 - 2,
                cols: key.cols, rows: key.rows)
        case .gliderLogic:
            // Two period-30 inputs converge. Their recurring collisions are the
            // same signal interactions from which Life logic gates are built.
            add(Self.gosperGun, atX: 26, y: 10, cols: key.cols, rows: key.rows)
            add(Self.gosperGun, atX: 82, y: 10, mirrored: true,
                cols: key.cols, rows: key.rows)
        default:
            break
        }
    }

    private func add(_ pattern: [(Int, Int)], atX originX: Int, y originY: Int,
                     mirrored: Bool = false, cols: Int, rows: Int) {
        for (px, py) in pattern {
            let x = originX + (mirrored ? 35 - px : px)
            let y = originY + py
            guard x >= 0, x < cols, y >= 0, y < rows else { continue }
            let i = y * cols + x
            sparseAlive.insert(i)
            sparseAge[i] = UInt8(Self.solidityGens)
        }
    }

    private func seedRandom(_ key: Key, salt: UInt32) {
        for y in 0..<key.rows {
            for x in 0..<key.cols where Self.hash(UInt32(x), UInt32(y), salt) < key.density {
                setDense(y * key.cols + x)
            }
        }
    }

    /// A handful of locally random spores. Uniformly scattering the same number
    /// over a thumbnail almost never gives B3 a birth; compact spores guarantee
    /// visible irreversible fronts at every display size.
    private func seedCoral(_ key: Key, salt: UInt32) {
        let centres: [(Float, Float)] = [
            (0.18, 0.25), (0.34, 0.70), (0.50, 0.42), (0.68, 0.72), (0.84, 0.28),
        ]
        let radius = max(3, min(key.cols, key.rows) / 20)
        for (cx, cy) in centres {
            let centerX = Int(Float(key.cols) * cx)
            let centerY = Int(Float(key.rows) * cy)
            for y in max(0, centerY - radius)...min(key.rows - 1, centerY + radius) {
                for x in max(0, centerX - radius)...min(key.cols - 1, centerX + radius)
                    where Self.hash(UInt32(x), UInt32(y), salt) < key.density {
                    setDense(y * key.cols + x)
                }
            }
        }
    }

    /// Day & Night is invariant under swapping live and dead. Start its right
    /// half as the mirrored complement of its left so that symmetry is visible,
    /// not merely a fact hidden in another random soup.
    private func seedComplements(_ key: Key, salt: UInt32) {
        let half = key.cols / 2
        for y in 0..<key.rows {
            for x in 0..<half {
                let leftIsAlive = Self.hash(UInt32(x), UInt32(y), salt) < key.density
                if leftIsAlive { setDense(y * key.cols + x) }
                if !leftIsAlive { setDense(y * key.cols + (key.cols - 1 - x)) }
            }
        }
    }

    /// Three copies of one soup, with blank gutters. Evolution starts identical;
    /// only B3/S23, B36/S23, and B2/S differ.
    private func seedComparison(_ key: Key, salt: UInt32) {
        let width = key.cols / 3
        for y in 0..<key.rows {
            for x in 1..<(width - 1) {
                guard Self.hash(UInt32(x), UInt32(y), salt) < key.density else { continue }
                for panel in 0..<3 { setDense(y * key.cols + panel * width + x) }
            }
        }
    }

    private func setDense(_ index: Int) {
        alive[index] = 1
        age[index] = UInt8(Self.solidityGens)
    }

    // MARK: - Evolution

    private func step(_ key: Key) {
        if key.story.finite {
            stepSparse(cols: key.cols, rows: key.rows, rule: key.story.rule,
                       trailDecay: key.story.trailDecay)
        } else if key.story == .comparison {
            stepComparison(cols: key.cols, rows: key.rows)
        } else {
            stepDense(cols: key.cols, rows: key.rows, rule: key.story.rule)
        }
    }

    private func stepDense(cols: Int, rows: Int, rule: Rule) {
        alive.withUnsafeBufferPointer { a in
            scratch.withUnsafeMutableBufferPointer { next in
                age.withUnsafeMutableBufferPointer { ages in
                    trail.withUnsafeMutableBufferPointer { trails in
                        for y in 0..<rows {
                            let row = y * cols
                            let up = ((y + 1) % rows) * cols
                            let down = ((y + rows - 1) % rows) * cols
                            for x in 0..<cols {
                                let right = x + 1 == cols ? 0 : x + 1
                                let left = x == 0 ? cols - 1 : x - 1
                                let n = Int(a[down + left]) + Int(a[down + x]) + Int(a[down + right])
                                      + Int(a[row + left])                      + Int(a[row + right])
                                      + Int(a[up + left])   + Int(a[up + x])   + Int(a[up + right])
                                update(index: row + x, live: rule.next(wasAlive: a[row + x] != 0,
                                                                       neighbours: n),
                                       previous: a, next: next, ages: ages, trails: trails)
                            }
                        }
                    }
                }
            }
        }
        swap(&alive, &scratch)
    }

    /// The first of three consecutive generations changing at most one percent
    /// of the board. Looking ahead avoids mistaking a single quiet beat for the
    /// finished maze; restoring the arrays keeps the probe out of rendered state.
    private func detectMazeCompletion(cols: Int, rows: Int) -> Int {
        let initialAlive = alive, initialScratch = scratch
        let initialAge = age, initialTrail = trail
        defer {
            alive = initialAlive
            scratch = initialScratch
            age = initialAge
            trail = initialTrail
        }

        var quiet = 0
        for candidate in 1...Self.mazeCompletionLimit {
            stepDense(cols: cols, rows: rows, rule: .maze)
            let changed = zip(alive, scratch).reduce(into: 0) {
                if $1.0 != $1.1 { $0 += 1 }
            }
            quiet = changed * 100 <= alive.count ? quiet + 1 : 0
            if quiet == Self.mazeQuietGenerations {
                return candidate - Self.mazeQuietGenerations + 1
            }
        }
        return Self.mazeCompletionLimit
    }

    private func stepComparison(cols: Int, rows: Int) {
        let width = cols / 3
        let rules = [Rule.conway, Rule.highLife, Rule.seeds]
        alive.withUnsafeBufferPointer { a in
            scratch.withUnsafeMutableBufferPointer { next in
                age.withUnsafeMutableBufferPointer { ages in
                    trail.withUnsafeMutableBufferPointer { trails in
                        for panel in 0..<3 {
                            let start = panel * width + 1
                            let end = (panel + 1) * width - 2
                            let rule = rules[panel]
                            for y in 0..<rows {
                                let row = y * cols
                                let up = ((y + 1) % rows) * cols
                                let down = ((y + rows - 1) % rows) * cols
                                for x in start...end {
                                    let left = x == start ? end : x - 1
                                    let right = x == end ? start : x + 1
                                    let n = Int(a[down + left]) + Int(a[down + x]) + Int(a[down + right])
                                          + Int(a[row + left])                      + Int(a[row + right])
                                          + Int(a[up + left])   + Int(a[up + x])   + Int(a[up + right])
                                    update(index: row + x,
                                           live: rule.next(wasAlive: a[row + x] != 0, neighbours: n),
                                           previous: a, next: next, ages: ages, trails: trails)
                                }
                            }
                        }
                    }
                }
            }
        }
        swap(&alive, &scratch)
    }

    private func update(index: Int, live: Bool,
                        previous: UnsafeBufferPointer<UInt8>,
                        next: UnsafeMutableBufferPointer<UInt8>,
                        ages: UnsafeMutableBufferPointer<UInt8>,
                        trails: UnsafeMutableBufferPointer<UInt8>) {
        let wasAlive = previous[index] != 0
        next[index] = live ? 1 : 0
        if live {
            ages[index] = ages[index] < 255 ? ages[index] + 1 : 255
            trails[index] = 0
        } else {
            ages[index] = 0
            trails[index] = wasAlive ? 255 : UInt8(Float(trails[index]) * Self.trailDecay)
        }
    }

    private func stepSparse(cols: Int, rows: Int, rule: Rule, trailDecay: Float) {
        let old = sparseAlive
        let next = Self.nextSparse(old, cols: cols, rows: rows, rule: rule)

        var nextAge: [Int: UInt8] = [:]
        nextAge.reserveCapacity(next.count)
        for i in next {
            let previous = sparseAge[i] ?? 0
            nextAge[i] = previous < 255 ? previous + 1 : 255
        }

        var nextTrail: [Int: UInt8] = [:]
        nextTrail.reserveCapacity(sparseTrail.count + old.count)
        for (i, value) in sparseTrail {
            let faded = UInt8(Float(value) * trailDecay)
            if faded > 1, !next.contains(i) { nextTrail[i] = faded }
        }
        for i in old where !next.contains(i) { nextTrail[i] = 255 }

        sparseAlive = next
        sparseAge = nextAge
        sparseTrail = nextTrail
    }

    private static func nextSparse(_ current: Set<Int>, cols: Int, rows: Int,
                                   rule: Rule) -> Set<Int> {
        var counts: [Int: UInt8] = [:]
        counts.reserveCapacity(current.count * 6)
        for i in current {
            let x = i % cols, y = i / cols
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < cols, ny >= 0, ny < rows else { continue }
                    counts[ny * cols + nx, default: 0] += 1
                }
            }
        }
        return Set(counts.compactMap { index, neighbours in
            rule.next(wasAlive: current.contains(index), neighbours: Int(neighbours)) ? index : nil
        })
    }

    // MARK: - Runnable rule check

    /// Small enough to run on every development build, strong enough to catch a
    /// wrong mask, a transcribed canonical pattern, or birth being applied to a
    /// live cell. Invoked by `LerpPreview --life-selftest`.
    public static func selfTest() -> Bool {
        func outcomes(_ rule: Rule, alive: Bool) -> [Int] {
            (0...8).filter { rule.next(wasAlive: alive, neighbours: $0) }
        }
        guard outcomes(.conway, alive: false) == [3],
              outcomes(.conway, alive: true) == [2, 3],
              outcomes(.highLife, alive: false) == [3, 6],
              outcomes(.seeds, alive: true).isEmpty,
              outcomes(.lifeWithoutDeath, alive: true) == Array(0...8),
              Story.maze.epochLength == 64,
              Story.rPentomino.generation(at: 0.09) == 0,
              Story.rPentomino.generation(at: 0.65) == 500,
              Story.rPentomino.generation(at: 0.88) == 1103,
              gosperGun.count == 36, rPentomino.count == 5, replicator.count == 12
        else { return false }

        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let provider = LifeData(device: device)
        let maze = Key(seed: Float(0.42).bitPattern, cols: 120, rows: 80,
                       epoch: 0, density: 0.43, story: .maze)
        provider.reseed(maze)
        let completion = provider.detectMazeCompletion(cols: maze.cols, rows: maze.rows)
        guard (4...12).contains(completion),
              Story.maze.generation(at: 0.4,
                                    mazeCompletionGeneration: completion) == completion
        else { return false }

        var cells = Set(replicator.map { (50 + $0.1) * 100 + 50 + $0.0 })
        for _ in 0..<12 { cells = nextSparse(cells, cols: 100, rows: 100, rule: .highLife) }
        return cells.count == 24
    }

    // MARK: - Texture

    private static func makeTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "life.board"
        return texture
    }

    private func upload(into texture: MTLTexture, key: Key) {
        let count = key.cols * key.rows
        var rgba = [UInt8](repeating: 0, count: count * 4)
        let span = Float(Self.solidityGens)

        if key.story.finite {
            for i in sparseAlive {
                let ramp = Float(min(Int(sparseAge[i] ?? 0), Self.solidityGens)) / span
                rgba[i * 4] = 255
                rgba[i * 4 + 1] = UInt8((Self.solidityFloor + (1 - Self.solidityFloor) * ramp) * 255)
            }
            for (i, value) in sparseTrail where !sparseAlive.contains(i) { rgba[i * 4 + 2] = value }
        } else {
            for i in 0..<count {
                let ramp = Float(min(Int(age[i]), Self.solidityGens)) / span
                rgba[i * 4] = alive[i] != 0 ? 255 : 0
                rgba[i * 4 + 1] = UInt8((Self.solidityFloor + (1 - Self.solidityFloor) * ramp) * 255)
                rgba[i * 4 + 2] = trail[i]
            }
        }

        rgba.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, key.cols, key.rows),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: key.cols * 4)
        }
    }

    // MARK: - Noise

    private static func hash(_ x: UInt32, _ y: UInt32, _ salt: UInt32) -> Float {
        var h = x &* 0x27D4EB2D ^ y &* 0x165667B1 ^ salt &* 0x9E3779B9
        h ^= h >> 15
        h = h &* 0x2545F491
        h ^= h >> 13
        h = h &* 0x85EBCA6B
        h ^= h >> 16
        return Float(h) / Float(UInt32.max)
    }

    // MARK: - MSL

    static let metalSource = """
    // ---- lerp-data: life ---------------------------------------------------
    // Fragment texture 1: R alive, G birth solidity, B death trail.
    """
}
