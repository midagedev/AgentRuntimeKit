import Foundation

public enum AgentRuntimeError: LocalizedError, Sendable, Equatable {
    case providerNotFound(String)
    case providerCapabilityMissing(provider: String, capability: String)
    case duplicateTool(String)
    case invalidToolName(String)
    case toolNotFound(String)
    case toolNotAllowed(String)
    case toolDenied(name: String, reason: String)
    case toolApprovalDenied(name: String, reason: String)
    case toolArgumentsInvalid(name: String, reason: String)
    case toolTimedOut(String)
    case maximumStepsExceeded(Int)
    case maximumToolCallsExceeded(Int)
    case tokenBudgetExceeded(Int)
    case runTimedOut
    case contextProviderFailed(identifier: String, reason: String)
    case checkpointFailed(String)
    case resumeCheckpointMismatch(field: String)
    case checkpointRequiredForNonIdempotentTool(String)
    case nonIdempotentToolRequiresReconciliation(callID: String, toolName: String)
    case nonIdempotentToolExecutionIndeterminate(callID: String, toolName: String)
    case duplicateToolCallID(String)
    case invalidProviderResponse(String)

    public var errorDescription: String? {
        switch self {
        case .providerNotFound(let id): "Model provider '\(id)' is not registered."
        case .providerCapabilityMissing(let provider, let capability):
            "Provider '\(provider)' does not support \(capability)."
        case .duplicateTool(let name): "Tool '\(name)' is already registered."
        case .invalidToolName(let name): "Tool name '\(name)' is invalid."
        case .toolNotFound(let name): "Tool '\(name)' is not registered."
        case .toolNotAllowed(let name): "Tool '\(name)' is not allowed for this agent."
        case .toolDenied(let name, let reason): "Tool '\(name)' was denied: \(reason)"
        case .toolApprovalDenied(let name, let reason): "Approval for '\(name)' was denied: \(reason)"
        case .toolArgumentsInvalid(let name, let reason): "Invalid arguments for '\(name)': \(reason)"
        case .toolTimedOut(let name): "Tool '\(name)' timed out."
        case .maximumStepsExceeded(let count): "Agent exceeded its \(count)-step limit."
        case .maximumToolCallsExceeded(let count): "Agent exceeded its \(count)-tool-call limit."
        case .tokenBudgetExceeded(let count): "Agent exceeded its \(count)-token budget."
        case .runTimedOut: "Agent run exceeded its time limit."
        case .contextProviderFailed(let identifier, let reason):
            "Context provider '\(identifier)' failed: \(reason)"
        case .checkpointFailed(let reason): "Could not persist agent checkpoint: \(reason)"
        case .resumeCheckpointMismatch(let field):
            "The checkpoint does not belong to this agent run (mismatched \(field))."
        case .checkpointRequiredForNonIdempotentTool(let name):
            "Tool '\(name)' has non-idempotent effects and requires durable checkpoint storage."
        case .nonIdempotentToolRequiresReconciliation(let callID, let toolName):
            "Tool '\(toolName)' may already have run for call '\(callID)'. Reconcile its external effect before resuming."
        case .nonIdempotentToolExecutionIndeterminate(let callID, let toolName):
            "Tool '\(toolName)' returned an indeterminate result for call '\(callID)'. Reconcile its external effect before continuing."
        case .duplicateToolCallID(let callID):
            "The provider reused tool call ID '\(callID)'; the tool was not executed again."
        case .invalidProviderResponse(let reason): "Invalid provider response: \(reason)"
        }
    }
}
