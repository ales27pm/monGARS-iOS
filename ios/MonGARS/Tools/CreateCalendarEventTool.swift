import EventKit
import Foundation

nonisolated final class CreateCalendarEventTool: ToolExecutable, @unchecked Sendable {
    let schema = ToolSchema(
        name: "create_calendar_event",
        description: "Creates a calendar event in the user's default calendar. Requires user approval.",
        parameters: [
            ToolParameter(name: "title", description: "The event title", type: .string, required: true),
            ToolParameter(name: "start_date", description: "Start date in ISO 8601 format (e.g. 2025-01-15T14:00:00)", type: .string, required: true),
            ToolParameter(name: "end_date", description: "End date in ISO 8601 format", type: .string, required: false),
            ToolParameter(name: "notes", description: "Additional notes for the event", type: .string, required: false),
            ToolParameter(name: "location", description: "Location string for the event", type: .string, required: false),
        ],
        requiresApproval: true
    )

    private let store = EKEventStore()

    func execute(arguments: [String: String]) async -> ToolCallResult {
        guard let title = arguments["title"], !title.isEmpty else {
            return .failure("Missing required parameter: title")
        }
        guard let startStr = arguments["start_date"] else {
            return .failure("Missing required parameter: start_date")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var startDate = formatter.date(from: startStr)
        if startDate == nil {
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            startDate = basic.date(from: startStr)
        }
        if startDate == nil {
            let simple = DateFormatter()
            simple.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            simple.locale = Locale(identifier: "en_US_POSIX")
            startDate = simple.date(from: startStr)
        }

        guard let finalStart = startDate else {
            return .failure("Invalid start_date format. Use ISO 8601 (e.g. 2025-01-15T14:00:00)")
        }

        do {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else {
                return .failure("Calendar access not granted")
            }

            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = finalStart
            event.notes = arguments["notes"]
            event.location = arguments["location"]

            if let endStr = arguments["end_date"] {
                let endDate = formatter.date(from: endStr) ?? finalStart.addingTimeInterval(3600)
                event.endDate = endDate
            } else {
                event.endDate = finalStart.addingTimeInterval(3600)
            }

            event.calendar = store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent)

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            return .success("Calendar event '\(title)' created for \(dateFormatter.string(from: finalStart)).")
        } catch {
            return .failure("Failed to create calendar event: \(error.localizedDescription)")
        }
    }
}
