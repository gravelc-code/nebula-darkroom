// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import AppKit
import Foundation
import UserNotifications

/// Watch-mode notifications (design §6): when a target auto-develops, post a
/// local notification with its thumbnail; tapping it opens the target. Guarded
/// by a bundle identifier — `UNUserNotificationCenter` requires a real app
/// bundle, so this safely no-ops in the bare `swift run` executable and works
/// in the packaged `Nebula.app`.
enum Notifier {
    static let targetDirKey = "targetDir"

    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func developed(_ name: String, targetDir: URL, thumbURL: URL?) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Developed \(name)"
        content.body = "Tap to open it in Nebula."
        content.sound = .default
        content.userInfo = [targetDirKey: targetDir.path]
        // The system *moves* an attachment into its own store, so hand it a
        // copy — attaching thumb.png itself removed it from the cache.
        if let thumb = thumbURL, let copy = temporaryCopy(of: thumb),
           let attachment = try? UNNotificationAttachment(identifier: "thumb", url: copy, options: nil) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(
            identifier: "developed-\(targetDir.lastPathComponent)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// A private copy of `file` the notification system may consume.
    static func temporaryCopy(of file: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return nil }
        let dir = fm.temporaryDirectory.appendingPathComponent("nebula-notify", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("\(UUID().uuidString).\(file.pathExtension)")
        do { try fm.copyItem(at: file, to: copy) } catch { return nil }
        return copy
    }
}

/// Routes notification taps back into the app and lets banners show while
/// Nebula is frontmost (by default the system hides them then).
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    private var openTarget: ((URL) -> Void)?

    /// Install as the notification centre's delegate. Call before launch
    /// finishes so a tap that launched the app is delivered too.
    func install(openTarget: @escaping (URL) -> Void) {
        self.openTarget = openTarget
        guard Notifier.available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let path = response.notification.request.content.userInfo[Notifier.targetDirKey] as? String
        completionHandler()
        guard let path else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NotificationRouter.shared.openTarget?(URL(fileURLWithPath: path, isDirectory: true))
        }
    }
}
