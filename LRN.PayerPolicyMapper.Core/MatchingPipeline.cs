using System.Text.Json;
using LRN.PayerPolicyMapper.Core.Abstractions;
using LRN.PayerPolicyMapper.Core.Steps;

namespace LRN.PayerPolicyMapper.Core;

/// <summary>
/// Orchestrates Steps 1A-8 (pure, testable via Evaluate) and Step 9 persistence
/// (EvaluateAndPersistAsync) through the injected repository interfaces. The same pipeline
/// runs in the web app (upload hook, on-demand suggestions) and the worker service.
/// </summary>
public sealed class MatchingPipeline
{
    public const string SystemAutoMatch = "System (Auto-Match)";
    public const string NoMatchRemark = "No Mapping Payer Found in Payer Policy Master";

    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private readonly IPayerPolicyIndexProvider _indexProvider;
    private readonly ILabInsuranceRepository _labRepository;
    private readonly IAuditRepository _auditRepository;
    private readonly INotificationService _notifications;
    private readonly MatchingOptions _options;

    public MatchingPipeline(IPayerPolicyIndexProvider indexProvider, ILabInsuranceRepository labRepository,
        IAuditRepository auditRepository, INotificationService notifications, MatchingOptions options)
    {
        _indexProvider = indexProvider;
        _labRepository = labRepository;
        _auditRepository = auditRepository;
        _notifications = notifications;
        _options = options;
    }

    public MatchingOptions Options => _options;

    /// <summary>Steps 1A-8, no persistence. One MatchContext per raw name; fields set once, never overwritten.</summary>
    public MatchResult Evaluate(LabInsuranceRow row, PayerPolicyIndex index)
    {
        var context = new MatchContext
        {
            PayerNameRaw = row.PayerNameRaw,
            LabState = row.LabState,
            LabStateCode = row.LabStateCode,
            LabPlanType = row.PlanType
        };

        Step1ACanonicalize.Run(context);
        Step1BStripPlanCodes.Run(context, index);
        Step2ResolveState.Run(context, index);
        Step3ResolveProgramType.Run(context, index);
        Step4ClassifyFamily.Run(context, index);
        Step5AliasLookup.Run(context, index);

        if (context.AliasHit)
        {
            return new MatchResult
            {
                Context = context,
                Decision = MatchDecision.AutoMap,
                ConfidenceScore = 100m,
                SelectedGlobalPayerId = context.AliasGlobalPayerId,
                // The alias only stores the Global Payer ID; resolve the policy master's normalized
                // name from the index so the auto-mapped Lab row carries the policy name, not the
                // canonicalized lab name.
                SelectedPayerNameNormalized = index.PolicyRecords
                    .FirstOrDefault(r => r.GlobalPayerId == context.AliasGlobalPayerId)?.PayerNameNormalized
            };
        }

        var pool = Step6SelectCandidates.Run(context, index);
        var candidates = Step7FuzzyScore.Run(context, pool, _options.TopCandidates);
        var (decision, tieGuard) = Step8Decide.Run(context, candidates, _options);

        return new MatchResult
        {
            Context = context,
            Decision = decision,
            Candidates = candidates,
            ConfidenceScore = candidates.Count > 0 ? candidates[0].Score : null,
            SelectedGlobalPayerId = decision == MatchDecision.AutoMap ? candidates[0].Record.GlobalPayerId : null,
            SelectedPayerNameNormalized = decision == MatchDecision.AutoMap ? candidates[0].Record.PayerNameNormalized : null,
            TieGuardTriggered = tieGuard
        };
    }

    /// <summary>
    /// Steps 1A-9. actionType is "Evaluate" for upload/poll runs or "NightlyRescan" for the safety-net pass;
    /// auto-mapped Evaluate runs are audited as "AutoMap". runId links the audit row to a
    /// dbo.PayerMapperRun service run (null for web-request evaluations).
    /// </summary>
    public async Task<MatchResult> EvaluateAndPersistAsync(LabInsuranceRow row, string actionType, CancellationToken ct, Guid? runId = null)
    {
        var index = await _indexProvider.GetAsync(ct);
        var result = Evaluate(row, index);
        await PersistAsync(row, result, actionType, ct, runId);
        return result;
    }

