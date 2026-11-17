using LRN.AI.Application.Abstractions;
using LRN.AI.Application.Common;
using Microsoft.Extensions.Logging;

namespace LRN.AI.Infrastructure.Observability;

/// <summary>
/// Phase 1 audit sink: one structured entry per event under the "LRN.AI.Audit" category, so it can be routed and
/// retained separately from diagnostic logs. Replaced by an LRNAI database sink in Phase 2.
/// </summary>
internal sealed class LoggerAuditLogger(ILoggerFactory loggerFactory) : IAiAuditLogger
{
    public const string Category = "LRN.AI.Audit";

    private readonly ILogger _logger = loggerFactory.CreateLogger(Category);

    public void Record(AiAuditEvent auditEvent)
    {
        var outcomes = auditEvent.ModelOutcomes is null
            ? null
            : string.Join("; ", auditEvent.ModelOutcomes.Select(o => $"{o.ModelName}={(o.Success ? "ok" : o.ErrorCode)}/{o.DurationMs}ms"));

        _logger.LogInformation(
            "AI audit {Action} {Outcome} user={UserId} correlation={CorrelationId} reference={ReferenceId} at={OccurredAt:o} models={ModelNames} promptChars={PromptCharacters} reason={Reason} results={ModelOutcomes}",
            auditEvent.Action,
            auditEvent.Outcome,
            auditEvent.Caller.UserId,
            auditEvent.Caller.CorrelationId,
            auditEvent.ReferenceId,
            auditEvent.OccurredAt,
            auditEvent.ModelNames is null ? null : string.Join(",", auditEvent.ModelNames),
            auditEvent.PromptCharacters,
            auditEvent.Reason,
            outcomes);
    }
}
