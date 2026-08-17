namespace LRN.ReportsApi.Models;

// ── Analytics: Lab Modes / Lab Medians (Meridian) list pages ─────────────────
// View-only reference data. LabId, RunID, and CreatedOn are intentionally not
// exposed on the DTOs (LabId is accepted only as a filter).

public sealed class LabRateQuery
{
    public string? PayerName { get; set; }
    public string? PanelName { get; set; }
    public string? CptCode { get; set; }
    public int? LabId { get; set; }
    public string? SortColumn { get; set; }
    public string? SortDirection { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
}

public sealed class LabModeDto
{
    public string? PayerName { get; set; }
    public string? PanelName { get; set; }
    public string? CptCode { get; set; }
    public decimal? AllowedAmount { get; set; }
    public decimal? InsurancePayment { get; set; }
    public int? DistinctAllowedPaymentCount { get; set; }
    public decimal? ModeAllowedAmount { get; set; }
    public decimal? ModeInsurancePaymentAmount { get; set; }
    public decimal? AllowedAmountPerUnitMode { get; set; }
    public decimal? InsurancePaymentPerUnitMode { get; set; }
    public string LabName { get; set; } = string.Empty;
}

public sealed class LabMedianDto
{
    public string? PayerName { get; set; }
    public string? PanelName { get; set; }
    public string? CptCode { get; set; }
    public decimal? AllowedAmount { get; set; }
    public decimal? InsurancePayment { get; set; }
    public int? DistinctAllowedPaymentCount { get; set; }
    public decimal? MedianAllowedAmount { get; set; }
    public decimal? MedianInsurancePaymentAmount { get; set; }
    public decimal? AllowedAmountPerUnitMedian { get; set; }
    public decimal? InsurancePaymentPerUnitMedian { get; set; }
    public string LabName { get; set; } = string.Empty;
}

// ── CPT & Panel Lookup ───────────────────────────────────────────────────────
// One screen over four tables: dbo.CPTAverage and dbo.PanelAverage carry the
// averages, dbo.LabModes and dbo.LabMedians the mode/median rates. All four use
// the same window vocabulary — CPTAverage/PanelAverage call it WindowType and
// LabModes/LabMedians call it RollingDays, with values YTD | Rolling180 | Rolling90.

public sealed class LookupQuery
{
    public string? CptCode { get; set; }
    public string? PanelName { get; set; }
    public string? Payer { get; set; }
    /// <summary>YTD | Rolling180 | Rolling90. Empty means every window.</summary>
    public string? WindowType { get; set; }
    public int? LabId { get; set; }
    public string? SortColumn { get; set; }
    public string? SortDirection { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

/// <summary>
/// A CPTAverage row with its matching mode/median rates attached. The mode and
/// median columns are null when LabModes/LabMedians has no row for the same
/// lab + CPT + panel + payer + window — the payer names only partly overlap
/// between the two sources, so a missing rate is normal, not an error.
/// </summary>
public sealed class CptLookupRow
{
    public int? LabId { get; set; }
    public string? LabName { get; set; }
    public string? CptCode { get; set; }
    public string? PanelName { get; set; }
    public string? PayerDisplayName { get; set; }
    public string? PayerCommonCode { get; set; }
    public int? GlobalPayerId { get; set; }
    public string? WindowType { get; set; }
    /// <summary>CPTAverage.WindowBasis — what the window is measured against (e.g. DOS).</summary>
    public string? WindowBasis { get; set; }
    public DateTime? StartDate { get; set; }
    public DateTime? EndDate { get; set; }
    public DateTime? AsOfDate { get; set; }

    // CPTAverage
    public int? AvgUnits { get; set; }
    public decimal? AvgChargeAmountPerUnit { get; set; }
    public decimal? AvgAllowedAmountPerUnit { get; set; }
    public decimal? AvgPaidAmountPerUnit { get; set; }
    public decimal? AvgPatientResponsibilityPerUnit { get; set; }
    /// <summary>What the patient actually paid, as opposed to what they were responsible for.</summary>
    public decimal? AvgPatientPaidAmountPerUnit { get; set; }
    public decimal? MedianPaidAmount { get; set; }
    public decimal? P25PaidAmount { get; set; }
    public decimal? P75PaidAmount { get; set; }
    public int? PaidLineCount { get; set; }
    public int? TotalLineCount { get; set; }
    public int? DeniedLineCount { get; set; }
    public int? AdjustedLineCount { get; set; }

    // LabModes
    public decimal? ModeAllowedAmount { get; set; }
    public decimal? ModeInsurancePaymentAmount { get; set; }
    public decimal? AllowedAmountPerUnitMode { get; set; }
    public decimal? InsurancePaymentPerUnitMode { get; set; }

    // LabMedians
    public decimal? MedianAllowedAmount { get; set; }
    public decimal? MedianInsurancePaymentAmount { get; set; }
    public decimal? AllowedAmountPerUnitMedian { get; set; }
    public decimal? InsurancePaymentPerUnitMedian { get; set; }

    /// <summary>
    /// How the mode rate was resolved: "payer" for this payer's own rate, "lab" for the
    /// lab-wide rate used when LabModes has no row for this payer, null when neither exists.
    /// </summary>
    public string? ModeMatch { get; set; }

    /// <summary>Same contract as <see cref="ModeMatch"/>, for the LabMedians rate.</summary>
    public string? MedianMatch { get; set; }

    /// <summary>DeniedLineCount / TotalLineCount as a percentage; null when there are no lines.</summary>
    public decimal? DenialRate =>
        TotalLineCount is > 0 ? Math.Round((decimal)(DeniedLineCount ?? 0) * 100m / TotalLineCount.Value, 1) : null;
}

/// <summary>A PanelAverage row — panel-level averages, no CPT breakdown.</summary>
public sealed class PanelLookupRow
{
    public int? LabId { get; set; }
    public string? LabName { get; set; }
    public string? PanelName { get; set; }
    public string? PayerId { get; set; }
    public string? PayerDisplayName { get; set; }
    public string? WindowType { get; set; }
    /// <summary>PanelAverage.WindowBasis — Billed or DOS. A panel repeats once per basis.</summary>
    public string? WindowBasis { get; set; }
    public DateTime? StartDate { get; set; }
    public DateTime? EndDate { get; set; }
    public DateTime? AsOfDate { get; set; }
    public decimal? AvgChargeAmount { get; set; }
    public decimal? AvgAllowedAmount { get; set; }
    public decimal? AvgPaidAmount { get; set; }
    public decimal? AvgPatientResponsibility { get; set; }
    /// <summary>What the patient actually paid, as opposed to what they were responsible for.</summary>
    public decimal? AvgPatientPaidAmount { get; set; }
    public decimal? MedianPaidAmount { get; set; }
    public decimal? P25PaidAmount { get; set; }
    public decimal? P75PaidAmount { get; set; }
    public int? PaidLineCount { get; set; }
    public int? TotalLineCount { get; set; }
    public int? DeniedLineCount { get; set; }
    public int? AdjustedLineCount { get; set; }

    // Panel-level modes from dbo.LabModes. That table is CPT-level, so these are the
    // average of the per-CPT modes across the panel; ModeCptCount says how many CPTs
    // that average covers, so a one-CPT panel figure is not mistaken for a broad one.
    public decimal? ModeAllowedAmount { get; set; }
    public decimal? ModeInsurancePaymentAmount { get; set; }
    public int? ModeCptCount { get; set; }

    /// <summary>"payer" | "lab" | null — see <see cref="CptLookupRow.ModeMatch"/>.</summary>
    public string? ModeMatch { get; set; }

    public decimal? DenialRate =>
        TotalLineCount is > 0 ? Math.Round((decimal)(DeniedLineCount ?? 0) * 100m / TotalLineCount.Value, 1) : null;
}

/// <summary>Headline numbers for the KPI row, computed over every row matching the filters.</summary>
public sealed class LookupSummary
{
    public int RowCount { get; set; }
    public decimal? AvgAllowed { get; set; }
    public decimal? AvgPaid { get; set; }
    public decimal? DenialRate { get; set; }
}

public sealed class LookupResult<T>
{
    public List<T> Items { get; set; } = new();
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
    public int TotalCount { get; set; }
    public int TotalPages => PageSize <= 0 ? 0 : (int)Math.Ceiling((double)TotalCount / PageSize);
    public LookupSummary Summary { get; set; } = new();
}
