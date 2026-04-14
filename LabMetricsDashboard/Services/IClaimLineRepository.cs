using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads paginated Claim Level and Line Level detail rows
/// from <c>dbo.ClaimLevelData</c> and <c>dbo.LineLevelData</c>.
/// </summary>
public interface IClaimLineRepository
{
    /// <summary>
    /// Returns a page of claim-level records with server-side filtering and pagination.
    /// Also returns filter-option lists (unfiltered, lab-scoped) and total counts.
    /// </summary>
    Task<ClaimLevelResult> GetClaimLevelAsync(
        string connectionString,
        string labName,
        string? filterPayerName = null,
        List<string>? filterPayerTypes = null,
        List<string>? filterClaimStatuses = null,
        List<string>? filterClinicNames = null,
        string? filterDenialCode = null,
        bool filterDenialCodeExcludeBlank = false,
        List<string>? filterPayerNames = null,
        bool filterPayerExcludeBlank = false,
        List<string>? filterPanelNames = null,
        bool filterPanelExcludeBlank = false,
        List<string>? filterAgingBuckets = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        bool filterFirstBillNull = false,
        bool filterFirstBillExcludeBlank = false,
        DateOnly? filterChargeEnteredFrom = null,
        DateOnly? filterChargeEnteredTo = null,
        bool filterChargeEnteredNull = false,
        bool filterChargeEnteredExcludeBlank = false,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        bool filterDosNull = false,
        int page = 1,
        int pageSize = 50,
        CancellationToken ct = default);

    /// <summary>
    /// Returns a page of line-level records with server-side filtering and pagination.
    /// Also returns filter-option lists (unfiltered, lab-scoped) and total counts.
    /// </summary>
    Task<LineLevelResult> GetLineLevelAsync(
        string connectionString,
        string labName,
        string? filterPayerName = null,
        List<string>? filterPayerTypes = null,
        List<string>? filterClaimStatuses = null,
        List<string>? filterPayStatuses = null,
        List<string>? filterCPTCodes = null,
        List<string>? filterClinicNames = null,
        string? filterDenialCode = null,
        int page = 1,
        int pageSize = 50,
        CancellationToken ct = default);
}

/// <summary>Result container for the Claim Level details page.</summary>
public sealed record ClaimLevelResult(
    List<string> PayerTypes,
    List<string> ClaimStatuses,
    List<string> ClinicNames,
    List<string> PayerNames,
    List<string> PanelNames,
    List<string> AgingBuckets,
    List<ClaimRecord> Records,
    int TotalFiltered,
    int TotalAll);

/// <summary>Result container for the Line Level details page.</summary>
public sealed record LineLevelResult(
    List<string> PayerTypes,
    List<string> ClaimStatuses,
    List<string> PayStatuses,
    List<string> ClinicNames,
    List<string> CPTCodes,
    List<LineRecord> Records,
    int TotalFiltered,
    int TotalAll);
