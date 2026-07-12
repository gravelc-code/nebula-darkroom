// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import UserNotifications

/// Watch-mode notifications (design §6): when a target auto-develops, post a
/// local notification with its thumbnail. Guarded by a bundle identifier —
/// `UNUserNotificationCenter` requires a real app bundle, so this safely no-ops
/// in the bare `swift run` executable and works in the packaged `Nebula.app`.
enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func developed(_ name: String, thumbURL: URL?) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Developed \(name)"
        content.body = "Tap to open it in Nebula."
        content.sound = .default
        if let t = thumbURL, FileManager.default.fileExists(atPath: t.path),
           let attachment = try? UNNotificationAttachment(identifier: "thumb", url: t, options: nil) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(
            identifier: "developed-\(name)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
