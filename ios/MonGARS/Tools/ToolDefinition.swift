import Foundation

protocol ToolExecutable: Sendable {
    var schema: ToolSchema { get }
    func execute(arguments: [String: String]) async -> ToolCallResult
}
