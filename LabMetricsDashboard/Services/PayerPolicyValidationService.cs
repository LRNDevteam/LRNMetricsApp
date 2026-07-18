using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Loads Payer Policy Validation rows for the selected lab.
///
/// DB-enabled labs use SERVER-SIDE paging via dbo.usp_GetPayerValidationReportPaged —
/// only one page of rows ever crosses the network, so the screen opens fast even when
/// PayerValidationReport holds hundreds of thousands of rows. Dropdown options come
/// from the PV_FilterOptions snapshot (usp_GetPredictionFilterOptions).
///
/// Labs still on the old SP version, and file-based labs, fall back to the legacy
/// full-load + in-memory filter/page path.
/// </summary>
public sealed class PayerPolicyValidationService
{
    private readonly IPredictionDbRepository _dbRepo;
    private readonly LabCsvFileResolver _resolver;
    private readonly PredictionReportParserService _parser;
    private readonly ILogger<PayerPolicyValidationService> _logger;

    public PayerPolicyValidationService(
        IPredictionDbRepository dbRepo,
        LabCsvFileResolver resolver,
        PredictionReportParserService parser,
        ILogger<PayerPolicyValidationService> logger)
    {
        _dbRepo   = dbRepo;
        _resolver = resolver;
        _parser   = parser;
        _logger   = logger;
    }

    public sealed record FilterOptions(
        List<string> PayerNames,
        List<string> PanelNames,
        List<string> FinalCoverageStatuses,
        List<string> CPTCodes,
        List<string> ForecastingPayabilitySubstatuses,
        List<string> PredictionStatuses,
        List<string> PayStatuses)
    {
        public static FilterOptions Empty => new([], [], [], [], [], [], []);
    }

    public sealed record LoadResult(
        List<PredictionRecord> PagedRows,
        int TotalFiltered,
        int TotalAll,
        bool UsingDb,
        string DataSourceLabel,
        FilterOptions Options);

    public async Task<LoadResult> LoadAsync(
        string labName,
        LabCsvConfig config,
        string? filterPayerName,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterCPTCode,
        string? filterForecastingPayabilitySubstatus,
        string? filterPredictionStatus,
        string? filterPayStatus,
        int page,
        int pageSize,
        CancellationToken ct = default)
    {
        var currentPage = Math.Max(1, page);

        if (config.DBEnabled && !string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            try
            {
                // Paged rows and dropdown options are independent — run both concurrently.
                var pagedTask = _dbRepo.GetRecordsPagedAsync(
                    config.DbConnectionString,
                    filterPayerName: filterPayerName,
                    filterPanelName: filterPanelName,
                    filterFinalCoverageStatus: filterFinalCoverageStatus,
                    filterCPTCode: filterCPTCode,
                    filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus,
                    filterPredictionStatus: filterPredictionStatus,
                    filterPayStatus: filterPayStatus,
                    pageNumber: currentPage,
                    pageSize: pageSize,
                    cancellationToken: ct);
                var optionsTask = _dbRepo.GetFilterOptionsAsync(config.DbConnectionString, cancellationToken: ct);
                await Task.WhenAll(pagedTask, optionsTask);

                var paged = await pagedTask;
                var opts  = await optionsTask;

                _logger.LogInformation(
                    "PayerPolicyValidation [{Lab}]: served page {Page} ({Rows} rows) from paged SP.",
                    labName, currentPage, paged.Rows.Count);

                return new LoadResult(
                    paged.Rows,
                    paged.TotalFiltered,
                    paged.TotalAll,
                    UsingDb: true,
                    DataSourceLabel: $"[DB] {labName} — dbo.PayerValidationReport (paged)",
                    Options: new FilterOptions(
                        opts.PayerNames,
                        opts.PanelNames,
                        opts.FinalCoverageStatuses,
                        opts.CPTCodes,
                        opts.ForecastingPayabilitySubstatuses,
                        opts.PredictionStatuses,
                        opts.PayStatuses));
            }
            catch (SqlException ex) when (IsMissingPagedSp(ex))
            {
                _logger.LogWarning(
                    "usp_GetPayerValidationReportPaged is missing on {Lab} — falling back to legacy full load. " +
                    "Deploy PredictionAnalysisApp/Database/12_PayerValidationReportPaged.sql for fast paging.",
                    labName);
                // fall through to legacy path below
            }
        }

        // ── Legacy path: full load + in-memory filter/page (file labs, old SP) ──
        var (baseDataset, usingDb, dataSourceLabel) = await LoadBaseDatasetAsync(labName, config, ct);

        var filtered = ApplyDimensionFilters(
            baseDataset,
            filterPayerName, filterPanelName, filterFinalCoverageStatus, filterCPTCode,
            filterForecastingPayabilitySubstatus, filterPredictionStatus, filterPayStatus);

        var pagedRows = filtered
            .Skip((currentPage - 1) * pageSize)
            .Take(pageSize)
            .ToList();

        return new LoadResult(
            pagedRows,
            filtered.Count,
            baseDataset.Count,
            usingDb,
            dataSourceLabel,
            BuildOptionsInMemory(baseDataset));
    }

