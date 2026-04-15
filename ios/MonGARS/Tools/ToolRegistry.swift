import Foundation

@Observable
@MainActor
final class ToolRegistry {
    private var tools: [String: any ToolExecutable] = [:]

    func register(_ tool: any ToolExecutable) {
        tools[tool.schema.name] = tool
    }

    func execute(toolName: String, arguments: [String: String]) async -> ToolCallResult {
        guard let tool = tools[toolName] else {
            return .failure("Tool '\(toolName)' not found")
        }
        return await tool.execute(arguments: arguments)
    }

    func requiresApproval(toolName: String) -> Bool {
        tools[toolName]?.schema.requiresApproval ?? true
    }

    func isNetworkRequired(toolName: String) -> Bool {
        tools[toolName]?.schema.requiresNetwork ?? false
    }

    func schema(for toolName: String) -> ToolSchema? {
        tools[toolName]?.schema
    }

    func availableToolDescriptions(policy: NetworkPolicyService?) -> String {
        let filtered = tools.values.filter { tool in
            if tool.schema.requiresNetwork {
                guard let policy else { return false }
                return policy.isToolAllowed(tool.schema.name)
            }
            return true
        }

        return filtered.map { tool in
            let params = tool.schema.parameters.map { p in
                "  - \(p.name) (\(p.type.rawValue), \(p.required ? "required" : "optional")): \(p.description)"
            }.joined(separator: "\n")

            var desc = "\(tool.schema.name): \(tool.schema.description)"
            if tool.schema.requiresNetwork {
                desc += " [requires network]"
            }
            desc += "\nParameters:\n\(params)"
            return desc
        }.joined(separator: "\n\n")
    }

    var registeredSchemas: [ToolSchema] {
        tools.values.map(\.schema)
    }

    var offlineSchemas: [ToolSchema] {
        tools.values.filter { !$0.schema.requiresNetwork }.map(\.schema)
    }

    var networkSchemas: [ToolSchema] {
        tools.values.filter { $0.schema.requiresNetwork }.map(\.schema)
    }
}
