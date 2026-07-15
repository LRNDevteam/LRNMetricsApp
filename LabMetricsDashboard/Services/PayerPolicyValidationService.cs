using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Loads Payer Policy Validation rows for the selected lab from
/// dbo.PayerValidationReport (or the lab's report file when DB is disabled).
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

    public sealed record LoadResult(
        List<PredictionRecord> AllFilteredRows,
        List<PredictionRecord> PagedRows,
        List<PredictionRecord> BaseDataset,
        bool UsingDb,
        string DataSourceLabel);

    public async Task<LoadResult> LoadAsync(
        string labName,
        LabCsvConfig config,
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterPayability,
        string? filterCPTCode,
        int page,
        int pageSize,
        CancellationToken ct = default)
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
            "PayerPolicyValidation [{Lab}]: loaded {Count} rows from {Source}.",
            labName, baseDataset.Count, dataSourceLabel);

        var filtered = ApplyDimensionFilters(
            baseDataset,
            filterPayerName, filterPayerType, filterPanelName,
            filterFinalCoverageStatus, filterPayability, filterCPTCode);

        var currentPage = Math.Max(1, page);
        var paged = filtered
            .Skip((currentPage - 1) * pageSize)
            .Take(pageSize)
            .ToList();

        return new LoadResult(filtered, paged, baseDataset, usingDb, dataSourceLabel);
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

    private static List<PredictionRecord> ApplyDimensionFilters(
        List<PredictionRecord> rows,
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterFinalCoverageStatus,
        string? filterPayability,
        string? filterCPTCode)
    {
        IEnumerable<PredictionRecord> q = rows;

        if (!string.IsNullOrWhiteSpace(filterPayerName))
            q = q.Where(r => r.PayerNameNormalized.Equals(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayerType))
            q = q.Where(r => r.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPanelName))
            q = q.Where(r => r.PanelName.Equals(filterPanelName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterFinalCoverageStatus))
            q = q.Where(r => r.FinalCoverageStatus.Equals(filterFinalCoverageStatus, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayability))
            q = q.Where(r => r.Payability.Equals(filterPayability, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterCPTCode))
            q = q.Where(r => r.CPTCode.Equals(filterCPTCode, StringComparison.OrdinalIgnoreCase));

        return q.ToList();
    }
}
