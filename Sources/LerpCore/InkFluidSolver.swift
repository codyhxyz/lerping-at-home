import Foundation

/// The simulation behind `ink-fluid`: Jos Stam's stable-fluids solver from
/// "Real-Time Fluid Dynamics for Games" (GDC 2003), written from the paper,
/// with three advected dyes and a seeded, scripted stir standing in for the
/// mouse.
///
/// This type knows nothing about Metal, time or parameters-as-UI. It is a grid,
/// a deterministic `advance()`, and the fields a renderer reads — so a GPU
/// compute path can replace it without touching how `InkFluidData` keys,
/// caches and uploads.
///
/// **Units.** Everything is in cells and steps: one step is the paper's `dt`,
/// one cell is its `h`, so the paper's `dt0 = dt * N` is 1 and its diffusion
/// coefficient `a = dt * diff * N * N` is simply `settings.viscosity`.
/// Velocities are cells per step.
///
/// **Grid.** `width × height` interior cells plus the paper's one-cell border,
/// stored row-major with a row stride of `width + 2`. The border holds the
/// paper's `set_bnd` reflections: a closed tank whose walls stop the normal
/// component of the flow.
///
/// **Determinism.** `advance()` is a pure function of the state it is given
/// and of `(width, height, seed, settings)`; the stir is scheduled by step
/// index from a splitmix64 stream, never by wall clock. The linear solves are
/// red-black Gauss–Seidel rather than the paper's lexicographic sweep: each
/// half-sweep updates cells that read only the other colour, so the result does
/// not depend on visiting order — which keeps the door open to splitting rows
/// across threads (or a compute grid) without changing a single bit.
public final class InkFluidSolver {

    public struct Settings: Hashable, Sendable {
        /// The paper's `a` for velocity diffusion, cells² per step.
        public var viscosity: Float
        /// Scales every scripted force: the drops' jets and the ambient swirl.
        public var stir: Float
        /// Vorticity-confinement strength (Fedkiw, Stam & Jensen 2001).
        public var vorticity: Float

        public init(viscosity: Float, stir: Float, vorticity: Float) {
            self.viscosity = viscosity
            self.stir = stir
            self.vorticity = vorticity
        }
    }

    public static let dyeCount = 3

    // MARK: - Tunables

    /// Red-black Gauss–Seidel iterations. The paper uses 20 lexicographic
    /// sweeps; red-black converges about as fast, and pressure is warm-started
    /// from the previous solve, which a slowly stirred tank rewards. The paper
    /// projects twice — before advection, so velocity carries itself along a
    /// mass-conserving field, and after, for the field the dyes ride. Only the
    /// second is what the picture shows, so the first gets fewer sweeps.
    static let diffuseIterations = 4
    static let preAdvectPressureIterations = 8
    static let pressureIterations = 14
    /// Width of the dye-absorbing band along the walls, in cells at the
    /// 160-cell grid, and the most it removes per step at the wall itself.
    static let spongeCells: Float = 7
    static let spongeStrength: Float = 0.015
    /// Fixed row bands for the advection passes (see `forEachRowBand`).
    static let rowBands = 4
    /// Linear drag on the flow, per step. Stands in for the tank floor and
    /// keeps the ambient swirl from pumping energy in without bound.
    static let velocityKeep: Float = 0.996
    /// Dye fade per step; ~50 s half-life, so ink lingers, but the tank still
    /// clears before the epoch ends (see `dyeKeep(at:)`).
    static let dyeKeepBase: Float = 0.9993

    // MARK: - Geometry and state

    public let width: Int
    public let height: Int
    public let settings: Settings
    /// Steps taken since the seeded initial (empty, still) tank.
    public private(set) var step = 0

    let rowStride: Int
    let count: Int
    /// Steps in one reseeded story; the provider's epoch. The stir schedules
    /// itself inside it and the tank clears towards its end.
    public let epochSteps: Int

    private(set) var u: UnsafeMutablePointer<Float>
    private(set) var v: UnsafeMutablePointer<Float>
    private var uPrev: UnsafeMutablePointer<Float>
    private var vPrev: UnsafeMutablePointer<Float>
    private var pressure: UnsafeMutablePointer<Float>
    private var divergence: UnsafeMutablePointer<Float>
    private var curl: UnsafeMutablePointer<Float>
    private let solveScratch: UnsafeMutablePointer<Float>
    private(set) var dye: [UnsafeMutablePointer<Float>]
    private var dyePrev: [UnsafeMutablePointer<Float>]

