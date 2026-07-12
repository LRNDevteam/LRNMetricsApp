using LRN.PayerPolicyMapper.Core;
using LRN.PayerPolicyMapper.Core.Abstractions;
using LRN.PayerPolicyMapper.Core.Steps;
using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services;

/// <summary>
/// Web-side facade over the shared LRN.PayerPolicyMapper.Core pipeline: the upload hook,
/// the suggestion endpoint, the ranked typeahead search and the three explicit mapping actions
/// (Approve / Manual Map / Reject - intent is never inferred).
/// </summary>
public interface IPayerMappingService
{
    Task<MappingEvaluationSummaryDto> EvaluateRowsAsync(IReadOnlyCollection<int> labInsuranceMasterIds, CancellationToken ct);
    Task<PayerMappingSuggestionsResponse?> GetSuggestionsAsync(int labInsuranceMasterId, CancellationToken ct);
    Task<IReadOnlyList<PayerPolicySearchResultDto>> SearchPolicyPayersAsync(string query, int top, CancellationToken ct);
    Task<PayerMappingActionResult> ApproveAsync(int labInsuranceMasterId, int ppInsuranceMasterId, string userName, CancellationToken ct);
    Task<PayerMappingActionResult> ManualMapAsync(int labInsuranceMasterId, int ppInsuranceMasterId, string userName, CancellationToken ct);
    Task<PayerMappingActionResult> RejectAsync(int labInsuranceMasterId, string userName, CancellationToken ct);
    Task<MappingStatusSummaryDto> GetMappingSummaryAsync(CancellationToken ct);
}

public sealed class PayerMappingService : IPayerMappingService
{
    private readonly MatchingPipeline _pipeline;
    private readonly IPayerPolicyIndexProvider _indexProvider;
    private readonly ILabInsuranceRepository _labRepository;
    private readonly IAuditRepository _auditRepository;
    private readonly ILogger<PayerMappingService> _logger;

    public PayerMappingService(MatchingPipeline pipeline, IPayerPolicyIndexProvider indexProvider,
        ILabInsuranceRepository labRepository, IAuditRepository auditRepository, ILogger<PayerMappingService> logger)
    {
        _pipeline = pipeline;
        _indexProvider = indexProvider;
        _labRepository = labRepository;
        _auditRepository = auditRepository;
        _logger = logger;
    }

