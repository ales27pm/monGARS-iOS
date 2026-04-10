import Foundation
import UserNotifications

nonisolated final class SendNotificationTool: ToolExecutable, @unchecked Sendable {
    let schema = ToolSchema(
        name: "send_notification",
        description: "Schedules a local notification to remind the user of something.",
        parameters: [
            ToolParameter(name: "title", description: "Notification title", type: .string, required: true),
            ToolParameter(name: "body", description: "Notification body text", type: .string, required: true),
            ToolParameter(name: "delay_seconds", description: "Seconds from now to deliver (default 5)", type: .integer, required: false),
        ],
        requiresApproval: true
    )

    func execute(arguments: [String: String]) async -> ToolCallResult {
        guard let title = arguments["title"], !title.isEmpty else {
            return .failure("Missing required parameter: title")
        }
        guard let body = arguments["body"], !body.isEmpty else {
            return .failure("Missing required parameter: body")
        }

        let center = UNUserNotificationCenter.current()

        do {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else {
                    return .failure("Notification permission not granted")
                }
            } else if settings.authorizationStatus == .denied {
                return .failure("Notifications are disabled. Please enable them in Settings.")
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let delay = Double(arguments["delay_seconds"] ?? "5") ?? 5
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: trigger
            )

            try await center.add(request)
            return .success("Notification '\(title)' scheduled in \(Int(delay)) seconds.")
        } catch {
            return .failure("Failed to schedule notification: \(error.localizedDescription)")
        }
    }
}
