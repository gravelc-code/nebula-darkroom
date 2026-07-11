import Foundation
import NebulaAI

// Usage: nebula-ai-probe <model.onnx>
// Proves onnxruntime links from Swift and can open a GraXpert model.
guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: nebula-ai-probe <model.onnx>\n".utf8))
    exit(2)
}
let path = CommandLine.arguments[1]
do {
    let info = try OrtRuntime.probe(modelPath: path)
    print("ORT loaded: \(path)")
    print("  inputs : \(info.inputs)")
    print("  outputs: \(info.outputs)")
} catch {
    FileHandle.standardError.write(Data("ORT probe failed: \(error)\n".utf8))
    exit(1)
}
