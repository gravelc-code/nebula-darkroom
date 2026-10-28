// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaBake
import NebulaEngine

/// What the user is told when something goes wrong — the single place errors
/// become words. Titles and bodies are plain language (no file formats, tool
/// names or internal stage names; there's a test for that). The technical text
/// stays available under "Details" for bug reports.
struct UserMessage: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Offer to watch this folder (a parent of several `…_sub` folders).
        case watch(URL)
    }

    var title: String
    var body: String
    /// Technical description for bug reports; shown only on request.
    var details: String?
    /// Where the failed develop's logs were kept, if anywhere.
    var logsFolder: URL?
    var action: Action?

    /// The raw technical text for `details`.
    static func technical(_ error: any Error) -> String { String(describing: error) }
}

// MARK: - Opening

extension UserMessage {
    static func notAFolder(_ name: String) -> UserMessage {
        UserMessage(title: "That’s not a folder",
                    body: "“\(name)” is a file. Choose the folder your Seestar saved its "
                        + "frames in — its name ends in “_sub”.")
    }

    static func nothingToDevelop(in name: String) -> UserMessage {
        UserMessage(title: "Nothing to develop here",
                    body: "“\(name)” doesn’t contain any telescope frames. Choose the folder "
                        + "whose name ends in “_sub” — that’s where your Seestar keeps each frame.")
    }

    /// The user picked a folder that holds several captures.
    static func chooseOneSubFolder(in parent: URL, names: [String]) -> UserMessage {
        let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? "…" : "")
        return UserMessage(
            title: "Choose one of the “…_sub” folders",
            body: "“\(parent.lastPathComponent)” holds \(names.count) captures (\(shown)). "
                + "Open one of its “…_sub” folders to develop it — or watch this folder and "
                + "Nebula will develop each capture automatically.",
            action: .watch(parent))
    }

    static func cantOpen(_ name: String, error: any Error) -> UserMessage {
        UserMessage(title: "“\(name)” couldn’t be opened",
                    body: "Its files may be damaged or incomplete. Develop the folder again "
                        + "to rebuild it.",
                    details: technical(error))
    }

    static func engineUnavailable(_ error: (any Error)?) -> UserMessage {
        UserMessage(title: "Nebula can’t show images on this Mac",
                    body: "The graphics system couldn’t be started. Quit and reopen Nebula; "
                        + "if this keeps happening, check for a macOS update.",
                    details: error.map(technical))
    }
}

// MARK: - Developing

extension UserMessage {
    /// Broad reasons a develop fails, as far as the user can act on them.
    enum Cause: Equatable, Sendable {
        case noFrames, couldNotCombine, tookTooLong, partMissing, unreadableFrames
        case framesUnavailable, noPermission, diskFull, unknown
    }

    static func cause(of error: any Error) -> Cause {
        if let failure = error as? BakeFailure { return cause(of: failure.error) }
        if let siril = error as? SirilStage.SirilError {
            if case .notFound = siril { return .partMissing }
            if case .timedOut = siril { return .tookTooLong }
            if case .noMaster(let why) = siril {
                let w = why.lowercased()
                if w.contains("no fits light") { return .noFrames }
                if w.contains("timed out") || w.contains("timeout") { return .tookTooLong }
                return .couldNotCombine
            }
            return .couldNotCombine
        }
        if error is FITSImage.FITSError { return .unreadableFrames }
        if let cause = fileSystemCause(error as NSError) { return cause }
        let text = String(describing: error).lowercased()
        if text.contains("timed out") || text.contains("timeout") { return .tookTooLong }
        return .unknown
    }

