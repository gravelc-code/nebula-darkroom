import Foundation
import OnnxRuntimeBindings

/// A loaded ONNX model with a persistent session, so many tiles can be run
/// without reloading the (hundreds-of-MB) weights each time. This is the ORT
/// primitive the denoise / background-extraction pipelines build on.
public final class OrtModel {
    private let env: ORTEnv
    private let session: ORTSession
    public let inputName: String
    public let outputName: String

    public init(modelPath: String) throws {
        env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: nil)
        inputName = try session.inputNames().first ?? "gen_input_image"
        outputName = try session.outputNames().first ?? "output"
    }

    /// Run one float tensor (row-major, `shape`) and return the first output flat.
    public func run(_ input: [Float], shape: [Int]) throws -> [Float] {
        let data = input.withUnsafeBufferPointer {
            NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.stride)
        }
        let tensor = try ORTValue(tensorData: data, elementType: .float,
                                  shape: shape.map { NSNumber(value: $0) })
        let outputs = try session.run(withInputs: [inputName: tensor],
                                      outputNames: [outputName], runOptions: nil)
        guard let out = outputs[outputName] else {
            throw NSError(domain: "NebulaAI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing output \(outputName)"])
        }
        let outData = try out.tensorData() as Data
        return outData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Thin convenience wrappers (used by the probe).
public enum OrtRuntime {
    public struct ModelInfo { public let inputs: [String]; public let outputs: [String] }

    public static func probe(modelPath: String) throws -> ModelInfo {
        let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: nil)
        return ModelInfo(inputs: try session.inputNames(), outputs: try session.outputNames())
    }

    public static func run(modelPath: String, inputName: String, outputName: String,
                           input: [Float], shape: [Int]) throws -> [Float] {
        try OrtModel(modelPath: modelPath).run(input, shape: shape)
    }
}
