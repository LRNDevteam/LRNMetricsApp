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

/// <summary>Approve (system-proposed) or Manual Map (typeahead-picked) request.</summary>
public sealed class PayerMappingActionRequest
{
    /// <summary>The chosen Payer Policy record. Its Global Payer ID is resolved server-side.</summary>
    public int PPInsuranceMasterId { get; set; }
}

public sealed class PayerMappingActionResult
{
    public bool Success { get; set; }
    public string? Message { get; set; }
    public int? GlobalPayerId { get; set; }
    public string? MappingStatus { get; set; }
}
