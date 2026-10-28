// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaApp
@testable import NebulaBake
import NebulaEngine

/// What users read when something goes wrong is plain language — never a file
/// format, a tool's name, an internal stage or a raw Swift error.
final class UserMessageTests: XCTestCase {
    /// Words that must never reach a title or body (same spirit as the slider
    /// jargon test in NebulaCoreTests).
    private let banned = ["FITS", "fits", "Siril", "siril", "SIRIL", "StarNet", "starnet",
                          "GHS", "PCC", "SPCC", "starless", "Starless", "onnx", "ONNX", "NEBULA_",
                          "Metal", "CoreML", "NAXIS", "manifest", "superres", "SuperResolver",
                          "Error Domain", "Error(", "badHeader", "noMaster", "CancellationError",
                          ".log", "_work", "pipeline", "bake", "Bake", "/Users/", "/tmp/"]

    private var developFailures: [BakeFailure] {
        let errors: [any Error] = [
            SirilStage.SirilError.notFound,
            SirilStage.SirilError.noMaster("no FITS light frames"),
            SirilStage.SirilError.noMaster("exit 1; check subs are registrable FITS"),
            SirilStage.SirilError.noMaster("timed out after 1800 s"),
            SirilStage.SirilError.timedOut(seconds: 1260),
            FITSImage.FITSError.badHeader("missing NAXIS1"),
            FITSImage.FITSError.truncated,
            NSError(domain: "NebulaBake", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "starnet produced no output"]),
            NSError(domain: "NebulaAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "onnx session failed"]),
            CocoaError(.fileWriteOutOfSpace),
            CocoaError(.fileReadNoSuchFile),
            CocoaError(.fileReadNoPermission),
            POSIXError(.ENOSPC),
            BakeFailure.NoLayers(),
        ]
        let stages: [BakeFailure.Stage] = [.prepare, .develop, .noLayers, .save]
        return stages.flatMap { stage in
            errors.map { BakeFailure(stage: stage, error: $0,
                                     logsFolder: URL(fileURLWithPath: "/Users/x/Library/Caches/Nebula/M 42/_work")) }
        }
    }

    private var everyMessage: [UserMessage] {
        var all = developFailures.map(UserMessage.developFailed)
        let error = FITSImage.FITSError.badHeader("missing NAXIS1")
        all += [
            .notAFolder("Light_0001.fit"),
            .nothingToDevelop(in: "Stacked"),
            .chooseOneSubFolder(in: URL(fileURLWithPath: "/Volumes/Seestar/MyWorks"),
                                names: ["M 42_sub", "M 31_sub", "M 8_sub", "M 81_sub"]),
            .cantOpen("M 42", error: error),
            .engineUnavailable(NSError(domain: "MTLLibraryErrorDomain", code: 3)),
            .engineUnavailable(nil),
            .exportFailed(CocoaError(.fileWriteOutOfSpace)),
            .exportFailed(CocoaError(.fileWriteNoPermission)),
            .exportFailed(NSError(domain: "FITSImage", code: 10)),
            .enhanceFailed(NSError(domain: "NebulaAI", code: 1)),
            .enhanceUnavailable,
            .nothingToExport,
        ]
        return all
    }

    func testNoJargonReachesTheUser() {
        for message in everyMessage {
            for text in [message.title, message.body] {
                for word in banned {
                    XCTAssertFalse(text.contains(word), "“\(text)” leaks “\(word)”")
                }
                XCTAssertFalse(text.isEmpty)
            }
        }
    }

    func testTheTechnicalDetailIsKeptForBugReports() throws {
        let failure = BakeFailure(stage: .develop,
                                  error: SirilStage.SirilError.noMaster("exit 1; check subs are registrable FITS"),
                                  logsFolder: URL(fileURLWithPath: "/tmp/M 42/_work"))
        let message = UserMessage.developFailed(failure)
        let details = try XCTUnwrap(message.details)
        XCTAssertTrue(details.contains("registrable"), details)
        XCTAssertTrue(details.contains("/tmp/M 42/_work"), details)
        XCTAssertEqual(message.logsFolder?.path, "/tmp/M 42/_work")
    }

    func testTypedStackTimeoutReadsAsTookTooLong() {
        XCTAssertEqual(UserMessage.cause(of: SirilStage.SirilError.timedOut(seconds: 1260)), .tookTooLong)
    }

    func testFailuresAreToldApart() {
        func title(_ e: any Error, _ stage: BakeFailure.Stage = .develop) -> String {
            UserMessage.developFailed(BakeFailure(stage: stage, error: e)).title
        }
        let titles = [
            title(SirilStage.SirilError.noMaster("no FITS light frames")),
            title(SirilStage.SirilError.noMaster("exit 1")),
            title(SirilStage.SirilError.noMaster("Siril timed out")),
            title(SirilStage.SirilError.notFound),
            title(FITSImage.FITSError.truncated),
            title(CocoaError(.fileReadNoSuchFile)),
            title(CocoaError(.fileWriteOutOfSpace)),
            title(BakeFailure.NoLayers(), .noLayers),
        ]
        XCTAssertEqual(Set(titles).count, titles.count, "\(titles)")
        XCTAssertFalse(titles.contains("Couldn’t develop this folder"), "each has a specific title")
    }

    func testAParentFolderOffersToWatchIt() {
        let parent = URL(fileURLWithPath: "/Volumes/Seestar/MyWorks")
        let m = UserMessage.chooseOneSubFolder(in: parent, names: ["M 42_sub", "M 31_sub"])
        XCTAssertEqual(m.action, .watch(parent))
        XCTAssertTrue(m.title.contains("_sub"))
    }
}

/// Cancelling Export/Enhance must reach the work itself.
final class CancellationPropagationTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    func testCancellingTheCallerCancelsTheDetachedWork() async throws {
        let sawCancel = Flag(), started = Flag()
        let outer = Task {
            try await runDetached { () -> Int in
                started.set()
                let giveUp = Date().addingTimeInterval(10)
                while !Task.isCancelled {
                    if Date() > giveUp { return 0 }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                sawCancel.set()
                try Task.checkCancellation()
                return 1
            }
        }
        while !started.isSet { try await Task.sleep(nanoseconds: 5_000_000) }
        outer.cancel()
        do {
            _ = try await outer.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(sawCancel.isSet, "the inner work saw the cancel")
        }
    }
}
