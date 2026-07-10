namespace LRN.PayerPolicyMapper.Core;

/// <summary>
/// One active PayerPolicyInsuranceMaster row as held in the Step 0 in-memory index.
/// Names are canonicalized once (Step 1A transform) at index build time.
/// </summary>
public sealed class PayerPolicyRecord
{
    public required int PPInsuranceMasterId { get; init; }
    /// <summary>
    /// TRY_CAST of the nvarchar(50) GlobalPayerId column. Null when the column is NULL or not numeric;
    /// such rows are manual-review-only candidates (they can be suggested but never auto-mapped).
    /// </summary>
    public int? GlobalPayerId { get; init; }
    public string PayerNameRaw { get; init; } = string.Empty;
    public string? PayerNameNormalized { get; init; }
    public string? PayerFamily { get; init; }
    public string? PlanType { get; init; }
    public string? PayerState { get; init; }

    // Precomputed at index build time (Step 0).
    public string CanonicalRawName { get; internal set; } = string.Empty;
    public string? CanonicalNormalizedName { get; internal set; }
    /// <summary>PayerState resolved to a 2-letter code (accepts code or full state name), else null.</summary>
    public string? StateCode { get; internal set; }
    /// <summary>Program type: PlanType when populated, else inferred from the canonical raw name via ProgramTypeRule.</summary>
    public string? ProgramType { get; internal set; }
    /// <summary>Alphanumeric-only uppercase family key ("AETNA_BETTER_HEALTH" and "Aetna Better Health" collide on purpose).</summary>
    public string? FamilyKey { get; internal set; }
}

/// <summary>The lab-side row being evaluated (input to the pipeline).</summary>
public sealed class LabInsuranceRow
{
    public required int LabInsuranceMasterId { get; init; }
    public required string PayerNameRaw { get; init; }
    public string? PlanType { get; init; }
    public string? LabState { get; init; }
    public string? LabStateCode { get; init; }
    public string? Remarks { get; init; }
}
