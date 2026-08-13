using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Everything <see cref="DenialDashboardExcelExportBuilder"/> needs for the six exported
/// tabs, already filtered and aggregated the same way DenialDashboardController.Index
/// aggregates them for the page. Built once by
/// <see cref="Controllers.DenialDashboardController.BuildExportData"/> so the synchronous
/// download and the queued LRN.ReportWorker run always produce the same workbook.
/// </summary>
public sealed record DenialDashboardExportData(
    string LabName,
    string RunId,
    // Every line item matching the filters — the Line Item sheet.
    IReadOnlyList<DenialLineItemRecord> LineItems,
    // Filtered task-board rows — the SLA Tracker sheet and the Filter Panel counts.
    IReadOnlyList<DenialRecord> TaskRecords,
    // Pre-aggregated dbo.DenialInsight rows — the Denial Insight sheet.
    IReadOnlyList<DenialInsightRecord> Insights,
    BreakdownPivotViewModel? WeeklyPivot,
    BreakdownPivotViewModel? MonthlyPivot,
    IReadOnlyList<BreakdownItem> StatusBreakdown,
    IReadOnlyList<BreakdownItem> PriorityBreakdown,
    IReadOnlyList<BreakdownItem> ActionCategoryBreakdown,
    IReadOnlyList<BreakdownItem> ClassificationBreakdown,
    IReadOnlyList<BreakdownItem> DeadlineBreakdown,
    // Workload per reviewer — who is carrying which denials, and how much balance.
    IReadOnlyList<BreakdownItem> AssignedToBreakdown,
    // Resolves each line item's Denial Workflow assignment, status and notes.
    DenialWorkflowLineItemAnnotator Workflow,
    IReadOnlyList<(string Label, string? Value)> ActiveFilters);