    /// <summary>All filtered rows (no paging) — used by the Excel export.</summary>
    public async Task<List<PredictionRecord>> LoadAllFilteredAsync(
        string labName,
        LabCsvConfig config,
        string? filterPayerName,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterCPTCode,
        string? filterForecastingPayabilitySubstatus,
        string? filterPredictionStatus,
        string? filterPayStatus,
        CancellationToken ct = default)
    {
        if (config.DBEnabled && !string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            try
            {
                var paged = await _dbRepo.GetRecordsPagedAsync(
                    config.DbConnectionString,
                    filterPayerName: filterPayerName,
                    filterPanelName: filterPanelName,
                    filterFinalCoverageStatus: filterFinalCoverageStatus,
                    filterCPTCode: filterCPTCode,
                    filterForecastingPayabilitySubstatus: filterForecastingPayabilitySubstatus,
                    filterPredictionStatus: filterPredictionStatus,
                    filterPayStatus: filterPayStatus,
                    pageNumber: 1,
                    pageSize: null, // null => SP returns ALL filtered rows
                    cancellationToken: ct);
                return paged.Rows;
            }
            catch (SqlException ex) when (IsMissingPagedSp(ex))
            {
                _logger.LogWarning(
                    "usp_GetPayerValidationReportPaged is missing on {Lab} — export falling back to legacy full load.",
                    labName);
            }
        }

        var (baseDataset, _, _) = await LoadBaseDatasetAsync(labName, config, ct);
        return ApplyDimensionFilters(
            baseDataset,
            filterPayerName, filterPanelName, filterFinalCoverageStatus, filterCPTCode,
            filterForecastingPayabilitySubstatus, filterPredictionStatus, filterPayStatus);
    }

    public static List<string> GetAvailableLabs(IReadOnlyDictionary<string, LabCsvConfig> labConfigs) =>
        labConfigs
            .Where(kv => IsEligible(kv.Key, kv.Value))
            .Select(kv => kv.Key)
            .OrderBy(x => x)
            .ToList();

    public static bool IsEligible(string labName, LabCsvConfig config)
    {
        if (!config.EnablePrediction)
            return false;

        if (config.DBEnabled && !string.IsNullOrWhiteSpace(config.DbConnectionString))
            return true;

        return !string.IsNullOrWhiteSpace(config.PayerPolicyValidationReportPath);
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    /// <summary>SQL error 2812: "Could not find stored procedure ..." (old lab DB).</summary>
    private static bool IsMissingPagedSp(SqlException ex) =>
        ex.Number == 2812
        || ex.Message.Contains("usp_GetPayerValidationReportPaged", StringComparison.OrdinalIgnoreCase);

    private async Task<(List<PredictionRecord> Rows, bool UsingDb, string Label)> LoadBaseDatasetAsync(
        string labName, LabCsvConfig config, CancellationToken ct)
    {
        List<PredictionRecord> baseDataset;
        bool usingDb;
        string dataSourceLabel;

        if (config.DBEnabled && !string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            baseDataset = await _dbRepo.GetRecordsAsync(
                config.DbConnectionString,
                cancellationToken: ct);
            usingDb = true;
            dataSourceLabel = $"[DB] {labName} — dbo.PayerValidationReport";
        }
        else
        {
            var filePath = _resolver.ResolvePredictionValidationReport(labName);
            if (filePath is null)
                throw new InvalidOperationException(
                    $"No database connection or report file is configured for {labName}.");

            baseDataset = _parser.Parse(filePath);
            usingDb = false;
            dataSourceLabel = filePath;
        }

        _logger.LogInformation(
            "PayerPolicyValidation [{Lab}]: loaded {Count} rows from {Source} (legacy full load).",
            labName, baseDataset.Count, dataSourceLabel);

        return (baseDataset, usingDb, dataSourceLabel);
    }

    private static FilterOptions BuildOptionsInMemory(List<PredictionRecord> rows) =>
        new(
            Distinct(rows, r => r.PayerNameNormalized),
            Distinct(rows, r => r.PanelName),
            Distinct(rows, r => r.FinalCoverageStatus),
            Distinct(rows, r => r.CPTCode),
            Distinct(rows, r => r.ForecastingPayabilitySubstatus),
            Distinct(rows, r => r.PredictionStatus),
            Distinct(rows, r => r.PayStatus));

    private static List<string> Distinct(
        IEnumerable<PredictionRecord> rows,
        Func<PredictionRecord, string> selector) =>
        rows.Select(selector).Where(v => !string.IsNullOrWhiteSpace(v))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(v => v)
            .ToList();

    private static List<PredictionRecord> ApplyDimensionFilters(
        List<PredictionRecord> rows,
        string? filterPayerName,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterCPTCode,
        string? filterForecastingPayabilitySubstatus,
        string? filterPredictionStatus,
        string? filterPayStatus)
    {
        IEnumerable<PredictionRecord> q = rows;

        if (!string.IsNullOrWhiteSpace(filterPayerName))
            q = q.Where(r => r.PayerNameNormalized.Equals(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPanelName))
            q = q.Where(r => r.PanelName.Equals(filterPanelName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterFinalCoverageStatus))
            q = q.Where(r => r.FinalCoverageStatus.Equals(filterFinalCoverageStatus, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterCPTCode))
            q = q.Where(r => r.CPTCode.Equals(filterCPTCode, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterForecastingPayabilitySubstatus))
            q = q.Where(r => r.ForecastingPayabilitySubstatus.Equals(filterForecastingPayabilitySubstatus, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPredictionStatus))
            q = q.Where(r => r.PredictionStatus.Equals(filterPredictionStatus, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayStatus))
            q = q.Where(r => r.PayStatus.Equals(filterPayStatus, StringComparison.OrdinalIgnoreCase));

        return q.ToList();
    }
}
