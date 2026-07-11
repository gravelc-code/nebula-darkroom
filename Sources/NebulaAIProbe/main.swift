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
