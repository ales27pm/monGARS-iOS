import SwiftUI

struct ToolApprovalSheet: View {
    let toolCall: ToolCallRequest?
    let localeManager: LocaleManager
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse)

                Text(localeManager.localizedString(
                    "Action Requires Approval",
                    "Action n\u{00E9}cessitant une approbation"
                ))
                .font(.title2.bold())
                .multilineTextAlignment(.center)

                if let toolCall {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(localeManager.localizedString("Action:", "Action :"))
                                .font(.subheadline.bold())
                            Text(toolCall.toolName)
                                .font(.subheadline)
                        }

                        ForEach(Array(toolCall.arguments), id: \.key) { key, value in
                            HStack(alignment: .top) {
                                Text("\(key):")
                                    .font(.subheadline.bold())
                                Text(value)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                }

                Text(localeManager.localizedString(
                    "monGARS wants to perform this action on your behalf. This requires your explicit approval.",
                    "monGARS souhaite effectuer cette action en ton nom. Cela n\u{00E9}cessite ton approbation explicite."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        onApprove()
                    } label: {
                        Text(localeManager.localizedString("Approve", "Approuver"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .cancel) {
                        onDeny()
                    } label: {
                        Text(localeManager.localizedString("Deny", "Refuser"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