    /// <summary>Upload hook: runs the pipeline synchronously for a just-imported batch and returns the summary.</summary>
    public async Task<MappingEvaluationSummaryDto> EvaluateRowsAsync(IReadOnlyCollection<int> labInsuranceMasterIds, CancellationToken ct)
    {
        var summary = new MappingEvaluationSummaryDto();
        foreach (var id in labInsuranceMasterIds)
        {
            var row = await _labRepository.GetRowAsync(id, ct);
            if (row is null || string.IsNullOrWhiteSpace(row.PayerNameRaw)) continue;
            summary.Evaluated++;
            try
            {
                var result = await _pipeline.EvaluateAndPersistAsync(row, "Evaluate", ct);
                switch (result.Decision)
                {
                    case MatchDecision.AutoMap: summary.AutoMapped++; break;
                    case MatchDecision.ManualReview: summary.PendingReview++; break;
                    case MatchDecision.NoMatch: summary.NoMatch++; break;
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                summary.Failed++;
                _logger.LogError(ex, "Pipeline evaluation failed for LabInsuranceMasterId {Id}", id);
            }
        }
        return summary;
    }

    public async Task<PayerMappingSuggestionsResponse?> GetSuggestionsAsync(int labInsuranceMasterId, CancellationToken ct)
    {
        var row = await _labRepository.GetRowAsync(labInsuranceMasterId, ct);
        if (row is null) return null;

        var index = await _indexProvider.GetAsync(ct);
        var byId = index.PolicyRecords.ToDictionary(r => r.PPInsuranceMasterId);

        // Evaluate is cheap and gives the response its canonical/state/family context even
        // when the candidates themselves come from the stored table.
        var result = _pipeline.Evaluate(row, index);
        var response = new PayerMappingSuggestionsResponse
        {
            LabInsuranceMasterId = labInsuranceMasterId,
            PayerNameRaw = row.PayerNameRaw,
            CanonicalName = result.Context.CanonicalName,
            ResolvedStateCode = result.Context.ResolvedStateCode,
            StateSignalSource = result.Context.StateSignalSource.ToString(),
            ResolvedProgramType = result.Context.ResolvedProgramType,
            CandidateFamily = result.Context.CandidateFamily,
            Decision = result.Decision.ToString(),
            AliasHit = result.Context.AliasHit,
            AliasGlobalPayerId = result.Context.AliasGlobalPayerId
        };

        // Step 5 alias shortcut skips candidate scoring entirely, so result.Candidates is empty -
        // surface the confirmed alias target itself as the rank-1 suggestion (score 100) so the
        // screen never shows "no candidates" for a name the system actually knows cold.
        if (result.Context.AliasHit)
        {
            var target = index.PolicyRecords.FirstOrDefault(r => r.GlobalPayerId == result.Context.AliasGlobalPayerId);
            if (target != null)
            {
                response.Suggestions.Add(new PayerMappingSuggestionDto
                {
                    Rank = 1,
                    PPInsuranceMasterId = target.PPInsuranceMasterId,
                    GlobalPayerId = target.GlobalPayerId,
                    PayerName = target.PayerNameRaw,
                    PayerNameNormalized = target.PayerNameNormalized,
                    PayerFamily = target.PayerFamily,
                    State = target.StateCode,
                    ProgramType = target.ProgramType,
                    Score = 100m,
                    BaseNameScore = 100m
                });
            }
            return response;
        }

        var stored = await _labRepository.GetPendingCandidatesAsync(labInsuranceMasterId, ct);
        if (stored.Count > 0)
        {
            response.FromStoredCandidates = true;
            foreach (var s in stored)
            {
                byId.TryGetValue(s.PPInsuranceMasterId, out var record);
                response.Suggestions.Add(new PayerMappingSuggestionDto
                {
                    Rank = s.Rank,
                    PPInsuranceMasterId = s.PPInsuranceMasterId,
                    GlobalPayerId = s.GlobalPayerId,
                    PayerName = record?.PayerNameRaw ?? $"(policy record {s.PPInsuranceMasterId})",
                    PayerNameNormalized = record?.PayerNameNormalized,
                    PayerFamily = record?.PayerFamily,
                    State = record?.StateCode,
                    ProgramType = record?.ProgramType,
                    Score = s.Score,
                    BaseNameScore = s.BaseNameScore,
                    StateAdjustment = s.StateAdjustment,
                    ProgramAdjustment = s.ProgramAdjustment,
                    MissingGlobalPayerId = s.GlobalPayerId is null
                });
            }
        }
        else
        {
            // No stored candidates - serve the on-demand evaluation (read-only; nothing is persisted here).
            response.Suggestions.AddRange(result.Candidates.Select(c => new PayerMappingSuggestionDto
            {
                Rank = c.Rank,
                PPInsuranceMasterId = c.Record.PPInsuranceMasterId,
                GlobalPayerId = c.Record.GlobalPayerId,
                PayerName = c.Record.PayerNameRaw,
                PayerNameNormalized = c.Record.PayerNameNormalized,
                PayerFamily = c.Record.PayerFamily,
                State = c.Record.StateCode,
                ProgramType = c.Record.ProgramType,
                Score = c.Score,
                BaseNameScore = c.BaseNameScore,
                StateAdjustment = c.StateAdjustment,
                ProgramAdjustment = c.ProgramAdjustment,
                MissingGlobalPayerId = c.MissingGlobalPayerId
            }));
        }
        return response;
    }

    /// <summary>Ranked typeahead: Step 1A+1B on the query, Step 7 base scoring against the full master (no family filter).</summary>
    public async Task<IReadOnlyList<PayerPolicySearchResultDto>> SearchPolicyPayersAsync(string query, int top, CancellationToken ct)
    {
        var index = await _indexProvider.GetAsync(ct);
        var canonical = Step1BStripPlanCodes.Run(Step1ACanonicalize.Run(query), index.PlanCodesByLength);
        if (canonical.Length == 0) return Array.Empty<PayerPolicySearchResultDto>();

        return index.PolicyRecords
            .Select(r =>
            {
                var score = Step7FuzzyScore.BaseScore(canonical, r.CanonicalRawName);
                if (r.CanonicalNormalizedName is { Length: > 0 })
                    score = Math.Max(score, Step7FuzzyScore.BaseScore(canonical, r.CanonicalNormalizedName));
                return (Record: r, Score: decimal.Round(score, 2));
            })
            .OrderByDescending(x => x.Score)
            .ThenBy(x => x.Record.PayerNameRaw)
            .Take(top)
            .Select(x => new PayerPolicySearchResultDto
            {
                PPInsuranceMasterId = x.Record.PPInsuranceMasterId,
                GlobalPayerId = x.Record.GlobalPayerId,
                PayerName = x.Record.PayerNameRaw,
                PayerNameNormalized = x.Record.PayerNameNormalized,
                PayerFamily = x.Record.PayerFamily,
                State = x.Record.StateCode,
                ProgramType = x.Record.ProgramType,
                Score = x.Score,
                MissingGlobalPayerId = x.Record.GlobalPayerId is null
            })
            .ToList();
    }

    public Task<PayerMappingActionResult> ApproveAsync(int labInsuranceMasterId, int ppInsuranceMasterId, string userName, CancellationToken ct)
        => MapAsync(labInsuranceMasterId, ppInsuranceMasterId, userName, "Approve", "Approved (System Match)", "Approved", ct);

    public Task<PayerMappingActionResult> ManualMapAsync(int labInsuranceMasterId, int ppInsuranceMasterId, string userName, CancellationToken ct)
        => MapAsync(labInsuranceMasterId, ppInsuranceMasterId, userName, "ManualMap", $"Manual ({userName})", "ManualMap", ct);

    private async Task<PayerMappingActionResult> MapAsync(int labInsuranceMasterId, int ppInsuranceMasterId,
        string userName, string actionType, string mappedBy, string aliasSourceAction, CancellationToken ct)
    {
        var row = await _labRepository.GetRowAsync(labInsuranceMasterId, ct);
        if (row is null) return new PayerMappingActionResult { Success = false, Message = "Lab insurance record was not found." };

        var index = await _indexProvider.GetAsync(ct);
        var record = index.PolicyRecords.FirstOrDefault(r => r.PPInsuranceMasterId == ppInsuranceMasterId);
        if (record is null) return new PayerMappingActionResult { Success = false, Message = "Payer Policy record was not found (or is inactive)." };
        if (record.GlobalPayerId is null)
            return new PayerMappingActionResult { Success = false, Message = $"Payer Policy record '{record.PayerNameRaw}' has no Global Payer ID on file - it must be fixed in the Payer Policy Insurance Master before it can be mapped." };

        // Re-derive the canonical name and state signal so the confirmed alias uses the exact composite key.
        var evaluation = _pipeline.Evaluate(row, index);
        var context = evaluation.Context;

        var ok = await _labRepository.ApplyUserMappingAsync(labInsuranceMasterId, record, mappedBy, userName, ct);
        if (!ok) return new PayerMappingActionResult { Success = false, Message = "Lab insurance record was not found." };

        await _auditRepository.UpsertAliasAsync(context.CanonicalName, context.ResolvedStateCode,
            context.StateSignalSource == StateSignalSource.None ? null : context.StateSignalSource.ToString(),
            record.GlobalPayerId.Value, userName, aliasSourceAction, row.PayerNameRaw, ct);

        await _auditRepository.WriteAsync(new PayerMatchAuditEntry
        {
            LabInsuranceMasterId = labInsuranceMasterId,
            PayerNameRaw = row.PayerNameRaw,
            CanonicalName = context.CanonicalName,
            ResolvedStateCode = context.ResolvedStateCode,
            StateSignalSource = context.StateSignalSource.ToString(),
            ResolvedProgramType = context.ResolvedProgramType,
            CandidateFamily = context.CandidateFamily,
            SelectedGlobalPayerId = record.GlobalPayerId,
            AliasHit = context.AliasHit,
            ActionType = actionType,
            PerformedBy = userName
        }, ct);

        return new PayerMappingActionResult { Success = true, GlobalPayerId = record.GlobalPayerId, MappingStatus = "Mapped" };
    }

    public async Task<MappingStatusSummaryDto> GetMappingSummaryAsync(CancellationToken ct)
    {
        var counts = await _labRepository.GetMappingStatusCountsAsync(ct);
        int Of(string status) => counts.TryGetValue(status, out var n) ? n : 0;
        var summary = new MappingStatusSummaryDto
        {
            Mapped = Of("Mapped"),
            Unmapped = Of("Unmapped"),
            PendingReview = Of("Unmapped - Pending Review"),
            NoMatch = Of("No Match Found"),
            Total = counts.Values.Sum()
        };
        return summary;
    }

    /// <summary>Reject: audit only - no data change, the row stays 'Unmapped - Pending Review'.</summary>
    public async Task<PayerMappingActionResult> RejectAsync(int labInsuranceMasterId, string userName, CancellationToken ct)
    {
        var row = await _labRepository.GetRowAsync(labInsuranceMasterId, ct);
        if (row is null) return new PayerMappingActionResult { Success = false, Message = "Lab insurance record was not found." };

        var index = await _indexProvider.GetAsync(ct);
        var context = _pipeline.Evaluate(row, index).Context;
        await _auditRepository.WriteAsync(new PayerMatchAuditEntry
        {
            LabInsuranceMasterId = labInsuranceMasterId,
            PayerNameRaw = row.PayerNameRaw,
            CanonicalName = context.CanonicalName,
            ResolvedStateCode = context.ResolvedStateCode,
            StateSignalSource = context.StateSignalSource.ToString(),
            ResolvedProgramType = context.ResolvedProgramType,
            CandidateFamily = context.CandidateFamily,
            AliasHit = context.AliasHit,
            ActionType = "Reject",
            PerformedBy = userName
        }, ct);
        return new PayerMappingActionResult { Success = true };
    }
}
