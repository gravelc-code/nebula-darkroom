import Foundation
import NebulaAI

// Proves onnxruntime links and runs from Swift.
//   nebula-ai-probe <model.onnx>
//   nebula-ai-probe run <model.onnx> <inName> <outName> <in.raw> <out.raw>
//       runs a [1,256,256,3] float32 tile (raw little-endian) through the model.
let args = CommandLine.arguments

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1)
}

if args.count >= 2, args[1] == "bg" {
    // nebula-ai-probe bg <model> <in.raw> <H> <W> <C> <out.raw>
    guard args.count == 8 else {
        fail("usage: nebula-ai-probe bg <model> <in.raw> <H> <W> <C> <out.raw>")
    }
    let model = args[2], inRaw = args[3]
    guard let H = Int(args[4]), let W = Int(args[5]), let C = Int(args[6]) else { fail("bad numeric args") }
    let outRaw = args[7]
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: inRaw))
        let pixels = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        precondition(pixels.count == H * W * C, "\(pixels.count) floats, expected \(H*W*C)")
        let bg = try BgExtractor(modelPath: model)
        let out = try bg.extract(pixels: pixels, h: H, w: W, c: C, smoothing: 0)
        let outData = out.withUnsafeBufferPointer { Data(buffer: $0) }
        try outData.write(to: URL(fileURLWithPath: outRaw))
        print("bg-extracted \(H)x\(W)x\(C) -> \(outRaw)")
    } catch { fail("bg failed: \(error)") }
    exit(0)
}

if args.count >= 2, args[1] == "denoise" {
    // nebula-ai-probe denoise <model> <in.raw> <H> <W> <C> <strength> <out.raw>
    // in/out are row-major HxWxC float32 (little-endian).
    guard args.count == 9 else {
        fail("usage: nebula-ai-probe denoise <model> <in.raw> <H> <W> <C> <strength> <out.raw>")
    }
    let model = args[2], inRaw = args[3]
    guard let H = Int(args[4]), let W = Int(args[5]), let C = Int(args[6]),
          let strength = Float(args[7]) else { fail("bad numeric args") }
    let outRaw = args[8]
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: inRaw))
        let pixels = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        precondition(pixels.count == H * W * C, "\(pixels.count) floats, expected \(H*W*C)")
        let dn = try Denoiser(modelPath: model)
        let out = try dn.denoise(pixels: pixels, h: H, w: W, c: C, strength: strength)
        let outData = out.withUnsafeBufferPointer { Data(buffer: $0) }
        try outData.write(to: URL(fileURLWithPath: outRaw))
        print("denoised \(H)x\(W)x\(C) strength=\(strength) -> \(outRaw)")
    } catch { fail("denoise failed: \(error)") }
    exit(0)
}

if args.count >= 2, args[1] == "run" {
    guard args.count == 7 else {
        fail("usage: nebula-ai-probe run <model> <inName> <outName> <in.raw> <out.raw>")
    }
    let (model, inName, outName, inRaw, outRaw) = (args[2], args[3], args[4], args[5], args[6])
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: inRaw))
        let input = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let shape = [1, 256, 256, 3]
        precondition(input.count == shape.reduce(1, *), "input has \(input.count) floats, expected \(shape.reduce(1, *))")
        let output = try OrtRuntime.run(modelPath: model, inputName: inName,
                                        outputName: outName, input: input, shape: shape)
        let outData = output.withUnsafeBufferPointer { Data(buffer: $0) }
        try outData.write(to: URL(fileURLWithPath: outRaw))
        print("ran \(model): \(input.count) -> \(output.count) floats, wrote \(outRaw)")
    } catch { fail("ORT run failed: \(error)") }
    exit(0)
}

guard args.count > 1 else { fail("usage: nebula-ai-probe <model.onnx>") }
do {
    let info = try OrtRuntime.probe(modelPath: args[1])
    print("ORT loaded: \(args[1])")
    print("  inputs : \(info.inputs)")
    print("  outputs: \(info.outputs)")
} catch { fail("ORT probe failed: \(error)") }
