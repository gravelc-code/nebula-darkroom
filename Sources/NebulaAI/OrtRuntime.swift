import Foundation
import OnnxRuntimeBindings

/// Phase 2: the seam that will run GraXpert's models in-process via onnxruntime,
/// replacing the GraXpert subprocess. This first cut is a probe — it loads a
/// model and reports its I/O — to prove ORT links and runs from Swift before the
/// full denoise / background-extraction pipelines are ported.
public enum OrtRuntime {
    public struct ModelInfo {
        public let inputs: [String]
        public let outputs: [String]
    }

    /// Load a model and read its input/output names — a minimal end-to-end check
    /// that the runtime is wired up correctly.
    public static func probe(modelPath: String) throws -> ModelInfo {
        let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: nil)
        return ModelInfo(inputs: try session.inputNames(),
                         outputs: try session.outputNames())
    }

    /// Run a single float tensor through a model — the primitive the denoise /
    /// background pipelines are built on. `input` is row-major with `shape`;
    /// returns the first output as a flat `[Float]`.
    public static func run(modelPath: String, inputName: String, outputName: String,
                           input: [Float], shape: [Int]) throws -> [Float] {
        let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: nil)

        let data = input.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.stride) }
        let tensor = try ORTValue(tensorData: data,
                                  elementType: .float,
                                  shape: shape.map { NSNumber(value: $0) })
        let outputs = try session.run(withInputs: [inputName: tensor],
                                      outputNames: [outputName],
                                      runOptions: nil)
        guard let out = outputs[outputName] else {
            throw NSError(domain: "NebulaAI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing output \(outputName)"])
        }
        let outData = try out.tensorData() as Data
        return outData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}
