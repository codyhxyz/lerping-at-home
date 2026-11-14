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
        func read(_ target: Int, damage: Bool, epoch: Int = 0) -> [Float] {
            let key = LerpGPUSimulation.Key(seed: 0.37, epoch: epoch, width: 96, height: 96, config: [damage ? 1 : 0])
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
        let controlBefore = read(319, damage: false)
        guard before == controlBefore else { fatalError("wound changed state before generation 320") }
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
        // The production injury clears every channel, not only visible alpha.
        for y in 0..<96 { for x in 0..<96 where (x - 56) * (x - 56) + (y - 48) * (y - 48) < 100 {
            for plane in 0..<4 { for channel in 0..<4 {
                guard wounded[plane * planeLength / 4 + (y * 96 + x) * 4 + channel] == 0 else { fatalError("wound did not clear all channels") }
            }}
        }}
        let d0 = distance(wounded, control320), d1 = distance(recovery, control500)
        print("seed mass=\(mass(seed)) growth=\(mass(growth)) pre=\(mass(before)) wounded=\(mass(wounded)) recovered=\(mass(recovery)) control=\(mass(cold))")
        print("damage alpha L1: immediately=\(d0), 180 steps later=\(d1)")
        guard mass(growth) > mass(seed) * 10 else { fatalError("no measurable growth") }
        guard d0 > 1 else { fatalError("damage produced no measurable change") }
        guard d1 < d0 else { fatalError("no measurable recovery against undamaged control") }
        // Worst in-epoch cold replay, followed by ten one-generation live frames.
        func timedAdvance(_ target: Int, epoch: Int) -> (Double, Double) {
            let key = LerpGPUSimulation.Key(seed: 0.37, epoch: epoch, width: 96, height: 96, config: [1])
            let start = CFAbsoluteTimeGetCurrent()
            guard let cb = queue.makeCommandBuffer(), simulation.advance(cb, to: target, of: key) != nil else { fatalError("benchmark allocation") }
            cb.commit(); cb.waitUntilCompleted()
            guard cb.status == .completed else { fatalError("benchmark GPU: \(String(describing: cb.error))") }
            return (CFAbsoluteTimeGetCurrent() - start, cb.gpuEndTime - cb.gpuStartTime)
        }
        let coldWorst = timedAdvance(639, epoch: 2)
        _ = timedAdvance(0, epoch: 3)
        var liveWall = 0.0, liveGPU = 0.0
        for generation in 1...10 {
            let (wall, gpu) = timedAdvance(generation, epoch: 3)
            liveWall = max(liveWall, wall); liveGPU = max(liveGPU, gpu)
        }
        print("639-step cold wall=\(coldWorst.0)s GPU=\(coldWorst.1)s; live 1-step max wall=\(liveWall)s GPU=\(liveGPU)s (10 frames)")
        let epochWound = read(320, damage: true, epoch: 4)
        _ = read(0, damage: true, epoch: 5) // force a fresh epoch-4 replay
        let epochReplay = read(320, damage: true, epoch: 4)
        guard epochWound == epochReplay else { fatalError("epoch replay differs") }
        print("OK deterministic cold/incremental/backward replay, growth and damage response")
    }
}
