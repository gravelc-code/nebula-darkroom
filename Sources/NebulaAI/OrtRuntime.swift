// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
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

    /// Loads the model on the **CPU** execution provider by default — which is
    /// bit-exact with the Python spikes and, for these GraXpert models, the right
    /// call: ORT's CoreML EP won't compile the denoise graph (Espresso broadcast
    /// error / falls back to CPU under `onlyAllowStaticInputShapes`) and is
    /// *slower* than CPU for the single-pass bge model (compile overhead). CPU
    /// denoise (~136 s/frame) is already comparable to GraXpert's own runtime, so
    /// there's little to gain. `useCoreML` is kept for a future compatible model.
    public init(modelPath: String, useCoreML: Bool = false) throws {
        env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        let options = try ORTSessionOptions()
        if useCoreML && ORTIsCoreMLExecutionProviderAvailable() {
            try options.appendCoreMLExecutionProvider(with: ORTCoreMLExecutionProviderOptions())
        }
        session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        inputName = try session.inputNames().first ?? "gen_input_image"
        outputName = try session.outputNames().first ?? "output"
    }

    /// Run one float tensor (row-major, `shape`) and return the first output flat.
    ///
    /// The output is vetted before anyone indexes it: it must be a float32
    /// tensor whose byte length matches its shape, and — when the caller knows
    /// what the model should produce — exactly `expectedCount` values. A model
    /// that answers in fp16/uint8 or a different shape (a newer GraXpert release,
    /// a wrong file) then becomes a descriptive, catchable error instead of an
    /// out-of-range trap in the caller's loops.
    public func run(_ input: [Float], shape: [Int], expectedCount: Int? = nil) throws -> [Float] {
        let data = input.withUnsafeBufferPointer {
            NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.stride)
        }
        let tensor = try ORTValue(tensorData: data, elementType: .float,
                                  shape: shape.map { NSNumber(value: $0) })
        let outputs = try session.run(withInputs: [inputName: tensor],
                                      outputNames: [outputName], runOptions: nil)
        guard let out = outputs[outputName] else {
            throw AIError.unexpectedOutput("missing output '\(outputName)'")
        }
        let info: ORTTensorTypeAndShapeInfo
        do { info = try out.tensorTypeAndShapeInfo() } catch {
            // The ObjC binding only maps float/int/uint/string; fp16 & co. throw here.
            throw AIError.unexpectedOutput(
                "output '\(outputName)' has an element type Nebula can't read (expected float32): "
                + error.localizedDescription)
        }
        guard info.elementType == .float else {
            throw AIError.unexpectedOutput(
                "output '\(outputName)' is \(Self.name(of: info.elementType)), expected float32")
        }
        let dims = info.shape.map(\.intValue)
        let count = dims.reduce(1, *)
        if let expectedCount, count != expectedCount {
            throw AIError.unexpectedOutput(
                "output '\(outputName)' has shape \(dims) (\(count) values), expected \(expectedCount) "
                + "for input shape \(shape)")
        }
        let outData = try out.tensorData() as Data
        guard outData.count == count * MemoryLayout<Float>.stride else {
            throw AIError.unexpectedOutput(
                "output '\(outputName)' holds \(outData.count) bytes for shape \(dims)")
        }
        return outData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private static func name(of type: ORTTensorElementDataType) -> String {
        switch type {
        case .float: return "float32"
        case .int8: return "int8"
        case .uInt8: return "uint8"
        case .int32: return "int32"
        case .uInt32: return "uint32"
        case .int64: return "int64"
        case .uInt64: return "uint64"
        case .string: return "string"
        case .undefined: return "undefined"
        @unknown default: return "element type \(type.rawValue)"
        }
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
