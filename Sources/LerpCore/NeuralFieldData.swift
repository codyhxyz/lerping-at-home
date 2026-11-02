import Foundation
import Metal

/// CPU side of the `neural-field` shader: the weights of a tiny MLP (a CPPN,
/// compositional pattern-producing network) held in a Metal 4 `MTLTensor`,
/// which the fragment function multiplies through with Metal Performance
/// Primitives' `matmul2d` — once per pixel, on a single thread, the one
/// execution scope fragment shaders support.
///
/// **Binding on the classic encoder.** `MTLRenderCommandEncoder` has no tensor
/// setter, and a tensor taken directly as a fragment argument (`[[buffer(n)]]`)
/// is only bindable through an `MTL4ArgumentTable`. A tensor that sits *inside
/// an argument buffer* is the exception: its `gpuResourceID` is written into a
/// plain `MTLBuffer`, the buffer goes to fragment index 1 with
/// `setFragmentBuffer`, and `useResource` makes the tensor resident. So the
/// render loop stays exactly as it is.
///
/// **Purity.** The weights never change after `init`: `banks` independent
/// networks are generated from fixed seeds, and the shader picks one with
/// `u.seed`. Time, the latent walk and every `// lerp-param:` act on the
/// network's *inputs* in the shader, so a frame is a pure function of
/// (time, seed, parameters) with nothing to rewrite, cache or ring-buffer.
///
/// Layout, rank 2, extents `[width, banks * rowsPerBank]`, row-major half:
///
///     rows  0…15  layer 0, 16 inputs → 16 hidden (sin)   row = input,  column = unit
///     rows 16…31  layer 1, 16 hidden → 16 hidden (tanh)
///     rows 32…47  layer 2, 16 hidden →  4 outputs        columns 4…15 are zero
///
/// Input 15 and hidden unit 15 are held at 1 by the shader, so row 15 of each
/// layer is that layer's bias.
///
/// Only reachable on macOS 26+ with a `.metal4` GPU: the shader declares
/// `// lerp-requires: metal4`, and `ShaderLibrary.discover()` drops it
/// everywhere else, so on older systems this object is never asked to bind.
public final class NeuralFieldData: LerpDataProvider {
    static let banks = 8
    static let width = 16
    static let rowsPerBank = 48

    /// `MTLTensor`, typed loosely so the class itself needs no availability
    /// annotation and can sit in the registry on every OS the saver supports.
    private var tensor: AnyObject?
    private var argumentBuffer: MTLBuffer?

    public init(device: MTLDevice) {
        guard #available(macOS 26.0, *), device.supportsFamily(.metal4) else { return }
        let rows = Self.banks * Self.rowsPerBank
        let descriptor = MTLTensorDescriptor()
        guard let dims = MTLTensorExtents([Self.width, rows]),
              let origin = MTLTensorExtents([0, 0]),
              let strides = MTLTensorExtents([1, Self.width]) else { return }
        descriptor.dimensions = dims
        descriptor.dataType = .float16
        descriptor.usage = .render
        descriptor.storageMode = .shared
        guard let made = try? device.makeTensor(descriptor: descriptor) else { return }
        let weights = Self.weights()
        weights.withUnsafeBytes { raw in
            made.replace(sliceOrigin: origin, sliceDimensions: dims,
                         withBytes: raw.baseAddress!, strides: strides)
        }
        var id = made.gpuResourceID
        guard let buffer = device.makeBuffer(bytes: &id, length: MemoryLayout<MTLResourceID>.size,
                                             options: .storageModeShared) else { return }
        made.label = "Lerping/neural-field weights"
        buffer.label = "Lerping/neural-field arguments"
        tensor = made
        argumentBuffer = buffer
    }

