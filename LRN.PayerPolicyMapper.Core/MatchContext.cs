namespace LRN.PayerPolicyMapper.Core;

/// <summary>
/// One evaluation context per raw payer name. Fields are set once by their owning step
/// and never overwritten (Step 1A -> 1B -> 2 -> 3 -> 4 -> 5).
/// </summary>
public sealed class MatchContext
{
    public required string PayerNameRaw { get; init; }
    public string? LabState { get; init; }
    public string? LabStateCode { get; init; }
    /// <summary>LabInsuranceMaster.PlanType; when populated it wins over name-inferred program type (Step 3).</summary>
    public string? LabPlanType { get; init; }

    /// <summary>Step 1A output: uppercase, punctuation to spaces, collapsed whitespace.</summary>
    public string CosmeticName { get; set; } = string.Empty;
    /// <summary>Step 1B output: CosmeticName with plan/network-type codes stripped. This is what Step 7 scores
    /// and what gets written to LabInsuranceMaster.PayerNameNormalized.</summary>
    public string CanonicalName { get; set; } = string.Empty;

    /// <summary>Step 2 output.</summary>
    public string? ResolvedStateCode { get; set; }
    public StateSignalSource StateSignalSource { get; set; } = StateSignalSource.None;

    /// <summary>Step 3 output.</summary>
    public string? ResolvedProgramType { get; set; }

    /// <summary>Step 4 output; null does NOT stop the pipeline (full-master fallback).</summary>
    public string? CandidateFamily { get; set; }

    /// <summary>Step 5 output.</summary>
    public bool AliasHit { get; set; }
    public int? AliasGlobalPayerId { get; set; }
}
