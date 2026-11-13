namespace LRN.AI.Application.Common;

/// <summary>The authenticated caller and the request correlation id, passed from the API into use cases.</summary>
public sealed record CallerContext(string UserId, string CorrelationId);

public static class AuditActions
{
    public const string ModelsList = "Models.List";
    public const string ModelsCompare = "Models.Compare";
}

public static class AuditOutcomes
{
    public const string Succeeded = "Succeeded";
    public const string PartiallySucceeded = "PartiallySucceeded";
    public const string Failed = "Failed";
    public const string Rejected = "Rejected";
    public const string Cancelled = "Cancelled";
}

/// <summary>
/// One audit record. By design it carries no prompt, system prompt or model output, only their sizes, so
/// the audit trail never becomes a second copy of PHI.
/// </summary>
public sealed record AiAuditEvent(
    string Action,
    string Outcome,
    CallerContext Caller,
    DateTimeOffset OccurredAt,
    string? ReferenceId = null,
    IReadOnlyList<string>? ModelNames = null,
    int? PromptCharacters = null,
    string? Reason = null,
    IReadOnlyList<AiAuditModelOutcome>? ModelOutcomes = null);

public sealed record AiAuditModelOutcome(string ModelName, bool Success, long DurationMs, string? ErrorCode);