    private let plan: StirPlan
    /// Per-step sine tables for the ambient swirl (see `addSwirl`).
    private let swirlTable: UnsafeMutablePointer<Float>
    /// Per cell, all ones where it is an interior cell of colour 0 / colour 1.
    private let colourMask: [UnsafeMutablePointer<UInt32>]
    /// Per cell, the extra dye kept per step: 1 in open water, less within
    /// `spongeCells` of a wall.
    private let sponge: UnsafeMutablePointer<Float>

    public init(width: Int, height: Int, seed: UInt64, epochSteps: Int, settings: Settings) {
        self.width = max(8, width)
        self.height = max(8, height)
        self.settings = settings
        self.epochSteps = max(1, epochSteps)
        let gridWidth = self.width, gridHeight = self.height
        let cells = (gridWidth + 2) * (gridHeight + 2)
        rowStride = self.width + 2
        count = cells

        func field() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: cells)
            p.initialize(repeating: 0, count: cells)
            return p
        }
        u = field(); v = field(); uPrev = field(); vPrev = field()
        pressure = field(); divergence = field(); curl = field(); solveScratch = field()
        dye = (0..<Self.dyeCount).map { _ in field() }
        dyePrev = (0..<Self.dyeCount).map { _ in field() }
        colourMask = (0..<2).map { colour in
            let m = UnsafeMutablePointer<UInt32>.allocate(capacity: cells)
            m.initialize(repeating: 0, count: cells)
            for j in 1...gridHeight { for i in 1...gridWidth where (i + j + colour) & 1 == 0 {
                m[i + (gridWidth + 2) * j] = .max
            } }
            return m
        }
        sponge = UnsafeMutablePointer<Float>.allocate(capacity: cells)
        sponge.initialize(repeating: 1, count: cells)
        let band = Self.spongeCells * Float(max(gridWidth, gridHeight)) / 160
        for j in 1...gridHeight {
            for i in 1...gridWidth {
                let edge = Float(min(i - 1, j - 1, gridWidth - i, gridHeight - j))
                let x = max(0, 1 - edge / band)
                sponge[i + (gridWidth + 2) * j] = 1 - Self.spongeStrength * x * x
            }
        }
        let tableSize = StirPlan.swirlTerms * 2 * ((gridWidth + 2) + (gridHeight + 2))
        swirlTable = UnsafeMutablePointer<Float>.allocate(capacity: tableSize)
        swirlTable.initialize(repeating: 0, count: tableSize)
        plan = StirPlan(width: self.width, height: self.height,
                        epochSteps: self.epochSteps, seed: seed)
    }

    deinit {
        for p in [u, v, uPrev, vPrev, pressure, divergence, curl, solveScratch] + dye + dyePrev {
            p.deallocate()
        }
        colourMask.forEach { $0.deallocate() }
        sponge.deallocate()
        swirlTable.deallocate()
    }

    @inline(__always) func index(_ i: Int, _ j: Int) -> Int { i + rowStride * j }

    // MARK: - One step

    /// The paper's `vel_step` then `dens_step`, with forces from the stir plan
    /// and vorticity confinement added at the start, as the paper adds its
    /// sources.
    public func advance() {
        let s = settings

        // Sources: the scripted stir, then confinement's curl-sharpening push.
        plan.apply(step: step, stir: s.stir, solver: self)
        if s.vorticity > 0 { confineVorticity(s.vorticity) }

        // vel_step: diffuse, project, advect, project.
        if s.viscosity > 0 {
            swap(&u, &uPrev); swap(&v, &vPrev)
            u.update(from: uPrev, count: count)   // initial guess: the undiffused flow
            v.update(from: vPrev, count: count)
            linearSolve(boundary: 1, x: u, x0: uPrev, a: s.viscosity, c: 1 + 4 * s.viscosity,
                        iterations: Self.diffuseIterations)
            linearSolve(boundary: 2, x: v, x0: vPrev, a: s.viscosity, c: 1 + 4 * s.viscosity,
                        iterations: Self.diffuseIterations)
        }
        project(iterations: Self.preAdvectPressureIterations)
        swap(&u, &uPrev); swap(&v, &vPrev)
        advectVelocity()
        project(iterations: Self.pressureIterations)

        // dens_step, for each dye: advect through the new flow, then fade.
        // (The paper also diffuses density; semi-Lagrangian advection already
        // blurs at this grid size, so the dyes skip that solve.)
        for k in 0..<Self.dyeCount { swap(&dye[k], &dyePrev[k]) }
        advectDyes(keep: dyeKeep(at: step))

        step += 1
    }

    /// The fade is constant for most of the story and steepens over its last
    /// fifth, so every epoch ends on clear water and the reseed is invisible.
    func dyeKeep(at step: Int) -> Float {
        let phase = Float(step) / Float(epochSteps)
        let x = min(1, max(0, (phase - 0.80) / 0.20))
        let ramp = x * x * (3 - 2 * x)
        return Self.dyeKeepBase - 0.035 * ramp
    }

    // MARK: - Paper routines

    /// `set_bnd`: the border mirrors the first interior cell, negated for the
    /// velocity component normal to that wall (b = 1 for u at the side walls,
    /// b = 2 for v at the top and bottom).
    private func setBoundary(_ b: Int, _ x: UnsafeMutablePointer<Float>) {
        let w = width, h = height
        for i in 1...w {
            x[index(i, 0)]     = b == 2 ? -x[index(i, 1)] : x[index(i, 1)]
            x[index(i, h + 1)] = b == 2 ? -x[index(i, h)] : x[index(i, h)]
        }
        for j in 1...h {
            x[index(0, j)]     = b == 1 ? -x[index(1, j)] : x[index(1, j)]
            x[index(w + 1, j)] = b == 1 ? -x[index(w, j)] : x[index(w, j)]
        }
        x[index(0, 0)]         = 0.5 * (x[index(1, 0)] + x[index(0, 1)])
        x[index(0, h + 1)]     = 0.5 * (x[index(1, h + 1)] + x[index(0, h)])
        x[index(w + 1, 0)]     = 0.5 * (x[index(w, 0)] + x[index(w + 1, 1)])
        x[index(w + 1, h + 1)] = 0.5 * (x[index(w, h + 1)] + x[index(w + 1, h)])
    }

    /// `lin_solve`: x = (x0 + a · Σneighbours) / c, red cells then black.
    ///
    /// Vectorised over the flat array eight cells at a time. Within one
    /// colour's half-sweep a cell reads only cells of the other colour, which
    /// that half-sweep never changes, so computing every lane and keeping only
    /// this colour's interior cells (`colourMask`) is exactly the scalar
    /// sweep — same operations per cell, same bits, any visiting order. Each
    /// half-sweep writes the other buffer of a pair rather than in place: the
    /// values are identical, and it avoids overlapping unaligned stores that
    /// the next vector's loads would otherwise stall on.
    private func linearSolve(boundary b: Int, x: UnsafeMutablePointer<Float>,
                             x0: UnsafeMutablePointer<Float>, a: Float, c: Float,
                             iterations: Int) {
        let n = rowStride
        let first = n + 1, last = count - n - 2      // cells (1, 1) … (w, h)
        let inverse = 1 / c
        let tail = count - last - 1
        for _ in 0..<iterations {
            // The cells outside [first, last] are border; half-sweeps never
            // write them, so the scratch buffer needs x's current copy.
            solveScratch.update(from: x, count: first)
            (solveScratch + last + 1).update(from: x + last + 1, count: tail)
            halfSweep(from: x, to: solveScratch, x0: x0, mask: colourMask[0],
                      a: a, inverse: inverse, first: first, last: last)
            halfSweep(from: solveScratch, to: x, x0: x0, mask: colourMask[1],
                      a: a, inverse: inverse, first: first, last: last)
            setBoundary(b, x)
        }
    }

    @inline(__always)
    private func halfSweep(from src: UnsafeMutablePointer<Float>,
                           to dst: UnsafeMutablePointer<Float>,
                           x0: UnsafeMutablePointer<Float>, mask: UnsafeMutablePointer<UInt32>,
                           a: Float, inverse: Float, first: Int, last: Int) {
        let n = rowStride
        let va = SIMD8<Float>(repeating: a), vInverse = SIMD8<Float>(repeating: inverse)
        let s = UnsafeRawPointer(src), d = UnsafeMutableRawPointer(dst)
        let s0 = UnsafeRawPointer(x0), m = UnsafeRawPointer(mask)
        let stride = MemoryLayout<Float>.stride
        let row = n &* stride
        var k = first
        while k &+ 8 <= last &+ 1 {
            let o = k &* stride
            let left   = s.loadUnaligned(fromByteOffset: o &- stride, as: SIMD8<Float>.self)
            let right  = s.loadUnaligned(fromByteOffset: o &+ stride, as: SIMD8<Float>.self)
            let down   = s.loadUnaligned(fromByteOffset: o &- row, as: SIMD8<Float>.self)
            let up     = s.loadUnaligned(fromByteOffset: o &+ row, as: SIMD8<Float>.self)
            let here   = s.loadUnaligned(fromByteOffset: o, as: SIMD8<UInt32>.self)
            let source = s0.loadUnaligned(fromByteOffset: o, as: SIMD8<Float>.self)
            let keep   = m.loadUnaligned(fromByteOffset: o, as: SIMD8<UInt32>.self)
            let solved = (source + va * (((left + right) + down) + up)) * vInverse
            let blended = (unsafeBitCast(solved, to: SIMD8<UInt32>.self) & keep) | (here & ~keep)
            d.storeBytes(of: blended, toByteOffset: o, as: SIMD8<UInt32>.self)
            k &+= 8
        }
        while k <= last {
            dst[k] = mask[k] != 0
                ? (x0[k] + a * (((src[k &- 1] + src[k &+ 1]) + src[k &- n]) + src[k &+ n])) * inverse
                : src[k]
            k &+= 1
        }
    }

    /// `project`: subtract the gradient of the pressure that makes the flow
    /// divergence-free (Hodge decomposition, as the paper explains).
    private func project(iterations: Int) {
        let w = width, h = height, n = rowStride
        for j in 1...h {
            for i in 1...w {
                let k = i + n * j
                divergence[k] = -0.5 * (u[k + 1] - u[k - 1] + v[k + n] - v[k - n])
            }
        }
        setBoundary(0, divergence)
        setBoundary(0, pressure)
        linearSolve(boundary: 0, x: pressure, x0: divergence, a: 1, c: 4,
                    iterations: iterations)
        for j in 1...h {
            for i in 1...w {
                let k = i + n * j
                u[k] -= 0.5 * (pressure[k + 1] - pressure[k - 1])
                v[k] -= 0.5 * (pressure[k + n] - pressure[k - n])
            }
        }
        setBoundary(1, u)
        setBoundary(2, v)
    }

    /// One semi-Lagrangian backtrace: where the fluid now in cell (i, j) was a
    /// step ago, clamped inside the tank as in the paper, as the four source
    /// cells and their bilinear weights.
    @inline(__always)
    private func backtrace(_ i: Int, _ j: Int, _ k: Int,
                           through du: UnsafeMutablePointer<Float>,
                           _ dv: UnsafeMutablePointer<Float>)
        -> (k00: Int, s0: Float, s1: Float, t0: Float, t1: Float) {
        let maxX = Float(width) + 0.5, maxY = Float(height) + 0.5
        let x = min(maxX, max(0.5, Float(i) - du[k]))
        let y = min(maxY, max(0.5, Float(j) - dv[k]))
        let i0 = Int(x), j0 = Int(y)
        let s1 = x - Float(i0), t1 = y - Float(j0)
        return (i0 + rowStride * j0, 1 - s1, s1, 1 - t1, t1)
    }

    @inline(__always)
    private func sample(_ d: UnsafeMutablePointer<Float>,
                        _ b: (k00: Int, s0: Float, s1: Float, t0: Float, t1: Float)) -> Float {
        let k = b.k00, n = rowStride
        return b.s0 * (b.t0 * d[k] + b.t1 * d[k + n])
             + b.s1 * (b.t0 * d[k + 1] + b.t1 * d[k + 1 + n])
    }

    /// `advect` for both velocity components, which share one backtrace
    /// through the previous flow — the paper's self-advection of velocity.
    private func advectVelocity() {
        let w = width, n = rowStride
        let keep = Self.velocityKeep
        let u = u, v = v, u0 = uPrev, v0 = vPrev
        forEachRowBand { rows in
            for j in rows {
                for i in 1...w {
                    let k = i + n * j
                    let b = backtrace(i, j, k, through: u0, v0)
                    u[k] = keep * sample(u0, b)
                    v[k] = keep * sample(v0, b)
                }
            }
        }
        setBoundary(1, u)
        setBoundary(2, v)
    }

    /// `advect` for every dye through the projected flow, one backtrace each.
    /// Near the walls the dye also soaks away (`sponge`), so ink swept to the
    /// edge thins out instead of tracing the tank's outline.
    private func advectDyes(keep: Float) {
        let w = width, n = rowStride
        let u = u, v = v, sponge = sponge
        let d0 = dye[0], d1 = dye[1], d2 = dye[2]
        let p0 = dyePrev[0], p1 = dyePrev[1], p2 = dyePrev[2]
        forEachRowBand { rows in
            for j in rows {
                for i in 1...w {
                    let k = i + n * j
                    let b = backtrace(i, j, k, through: u, v)
                    let fade = keep * sponge[k]
                    d0[k] = fade * sample(p0, b)
                    d1[k] = fade * sample(p1, b)
                    d2[k] = fade * sample(p2, b)
                }
            }
        }
        for d in dye { setBoundary(0, d) }
    }

    /// Splits the interior rows into `rowBands` fixed bands and runs them
    /// concurrently. Only for out-of-place passes, where every cell is written
    /// once from inputs nobody writes — so the bands' order, and which thread
    /// takes which, cannot change a bit of the result.
    private func forEachRowBand(_ body: (ClosedRange<Int>) -> Void) {
        let h = height, bands = Self.rowBands
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let lo = 1 + band * h / bands, hi = (band + 1) * h / bands
            if lo <= hi { body(lo...hi) }
        }
    }

    /// Vorticity confinement: push along N × ω, where N points up the gradient
    /// of |ω|, putting back the small eddies that semi-Lagrangian advection
    /// smooths away. Strength is in cells per step per unit curl.
    private func confineVorticity(_ epsilon: Float) {
        let w = width, h = height, n = rowStride
        for j in 1...h {
            for i in 1...w {
                let k = i + n * j
                curl[k] = 0.5 * ((v[k + 1] - v[k - 1]) - (u[k + n] - u[k - n]))
            }
        }
        guard w > 2, h > 2 else { return }
        for j in 2...(h - 1) {
            for i in 2...(w - 1) {
                let k = i + n * j
                let gx = 0.5 * (abs(curl[k + 1]) - abs(curl[k - 1]))
                let gy = 0.5 * (abs(curl[k + n]) - abs(curl[k - n]))
                let inverse = 1 / ((gx * gx + gy * gy).squareRoot() + 1e-5)
                let omega = curl[k]
                u[k] += epsilon * gy * inverse * omega
                v[k] -= epsilon * gx * inverse * omega
            }
        }
    }

    // MARK: - Sources (used by the stir plan)

    /// Adds a Gaussian splat of force and dye centred at (cx, cy) in cell
    /// coordinates. Touches only the splat's 3σ box.
    func splat(cx: Float, cy: Float, radius: Float,
               force: SIMD2<Float>, dyeRadius: Float, dyeAmount: Float, species: Int) {
        let reach = 3 * max(radius, dyeRadius)
        let i0 = max(1, Int((cx - reach).rounded(.down)))
        let i1 = min(width, Int((cx + reach).rounded(.up)))
        let j0 = max(1, Int((cy - reach).rounded(.down)))
        let j1 = min(height, Int((cy + reach).rounded(.up)))
        guard i0 <= i1, j0 <= j1 else { return }
        let fInv = -1 / (radius * radius)
        let dInv = -1 / (dyeRadius * dyeRadius)
        let d = dye[species]
        for j in j0...j1 {
            let dy = Float(j) - cy
            for i in i0...i1 {
                let dx = Float(i) - cx
                let r2 = dx * dx + dy * dy
                let k = index(i, j)
                let wf = exp(r2 * fInv)
                u[k] += force.x * wf
                v[k] += force.y * wf
                d[k] += dyeAmount * exp(r2 * dInv)
            }
        }
    }

    /// Adds the ambient swirl: a divergence-free force, the curl of a stream
    /// function built from a few separable sine products.
    func addSwirl(_ terms: [StirPlan.SwirlTerm], step: Int, amplitude: Float) {
        guard amplitude != 0 else { return }
        precondition(terms.count == StirPlan.swirlTerms)
        let w = width, h = height, n = rowStride
        let t = Float(step)
        // Per term: sin and cos along x (scaled into the force), then along y.
        // ψ = s · sin(kx x + α) sin(ky y + β); force = (∂ψ/∂y, −∂ψ/∂x).
        let sx = swirlTable, cx = sx + 3 * n, sy = cx + 3 * n
        let cy = sy + 3 * (h + 2)
        for (m, term) in terms.enumerated() {
            let gu = amplitude * term.weight * term.ky
            let gv = -amplitude * term.weight * term.kx
            for i in 1...w {
                let a = term.kx * Float(i) + term.phaseX + term.driftX * t
                sx[m * n + i] = gu * sin(a); cx[m * n + i] = gv * cos(a)
            }
            for j in 1...h {
                let b = term.ky * Float(j) + term.phaseY + term.driftY * t
                sy[m * (h + 2) + j] = sin(b); cy[m * (h + 2) + j] = cos(b)
            }
        }
        let h2 = h + 2
        for j in 1...h {
            let c0 = cy[j], c1 = cy[h2 + j], c2 = cy[2 * h2 + j]
            let s0 = sy[j], s1 = sy[h2 + j], s2 = sy[2 * h2 + j]
            let row = n * j
            for i in 1...w {
                let k = row &+ i
                u[k] += (sx[i] * c0 + sx[n + i] * c1) + sx[2 * n + i] * c2
                v[k] += (cx[i] * s0 + cx[n + i] * s1) + cx[2 * n + i] * s2
            }
        }
    }

    // MARK: - Reading the state

    /// Interior cells only, row-major from the bottom row (j = 1) up:
    /// RGBA = the three dyes and |curl| of the current state.
    func writeDyes(into out: UnsafeMutablePointer<Float16>) {
        var o = 0
        for j in 1...height {
            for i in 1...width {
                let k = index(i, j)
                out[o]     = Float16(dye[0][k])
                out[o + 1] = Float16(dye[1][k])
                out[o + 2] = Float16(dye[2][k])
                out[o + 3] = Float16(min(64, abs(curl[k])))
                o += 4
            }
        }
    }

    /// Interior velocity, cells per step, same layout as `writeDyes`.
    func writeVelocity(into out: UnsafeMutablePointer<Float16>) {
        var o = 0
        for j in 1...height {
            for i in 1...width {
                let k = index(i, j)
                out[o] = Float16(u[k])
                out[o + 1] = Float16(v[k])
                o += 2
            }
        }
    }

    /// Order-sensitive digest of every field, for determinism checks.
    public func digest() -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for p in [u, v, pressure] + dye {
            for k in 0..<count {
                h ^= UInt64(p[k].bitPattern)
                h = h &* LerpHash.prime
            }
        }
        return h
    }
}

