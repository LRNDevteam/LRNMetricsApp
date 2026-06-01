namespace LabMetricsDashboard.Models;

/// <summary>
/// View model for the All Labs Collection Summary page.
/// </summary>
public sealed class AllLabsCollectionViewModel
{
    /// <summary>All labs that have Collection Report enabled.</summary>
    public List<string> EligibleLabs { get; init; } = [];

    // ── Active filters ────────────────────────────────────────────────────────

    public List<string> FilterPayerNames  { get; init; } = [];
    public List<string> FilterPanelNames  { get; init; } = [];
    public string? FilterFirstBillFrom    { get; init; }
    public string? FilterFirstBillTo      { get; init; }
    public string? FilterDosFrom          { get; init; }
    public string? FilterDosTo            { get; init; }
    public string? FilterCheckDateFrom    { get; init; }
    public string? FilterCheckDateTo      { get; init; }

    public bool HasActiveFilters =>
           FilterPayerNames.Count > 0
        || FilterPanelNames.Count > 0
        || !string.IsNullOrWhiteSpace(FilterFirstBillFrom)
        || !string.IsNullOrWhiteSpace(FilterFirstBillTo)
        || !string.IsNullOrWhiteSpace(FilterDosFrom)
        || !string.IsNullOrWhiteSpace(FilterDosTo)
        || !string.IsNullOrWhiteSpace(FilterCheckDateFrom)
        || !string.IsNullOrWhiteSpace(FilterCheckDateTo);

    // ── Error ─────────────────────────────────────────────────────────────────

    public string? ErrorMessage { get; init; }
}
