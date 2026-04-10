import Contacts
import Foundation

nonisolated final class SearchContactsTool: ToolExecutable, @unchecked Sendable {
    let schema = ToolSchema(
        name: "search_contacts",
        description: "Searches the user's contacts by name. Requires user approval before returning results.",
        parameters: [
            ToolParameter(name: "query", description: "Name or partial name to search for", type: .string, required: true),
        ],
        requiresApproval: true
    )

    private let store = CNContactStore()

    func execute(arguments: [String: String]) async -> ToolCallResult {
        guard let query = arguments["query"], !query.isEmpty else {
            return .failure("Missing required parameter: query")
        }

        do {
            let status = CNContactStore.authorizationStatus(for: .contacts)
            if status == .notDetermined {
                let granted = try await store.requestAccess(for: .contacts)
                guard granted else {
                    return .failure("Contacts access not granted")
                }
            } else if status != .authorized {
                return .failure("Contacts access not granted. Please enable it in Settings.")
            }

            let keysToFetch: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
            ]

            let predicate = CNContact.predicateForContacts(matchingName: query)
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

            guard !contacts.isEmpty else {
                return .success("No contacts found matching '\(query)'.")
            }

            let results = contacts.prefix(5).map { contact -> String in
                var parts: [String] = []
                let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                parts.append("Name: \(name)")

                if let phone = contact.phoneNumbers.first?.value.stringValue {
                    parts.append("Phone: \(phone)")
                }
                if let email = contact.emailAddresses.first?.value as String? {
                    parts.append("Email: \(email)")
                }
                return parts.joined(separator: ", ")
            }

            return .success("Found \(contacts.count) contact(s):\n" + results.joined(separator: "\n"))
        } catch {
            return .failure("Failed to search contacts: \(error.localizedDescription)")
        }
    }
}