// MARK: - The scripted stir

/// What stands in for the mouse in the paper's demo: a handful of "drops" —
/// a dye source with a short jet behind it, which rolls up into the mushroom
/// pair of counter-rotating vortices that an ink drop makes in water — plus a
/// faint, slowly drifting large-scale swirl so the tank never stands still.
/// Fully determined by `(width, height, epochSteps, seed)`.
struct StirPlan {

    struct Drop {
        var start: Int
        var length: Int
        var x: Float, y: Float          // cells
        var direction: SIMD2<Float>     // unit
        var travel: Float               // cells the source moves while pouring
        var species: Int
        var strength: Float
    }

    struct SwirlTerm {
        var kx: Float, ky: Float
        var phaseX: Float, phaseY: Float
        var driftX: Float, driftY: Float
        var weight: Float
    }

    /// Drops per story. The first few land in quick succession so a story
    /// never opens on empty water for long; the rest are spread across the
    /// window, leaving the remainder of the story to curl, mix and clear.
    static let dropsPerEpoch = 15
    static let openingStarts = [0, 14, 34]
    static let dropWindow: ClosedRange<Float> = 0.08...0.76
    /// Drop length in steps (the provider runs 20 steps/s at speed 1).
    static let dropLength = 56
    /// Peak jet acceleration, cells per step², before `stir`.
    static let jetForce: Float = 0.14
    /// Peak dye added per step at the drop's centre.
    static let dyeRate: Float = 0.75
    /// How far, in cells at the 160-cell grid, a source travels while it
    /// pours: a moving source lays a ribbon for the jet to roll up.
    static let travel: ClosedRange<Float> = 4...18
    /// Ambient swirl acceleration scale, cells per step², before `stir`.
    static let swirlForce: Float = 0.0011
    static let swirlTerms = 3