    private static func fileSystemCause(_ ns: NSError) -> Cause? {
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return .diskFull
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .framesUnavailable
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError,
                 NSFileWriteVolumeReadOnlyError: return .noPermission
            case NSFileReadCorruptFileError: return .unreadableFrames
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case ENOSPC, EDQUOT: return .diskFull
            case ENOENT, ENOTCONN, EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ETIMEDOUT, ESTALE:
                return .framesUnavailable
            case EACCES, EPERM, EROFS: return .noPermission
            default: break
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return fileSystemCause(underlying)
        }
        return nil
    }

    static func developFailed(_ failure: BakeFailure) -> UserMessage {
        var m: UserMessage
        switch (failure.stage, cause(of: failure.error)) {
        case (_, .diskFull):
            m = UserMessage(title: "Your Mac is out of space",
                            body: "Developing needs several gigabytes of free space. Free up some "
                                + "space, then try again.")
        case (.noLayers, _):
            m = UserMessage(title: "Developing stopped before the image was finished",
                            body: "Something went wrong part-way through. Try again; if it keeps "
                                + "happening, copy the details below into a bug report.")
        case (.save, _), (.prepare, _):
            m = UserMessage(title: "The finished image couldn’t be saved",
                            body: "Nebula couldn’t write to its image library. Check that your Mac "
                                + "has free space, then try again.")
        case (_, .noFrames):
            m = UserMessage(title: "No frames to develop",
                            body: "This folder doesn’t contain any telescope frames Nebula can use. "
                                + "Choose the folder whose name ends in “_sub” — that’s where your "
                                + "Seestar keeps each frame.")
        case (_, .couldNotCombine):
            m = UserMessage(title: "Your frames couldn’t be combined",
                            body: "Nebula couldn’t line up the frames in this folder. That usually "
                                + "means too few usable frames — clouds, dew or a very short "
                                + "session. Try a folder with more frames.")
        case (_, .tookTooLong):
            m = UserMessage(title: "Developing took too long",
                            body: "Combining your frames didn’t finish in time and was stopped. "
                                + "Very large folders take a while — close other apps and try again.")
        case (_, .partMissing):
            m = UserMessage(title: "Part of Nebula is missing",
                            body: "Nebula’s stacking component couldn’t be found. Reinstall Nebula, "
                                + "then try again.")
        case (_, .unreadableFrames):
            m = UserMessage(title: "Some frames couldn’t be read",
                            body: "One or more files may be damaged or still copying. Wait for any "
                                + "copy to finish, then try again.")
        case (_, .framesUnavailable):
            m = UserMessage(title: "The frames went missing",
                            body: "Nebula lost access to the frames while developing. If they’re on "
                                + "your Seestar or a network drive, check it’s still connected, "
                                + "then try again.")
        case (_, .noPermission):
            m = UserMessage(title: "Nebula can’t read this folder",
                            body: "macOS didn’t allow Nebula to open these files. Check the folder’s "
                                + "permissions, or copy it into your Pictures folder, then try again.")
        case (_, .unknown):
            m = UserMessage(title: "Couldn’t develop this folder",
                            body: "Something went wrong while developing. Try again; if it keeps "
                                + "happening, copy the details below into a bug report.")
        }
        m.details = failure.description
        m.logsFolder = failure.logsFolder
        return m
    }
}

// MARK: - Export & Enhance

extension UserMessage {
    static let nothingToExport = UserMessage(title: "Nothing to save yet",
                                             body: "Open an image first.")

    static let enhanceUnavailable = UserMessage(
        title: "Enhance isn’t available",
        body: "The detail-enhancement add-on isn’t installed with this copy of Nebula.")

    static func exportFailed(_ error: any Error) -> UserMessage {
        let body: String
        switch cause(of: error) {
        case .diskFull:
            body = "There isn’t enough free space to save it. Free up some space, or choose "
                + "another drive."
        case .noPermission:
            body = "Nebula isn’t allowed to save there. Choose another folder."
        case .framesUnavailable:
            body = "The folder you chose is no longer available. Choose another folder."
        default:
            body = "Something went wrong while saving. Try again, or choose another folder."
        }
        return UserMessage(title: "Couldn’t save the image", body: body, details: technical(error))
    }

    static func enhanceFailed(_ error: any Error) -> UserMessage {
        UserMessage(title: "Couldn’t enhance this image",
                    body: "The detail enhancement stopped unexpectedly. Your image is unchanged — "
                        + "try again.",
                    details: technical(error))
    }
}
