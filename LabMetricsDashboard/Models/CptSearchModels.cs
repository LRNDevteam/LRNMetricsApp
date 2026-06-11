namespace LabMetricsDashboard.Models;

// ── Input ─────────────────────────────────────────────────────────────────────

/// <summary>View-model posted from the CPT Code search form.</summary>
public sealed class CptSearchRequest
{
    /// <summary>CPT code typed by the user (e.g. "80307").</summary>
    public string? CptCode { get; set; }
}

/// <summary>
/// One active row from <c>dbo.LabRegistry</c> on LRNMaster.
/// Drives which SP to call for each lab — no config files needed.
/// </summary>
public sealed class CptLabEntry
{
    public string LabName     { get; init; } = string.Empty;  // e.g. Augustus_LRN
    public string DisplayName { get; init; } = string.Empty;  // e.g. Augustus Labs
    public string SprocName   { get; init; } = string.Empty;  // e.g. dbo.usp_CPTCodeSearch_Augustus_LRN
}


// ── Per-lab result containers ─────────────────────────────────────────────────

/// <summary>
/// RS1 from usp_CPTCodeSearch_{Lab} — one row per Panel × ClaimStatus × DenialCode.
/// Shows what purpose the CPT was billed for and whether each group was claimed or denied.
/// Payer detail is in RS5 (<see cref="CptPayerRow"/>).
/// </summary>
public sealed class CptPanelSummary
{
    public string  PanelName    { get; init; } = string.Empty;
    public string  ClaimStatus  { get; init; } = string.Empty;
    public string  DenialCode   { get; init; } = string.Empty;
    public int     TotalLines   { get; init; }
    public decimal TotalUnits   { get; init; }
    public decimal DeniedUnits  { get; init; }
    public decimal ClaimedUnits { get; init; }
    public decimal TotalPayments { get; init; }
    public decimal TotalCharges  { get; init; }
    public string  EarliestDOS  { get; init; } = string.Empty;
    public string  LatestDOS    { get; init; } = string.Empty;
    // kept for compatibility — not populated from RS1
    public string  Modifier     { get; init; } = string.Empty;
}

/// <summary>Denial code breakdown returned from usp_CPTCodeSearch result-set 2.</summary>
public sealed class CptDenialCode
{
    public string  DenialCode   { get; init; } = string.Empty;
    public int     LineCount    { get; init; }
    public decimal DeniedUnits  { get; init; }
    public decimal Payments     { get; init; }
}

/// <summary>Monthly trend row returned from usp_CPTCodeSearch result-set 3.</summary>
public sealed class CptMonthlyTrend
{
    public string  MonthYear    { get; init; } = string.Empty;
    public int     LineCount    { get; init; }
    public decimal TotalUnits   { get; init; }
    public decimal DeniedUnits  { get; init; }
    public decimal ClaimedUnits { get; init; }
    public decimal TotalPayments { get; init; }
}

/// <summary>Claim-level aggregate returned from usp_CPTCodeSearch result-set 4.</summary>
public sealed class CptClaimLevelRow
{
    public string  PanelName    { get; init; } = string.Empty;
    public string  ClaimStatus  { get; init; } = string.Empty;
    public string  DenialCode   { get; init; } = string.Empty;
    public int     ClaimCount   { get; init; }
    public decimal TotalPayments { get; init; }
    public decimal TotalCharges  { get; init; }
}

/// <summary>Payer breakdown returned from usp_CPTCodeSearch result-set 5.</summary>
public sealed class CptPayerRow
{
    public string  PayerName    { get; init; } = string.Empty;
    public string  PayerType    { get; init; } = string.Empty;
    public int     LineCount    { get; init; }
    public decimal TotalUnits   { get; init; }
    public decimal DeniedUnits  { get; init; }
    public decimal TotalPayments { get; init; }
}

/// <summary>Aggregated result for a single lab.</summary>
public sealed class LabCptResult
{
    public string LabName    { get; init; } = string.Empty;
    public string DisplayName { get; init; } = string.Empty;

    /// <summary>True if the SP executed successfully; false on connection/timeout errors.</summary>
    public bool   HasData    { get; init; }
    public string? ErrorMessage { get; init; }