    /// <summary>Step 9 - persist one evaluation outcome. ALL paths stamp LastEvaluatedOn.</summary>
    public async Task PersistAsync(LabInsuranceRow row, MatchResult result, string actionType, CancellationToken ct, Guid? runId = null)
    {
        var context = result.Context;
        switch (result.Decision)
        {
            case MatchDecision.AutoMap:
                // Carry the matched Payer Policy Insurance Master's PayerNameNormalized onto the Lab
                // row; fall back to the canonicalized lab name only if the policy row has none.
                await _labRepository.ApplyAutoMapAsync(row.LabInsuranceMasterId, result.SelectedGlobalPayerId!.Value,
                    string.IsNullOrWhiteSpace(result.SelectedPayerNameNormalized) ? context.CanonicalName : result.SelectedPayerNameNormalized!,
                    SystemAutoMatch, ct);
                await _auditRepository.UpsertAliasAsync(context.CanonicalName, context.ResolvedStateCode,
                    context.StateSignalSource == StateSignalSource.None ? null : context.StateSignalSource.ToString(),
                    result.SelectedGlobalPayerId.Value, SystemAutoMatch, "AutoMap", row.PayerNameRaw, ct);
                break;

            case MatchDecision.ManualReview:
                await _labRepository.ApplyManualReviewAsync(row.LabInsuranceMasterId, context.CanonicalName, result.Candidates, ct);
                await _notifications.NotifyReviewNeededAsync(row, result, ct);
                break;

            case MatchDecision.NoMatch:
                await _labRepository.ApplyNoMatchAsync(row.LabInsuranceMasterId, context.CanonicalName, NoMatchRemark, ct);
                // no notification on NoMatch - intentional; the Remarks alert carries the signal
                break;
        }

        await _auditRepository.WriteAsync(BuildAuditEntry(row, result,
            result.Decision == MatchDecision.AutoMap && actionType == "Evaluate" ? "AutoMap" : actionType,
            SystemAutoMatch, runId), ct);
    }

    public static PayerMatchAuditEntry BuildAuditEntry(LabInsuranceRow row, MatchResult result, string actionType, string performedBy, Guid? runId = null) => new()
    {
        RunId = runId,
        LabInsuranceMasterId = row.LabInsuranceMasterId,
        PayerNameRaw = row.PayerNameRaw,
        CanonicalName = result.Context.CanonicalName,
        ResolvedStateCode = result.Context.ResolvedStateCode,
        StateSignalSource = result.Context.StateSignalSource.ToString(),
        ResolvedProgramType = result.Context.ResolvedProgramType,
        CandidateFamily = result.Context.CandidateFamily,
        Decision = result.Decision.ToString(),
        ConfidenceScore = result.ConfidenceScore,
        SelectedGlobalPayerId = result.SelectedGlobalPayerId,
        CandidatesJson = SerializeCandidates(result.Candidates),
        AliasHit = result.Context.AliasHit,
        ActionType = actionType,
        PerformedBy = performedBy
    };

    public static string? SerializeCandidates(IReadOnlyList<MatchCandidate> candidates)
    {
        if (candidates.Count == 0) return null;
        return JsonSerializer.Serialize(candidates.Select(c => new
        {
            c.Rank,
            c.Record.PPInsuranceMasterId,
            c.Record.GlobalPayerId,
            PayerName = c.Record.PayerNameRaw,
            c.Record.PayerNameNormalized,
            c.Record.PayerFamily,
            State = c.Record.StateCode,
            Program = c.Record.ProgramType,
            c.Score,
            c.BaseNameScore,
            c.StateAdjustment,
            c.ProgramAdjustment,
            c.MissingGlobalPayerId
        }), JsonOptions);
    }
}
