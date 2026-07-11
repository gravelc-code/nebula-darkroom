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
}
