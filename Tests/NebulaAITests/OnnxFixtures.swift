// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// Builds tiny single-node ONNX models (hand-encoded protobuf) so the real
/// Denoiser / BgExtractor pipelines can run through onnxruntime in tests
/// without GraXpert's models, which are never bundled or downloaded.
///
/// Field numbers are from onnx/onnx.proto (ModelProto, GraphProto, NodeProto,
/// AttributeProto, ValueInfoProto, TypeProto, TensorShapeProto).
enum OnnxFixture {
    /// ONNX TensorProto.DataType values.
    enum ElemType: UInt64 { case float = 1, uint8 = 2, float16 = 10 }

    /// Identity: the model echoes its input — denoise then returns ~the input.
    static func identity() -> Data { model(op: "Identity", out: .float) }
    /// Log: NaN for negative inputs, -Inf at 0 — a model that emits non-finite values.
    static func log() -> Data { model(op: "Log", out: .float) }
    /// Cast to another element type — a model whose output isn't float32.
    static func cast(to t: ElemType) -> Data {
        model(op: "Cast", out: t, intAttribute: ("to", t.rawValue))
    }
    /// GlobalAveragePool on NHWC input → [N, 256, 1, 1]: the wrong element count.
    static func globalAveragePool() -> Data { model(op: "GlobalAveragePool", out: .float) }

    static func write(_ data: Data, named name: String) throws -> URL {
        // The fixtures are deterministic, so one shared folder (overwritten
        // atomically) serves every run instead of leaving one behind per run.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nebula-ai-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).onnx")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - protobuf encoding

    private static func varint(_ v: UInt64) -> Data {
        var v = v, d = Data()
        repeat {
            var byte = UInt8(v & 0x7f); v >>= 7
            if v != 0 { byte |= 0x80 }
            d.append(byte)
        } while v != 0
        return d
    }
    private static func key(_ field: UInt64, _ wire: UInt64) -> Data { varint(field << 3 | wire) }
    private static func int(_ field: UInt64, _ v: UInt64) -> Data { key(field, 0) + varint(v) }
    private static func bytes(_ field: UInt64, _ b: Data) -> Data { key(field, 2) + varint(UInt64(b.count)) + b }
    private static func string(_ field: UInt64, _ s: String) -> Data { bytes(field, Data(s.utf8)) }

    /// ValueInfoProto{name, type{tensor_type{elem_type, shape?}}}; symbolic dims.
    private static func valueInfo(_ name: String, _ elem: ElemType, dims: [String]?) -> Data {
        var tensor = int(1, elem.rawValue)
        if let dims {
            var shape = Data()
            for d in dims { shape += bytes(1, string(2, d)) }     // Dimension.dim_param
            tensor += bytes(2, shape)
        }
        return string(1, name) + bytes(2, bytes(1, tensor))
    }

    private static func model(op: String, out: ElemType,
                              intAttribute: (String, UInt64)? = nil) -> Data {
        var node = string(1, "gen_input_image") + string(2, "output") + string(3, "n0") + string(4, op)
        if let attr = intAttribute {
            node += bytes(5, string(1, attr.0) + int(3, attr.1) + int(20, 2))   // AttributeProto INT
        }
        let graph = bytes(1, node) + string(2, "fixture")
            + bytes(11, valueInfo("gen_input_image", .float, dims: ["N", "H", "W", "C"]))
            + bytes(12, valueInfo("output", out, dims: nil))
        return int(1, 8)                                        // ir_version 8
            + string(2, "nebula-tests")                         // producer_name
            + bytes(7, graph)
            + bytes(8, string(1, "") + int(2, 13))              // opset_import ai.onnx v13
    }
}