    // ── Aggregates ───────────────────────────────────────────
    public decimal TotalUnits    => Panels.Sum(p => p.TotalUnits);
    public decimal ClaimedUnits  => Panels.Sum(p => p.ClaimedUnits);
    public decimal DeniedUnits   => Panels.Sum(p => p.DeniedUnits);
    public decimal TotalPayments => Panels.Sum(p => p.TotalPayments);
    public decimal TotalCharges  => Panels.Sum(p => p.TotalCharges);
    public decimal DenialRate    => TotalUnits > 0 ? Math.Round(DeniedUnits / TotalUnits * 100, 1) : 0;

    // ── Detail rows ──────────────────────────────────────────
    public List<CptPanelSummary>  Panels      { get; init; } = [];
    public List<CptDenialCode>    DenialCodes { get; init; } = [];
    public List<CptMonthlyTrend>  MonthlyTrend { get; init; } = [];
    public List<CptClaimLevelRow> ClaimLevel  { get; init; } = [];
    public List<CptPayerRow>      Payers      { get; init; } = [];
}


// ── Top-level view model ──────────────────────────────────────────────────────

/// <summary>View model for the CPT Code Search page.</summary>
public sealed class CptSearchViewModel
{
    /// <summary>The CPT code that was searched (empty before first search).</summary>
    public string SearchedCptCode { get; init; } = string.Empty;

    /// <summary>True when the user has submitted a search.</summary>
    public bool HasSearched { get; init; }

    /// <summary>Per-lab results — only labs that returned ≥ 1 line are included.</summary>
    public List<LabCptResult> LabResults { get; init; } = [];

    /// <summary>Labs with LineClaimEnable=true that were searched (may have empty results).</summary>
    public int TotalLabsSearched { get; init; }

    // ── Cross-lab aggregates ──────────────────────────────────
    public decimal GrandTotalUnits    => LabResults.Sum(r => r.TotalUnits);
    public decimal GrandClaimedUnits  => LabResults.Sum(r => r.ClaimedUnits);
    public decimal GrandDeniedUnits   => LabResults.Sum(r => r.DeniedUnits);
    public decimal GrandTotalPayments => LabResults.Sum(r => r.TotalPayments);
    public decimal GrandTotalCharges  => LabResults.Sum(r => r.TotalCharges);
    public decimal OverallDenialRate  => GrandTotalUnits > 0
        ? Math.Round(GrandDeniedUnits / GrandTotalUnits * 100, 1) : 0;

    /// <summary>Denial codes aggregated across all labs, top 10.</summary>
    public List<CptDenialCode> TopDenialCodes => LabResults
        .SelectMany(r => r.DenialCodes)
        .GroupBy(d => d.DenialCode)
        .Select(g => new CptDenialCode
        {
            DenialCode  = g.Key,
            LineCount   = g.Sum(d => d.LineCount),
            DeniedUnits = g.Sum(d => d.DeniedUnits),
            Payments    = g.Sum(d => d.Payments),
        })
        .OrderByDescending(d => d.LineCount)
        .Take(10)
        .ToList();

    /// <summary>Monthly trend aggregated across all labs.</summary>
    public List<CptMonthlyTrend> AggregatedTrend => LabResults
        .SelectMany(r => r.MonthlyTrend)
        .GroupBy(t => t.MonthYear)
        .Select(g => new CptMonthlyTrend
        {
            MonthYear    = g.Key,
            LineCount    = g.Sum(t => t.LineCount),
            TotalUnits   = g.Sum(t => t.TotalUnits),
            DeniedUnits  = g.Sum(t => t.DeniedUnits),
            ClaimedUnits = g.Sum(t => t.ClaimedUnits),
            TotalPayments = g.Sum(t => t.TotalPayments),
        })
        .OrderBy(t => t.MonthYear)
        .ToList();

    /// <summary>Labs that had data (TotalUnits > 0).</summary>
    public List<LabCptResult> ActiveLabs => LabResults.Where(r => r.TotalUnits > 0).ToList();

    /// <summary>How many labs actually used this CPT code.</summary>
    public int LabsWithData => LabResults.Count(r => r.TotalUnits > 0);
}
