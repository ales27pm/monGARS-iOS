import EventKit
import Foundation

nonisolated final class CreateReminderTool: ToolExecutable, @unchecked Sendable {
    let schema = ToolSchema(
        name: "create_reminder",
        description: "Creates a reminder in the user's Reminders app. Requires user approval.",
        parameters: [
            ToolParameter(name: "title", description: "The reminder title", type: .string, required: true),
            ToolParameter(name: "notes", description: "Additional notes for the reminder", type: .string, required: false),
        ],
        requiresApproval: true
    )

    private let store = EKEventStore()

    func execute(arguments: [String: String]) async -> ToolCallResult {
        guard let title = arguments["title"], !title.isEmpty else {
            return .failure("Missing required parameter: title")
        }

        do {
            let granted = try await store.requestFullAccessToReminders()
            guard granted else {
                return .failure("Reminders access not granted")
            }

            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.notes = arguments["notes"]
            reminder.calendar = store.defaultCalendarForNewReminders()

            try store.save(reminder, commit: true)
            return .success("Reminder '\(title)' created successfully.")
        } catch {
            return .failure("Failed to create reminder: \(error.localizedDescription)")
        }
    }
}
