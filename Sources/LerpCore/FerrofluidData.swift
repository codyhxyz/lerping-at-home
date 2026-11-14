import Foundation
import Metal
import os

/// An artistic heightfield, not a Rosensweig-instability solver. Its damped
/// finite-difference wave update follows the standard discrete wave equation
/// (https://hplgit.github.io/fdm-book/doc/pub/wave/html/._wave-solarized003.html).
/// Seeded, narrow forcing sites stand in for magnets; their placement and the
/// spike shaping are artistic. Epochs bound replay and viewer input never enters
/// the simulation.
public final class FerrofluidData: LerpDataProvider {
    private let simulation: LerpGPUSimulation?
    private let placeholder: MTLTexture?
    private var texture: MTLTexture?
    private var frame = Frame(ready: 0, fade: 1)
    private struct Frame { var ready: UInt32; var fade: Float }

    public init(device: MTLDevice) {
        do {
            simulation = try LerpGPUSimulation(device: device, label: "ferrofluid", source: Self.kernels,
                planes: [.init("height-velocity", pixelFormat: .rg32Float)],
                seed: [.init("ferroSeed")], step: [.init("ferroStep")])
        } catch {
            Logger(subsystem: LerpDefaults.productionModule, category: "ferrofluid").error("compute: \(error.localizedDescription)")
            simulation = nil
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        placeholder = device.makeTexture(descriptor: d)
    }
    public var metalPrelude: String { "struct LerpFerroFrame { uint ready; float fade; };" }
    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        var f = frame
        encoder.setFragmentBytes(&f, length: MemoryLayout<Frame>.size, index: 1)
        encoder.setFragmentTexture(texture ?? placeholder, index: 1)
    }
    public func encodeCompute(into commandBuffer: MTLCommandBuffer, uniforms: LerpUniforms, params: LerpParameterValues?) {
        let speed = max(0, params?["speed"]?.scalarValue.map(Float.init) ?? 1)
        let clock = max(0, uniforms.time) * speed * 2 + 50
        let epoch = Int(floor(clock / 180))
        let step = Int(clock.truncatingRemainder(dividingBy: 180))
        let aspect = min(2.5, max(0.5, uniforms.resolution.x / max(1, uniforms.resolution.y)))
        let key = LerpGPUSimulation.Key(seed: uniforms.seed, epoch: epoch,
                                        width: Int(ceil(160 * aspect)), height: 160)
        let phase = Float(step) / 180
        let fade = min(1, min(phase / 0.08, (1 - phase) / 0.08))
        if let result = simulation?.advance(commandBuffer, to: step, of: key) {
            texture = result[0]; frame = Frame(ready: 1, fade: fade)
        } else { texture = nil; frame = Frame(ready: 0, fade: 1) }
    }
    private static let kernels = """
    kernel void ferroSeed(texture2d<float, access::write> out [[texture(1)]],
                          constant LerpSimFrame& f [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if (any(p >= f.size)) return;
        out.write(float4(0), p);
    }
    kernel void ferroStep(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> out [[texture(1)]],
                          constant LerpSimFrame& f [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if (any(p >= f.size)) return;
        float2 state = src.read(p).rg;
        constexpr int2 dirs[4] = {int2(1,0), int2(-1,0), int2(0,1), int2(0,-1)};
        float lap = -4.0 * state.x;
        for (int i = 0; i < 4; ++i)
            lap += src.read(uint2(clamp(int2(p) + dirs[i], int2(0), int2(f.size)-1))).r;
        // One jittered magnet per 24-cell tile. A local 3x3 search avoids seams.
        float2 cell = floor(float2(p) / 24.0);
        float force = 0.0;
        uint salt = f.seed ^ (f.epoch * 0x9e3779b9u);
        for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
            int2 tile = int2(cell) + int2(x,y);
            uint2 id = uint2(tile);
            float2 center = (float2(tile) + 0.5 + 0.32 * (float2(lerpSimHash(id.x,id.y,salt), lerpSimHash(id.y,id.x,salt ^ 42u)) - 0.5)) * 24.0;
            float2 d = (float2(p) - center) / 3.0;
            float pulse = 0.8 + 0.2 * sin(float(f.step) * 0.055 + lerpSimHash(id.x,id.y,salt ^ 91u) * 6.28318);
            force += exp(-dot(d,d)) * pulse;
        }
        float velocity = (state.y + 0.18 * lap - 0.035 * state.x + 0.09 * force) * 0.92;
        out.write(float4(state.x + velocity, velocity, 0, 0), p);
    }
    """
}
