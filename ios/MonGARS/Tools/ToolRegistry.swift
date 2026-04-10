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

    func availableToolDescriptions() -> String {
        tools.values.map { tool in
            let params = tool.schema.parameters.map { p in
                "  - \(p.name) (\(p.type.rawValue), \(p.required ? "required" : "optional")): \(p.description)"
            }.joined(separator: "\n")

            return """
            \(tool.schema.name): \(tool.schema.description)
            Parameters:
            \(params)
            """
        }.joined(separator: "\n\n")
    }

    var registeredSchemas: [ToolSchema] {
        tools.values.map(\.schema)
    }
}