    let drops: [Drop]
    let swirl: [SwirlTerm]
    let jetRadius: Float
    let dyeRadius: Float
    let dyeScale: Float

    init(width: Int, height: Int, epochSteps: Int, seed: UInt64) {
        var rng = LerpSplitMix64(state: seed)
        _ = rng.next()
        func unit() -> Float { Float(rng.unit()) }

        let scale = Float(max(width, height)) / 160
        jetRadius = 2.6 * scale
        dyeRadius = 2.8 * scale
        // The same drops would flood a letterbox-shaped tank: an ultrawide
        // display has half the water of a 16:10 one along the same long axis.
        dyeScale = min(1, Float(width * height) / (160 * 100))

        let firstSpecies = rng.below(InkFluidSolver.dyeCount)
        let opening = Self.openingStarts.count
        let window = Self.dropWindow
        let spacing = (window.upperBound - window.lowerBound) * Float(epochSteps)
            / Float(Self.dropsPerEpoch - opening)
        var drops: [Drop] = []
        for d in 0..<Self.dropsPerEpoch {
            let start: Int
            if d < opening {
                start = Self.openingStarts[d]
            } else {
                let slot = window.lowerBound * Float(epochSteps) + Float(d - opening) * spacing
                start = Int((slot + (unit() - 0.5) * 0.6 * spacing).rounded())
            }
            let x = (0.15 + 0.70 * unit()) * Float(width)
            let y = (0.15 + 0.70 * unit()) * Float(height)
            // Aim broadly across the tank, through its middle, with a wide
            // random swing, so plumes travel into open water.
            let toCentre = SIMD2<Float>(Float(width) * 0.5 - x, Float(height) * 0.5 - y)
            let angle = atan2(toCentre.y, toCentre.x) + (unit() - 0.5) * 2.2
            let travel = scale * (Self.travel.lowerBound
                + (Self.travel.upperBound - Self.travel.lowerBound) * unit())
            drops.append(Drop(start: start,
                              length: Int(Float(Self.dropLength) * (0.75 + 0.5 * unit())),
                              x: x, y: y,
                              direction: SIMD2<Float>(cos(angle), sin(angle)),
                              travel: travel,
                              species: (firstSpecies + d) % InkFluidSolver.dyeCount,
                              strength: 0.7 + 0.6 * unit()))
        }
        self.drops = drops

        // Swirl: three low wavenumbers over the tank, drifting in phase over
        // tens of seconds.
        var swirl: [SwirlTerm] = []
        for m in 0..<Self.swirlTerms {
            let nx = Float(1 + m) * (0.5 + unit())
            let ny = Float(1 + ((m + 1) % 3)) * (0.5 + unit())
            swirl.append(SwirlTerm(kx: .pi * nx / Float(width),
                                   ky: .pi * ny / Float(height),
                                   phaseX: 2 * .pi * unit(), phaseY: 2 * .pi * unit(),
                                   driftX: (unit() - 0.5) * 0.012,
                                   driftY: (unit() - 0.5) * 0.012,
                                   weight: (unit() < 0.5 ? -1 : 1) * Float(width) / Float(1 + m)))
        }
        self.swirl = swirl
    }

    func apply(step: Int, stir: Float, solver: InkFluidSolver) {
        for drop in drops where step >= drop.start && step < drop.start + drop.length {
            let s = (Float(step - drop.start) + 0.5) / Float(drop.length)
            let envelope = sin(.pi * s) * sin(.pi * s)
            // The jet is pushed by `stir`; the ink itself arrives regardless,
            // so stir = 0 still drops colour into a still tank.
            let along = drop.direction * (drop.travel * s)
            solver.splat(cx: drop.x + along.x, cy: drop.y + along.y, radius: jetRadius,
                         force: drop.direction * (Self.jetForce * stir * drop.strength * envelope),
                         dyeRadius: dyeRadius,
                         dyeAmount: Self.dyeRate * dyeScale * envelope * (0.6 + 0.4 * drop.strength),
                         species: drop.species)
        }
        solver.addSwirl(swirl, step: step, amplitude: Self.swirlForce * stir)
    }
}
