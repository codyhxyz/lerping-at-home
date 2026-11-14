import Foundation
import Metal

enum NeuralCASelfTest {
    static func run() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
        let sim = NeuralCAData(device: device)
        guard let simulation = sim.simulation else { fatalError("NCA compilation failed") }
        let bytesPerRow = 96 * 16
        let planeLength = bytesPerRow * 96
        let length = planeLength * 4
        func read(_ target: Int, damage: Bool) -> [Float] {
            let key = LerpGPUSimulation.Key(seed: 0.37, epoch: 0, width: 96, height: 96, config: [damage ? 1 : 0])
            guard let cb = queue.makeCommandBuffer(), let textures = simulation.advance(cb, to: target, of: key),
                  let buffer = device.makeBuffer(length: length, options: .storageModeShared), let blit = cb.makeBlitCommandEncoder() else { fatalError("allocation failed") }
            for i in 0..<4 {
                blit.copy(from: textures[i], sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: 96, height: 96, depth: 1), to: buffer, destinationOffset: i * planeLength, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: planeLength)
            }
            blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            guard cb.status == .completed else { fatalError("GPU: \(String(describing: cb.error))") }
            if target == 500 { print("GPU time to generation 500: \(cb.gpuEndTime - cb.gpuStartTime)s (includes any prior cached generations)") }
            return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: Float.self, capacity: length / 4), count: length / 4))
        }
        func mass(_ a: [Float]) -> Double { stride(from: 3, to: planeLength / 4, by: 4).reduce(0) { $0 + Double(max(0, min(1, a[$1]))) } }
        func distance(_ a: [Float], _ b: [Float]) -> Double { stride(from: 3, to: planeLength / 4, by: 4).reduce(0) { $0 + Double(abs(a[$1] - b[$1])) } }
        let seed = read(0, damage: true)
        let growth = read(300, damage: true)
        let before = read(319, damage: true)
        let wounded = read(320, damage: true)
        let recovery = read(500, damage: true)
        let cold = read(500, damage: false) // change key, forcing a cold replay
        let replay = read(500, damage: true)
        guard recovery == replay else { fatalError("cold and incremental replay differ") }
        _ = read(530, damage: true)
        let backwards = read(500, damage: true)
        guard recovery == backwards else { fatalError("backward scrub differs") }
        let control320 = read(320, damage: false)
        let control500 = read(500, damage: false)
        let d0 = distance(wounded, control320), d1 = distance(recovery, control500)
        print("seed mass=\(mass(seed)) growth=\(mass(growth)) pre=\(mass(before)) wounded=\(mass(wounded)) recovered=\(mass(recovery)) control=\(mass(cold))")
        print("damage alpha L1: immediately=\(d0), 180 steps later=\(d1)")
        guard mass(growth) > mass(seed) * 10 else { fatalError("no measurable growth") }
        guard d0 > 1 else { fatalError("damage produced no measurable change") }
        guard d1 < d0 else { fatalError("no measurable recovery against undamaged control") }
        print("OK deterministic cold/incremental/backward replay, growth and damage response")
    }
}