    public var metalPrelude: String {
        """
        #include <metal_tensor>
        #include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>

        #define NF_BANKS \(Self.banks)
        #define NF_ROWS_PER_BANK \(Self.rowsPerBank)

        // Fragment buffer 1: an argument buffer holding the weight tensor.
        struct LerpNeuralFieldArgs {
            tensor<device half, dextents<int, 2>> weights;
        };
        """
    }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        guard #available(macOS 26.0, *),
              let tensor = tensor as? MTLTensor, let argumentBuffer else { return }
        encoder.useResource(tensor, usage: .read, stages: .fragment)
        encoder.setFragmentBuffer(argumentBuffer, offset: 0, index: 1)
    }

    /// Every bank's three layers, generated once from fixed seeds with
    /// `LerpSplitMix64`, so they are identical on every machine and launch.
    /// Layer 0 gets uniform weights and uniform phase biases — SIREN-style,
    /// since it feeds `sin` — and layer 1 Gaussian weights at a gain that
    /// keeps `tanh` out of saturation. Layer 2 is then calibrated, below.
    static func weights() -> [Float16] {
        var out = [Float16](repeating: 0, count: banks * rowsPerBank * width)
        for bank in 0..<banks {
            var rng = LerpSplitMix64(state: 0x6E65_7572_616C ^ UInt64(bank) &* LerpSplitMix64.gamma)
            func uniform(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * Float(rng.unit()) }
            func gaussian() -> Float {
                let a = max(rng.unit(), 1e-12), b = rng.unit()
                return Float((-2 * log(a)).squareRoot() * cos(2 * .pi * b))
            }
            // Rounded through Float16 as generated, so calibration sees the
            // exact weights the GPU multiplies by.
            func half(_ v: Float) -> Float { Float(Float16(v)) }
            var layers = [[Float]](repeating: [Float](repeating: 0, count: 16 * 16), count: 3)
            for row in 0..<16 { for col in 0..<16 {
                layers[0][row * 16 + col] = half(row == 15 ? uniform(-.pi, .pi) : uniform(-1, 1))
            } }
            for row in 0..<16 { for col in 0..<16 {
                layers[1][row * 16 + col] = half(row == 15 ? 0.35 * gaussian() : 0.39 * gaussian())
            } }
            for row in 0..<16 { for col in 0..<4 {
                layers[2][row * 16 + col] = row == 15 ? 0 : gaussian()
            } }
            calibrate(&layers, rng: &rng)
            let base = bank * rowsPerBank * width
            for layer in 0..<3 { for i in 0..<256 {
                out[base + layer * 256 + i] = Float16(layers[layer][i])
            } }
        }
        return out
    }

    /// Rescales each output column of layer 2 to zero mean and unit spread
    /// over a probe of the inputs the shader actually feeds the network.
    ///
    /// Raw random networks differ a lot in where their outputs sit: one bank
    /// would paint the screen almost entirely in the high colour, another
    /// would never cross zero and so draw no veins. Normalising here gives
    /// every bank the same palette balance, contour density and vein count,
    /// so `u.seed` varies the *shapes* and not the exposure.
    ///
    /// The probe mirrors `nfInputs` in `neural-field.metal` at the default
    /// detail; it only has to be representative, not exact.
    static func calibrate(_ layers: inout [[Float]], rng: inout LerpSplitMix64) {
        let samples = 4096
        var sum = [Double](repeating: 0, count: 4), sumSq = [Double](repeating: 0, count: 4)
        var x = [Float](repeating: 0, count: 16), h0 = x, h1 = x
        for _ in 0..<samples {
            let qx = Float(rng.unit() * 3.6 - 1.8), qy = Float(rng.unit() * 2.2 - 1.1)
            let t = Float(rng.unit() * 400)
            let z: [Float] = [sin(t * 0.91), sin(t * 1.27 + 1.3), sin(t * 0.67 + 2.1),
                              sin(t * 1.13 + 4.0), sin(t * 0.53 + 0.7), sin(t * 1.61 + 5.2)]
            let sx = qx * 2.0, sy = qy * 2.0, r = (sx * sx + sy * sy).squareRoot()
            x = [sx, sy, r - 0.8, sin(1.7 * sx + z[0]), cos(1.9 * sy + z[1]), sin(1.3 * (sx + sy) + z[2]),
                 z[0], z[1], z[2], z[3], z[4], z[5], sx * z[3], sy * z[4], r * z[5], 1]
            for n in 0..<15 { h0[n] = sin((0..<16).reduce(0) { $0 + x[$1] * layers[0][$1 * 16 + n] }) }
            h0[15] = 1
            for n in 0..<15 { h1[n] = tanh((0..<16).reduce(0) { $0 + h0[$1] * layers[1][$1 * 16 + n] }) }
            h1[15] = 1
            for n in 0..<4 {
                let y = Double((0..<16).reduce(0) { $0 + h1[$1] * layers[2][$1 * 16 + n] })
                sum[n] += y; sumSq[n] += y * y
            }
        }
        for n in 0..<4 {
            let mean = sum[n] / Double(samples)
            let spread = max((sumSq[n] / Double(samples) - mean * mean).squareRoot(), 1e-6)
            for row in 0..<15 { layers[2][row * 16 + n] = Float(Double(layers[2][row * 16 + n]) / spread) }
            layers[2][15 * 16 + n] = Float((Double(layers[2][15 * 16 + n]) - mean) / spread)
        }
    }
}
