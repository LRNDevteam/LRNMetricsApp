namespace LRN.ReportsApi.Models;

/// <summary>Outcome counts of running the matching pipeline over a just-imported batch.</summary>
public sealed class MappingEvaluationSummaryDto
{
    public int Evaluated { get; set; }
    public int AutoMapped { get; set; }
    public int PendingReview { get; set; }
    public int NoMatch { get; set; }
    public int Failed { get; set; }
}

// ── External resolve APIs (stateless, for LIMS / ETL integrations) ───────────

/// <summary>Input to the Lab Insurance resolve API: a raw payer name plus its lab context.</summary>
public sealed class ResolveLabPayerRequest
{
    public string PayerNameRaw { get; set; } = string.Empty;
    public string? LabName { get; set; }
    public string? LabState { get; set; }
    /// <summary>Optional; when supplied it wins over the name-inferred program type (Step 3).</summary>
    public string? PlanType { get; set; }
}

/// <summary>Input to the Payer Policy resolve-or-create API: a raw payer name plus a state signal.</summary>
public sealed class ResolvePayerPolicyRequest
{
    public string PayerNameRaw { get; set; } = string.Empty;
    /// <summary>State signal used as the fallback in Step 2 (there is no lab here).</summary>
    public string? State { get; set; }
}

/// <summary>The Payer Policy Insurance Master detail returned by the resolve APIs.</summary>
public sealed class PayerPolicyDetailDto
{
    public int PPInsuranceMasterId { get; set; }
    public int? GlobalPayerId { get; set; }
    public string? GlobalPayerCode { get; set; }
    public string PayerNameRaw { get; set; } = string.Empty;
    public string? PayerNameNormalized { get; set; }
    public string? PayerFamily { get; set; }
    public int? PayerGroupCode { get; set; }
    public string? PlanType { get; set; }
    public string? PayerState { get; set; }
    public string? BenefitAdminCode { get; set; }
    public string? BenefitAdministrator { get; set; }
    public decimal? MatchScore { get; set; }
    public bool MissingGlobalPayerId { get; set; }
}

/// <summary>Full workflow result for the Lab Insurance resolve API (read-only).</summary>
public sealed class ResolveLabPayerResponse
{
    public string PayerNameRaw { get; set; } = string.Empty;
    /// <summary>Step 1B canonical name; this is what the system means by "normalized".</summary>
    public string CanonicalName { get; set; } = string.Empty;
    public string PayerNameNormalized { get; set; } = string.Empty;
    public string? ResolvedStateCode { get; set; }
    public string StateSignalSource { get; set; } = "None";
    public string? ResolvedProgramType { get; set; }
    public string? CandidateFamily { get; set; }
    public bool AliasHit { get; set; }
    public string Decision { get; set; } = "NoMatch";
    public decimal? ConfidenceScore { get; set; }
    /// <summary>True when the workflow produced a confident auto-map.</summary>
    public bool Matched { get; set; }
    /// <summary>The matched (or best-candidate) Payer Policy detail; null when nothing scored.</summary>
    public PayerPolicyDetailDto? PayerPolicy { get; set; }
    public List<PayerMappingSuggestionDto> Candidates { get; set; } = new();
}

/// <summary>Result for the Payer Policy resolve-or-create API.</summary>
public sealed class ResolvePayerPolicyResponse
{
    public string PayerNameRaw { get; set; } = string.Empty;
    public string PayerNameNormalized { get; set; } = string.Empty;
    public string? ResolvedStateCode { get; set; }
    public string StateSignalSource { get; set; } = "None";
    public string? ResolvedProgramType { get; set; }
    public string? CandidateFamily { get; set; }
    public string Decision { get; set; } = "NoMatch";
    public decimal? ConfidenceScore { get; set; }
    public int GlobalPayerId { get; set; }
    public string? GlobalPayerCode { get; set; }
    public int? PPInsuranceMasterId { get; set; }
    /// <summary>True when no existing payer matched and a brand-new Global Payer ID was minted.</summary>
    public bool Created { get; set; }
}

/// <summary>One ranked Global Payer ID suggestion for the mapping screen.</summary>
public sealed class PayerMappingSuggestionDto
{
    public int Rank { get; set; }
    public int PPInsuranceMasterId { get; set; }
    /// <summary>Null when the policy row has no parseable Global Payer ID - such a candidate can never be approved.</summary>
    public int? GlobalPayerId { get; set; }
    public string PayerName { get; set; } = string.Empty;
    public string? PayerNameNormalized { get; set; }
    public string? PayerFamily { get; set; }
    public string? State { get; set; }
    public string? ProgramType { get; set; }
    public decimal Score { get; set; }
    public decimal BaseNameScore { get; set; }
    public int StateAdjustment { get; set; }
    public int ProgramAdjustment { get; set; }
    public bool MissingGlobalPayerId { get; set; }
}

public sealed class PayerMappingSuggestionsResponse
{
    public int LabInsuranceMasterId { get; set; }
    public string PayerNameRaw { get; set; } = string.Empty;
    public string CanonicalName { get; set; } = string.Empty;
    public string? ResolvedStateCode { get; set; }
    public string StateSignalSource { get; set; } = "None";
    public string? ResolvedProgramType { get; set; }
    public string? CandidateFamily { get; set; }
    /// <summary>Pipeline decision when computed on demand; null when serving stored candidates.</summary>
    public string? Decision { get; set; }
    /// <summary>True when the (CanonicalName, ResolvedStateCode) pair is a confirmed PayerAlias -
    /// the pipeline auto-maps it directly (Step 5 shortcut), so the alias target is surfaced as
    /// the single rank-1 suggestion instead of ranked fuzzy candidates.</summary>
    public bool AliasHit { get; set; }
    public int? AliasGlobalPayerId { get; set; }
    /// <summary>True when the suggestions were served from dbo.PendingMatchCandidates rather than computed now.</summary>
    public bool FromStoredCandidates { get; set; }
    public List<PayerMappingSuggestionDto> Suggestions { get; set; } = new();
}

/// <summary>Typeahead result for the manual mapping search box (ranked, not alphabetical).</summary>
public sealed class PayerPolicySearchResultDto
{
    public int PPInsuranceMasterId { get; set; }
    public int? GlobalPayerId { get; set; }
    public string PayerName { get; set; } = string.Empty;
    public string? PayerNameNormalized { get; set; }
    public string? PayerFamily { get; set; }
    public string? State { get; set; }
    public string? ProgramType { get; set; }
    public decimal Score { get; set; }
    public bool MissingGlobalPayerId { get; set; }
}

/// <summary>MappingStatus row counts for the notification bell / dashboards.</summary>
public sealed class MappingStatusSummaryDto
{
    public int Mapped { get; set; }
    public int Unmapped { get; set; }
    public int PendingReview { get; set; }
    public int NoMatch { get; set; }
    public int Total { get; set; }
}

/// <summary>Approve (system-proposed) or Manual Map (typeahead-picked) request.</summary>
public sealed class PayerMappingActionRequest
{
    /// <summary>The chosen Payer Policy record. Its Global Payer ID is resolved server-side.</summary>
    public int PPInsuranceMasterId { get; set; }
}

/// <summary>Manual service-run trigger. Scope: 'All' (entire data) or 'UnmappedPending' (default).</summary>
public sealed class TriggerRunRequest
{
    public string? Scope { get; set; }
}

public sealed class PayerMappingActionResult
{
    public bool Success { get; set; }
    public string? Message { get; set; }
    public int? GlobalPayerId { get; set; }
    public string? MappingStatus { get; set; }
}
