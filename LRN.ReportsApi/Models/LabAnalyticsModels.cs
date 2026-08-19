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
// One screen over two tables: dbo.CPTAverage and dbo.PanelAverage. Both carry the
// averages AND their own mode/median columns, written by LRN.AveragesImport from the
// lab's line/claim data, so nothing else has to be joined in.
//
// This used to also read dbo.LabModes and dbo.LabMedians. Those joins are gone: the
// averages tables now hold the same figures for the same key, and re-deriving them
// from a 394k-row heap per page made the grid time out (a CTE is inlined, not
// materialised, so the aggregation ran once per page row).

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
/// One dbo.CPTAverage row. Every value — averages, mode, median, percentiles and
/// counts — comes from that single row, so a null means the aggregate had nothing
/// to compute from rather than a failed lookup somewhere else.
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

    // Mode / median, straight off the same CPTAverage row.
    //
    // These are per-LINE amounts (what a line actually came in at), whereas the Avg*
    // columns above are per-UNIT. On a multi-unit CPT the two are deliberately on
    // different scales — the column names carry the distinction.
    //
    // The former per-unit mode/median columns (AllowedAmountPerUnitMode and friends)
    // are gone: they only ever existed in LabModes/LabMedians and have no equivalent
    // in CPTAverage. ModeMatch/MedianMatch are gone too — there is no longer a
    // payer-specific vs lab-wide fallback to report, because the value belongs to
    // this exact row.
    public decimal? ModeAllowedAmount { get; set; }
    public decimal? ModeInsurancePaymentAmount { get; set; }
    public decimal? MedianAllowedAmount { get; set; }

    /// <summary>
    /// Median of the insurance payment. Same underlying CPTAverage.MedianPaidAmount as
    /// <see cref="MedianPaidAmount"/> above — both names are kept because the grid and
    /// the export each already label one of them.
    /// </summary>
    public decimal? MedianInsurancePaymentAmount { get; set; }

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

    // Mode / median straight off the same PanelAverage row — a true panel-level figure
    // computed from the panel's own claims, not an average of per-CPT modes as it was
    // when this came from the CPT-level LabModes. ModeCptCount is therefore gone: there
    // are no per-CPT modes being averaged any more, so there is nothing to count.
    public decimal? ModeAllowedAmount { get; set; }
    public decimal? ModeInsurancePaymentAmount { get; set; }
    public decimal? MedianAllowedAmount { get; set; }

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
