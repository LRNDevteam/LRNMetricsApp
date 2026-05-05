using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

public class DashboardController : Controller
{
    private const int PageSize = 50;

	private readonly LabSettings _labSettings;
    private readonly LabCsvFileResolver _resolver;
    private readonly CsvParserService _csvParser;
    private readonly IClinicSummaryRepository _clinicSummaryRepo;
    private readonly ISalesRepSummaryRepository _salesRepSummaryRepo;
    private readonly IDashboardRepository _dashboardRepo;
    private readonly IProductionReportRepository _productionReportRepo;
    private readonly INorthWestProductionSummaryRepository _nwSummaryRepo;
    private readonly IAugustusProductionSummaryRepository _augSummaryRepo;
    private readonly IReadOnlyDictionary<string, ILabProductionSummaryRepository> _labSummaryRepos;
    private readonly IClaimLineRepository _claimLineRepo;
    private readonly ILogger<DashboardController> _logger;
    public DashboardController(
        LabSettings labSettings,
        LabCsvFileResolver resolver,
        CsvParserService csvParser,
        IClinicSummaryRepository clinicSummaryRepo,
        ISalesRepSummaryRepository salesRepSummaryRepo,
        IDashboardRepository dashboardRepo,
        IProductionReportRepository productionReportRepo,
        INorthWestProductionSummaryRepository nwSummaryRepo,
        IAugustusProductionSummaryRepository augSummaryRepo,
        IReadOnlyDictionary<string, ILabProductionSummaryRepository> labSummaryRepos,
        IClaimLineRepository claimLineRepo,
        ILogger<DashboardController> logger)
    {
        _labSettings = labSettings;
        _resolver = resolver;
        _csvParser = csvParser;
        _clinicSummaryRepo = clinicSummaryRepo;
        _salesRepSummaryRepo = salesRepSummaryRepo;
        _dashboardRepo = dashboardRepo;
        _productionReportRepo = productionReportRepo;
        _nwSummaryRepo = nwSummaryRepo;
        _augSummaryRepo = augSummaryRepo;
        _labSummaryRepos = labSummaryRepos;
        _claimLineRepo = claimLineRepo;
        _logger = logger;
    }

    // GET /Dashboard  or  /Dashboard/Index?lab=PCRLabsofAmerica&filterPayerName=...
    public async Task<IActionResult> Index(
        string? lab,
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterClinicName,
        string? filterReferringProvider,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        // Resolve lab config to check for DB availability
        _labSettings.Labs.TryGetValue(selectedLab, out var labConfig);
        var useDb = labConfig is { LineClaimEnable: true }
                    && !string.IsNullOrWhiteSpace(labConfig.DbConnectionString);

        if (useDb)
        {
            return await IndexFromDbAsync(
                availableLabs, selectedLab, labConfig!,
                filterPayerName, filterPayerType, filterPanelName, filterClinicName,
                filterReferringProvider, filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo, ct);
        }

        return IndexFromCsv(
            availableLabs, selectedLab,
            filterPayerName, filterPayerType, filterPanelName, filterClinicName,
            filterReferringProvider, filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo);
    }

    /// <summary>Dashboard Index backed by the database.</summary>
    private async Task<IActionResult> IndexFromDbAsync(
        List<string> availableLabs, string selectedLab, LabCsvConfig labConfig,
        string? filterPayerName, string? filterPayerType, string? filterPanelName,
        string? filterClinicName, string? filterReferringProvider,
        string? filterDosFrom, string? filterDosTo,
        string? filterFirstBillFrom, string? filterFirstBillTo,
        CancellationToken ct)
    {
        var connStr   = labConfig.DbConnectionString!;
        var dbLabName = string.IsNullOrWhiteSpace(labConfig.DbLabName) ? selectedLab : labConfig.DbLabName;

        DateOnly.TryParse(filterDosFrom, out var dosFrom);
        DateOnly.TryParse(filterDosTo, out var dosTo);
        DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
        DateOnly.TryParse(filterFirstBillTo, out var fbTo);

        // Use pre-aggregated snapshot tables when UseDBDashboard=true and no filters are active
        bool hasActiveFilters = new[]
        {
            filterPayerName, filterPayerType, filterPanelName, filterClinicName,
            filterReferringProvider, filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo
        }.Any(f => !string.IsNullOrWhiteSpace(f));

        bool useAggregates = labConfig.UseDBDashboard && !hasActiveFilters;

        try
        {
            DashboardResult r;
            if (useAggregates)
            {
                r = await _dashboardRepo.GetDashboardFromAggregatesAsync(connStr, ct);
            }
            else
            {
                r = await _dashboardRepo.GetDashboardAsync(
                    connStr, dbLabName,
                    filterPayerName, filterPayerType, filterPanelName, filterClinicName,
                    filterReferringProvider,
                    dosFrom != default ? dosFrom : null,
                    dosTo   != default ? dosTo   : null,
                    fbFrom  != default ? fbFrom  : null,
                    fbTo    != default ? fbTo    : null,
                    ct);
            }

            var vm = new DashboardViewModel
            {
                AvailableLabs        = availableLabs,
                SelectedLab          = selectedLab,

                FilterPayerName          = filterPayerName,
                FilterPayerType          = filterPayerType,
                FilterPanelName          = filterPanelName,
                FilterClinicName         = filterClinicName,
                FilterReferringProvider  = filterReferringProvider,
                FilterDosFrom            = filterDosFrom,
                FilterDosTo              = filterDosTo,
                FilterFirstBillFrom      = filterFirstBillFrom,
                FilterFirstBillTo        = filterFirstBillTo,

                PayerNames         = r.PayerNames,
                PayerTypes         = r.PayerTypes,
                PanelNames         = r.PanelNames,
                ClinicNames        = r.ClinicNames,
                ReferringProviders = r.ReferringProviders,

                TotalClaims          = r.TotalClaims,
                TotalCharges         = r.TotalCharges,
                TotalPayments        = r.TotalPayments,
                TotalBalance         = r.TotalBalance,

                CollectionNumerator  = r.CollectionNumerator,
                DenialNumerator      = r.DenialNumerator,
                AdjustmentNumerator  = r.AdjustmentNumerator,
                OutstandingNumerator = r.OutstandingNumerator,

                ClaimStatusBreakdown = r.ClaimStatusRows.ToDictionary(s => s.Status, s => s.Claims),
                ClaimStatusRows      = r.ClaimStatusRows,

                TotalLines           = r.TotalLines,
                LineTotalCharges     = r.LineTotalCharges,
                LineTotalPayments    = r.LineTotalPayments,
                LineTotalBalance     = r.LineTotalBalance,
                TopCPTCharges        = r.TopCPTCharges,
                PayStatusBreakdown   = r.PayStatusBreakdown,

                PayerLevelInsights         = r.PayerLevelInsights,
                PanelLevelInsights         = r.PanelLevelInsights,
                ClinicLevelInsights        = r.ClinicLevelInsights,
                ReferringPhysicianInsights = r.ReferringPhysicianInsights,
                DOSMonthly                 = r.DOSMonthly,
                FirstBillMonthly           = r.FirstBillMonthly,

                PayerTypePayments = r.PayerTypePayments,

                AvgAllowedMonths       = r.AvgAllowedMonths,
                AvgAllowedByPanelMonth = r.AvgAllowedByPanelMonth,

                TopCptDetail = r.TopCptDetail,

                IsAggregateMode  = useAggregates,
                SupportsAggregateMode = labConfig.UseDBDashboard,
                IsDbMode         = true,
                DbLatestRunId    = r.LatestRunId,
            };

            return View(vm);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Dashboard DB query failed for lab '{LabName}'. Falling back to CSV.", selectedLab);

            // Fall back to CSV on DB error
            return IndexFromCsv(
                availableLabs, selectedLab,
                filterPayerName, filterPayerType, filterPanelName, filterClinicName,
                filterReferringProvider, filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo);
        }
    }

    /// <summary>Dashboard Index backed by CSV files (legacy fallback).</summary>
    private IActionResult IndexFromCsv(
        List<string> availableLabs, string selectedLab,
        string? filterPayerName, string? filterPayerType, string? filterPanelName,
        string? filterClinicName, string? filterReferringProvider,
        string? filterDosFrom, string? filterDosTo,
        string? filterFirstBillFrom, string? filterFirstBillTo)
    {

        var claimFilePath = string.IsNullOrEmpty(selectedLab) ? null : _resolver.ResolveClaimLevelCsv(selectedLab);
        var lineFilePath  = string.IsNullOrEmpty(selectedLab) ? null : _resolver.ResolveLineLevelCsv(selectedLab);

        var allClaims = claimFilePath is not null ? _csvParser.ParseClaimLevel(claimFilePath) : [];
        var allLines  = lineFilePath  is not null ? _csvParser.ParseLineLevel(lineFilePath)   : [];

        // ?? Filter option lists (from raw unfiltered data) ????????????????????
        var payerNames         = allClaims.Select(r => r.PayerName.Trim()).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();
        var payerTypes         = allClaims.Select(r => r.PayerType.Trim()).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();
        var panelNames         = allClaims.Select(r => r.PanelName.Trim()).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();
        var clinicNames        = allClaims.Select(r => r.ClinicName.Trim()).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();
        var referringProviders = allClaims.Select(r => r.ReferringProvider.Trim()).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();

        // ?? Apply filters to claim records ????????????????????????????????????
        var filtered = allClaims.AsEnumerable();

        if (!string.IsNullOrWhiteSpace(filterPayerName))
            filtered = filtered.Where(r => r.PayerName.Equals(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayerType))
            filtered = filtered.Where(r => r.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPanelName))
            filtered = filtered.Where(r => r.PanelName.Equals(filterPanelName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterClinicName))
            filtered = filtered.Where(r => r.ClinicName.Equals(filterClinicName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterReferringProvider))
            filtered = filtered.Where(r => r.ReferringProvider.Equals(filterReferringProvider, StringComparison.OrdinalIgnoreCase));
        if (DateOnly.TryParse(filterDosFrom, out var dosFrom))
            filtered = filtered.Where(r => DateOnly.TryParse(r.DateOfService, out var d) && d >= dosFrom);
        if (DateOnly.TryParse(filterDosTo, out var dosTo))
            filtered = filtered.Where(r => DateOnly.TryParse(r.DateOfService, out var d) && d <= dosTo);
        if (DateOnly.TryParse(filterFirstBillFrom, out var fbFrom))
            filtered = filtered.Where(r => DateOnly.TryParse(r.FirstBilledDate, out var d) && d >= fbFrom);
        if (DateOnly.TryParse(filterFirstBillTo, out var fbTo))
            filtered = filtered.Where(r => DateOnly.TryParse(r.FirstBilledDate, out var d) && d <= fbTo);

        var claimRecords = filtered.ToList();

        // Apply same filters to line records (shared dimensions)
        var lineFiltered = allLines.AsEnumerable();
        if (!string.IsNullOrWhiteSpace(filterPayerName))
            lineFiltered = lineFiltered.Where(r => r.PayerName.Equals(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayerType))
            lineFiltered = lineFiltered.Where(r => r.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPanelName))
            lineFiltered = lineFiltered.Where(r => r.PanelName.Equals(filterPanelName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterClinicName))
            lineFiltered = lineFiltered.Where(r => r.ClinicName.Equals(filterClinicName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterReferringProvider))
            lineFiltered = lineFiltered.Where(r => r.ReferringProvider.Equals(filterReferringProvider, StringComparison.OrdinalIgnoreCase));
        if (DateOnly.TryParse(filterDosFrom, out var ldosFrom))
            lineFiltered = lineFiltered.Where(r => DateOnly.TryParse(r.DateOfService, out var d) && d >= ldosFrom);
        if (DateOnly.TryParse(filterDosTo, out var ldosTo))
            lineFiltered = lineFiltered.Where(r => DateOnly.TryParse(r.DateOfService, out var d) && d <= ldosTo);
        if (DateOnly.TryParse(filterFirstBillFrom, out var lfbFrom))
            lineFiltered = lineFiltered.Where(r => DateOnly.TryParse(r.FirstBilledDate, out var d) && d >= lfbFrom);
        if (DateOnly.TryParse(filterFirstBillTo, out var lfbTo))
            lineFiltered = lineFiltered.Where(r => DateOnly.TryParse(r.FirstBilledDate, out var d) && d <= lfbTo);

        var lineRecords = lineFiltered.ToList();

        // ?? Insight helpers ???????????????????????????????????????????????????
        static IReadOnlyList<InsightRow> BuildInsight(
            IEnumerable<ClaimRecord> records,
            Func<ClaimRecord, string> keySelector) =>
            records
                .GroupBy(
                    r => { var k = keySelector(r).Trim(); return string.IsNullOrWhiteSpace(k) ? "Unknown" : k; },
                    StringComparer.OrdinalIgnoreCase)
                .Select(g => new InsightRow(
                    // Use the most-frequent casing as the display label
                    g.GroupBy(r => keySelector(r).Trim(), StringComparer.OrdinalIgnoreCase)
                     .OrderByDescending(x => x.Count()).First().Key,
                    g.Count(),
                    g.Sum(r => r.ChargeAmount),
                    g.Sum(r => r.TotalPayments),
                    g.Sum(r => r.TotalBalance)))
                .OrderByDescending(x => x.Charges)
                .Take(15)
                .ToList();

        static IReadOnlyList<(string Month, int Count)> BuildMonthly(
            IEnumerable<ClaimRecord> records,
            Func<ClaimRecord, string> dateSelector) =>
            records
                .Where(r => DateOnly.TryParse(dateSelector(r), out _))
                .GroupBy(r => { DateOnly.TryParse(dateSelector(r), out var d); return d.ToString("yyyy-MM"); })
                .Select(g => (Month: g.Key, Count: g.Count()))
                .OrderBy(x => x.Month)
                .ToList();

        // ?? Rate numerators � each uses the correct ClaimStatus filter per spec ??
        // Collection : SUM(AllowedAmount) where status IN (Fully Paid, Partially Paid,
        //              Patient Responsibility, Patient Payment)
        var collectionStatuses = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "Fully Paid", "Partially Paid", "Patient Responsibility", "Patient Payment" };

        // Denial : SUM(ChargeAmount) where status IN (Fully Denied, Partially Denied)
        var denialStatuses = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "Fully Denied", "Partially Denied" };

        // Adjustment : SUM(InsuranceAdjustments) where status IN (Complete W/O, Partially Adjusted)
        var adjustmentStatuses = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "Complete W/O", "Partially Adjusted" };

        // Outstanding : SUM(ChargeAmount) where status = No Response
        var outstandingStatuses = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "No Response" };

        decimal collectionNumerator  = claimRecords
            .Where(r => collectionStatuses.Contains(r.ClaimStatus))
            .Sum(r => r.AllowedAmount);

        decimal denialNumerator = claimRecords
            .Where(r => denialStatuses.Contains(r.ClaimStatus))
            .Sum(r => r.ChargeAmount);

        decimal adjustmentNumerator = claimRecords
            .Where(r => adjustmentStatuses.Contains(r.ClaimStatus))
            .Sum(r => r.InsuranceAdjustments);

        decimal outstandingNumerator = claimRecords
            .Where(r => outstandingStatuses.Contains(r.ClaimStatus))
            .Sum(r => r.ChargeAmount);

        // ?? Average Allowed by Panel � Month pivot ????????????????????????????
        // Only rows with a parseable DateOfService and non-blank PanelName contribute.
        // Group panel names case-insensitively; use the most-frequent casing as the display name.
        var panelMonthGroups = claimRecords
            .Where(r => !string.IsNullOrWhiteSpace(r.PanelName)
                     && DateOnly.TryParse(r.DateOfService, out _))
            .GroupBy(r =>
            {
                DateOnly.TryParse(r.DateOfService, out var d);
                return (Panel: r.PanelName.Trim(), Month: d.ToString("yyyy-MM"));
            })
            .Select(g => (g.Key.Panel, g.Key.Month,
                          Avg: Math.Round(g.Average(r => r.AllowedAmount), 0)))
            .ToList();

        // Resolve canonical panel name: group case-insensitively, pick the most frequent raw value.
        var canonicalPanelName = panelMonthGroups
            .GroupBy(x => x.Panel, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(
                g => g.Key,
                g => g.GroupBy(x => x.Panel)
                       .OrderByDescending(x => x.Count())
                       .First().Key,
                StringComparer.OrdinalIgnoreCase);

        var avgMonths = panelMonthGroups
            .Select(x => x.Month)
            .Distinct()
            .OrderBy(m => m)
            .ToList();

        var avgAllowedByPanelMonth = panelMonthGroups
            .GroupBy(x => x.Panel, StringComparer.OrdinalIgnoreCase)
            .Select(g => new
            {
                PanelName  = canonicalPanelName[g.Key],
                TotalAvg   = g.Sum(x => x.Avg),
                AvgByMonth = g
                    .GroupBy(x => x.Month)
                    .ToDictionary(
                        mg => mg.Key,
                        mg => Math.Round(mg.Average(x => x.Avg), 0)),
            })
            .OrderByDescending(x => x.TotalAvg)
            .Take(10)
            .OrderBy(x => x.PanelName, StringComparer.OrdinalIgnoreCase)
            .Select(x => new PanelMonthRow
            {
                PanelName  = x.PanelName,
                AvgByMonth = x.AvgByMonth,
            })
            .ToList();

        // ?? Top CPT By Charges (enriched) ????????????????????????????????????
        // Collection : PayStatus IN (Paid, Patient Responsibility)
        // Denial     : PayStatus = Denied
        // No Response: PayStatus = No Response
        var topCptDetail = lineRecords
            .Where(r => !string.IsNullOrWhiteSpace(r.CPTCode))
            .GroupBy(r => r.CPTCode)
            .Select(g =>
            {
                var charges    = g.Sum(r => r.ChargeAmount);
                var allowed    = g.Sum(r => r.AllowedAmount);
                var insBal     = g.Sum(r => r.InsuranceBalance);

                var collectionAllowed = g
                    .Where(r => r.PayStatus.Equals("Paid", StringComparison.OrdinalIgnoreCase)
                             || r.PayStatus.Equals("Patient Responsibility", StringComparison.OrdinalIgnoreCase))
                    .Sum(r => r.AllowedAmount);

                var denialCharges = g
                    .Where(r => r.PayStatus.Equals("Denied", StringComparison.OrdinalIgnoreCase))
                    .Sum(r => r.ChargeAmount);

                var noRespCharges = g
                    .Where(r => r.PayStatus.Equals("No Response", StringComparison.OrdinalIgnoreCase))
                    .Sum(r => r.ChargeAmount);

                return new CptDetailRow(
                    CPTCode        : g.Key,
                    Charges        : charges,
                    AllowedAmount  : allowed,
                    InsuranceBalance: insBal,
                    CollectionRate : charges == 0 ? 0 : Math.Round(collectionAllowed / charges * 100, 1),
                    DenialRate     : charges == 0 ? 0 : Math.Round(denialCharges     / charges * 100, 1),
                    NoResponseRate : charges == 0 ? 0 : Math.Round(noRespCharges     / charges * 100, 1));
            })
            .OrderByDescending(r => r.Charges)
            .Take(20)
            .ToList();

        var vm = new DashboardViewModel
        {
            AvailableLabs        = availableLabs,
            SelectedLab          = selectedLab,

            // Filters
            FilterPayerName          = filterPayerName,
            FilterPayerType          = filterPayerType,
            FilterPanelName          = filterPanelName,
            FilterClinicName         = filterClinicName,
            FilterReferringProvider  = filterReferringProvider,
            FilterDosFrom            = filterDosFrom,
            FilterDosTo              = filterDosTo,
            FilterFirstBillFrom      = filterFirstBillFrom,
            FilterFirstBillTo        = filterFirstBillTo,

            // Filter options
            PayerNames         = payerNames,
            PayerTypes         = payerTypes,
            PanelNames         = panelNames,
            ClinicNames        = clinicNames,
            ReferringProviders = referringProviders,

            // Claim KPIs
            TotalClaims          = claimRecords.Count,
            TotalCharges         = claimRecords.Sum(r => r.ChargeAmount),
            TotalPayments        = claimRecords.Sum(r => r.TotalPayments),
            TotalBalance         = claimRecords.Sum(r => r.TotalBalance),

            // Rate numerators
            CollectionNumerator  = collectionNumerator,
            DenialNumerator      = denialNumerator,
            AdjustmentNumerator  = adjustmentNumerator,
            OutstandingNumerator = outstandingNumerator,

            ClaimStatusBreakdown = claimRecords
                .GroupBy(r => string.IsNullOrWhiteSpace(r.ClaimStatus) ? "Unknown" : r.ClaimStatus)
                .ToDictionary(g => g.Key, g => g.Count()),
            ClaimStatusRows = claimRecords
                .GroupBy(r => string.IsNullOrWhiteSpace(r.ClaimStatus) ? "Unknown" : r.ClaimStatus)
                .Select(g => new ClaimStatusRow(
                    Status  : g.Key,
                    Claims  : g.Count(),
                    Charges : g.Sum(r => r.ChargeAmount),
                    Payments: g.Sum(r => r.TotalPayments),
                    Balance : g.Sum(r => r.TotalBalance)))
                .OrderByDescending(r => r.Claims)
                .ToList(),
            ResolvedClaimFilePath = claimFilePath,

            // Line KPIs
            TotalLines           = lineRecords.Count,
            LineTotalCharges     = lineRecords.Sum(r => r.ChargeAmount),
            LineTotalPayments    = lineRecords.Sum(r => r.TotalPayments),
            LineTotalBalance     = lineRecords.Sum(r => r.TotalBalance),
            TopCPTCharges        = lineRecords
                .GroupBy(r => r.CPTCode)
                .ToDictionary(g => g.Key, g => g.Sum(r => r.ChargeAmount))
                .OrderByDescending(kv => kv.Value).Take(10)
                .ToDictionary(kv => kv.Key, kv => kv.Value),
            PayStatusBreakdown   = lineRecords
                .GroupBy(r => string.IsNullOrWhiteSpace(r.PayStatus) ? "Unknown" : r.PayStatus)
                .ToDictionary(g => g.Key, g => g.Count()),
            ResolvedLineFilePath = lineFilePath,

            // Insights
            PayerLevelInsights         = BuildInsight(claimRecords, r => r.PayerName),
            PanelLevelInsights         = BuildInsight(claimRecords, r => r.PanelName),
            ClinicLevelInsights        = BuildInsight(claimRecords, r => r.ClinicName),
            ReferringPhysicianInsights = BuildInsight(claimRecords, r => r.ReferringProvider),
            DOSMonthly                 = BuildMonthly(claimRecords, r => r.DateOfService),
            FirstBillMonthly           = BuildMonthly(claimRecords, r => r.FirstBilledDate),

            PayerTypePayments = claimRecords
                .Where(r => !string.IsNullOrWhiteSpace(r.PayerType))
                .GroupBy(r => r.PayerType)
                .ToDictionary(g => g.Key, g => g.Sum(r => r.TotalPayments)),

            // Average Allowed by Panel � Month
            AvgAllowedMonths       = avgMonths,
            AvgAllowedByPanelMonth = avgAllowedByPanelMonth,

            // Top CPT By Charges (enriched)
            TopCptDetail = topCptDetail,
        };

        return View(vm);
    }

    // GET /Dashboard/ClaimLevel?lab=PCRLabsofAmerica&...
    public async Task<IActionResult> ClaimLevel(
        string? lab,
        string? filterPayerName,
        List<string>? filterPayerTypes,
        List<string>? filterClaimStatuses,
        List<string>? filterClinicNames,
        string? filterDenialCode,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        List<string>? filterAgingBuckets,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        string? filterChargeEnteredFrom,
        string? filterChargeEnteredTo,
        string? filterDosFrom,
        string? filterDosTo,
        bool filterFirstBillNull = false,
        bool filterFirstBillExcludeBlank = false,
        bool filterChargeEnteredNull = false,
        bool filterChargeEnteredExcludeBlank = false,
        bool filterDosNull = false,
        bool filterDenialCodeExcludeBlank = false,
        bool filterPayerExcludeBlank = false,
        bool filterPanelExcludeBlank = false,
        int page = 1,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        _labSettings.Labs.TryGetValue(selectedLab, out var labConfig);
        var useDb = labConfig is { LineClaimEnable: true }
                    && !string.IsNullOrWhiteSpace(labConfig.DbConnectionString);

        if (useDb)
        {
            return await ClaimLevelFromDbAsync(
                availableLabs, selectedLab, labConfig!,
                filterPayerName, filterPayerTypes, filterClaimStatuses,
                filterClinicNames, filterDenialCode, filterDenialCodeExcludeBlank,
                filterPayerNames, filterPayerExcludeBlank,
                filterPanelNames, filterPanelExcludeBlank,
                filterAgingBuckets,
                filterFirstBillFrom, filterFirstBillTo, filterFirstBillNull, filterFirstBillExcludeBlank,
                filterChargeEnteredFrom, filterChargeEnteredTo, filterChargeEnteredNull, filterChargeEnteredExcludeBlank,
                filterDosFrom, filterDosTo, filterDosNull,
                page, ct);
        }

        return ClaimLevelFromCsv(
            availableLabs, selectedLab,
            filterPayerName, filterPayerTypes, filterClaimStatuses,
            filterClinicNames, filterDenialCode, filterDenialCodeExcludeBlank,
            filterPayerNames, filterPayerExcludeBlank,
            filterPanelNames, filterPanelExcludeBlank,
            filterAgingBuckets,
            filterFirstBillFrom, filterFirstBillTo, filterFirstBillNull, filterFirstBillExcludeBlank,
            filterChargeEnteredFrom, filterChargeEnteredTo, filterChargeEnteredNull, filterChargeEnteredExcludeBlank,
            filterDosFrom, filterDosTo, filterDosNull,
            page);
    }

    /// <summary>Claim Level backed by the database with server-side pagination.</summary>
    private async Task<IActionResult> ClaimLevelFromDbAsync(
        List<string> availableLabs, string selectedLab, LabCsvConfig labConfig,
        string? filterPayerName, List<string>? filterPayerTypes, List<string>? filterClaimStatuses,
        List<string>? filterClinicNames, string? filterDenialCode, bool filterDenialCodeExcludeBlank,
        List<string>? filterPayerNames, bool filterPayerExcludeBlank,
        List<string>? filterPanelNames, bool filterPanelExcludeBlank,
        List<string>? filterAgingBuckets,
        string? filterFirstBillFrom, string? filterFirstBillTo, bool filterFirstBillNull, bool filterFirstBillExcludeBlank,
        string? filterChargeEnteredFrom, string? filterChargeEnteredTo, bool filterChargeEnteredNull, bool filterChargeEnteredExcludeBlank,
        string? filterDosFrom, string? filterDosTo, bool filterDosNull,
        int page, CancellationToken ct)
    {
        var connStr   = labConfig.DbConnectionString!;
        var dbLabName = string.IsNullOrWhiteSpace(labConfig.DbLabName) ? selectedLab : labConfig.DbLabName;

        DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
        DateOnly.TryParse(filterFirstBillTo, out var fbTo);
        DateOnly.TryParse(filterChargeEnteredFrom, out var ceFrom);
        DateOnly.TryParse(filterChargeEnteredTo, out var ceTo);
        DateOnly.TryParse(filterDosFrom, out var dosFrom);
        DateOnly.TryParse(filterDosTo, out var dosTo);

        try
        {
        var result = await _claimLineRepo.GetClaimLevelAsync(
            connStr, dbLabName,
            filterPayerName, filterPayerTypes, filterClaimStatuses,
            filterClinicNames, filterDenialCode, filterDenialCodeExcludeBlank,
            filterPayerNames, filterPayerExcludeBlank,
            filterPanelNames, filterPanelExcludeBlank,
            filterAgingBuckets,
            fbFrom != default ? fbFrom : null,
            fbTo != default ? fbTo : null,
            filterFirstBillNull,
            filterFirstBillExcludeBlank,
            ceFrom != default ? ceFrom : null,
            ceTo != default ? ceTo : null,
            filterChargeEnteredNull,
            filterChargeEnteredExcludeBlank,
            dosFrom != default ? dosFrom : null,
            dosTo != default ? dosTo : null,
            filterDosNull,
            page, PageSize, ct);

        var vm = new ClaimLevelViewModel
        {
            AvailableLabs      = availableLabs,
            SelectedLab        = selectedLab,
            FilterPayerName    = filterPayerName,
            FilterPayerTypes   = filterPayerTypes ?? [],
            FilterClaimStatuses= filterClaimStatuses ?? [],
            FilterClinicNames  = filterClinicNames ?? [],
            FilterDenialCode   = filterDenialCode,
            FilterDenialCodeExcludeBlank = filterDenialCodeExcludeBlank,
            FilterPayerNames   = filterPayerNames ?? [],
            FilterPayerExcludeBlank = filterPayerExcludeBlank,
            FilterPanelNames   = filterPanelNames ?? [],
            FilterPanelExcludeBlank = filterPanelExcludeBlank,
            FilterAgingBuckets = filterAgingBuckets ?? [],
            FilterFirstBillFrom     = filterFirstBillFrom,
            FilterFirstBillTo       = filterFirstBillTo,
            FilterFirstBillNull     = filterFirstBillNull,
            FilterFirstBillExcludeBlank = filterFirstBillExcludeBlank,
            FilterChargeEnteredFrom = filterChargeEnteredFrom,
            FilterChargeEnteredTo   = filterChargeEnteredTo,
            FilterChargeEnteredNull = filterChargeEnteredNull,
            FilterChargeEnteredExcludeBlank = filterChargeEnteredExcludeBlank,
            FilterDosFrom           = filterDosFrom,
            FilterDosTo             = filterDosTo,
            FilterDosNull           = filterDosNull,
            PayerTypes         = result.PayerTypes,
            ClaimStatuses      = result.ClaimStatuses,
            ClinicNames        = result.ClinicNames,
            PayerNames         = result.PayerNames,
            PanelNames         = result.PanelNames,
            AgingBuckets       = result.AgingBuckets,
            Records            = result.Records,
            Paging             = new PageInfo(Math.Max(1, page), PageSize, result.TotalFiltered, result.TotalAll),
            DataSource         = "SQL Database",
        };

        return View(vm);
        }
        catch (Exception ex) when (ex is Microsoft.Data.SqlClient.SqlException or TimeoutException or OperationCanceledException)
        {
            _logger.LogError(ex, "Claim Level query timed out or failed for lab '{LabName}'.", selectedLab);
            return View(new ClaimLevelViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"The query for {selectedLab} took too long and timed out. This lab has a very large dataset. Please apply filters (e.g. date range, payer, clinic) to narrow the results and try again.",
            });
        }
    }

    /// <summary>Claim Level backed by CSV files (legacy fallback).</summary>
    private IActionResult ClaimLevelFromCsv(
        List<string> availableLabs, string selectedLab,
        string? filterPayerName, List<string>? filterPayerTypes, List<string>? filterClaimStatuses,
        List<string>? filterClinicNames, string? filterDenialCode, bool filterDenialCodeExcludeBlank,
        List<string>? filterPayerNames, bool filterPayerExcludeBlank,
        List<string>? filterPanelNames, bool filterPanelExcludeBlank,
        List<string>? filterAgingBuckets,
        string? filterFirstBillFrom, string? filterFirstBillTo, bool filterFirstBillNull, bool filterFirstBillExcludeBlank,
        string? filterChargeEnteredFrom, string? filterChargeEnteredTo, bool filterChargeEnteredNull, bool filterChargeEnteredExcludeBlank,
        string? filterDosFrom, string? filterDosTo, bool filterDosNull,
        int page)
    {
        var claimFilePath = string.IsNullOrEmpty(selectedLab) ? null : _resolver.ResolveClaimLevelCsv(selectedLab);
        var allRecords    = claimFilePath is not null ? _csvParser.ParseClaimLevel(claimFilePath) : [];

        var payerTypes    = allRecords.Select(r => r.PayerType.Trim()).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();

        // Exclude values that look like dates
        var claimStatuses = allRecords
            .Select(r => r.ClaimStatus.Trim())
            .Where(v => !string.IsNullOrWhiteSpace(v) && !DateOnly.TryParse(v, out _))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(v => v)
            .ToList();

        var clinicNames   = allRecords.Select(r => r.ClinicName.Trim()).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();
        var payerNameOpts = allRecords.Select(r => r.PayerName.Trim()).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();
        var panelNameOpts = allRecords.Select(r => r.PanelName.Trim()).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();

        var filtered = allRecords.AsEnumerable();

        if (!string.IsNullOrWhiteSpace(filterPayerName))
            filtered = filtered.Where(r => r.PayerName.Contains(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (filterPayerTypes is { Count: > 0 })
        {
            var set = filterPayerTypes.ToHashSet(StringComparer.OrdinalIgnoreCase);
            filtered = filtered.Where(r => set.Contains(r.PayerType.Trim()));
        }
        if (filterClaimStatuses is { Count: > 0 })
        {
            var set = filterClaimStatuses.ToHashSet(StringComparer.OrdinalIgnoreCase);
            filtered = filtered.Where(r => set.Contains(r.ClaimStatus.Trim()));
        }
        if (filterClinicNames is { Count: > 0 })
        {
            var set = filterClinicNames.ToHashSet(StringComparer.OrdinalIgnoreCase);
            filtered = filtered.Where(r => set.Contains(r.ClinicName.Trim()));
        }
        if (!string.IsNullOrWhiteSpace(filterDenialCode))
            filtered = filtered.Where(r => r.DenialCode.Contains(filterDenialCode, StringComparison.OrdinalIgnoreCase));
        if (filterDenialCodeExcludeBlank)
            filtered = filtered.Where(r => !string.IsNullOrWhiteSpace(r.DenialCode));
        if (filterPayerNames is { Count: > 0 })
        {
            var set = filterPayerNames.ToHashSet(StringComparer.OrdinalIgnoreCase);
            filtered = filtered.Where(r => set.Contains(r.PayerName.Trim()));
        }
        if (filterPayerExcludeBlank)
            filtered = filtered.Where(r => !string.IsNullOrWhiteSpace(r.PayerName));
        if (filterPanelNames is { Count: > 0 })
        {
            var set = filterPanelNames.ToHashSet(StringComparer.OrdinalIgnoreCase);
            filtered = filtered.Where(r => set.Contains(r.PanelName.Trim()));
        }
        if (filterPanelExcludeBlank)
            filtered = filtered.Where(r => !string.IsNullOrWhiteSpace(r.PanelName));
        if (DateOnly.TryParse(filterFirstBillFrom, out var fbFrom))
            filtered = filtered.Where(r => DateOnly.TryParse(r.FirstBilledDate, out var d) && d >= fbFrom);
        if (DateOnly.TryParse(filterFirstBillTo, out var fbTo))
            filtered = filtered.Where(r => DateOnly.TryParse(r.FirstBilledDate, out var d) && d <= fbTo);
        if (filterFirstBillNull)
            filtered = filtered.Where(r => string.IsNullOrWhiteSpace(r.FirstBilledDate));
        if (filterFirstBillExcludeBlank)
            filtered = filtered.Where(r => !string.IsNullOrWhiteSpace(r.FirstBilledDate));
        if (DateOnly.TryParse(filterChargeEnteredFrom, out var ceFrom))
            filtered = filtered.Where(r => DateOnly.TryParse(r.ChargeEnteredDate, out var d) && d >= ceFrom);
        if (DateOnly.TryParse(filterChargeEnteredTo, out var ceTo))
            filtered = filtered.Where(r => DateOnly.TryParse(r.ChargeEnteredDate, out var d) && d <= ceTo);
        if (filterChargeEnteredNull)
            filtered = filtered.Where(r => string.IsNullOrWhiteSpace(r.ChargeEnteredDate));
        if (filterChargeEnteredExcludeBlank)
            filtered = filtered.Where(r => !string.IsNullOrWhiteSpace(r.ChargeEnteredDate));
        if (DateOnly.TryParse(filterDosFrom, out var dosFrom))
            filtered = filtered.Where(r => DateOnly.TryParse(r.DateOfService, out var d) && d >= dosFrom);
        if (DateOnly.TryParse(filterDosTo, out var dosTo))
            filtered = filtered.Where(r => DateOnly.TryParse(r.DateOfService, out var d) && d <= dosTo);
        if (filterDosNull)
            filtered = filtered.Where(r => string.IsNullOrWhiteSpace(r.DateOfService));

        var filteredList  = filtered.ToList();
        var currentPage   = Math.Max(1, page);
        var pagedRecords  = filteredList.Skip((currentPage - 1) * PageSize).Take(PageSize).ToList();

        var vm = new ClaimLevelViewModel
        {
            AvailableLabs      = availableLabs,
            SelectedLab        = selectedLab,
            FilterPayerName    = filterPayerName,
            FilterPayerTypes   = filterPayerTypes ?? [],
            FilterClaimStatuses= filterClaimStatuses ?? [],
            FilterClinicNames  = filterClinicNames ?? [],
            FilterDenialCode   = filterDenialCode,
            FilterDenialCodeExcludeBlank = filterDenialCodeExcludeBlank,
            FilterPayerNames   = filterPayerNames ?? [],
            FilterPayerExcludeBlank = filterPayerExcludeBlank,
            FilterPanelNames   = filterPanelNames ?? [],
            FilterPanelExcludeBlank = filterPanelExcludeBlank,
            FilterAgingBuckets = filterAgingBuckets ?? [],
            FilterFirstBillFrom     = filterFirstBillFrom,
            FilterFirstBillTo       = filterFirstBillTo,
            FilterFirstBillNull     = filterFirstBillNull,
            FilterFirstBillExcludeBlank = filterFirstBillExcludeBlank,
            FilterChargeEnteredFrom = filterChargeEnteredFrom,
            FilterChargeEnteredTo   = filterChargeEnteredTo,
            FilterChargeEnteredNull = filterChargeEnteredNull,
            FilterChargeEnteredExcludeBlank = filterChargeEnteredExcludeBlank,
            FilterDosFrom           = filterDosFrom,
            FilterDosTo             = filterDosTo,
            FilterDosNull           = filterDosNull,
            PayerTypes         = payerTypes,
            ClaimStatuses      = claimStatuses,
            ClinicNames        = clinicNames,
            PayerNames         = payerNameOpts,
            PanelNames         = panelNameOpts,
            Records            = pagedRecords,
            Paging             = new PageInfo(currentPage, PageSize, filteredList.Count, allRecords.Count),
            ResolvedFilePath   = claimFilePath,
            DataSource         = claimFilePath is not null ? $"CSV: {claimFilePath}" : null,
        };

        return View(vm);
    }

    // GET /Dashboard/LineLevel?lab=PCRLabsofAmerica&...
    public async Task<IActionResult> LineLevel(
        string? lab,
        string? filterPayerName,
        List<string>? filterPayerTypes,
        List<string>? filterClaimStatuses,
        List<string>? filterPayStatuses,
        List<string>? filterCPTCodes,
        List<string>? filterClinicNames,
        string? filterDenialCode,
        int page = 1,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        _labSettings.Labs.TryGetValue(selectedLab, out var labConfig);
        var useDb = labConfig is { LineClaimEnable: true }
                    && !string.IsNullOrWhiteSpace(labConfig.DbConnectionString);

        if (useDb)
        {
            return await LineLevelFromDbAsync(
                availableLabs, selectedLab, labConfig!,
                filterPayerName, filterPayerTypes, filterClaimStatuses,
                filterPayStatuses, filterCPTCodes, filterClinicNames,
                filterDenialCode, page, ct);
        }

        return LineLevelFromCsv(
            availableLabs, selectedLab,
            filterPayerName, filterPayerTypes, filterClaimStatuses,
            filterPayStatuses, filterCPTCodes, filterClinicNames,
            filterDenialCode, page);
    }

    /// <summary>Line Level backed by the database with server-side pagination.</summary>
    private async Task<IActionResult> LineLevelFromDbAsync(
        List<string> availableLabs, string selectedLab, LabCsvConfig labConfig,
        string? filterPayerName, List<string>? filterPayerTypes, List<string>? filterClaimStatuses,
        List<string>? filterPayStatuses, List<string>? filterCPTCodes, List<string>? filterClinicNames,
        string? filterDenialCode, int page, CancellationToken ct)
    {
        var connStr   = labConfig.DbConnectionString!;
        var dbLabName = string.IsNullOrWhiteSpace(labConfig.DbLabName) ? selectedLab : labConfig.DbLabName;

        try
        {
        var result = await _claimLineRepo.GetLineLevelAsync(
            connStr, dbLabName,
            filterPayerName, filterPayerTypes, filterClaimStatuses,
            filterPayStatuses, filterCPTCodes, filterClinicNames,
            filterDenialCode, page, PageSize, ct);

        var vm = new LineLevelViewModel
        {
            AvailableLabs       = availableLabs,
            SelectedLab         = selectedLab,
            FilterPayerName     = filterPayerName,
            FilterPayerTypes    = filterPayerTypes ?? [],
            FilterClaimStatuses = filterClaimStatuses ?? [],
            FilterPayStatuses   = filterPayStatuses ?? [],
            FilterCPTCodes      = filterCPTCodes ?? [],
            FilterClinicNames   = filterClinicNames ?? [],
            FilterDenialCode    = filterDenialCode,
            PayerTypes          = result.PayerTypes,
            ClaimStatuses       = result.ClaimStatuses,
            PayStatuses         = result.PayStatuses,
            ClinicNames         = result.ClinicNames,
            CPTCodes            = result.CPTCodes,
            Records             = result.Records,
            Paging              = new PageInfo(Math.Max(1, page), PageSize, result.TotalFiltered, result.TotalAll),
            DataSource          = "SQL Database",
        };

        return View(vm);
        }
        catch (Exception ex) when (ex is Microsoft.Data.SqlClient.SqlException or TimeoutException or OperationCanceledException)
        {
            _logger.LogError(ex, "Line Level query timed out or failed for lab '{LabName}'.", selectedLab);
            return View(new LineLevelViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"The query for {selectedLab} took too long and timed out. This lab has a very large dataset. Please apply filters (e.g. date range, payer, clinic) to narrow the results and try again.",
            });
        }
    }

    /// <summary>Line Level backed by CSV files (legacy fallback).</summary>
    private IActionResult LineLevelFromCsv(
        List<string> availableLabs, string selectedLab,
        string? filterPayerName, List<string>? filterPayerTypes, List<string>? filterClaimStatuses,
        List<string>? filterPayStatuses, List<string>? filterCPTCodes, List<string>? filterClinicNames,
        string? filterDenialCode, int page)
    {
        var lineFilePath = string.IsNullOrEmpty(selectedLab) ? null : _resolver.ResolveLineLevelCsv(selectedLab);
        var allRecords   = lineFilePath is not null ? _csvParser.ParseLineLevel(lineFilePath) : [];

        var payerTypes    = allRecords.Select(r => r.PayerType).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();

        // Exclude values that look like dates
        var claimStatuses = allRecords
            .Select(r => r.ClaimStatus.Trim())
            .Where(v => !string.IsNullOrWhiteSpace(v) && !DateOnly.TryParse(v, out _))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(v => v)
            .ToList();

        var payStatuses   = allRecords.Select(r => r.PayStatus.Trim()).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();
        var clinicNames   = allRecords.Select(r => r.ClinicName.Trim()).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();

        // Normalize CPT codes (strip decimal suffix e.g. "84443.00" ? "84443")
        var cptCodes = allRecords
            .Select(r => r.CPTCode.Trim())
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Select(v => decimal.TryParse(v, System.Globalization.NumberStyles.Any,
                             System.Globalization.CultureInfo.InvariantCulture, out var d)
                         ? ((long)d).ToString() : v)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(v => v)
            .ToList();

        var filtered = allRecords.AsEnumerable();

        if (!string.IsNullOrWhiteSpace(filterPayerName))
            filtered = filtered.Where(r => r.PayerName.Contains(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (filterPayerTypes is { Count: > 0 })
        {
            var set = filterPayerTypes.ToHashSet(StringComparer.OrdinalIgnoreCase);
            filtered = filtered.Where(r => set.Contains(r.PayerType.Trim()));
        }
        if (filterClaimStatuses is { Count: > 0 })
        {
            var set = filterClaimStatuses.ToHashSet(StringComparer.OrdinalIgnoreCase);
            filtered = filtered.Where(r => set.Contains(r.ClaimStatus.Trim()));
        }
        if (filterPayStatuses is { Count: > 0 })
        {
            var set = filterPayStatuses.ToHashSet(StringComparer.OrdinalIgnoreCase);
            filtered = filtered.Where(r => set.Contains(r.PayStatus.Trim()));
        }
        if (filterCPTCodes is { Count: > 0 })
        {
            var set = filterCPTCodes.ToHashSet(StringComparer.OrdinalIgnoreCase);
            filtered = filtered.Where(r => set.Contains(r.CPTCode.Trim()));
        }
        if (filterClinicNames is { Count: > 0 })
        {
            var set = filterClinicNames.ToHashSet(StringComparer.OrdinalIgnoreCase);
            filtered = filtered.Where(r => set.Contains(r.ClinicName.Trim()));
        }
        if (!string.IsNullOrWhiteSpace(filterDenialCode))
            filtered = filtered.Where(r => r.DenialCode.Contains(filterDenialCode, StringComparison.OrdinalIgnoreCase));

        var filteredList  = filtered.ToList();
        var currentPage   = Math.Max(1, page);
        var pagedRecords  = filteredList.Skip((currentPage - 1) * PageSize).Take(PageSize).ToList();

        var vm = new LineLevelViewModel
        {
            AvailableLabs       = availableLabs,
            SelectedLab         = selectedLab,
            FilterPayerName     = filterPayerName,
            FilterPayerTypes    = filterPayerTypes ?? [],
            FilterClaimStatuses = filterClaimStatuses ?? [],
            FilterPayStatuses   = filterPayStatuses ?? [],
            FilterCPTCodes      = filterCPTCodes ?? [],
            FilterClinicNames   = filterClinicNames ?? [],
            FilterDenialCode    = filterDenialCode,
            PayerTypes          = payerTypes,
            ClaimStatuses       = claimStatuses,
            PayStatuses         = payStatuses,
            ClinicNames         = clinicNames,
            CPTCodes            = cptCodes,
            Records             = pagedRecords,
            Paging              = new PageInfo(currentPage, PageSize, filteredList.Count, allRecords.Count),
            ResolvedFilePath    = lineFilePath,
            DataSource          = lineFilePath is not null ? $"CSV: {lineFilePath}" : null,
        };

        return View(vm);
    }

    // GET /Dashboard/ClinicSummary?lab=...&filterClinicName=...&...
    // GET /Dashboard/ClinicSummary?lab=...&filterClinicNames=A&filterClinicNames=B&...
    /// <summary>
    /// Clinic Summary page � reads from <c>dbo.ClaimLevelData</c> via the lab's
    /// DB connection string. Groups by ClinicName and computes billing, payment,
    /// denial, and outstanding metrics. Supports multi-select filters.
    /// </summary>
    public async Task<IActionResult> ClinicSummary(
        string? lab,
        List<string>? filterClinicNames,
        List<string>? filterSalesRepNames,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        // Normalize: remove empty entries
        filterClinicNames   = filterClinicNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterSalesRepNames = filterSalesRepNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPayerNames    = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames    = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        if (string.IsNullOrWhiteSpace(selectedLab))
            return View(new ClinicSummaryViewModel { AvailableLabs = availableLabs });

        if (!_labSettings.Labs.TryGetValue(selectedLab, out var config))
        {
            return View(new ClinicSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Configuration not found for {selectedLab}.",
            });
        }

        if (!config.EnableClinicsummary)
        {
            return View(new ClinicSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Clinic Summary feature is not enabled for {selectedLab}. Please contact your administrator.",
            });
        }

        if (!config.LineClaimEnable)
        {
            return View(new ClinicSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Clinic Summary is currently not available for {selectedLab}.",
            });
        }

        var connStr = config.DbConnectionString;
        if (string.IsNullOrWhiteSpace(connStr))
        {
            return View(new ClinicSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Clinic Summary is currently not available for {selectedLab}. No connection string configured.",
            });
        }

        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? selectedLab : config.DbLabName;

        DateOnly.TryParse(filterDosFrom, out var dosFrom);
        DateOnly.TryParse(filterDosTo, out var dosTo);
        DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
        DateOnly.TryParse(filterFirstBillTo, out var fbTo);

        try
        {
            var result = await _clinicSummaryRepo.GetClinicSummaryAsync(
                connStr, dbLabName,
                filterClinicNames.Count > 0 ? filterClinicNames : null,
                filterSalesRepNames.Count > 0 ? filterSalesRepNames : null,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                ct);

            var rows = result.Rows;

            // Build grand-total row from the rows
            var totals = new ClinicSummaryRow
            {
                ClinicName                  = "Grand Total",
                BilledClaimCount            = rows.Sum(r => r.BilledClaimCount),
                PaidClaimCount              = rows.Sum(r => r.PaidClaimCount),
                DeniedClaimCount            = rows.Sum(r => r.DeniedClaimCount),
                OutstandingClaimCount       = rows.Sum(r => r.OutstandingClaimCount),
                TotalBilledCharges          = rows.Sum(r => r.TotalBilledCharges),
                TotalBilledChargeOnPaidClaim = rows.Sum(r => r.TotalBilledChargeOnPaidClaim),
                TotalAllowedAmount          = rows.Sum(r => r.TotalAllowedAmount),
                TotalInsurancePaidAmount    = rows.Sum(r => r.TotalInsurancePaidAmount),
                TotalPatientResponsibility  = rows.Sum(r => r.TotalPatientResponsibility),
                TotalDeniedCharges          = rows.Sum(r => r.TotalDeniedCharges),
                TotalOutstandingCharges     = rows.Sum(r => r.TotalOutstandingCharges),
                AverageAllowedAmount        = rows.Count == 0 ? 0 : Math.Round(rows.Average(r => r.AverageAllowedAmount), 2),
                AverageInsurancePaidAmount  = rows.Count == 0 ? 0 : Math.Round(rows.Average(r => r.AverageInsurancePaidAmount), 2),
            };

            return View(new ClinicSummaryViewModel
            {
                AvailableLabs      = availableLabs,
                SelectedLab        = selectedLab,
                FilterClinicNames  = filterClinicNames,
                FilterSalesRepNames = filterSalesRepNames,
                FilterPayerNames   = filterPayerNames,
                FilterPanelNames   = filterPanelNames,
                FilterDosFrom      = filterDosFrom,
                FilterDosTo        = filterDosTo,
                FilterFirstBillFrom = filterFirstBillFrom,
                FilterFirstBillTo  = filterFirstBillTo,
                ClinicNames        = result.ClinicNames,
                SalesRepNames      = result.SalesRepNames,
                PayerNames         = result.PayerNames,
                PanelNames         = result.PanelNames,
                Rows               = rows,
                Totals             = totals,
                TopCollectedClinics   = result.TopCollectedClinics,
                TopCollectedSalesReps = result.TopCollectedSalesReps,
                TopCollectedPayers    = result.TopCollectedPayers,
                TopCollectedPanels    = result.TopCollectedPanels,
                TopDeniedClinics      = result.TopDeniedClinics,
                TopDeniedSalesReps    = result.TopDeniedSalesReps,
                TopDeniedPayers       = result.TopDeniedPayers,
                TopDeniedPanels       = result.TopDeniedPanels,
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Clinic Summary query failed for lab '{LabName}'.", selectedLab);
            return View(new ClinicSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Failed to load Clinic Summary: {ex.Message}",
            });
        }
    }

    /// <summary>
    /// Returns Clinic Panel Status pivot table as a partial view (loaded via AJAX tab).
    /// Groups ClaimLevelData by ClinicName → PanelName × ClaimStatus with COUNT(DISTINCT ClaimID).
    /// </summary>
    public async Task<IActionResult> ClinicPanelStatus(
        string? lab,
        List<string>? filterClinicNames,
        List<string>? filterSalesRepNames,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || !config.LineClaimEnable)
        {
            return PartialView("_ClinicPanelStatus", new ClinicPanelStatusViewModel
            {
                SelectedLab  = selectedLab ?? string.Empty,
                ErrorMessage = "Clinic Panel Status is not available for this lab.",
            });
        }

        var connStr = config.DbConnectionString;
        if (string.IsNullOrWhiteSpace(connStr))
        {
            return PartialView("_ClinicPanelStatus", new ClinicPanelStatusViewModel
            {
                SelectedLab  = selectedLab,
                ErrorMessage = "No connection string configured.",
            });
        }

        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? selectedLab : config.DbLabName;
        var (cn, sr, pn, pl, dosF, dosT, fbF, fbT) = NormalizeFilters(
            filterClinicNames, filterSalesRepNames, filterPayerNames, filterPanelNames,
            filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo);

        try
        {
            var vm = await _clinicSummaryRepo.GetClinicPanelStatusAsync(
                connStr, dbLabName, cn, sr, pn, pl, dosF, dosT, fbF, fbT, ct);
            return PartialView("_ClinicPanelStatus", vm);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Clinic Panel Status query failed for lab '{LabName}'.", selectedLab);
            return PartialView("_ClinicPanelStatus", new ClinicPanelStatusViewModel
            {
                SelectedLab  = selectedLab,
                ErrorMessage = $"Failed to load: {ex.Message}",
            });
        }
    }

    /// <summary>
    /// Returns Clinic $ Analysis pivot table as a partial view (loaded via AJAX tab).
    /// Groups ClaimLevelData by ClinicName → ClaimStatus with COUNT(DISTINCT ClaimID),
    /// SUM(ChargeAmount), SUM(InsurancePayment).
    /// </summary>
    public async Task<IActionResult> ClinicDollarAnalysis(
        string? lab,
        List<string>? filterClinicNames,
        List<string>? filterSalesRepNames,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || !config.LineClaimEnable)
        {
            return PartialView("_ClinicDollarAnalysis", new ClinicDollarAnalysisViewModel
            {
                SelectedLab  = selectedLab ?? string.Empty,
                ErrorMessage = "Clinic $ Analysis is not available for this lab.",
            });
        }

        var connStr = config.DbConnectionString;
        if (string.IsNullOrWhiteSpace(connStr))
        {
            return PartialView("_ClinicDollarAnalysis", new ClinicDollarAnalysisViewModel
            {
                SelectedLab  = selectedLab,
                ErrorMessage = "No connection string configured.",
            });
        }

        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? selectedLab : config.DbLabName;
        var (cn, sr, pn, pl, dosF, dosT, fbF, fbT) = NormalizeFilters(
            filterClinicNames, filterSalesRepNames, filterPayerNames, filterPanelNames,
            filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo);

        try
        {
            var vm = await _clinicSummaryRepo.GetClinicDollarAnalysisAsync(
                connStr, dbLabName, cn, sr, pn, pl, dosF, dosT, fbF, fbT, ct);
            return PartialView("_ClinicDollarAnalysis", vm);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Clinic $ Analysis query failed for lab '{LabName}'.", selectedLab);
            return PartialView("_ClinicDollarAnalysis", new ClinicDollarAnalysisViewModel
            {
                SelectedLab  = selectedLab,
                ErrorMessage = $"Failed to load: {ex.Message}",
            });
        }
    }

    /// <summary>
    /// Returns Clinic Count by DOS Month pivot table as a partial view (loaded via AJAX tab).
    /// Groups ClaimLevelData by ClinicName × YEAR(DateOfService) × MONTH(DateOfService)
    /// with COUNT(DISTINCT ClaimID).
    /// </summary>
    public async Task<IActionResult> ClinicDosCount(
        string? lab,
        List<string>? filterClinicNames,
        List<string>? filterSalesRepNames,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || !config.LineClaimEnable)
        {
            return PartialView("_ClinicDosCount", new ClinicDosCountViewModel
            {
                SelectedLab  = selectedLab ?? string.Empty,
                ErrorMessage = "Clinic Count by DOS Month is not available for this lab.",
            });
        }

        var connStr = config.DbConnectionString;
        if (string.IsNullOrWhiteSpace(connStr))
        {
            return PartialView("_ClinicDosCount", new ClinicDosCountViewModel
            {
                SelectedLab  = selectedLab,
                ErrorMessage = "No connection string configured.",
            });
        }

        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? selectedLab : config.DbLabName;
        var (cn, sr, pn, pl, dosF, dosT, fbF, fbT) = NormalizeFilters(
            filterClinicNames, filterSalesRepNames, filterPayerNames, filterPanelNames,
            filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo);

        try
        {
            var vm = await _clinicSummaryRepo.GetClinicDosCountAsync(
                connStr, dbLabName, cn, sr, pn, pl, dosF, dosT, fbF, fbT, ct);
            return PartialView("_ClinicDosCount", vm);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Clinic DOS Count query failed for lab '{LabName}'.", selectedLab);
            return PartialView("_ClinicDosCount", new ClinicDosCountViewModel
            {
                SelectedLab  = selectedLab,
                ErrorMessage = $"Failed to load: {ex.Message}",
            });
        }
    }

    /// <summary>
    /// Downloads the current Clinic Summary filtered data as a formatted Excel file.
    /// Accepts the same filter parameters as <see cref="ClinicSummary"/>.
    /// </summary>
    public async Task<IActionResult> ExportClinicSummaryExcel(
        string? lab,
        List<string>? filterClinicNames,
        List<string>? filterSalesRepNames,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        filterClinicNames   = filterClinicNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterSalesRepNames = filterSalesRepNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPayerNames    = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames    = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || !config.LineClaimEnable
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            TempData["ExportError"] = "Export is not available for the selected lab.";
            return RedirectToAction(nameof(ClinicSummary), new { lab });
        }

        var connStr   = config.DbConnectionString;
        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? selectedLab : config.DbLabName;

        DateOnly.TryParse(filterDosFrom, out var dosFrom);
        DateOnly.TryParse(filterDosTo, out var dosTo);
        DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
        DateOnly.TryParse(filterFirstBillTo, out var fbTo);

        try
        {
            var result = await _clinicSummaryRepo.GetClinicSummaryAsync(
                connStr, dbLabName,
                filterClinicNames.Count > 0 ? filterClinicNames : null,
                filterSalesRepNames.Count > 0 ? filterSalesRepNames : null,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                ct);

            var rows = result.Rows;
            var totals = new ClinicSummaryRow
            {
                ClinicName                  = "Grand Total",
                BilledClaimCount            = rows.Sum(r => r.BilledClaimCount),
                PaidClaimCount              = rows.Sum(r => r.PaidClaimCount),
                DeniedClaimCount            = rows.Sum(r => r.DeniedClaimCount),
                OutstandingClaimCount       = rows.Sum(r => r.OutstandingClaimCount),
                TotalBilledCharges          = rows.Sum(r => r.TotalBilledCharges),
                TotalBilledChargeOnPaidClaim = rows.Sum(r => r.TotalBilledChargeOnPaidClaim),
                TotalAllowedAmount          = rows.Sum(r => r.TotalAllowedAmount),
                TotalInsurancePaidAmount    = rows.Sum(r => r.TotalInsurancePaidAmount),
                TotalPatientResponsibility  = rows.Sum(r => r.TotalPatientResponsibility),
                TotalDeniedCharges          = rows.Sum(r => r.TotalDeniedCharges),
                TotalOutstandingCharges     = rows.Sum(r => r.TotalOutstandingCharges),
                AverageAllowedAmount        = rows.Count == 0 ? 0 : Math.Round(rows.Average(r => r.AverageAllowedAmount), 2),
                AverageInsurancePaidAmount  = rows.Count == 0 ? 0 : Math.Round(rows.Average(r => r.AverageInsurancePaidAmount), 2),
            };

            var (cn, sr, pn, pl, dosF, dosT, fbF, fbT) = NormalizeFilters(
                filterClinicNames, filterSalesRepNames, filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo);

            var panelStatusVm = await _clinicSummaryRepo.GetClinicPanelStatusAsync(
                connStr, dbLabName, cn, sr, pn, pl, dosF, dosT, fbF, fbT, ct);

            var dollarAnalysis = await _clinicSummaryRepo.GetClinicDollarAnalysisAsync(
                connStr, dbLabName, cn, sr, pn, pl, dosF, dosT, fbF, fbT, ct);

            var dosCountVm = await _clinicSummaryRepo.GetClinicDosCountAsync(
                connStr, dbLabName, cn, sr, pn, pl, dosF, dosT, fbF, fbT, ct);

            using var workbook = ClinicSummaryExcelExportBuilder.CreateWorkbook(
                rows, totals,
                result.TopCollectedClinics, result.TopCollectedSalesReps,
                result.TopCollectedPayers, result.TopCollectedPanels,
                result.TopDeniedClinics, result.TopDeniedSalesReps,
                result.TopDeniedPayers, result.TopDeniedPanels,
                selectedLab,
                panelStatus: panelStatusVm,
                dollarAnalysis: dollarAnalysis,
                dosCount: dosCountVm,
                activeFilters: new List<(string, IReadOnlyList<string>?)>
                {
                    ("Clinic", filterClinicNames is { Count: > 0 } ? filterClinicNames : null),
                    ("Sales Rep", filterSalesRepNames is { Count: > 0 } ? filterSalesRepNames : null),
                    ("Payer", filterPayerNames is { Count: > 0 } ? filterPayerNames : null),
                    ("Panel", filterPanelNames is { Count: > 0 } ? filterPanelNames : null),
                    ("DOS From", string.IsNullOrWhiteSpace(filterDosFrom) ? null : new[] { filterDosFrom }),
                    ("DOS To", string.IsNullOrWhiteSpace(filterDosTo) ? null : new[] { filterDosTo }),
                    ("First Bill From", string.IsNullOrWhiteSpace(filterFirstBillFrom) ? null : new[] { filterFirstBillFrom }),
                    ("First Bill To", string.IsNullOrWhiteSpace(filterFirstBillTo) ? null : new[] { filterFirstBillTo }),
                });

            await using var stream = new MemoryStream();
            workbook.SaveAs(stream);
            stream.Position = 0;

            var safeLabName = string.Join("_", selectedLab.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
            var fileName = $"{safeLabName}_ClinicSummary_{DateTime.Now:yyyyMMddHHmmss}.xlsx";

            return File(
                stream.ToArray(),
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Clinic Summary Excel export failed for lab '{LabName}'.", selectedLab);
            TempData["ExportError"] = $"Export failed: {ex.Message}";
            return RedirectToAction(nameof(ClinicSummary), new { lab });
        }
    }

    /// <summary>
    /// Sales Rep Summary page � reads from <c>dbo.ClaimLevelData</c> via the lab's
    /// DB connection string. Groups by SalesRepName and computes billing, payment,
    /// denial, and outstanding metrics. Supports multi-select filters.
    /// </summary>
    public async Task<IActionResult> SalesRepSummary(
        string? lab,
        List<string>? filterSalesRepNames,
        List<string>? filterClinicNames,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        // Normalize: remove empty entries
        filterSalesRepNames = filterSalesRepNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterClinicNames   = filterClinicNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPayerNames    = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames    = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        if (string.IsNullOrWhiteSpace(selectedLab))
            return View(new SalesRepSummaryViewModel { AvailableLabs = availableLabs });

        if (!_labSettings.Labs.TryGetValue(selectedLab, out var config))
        {
            return View(new SalesRepSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Configuration not found for {selectedLab}.",
            });
        }

        if (!config.EnableSalesRepsummary)
        {
            return View(new SalesRepSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Sales Rep Summary feature is not enabled for {selectedLab}. Please contact your administrator.",
            });
        }

        if (!config.LineClaimEnable)
        {
            return View(new SalesRepSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Sales Rep Summary is currently not available for {selectedLab}.",
            });
        }

        var connStr = config.DbConnectionString;
        if (string.IsNullOrWhiteSpace(connStr))
        {
            return View(new SalesRepSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Sales Rep Summary is currently not available for {selectedLab}. No connection string configured.",
            });
        }

        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? selectedLab : config.DbLabName;

        DateOnly.TryParse(filterDosFrom, out var srDosFrom);
        DateOnly.TryParse(filterDosTo, out var srDosTo);
        DateOnly.TryParse(filterFirstBillFrom, out var srFbFrom);
        DateOnly.TryParse(filterFirstBillTo, out var srFbTo);

        try
        {
            var result = await _salesRepSummaryRepo.GetSalesRepSummaryAsync(
                connStr, dbLabName,
                filterSalesRepNames.Count > 0 ? filterSalesRepNames : null,
                filterClinicNames.Count > 0 ? filterClinicNames : null,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                srDosFrom != default ? srDosFrom : null,
                srDosTo != default ? srDosTo : null,
                srFbFrom != default ? srFbFrom : null,
                srFbTo != default ? srFbTo : null,
                ct);

            var rows = result.Rows;

            var totals = new SalesRepSummaryRow
            {
                SalesRepName                = "Grand Total",
                BilledClaimCount            = rows.Sum(r => r.BilledClaimCount),
                PaidClaimCount              = rows.Sum(r => r.PaidClaimCount),
                DeniedClaimCount            = rows.Sum(r => r.DeniedClaimCount),
                OutstandingClaimCount       = rows.Sum(r => r.OutstandingClaimCount),
                TotalBilledCharges          = rows.Sum(r => r.TotalBilledCharges),
                TotalAllowedAmount          = rows.Sum(r => r.TotalAllowedAmount),
                TotalInsurancePaidAmount    = rows.Sum(r => r.TotalInsurancePaidAmount),
                TotalPatientResponsibility  = rows.Sum(r => r.TotalPatientResponsibility),
                TotalDeniedCharges          = rows.Sum(r => r.TotalDeniedCharges),
                TotalOutstandingCharges     = rows.Sum(r => r.TotalOutstandingCharges),
                AverageAllowedAmount        = rows.Count == 0 ? 0 : Math.Round(rows.Average(r => r.AverageAllowedAmount), 2),
                AverageInsurancePaidAmount  = rows.Count == 0 ? 0 : Math.Round(rows.Average(r => r.AverageInsurancePaidAmount), 2),
            };

            return View(new SalesRepSummaryViewModel
            {
                AvailableLabs        = availableLabs,
                SelectedLab          = selectedLab,
                FilterSalesRepNames  = filterSalesRepNames,
                FilterClinicNames    = filterClinicNames,
                FilterPayerNames     = filterPayerNames,
                FilterPanelNames     = filterPanelNames,
                FilterDosFrom        = filterDosFrom,
                FilterDosTo          = filterDosTo,
                FilterFirstBillFrom  = filterFirstBillFrom,
                FilterFirstBillTo    = filterFirstBillTo,
                SalesRepNames        = result.SalesRepNames,
                ClinicNames          = result.ClinicNames,
                PayerNames           = result.PayerNames,
                PanelNames           = result.PanelNames,
                Rows                 = rows,
                Totals               = totals,
                TopCollectedSalesReps = result.TopCollectedSalesReps,
                TopCollectedClinics   = result.TopCollectedClinics,
                TopCollectedPayers    = result.TopCollectedPayers,
                TopCollectedPanels    = result.TopCollectedPanels,
                TopDeniedSalesReps    = result.TopDeniedSalesReps,
                TopDeniedClinics      = result.TopDeniedClinics,
                TopDeniedPayers       = result.TopDeniedPayers,
                TopDeniedPanels       = result.TopDeniedPanels,
                DrilldownCollectedSalesReps = result.DrilldownCollectedSalesReps,
                DrilldownDeniedSalesReps    = result.DrilldownDeniedSalesReps,
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Sales Rep Summary query failed for lab '{LabName}'.", selectedLab);
            return View(new SalesRepSummaryViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Failed to load Sales Rep Summary: {ex.Message}",
            });
        }
    }

    /// <summary>
    /// Downloads the Dashboard Index data as a formatted Excel file.
    /// Accepts the same filter parameters as <see cref="Index"/>.
    /// </summary>
    public async Task<IActionResult> ExportDashboardExcel(
        string? lab,
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterClinicName,
        string? filterReferringProvider,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        try
        {
            var vm = await BuildDashboardViewModelAsync(
                selectedLab,
                filterPayerName, filterPayerType, filterPanelName, filterClinicName,
                filterReferringProvider, filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo, ct);

            using var workbook = DashboardExcelExportBuilder.CreateWorkbook(vm, selectedLab);

            await using var stream = new MemoryStream();
            workbook.SaveAs(stream);
            stream.Position = 0;

            var safeLabName = string.Join("_", selectedLab.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
            var fileName = $"{safeLabName}_Dashboard_{DateTime.Now:yyyyMMddHHmmss}.xlsx";

            return File(
                stream.ToArray(),
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Dashboard Excel export failed for lab '{LabName}'.", selectedLab);
            TempData["ExportError"] = $"Export failed: {ex.Message}";
            return RedirectToAction(nameof(Index), new { lab });
        }
    }

    /// <summary>
    /// Downloads the current Sales Rep Summary filtered data as a formatted Excel file.
    /// Accepts the same filter parameters as <see cref="SalesRepSummary"/>.
    /// </summary>
    public async Task<IActionResult> ExportSalesRepSummaryExcel(
        string? lab,
        List<string>? filterSalesRepNames,
        List<string>? filterClinicNames,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        filterSalesRepNames = filterSalesRepNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterClinicNames   = filterClinicNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPayerNames    = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames    = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || !config.LineClaimEnable
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            TempData["ExportError"] = "Export is not available for the selected lab.";
            return RedirectToAction(nameof(SalesRepSummary), new { lab });
        }

        var connStr   = config.DbConnectionString;
        var dbLabName = string.IsNullOrWhiteSpace(config.DbLabName) ? selectedLab : config.DbLabName;

        DateOnly.TryParse(filterDosFrom, out var dosFrom);
        DateOnly.TryParse(filterDosTo, out var dosTo);
        DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
        DateOnly.TryParse(filterFirstBillTo, out var fbTo);

        try
        {
            var result = await _salesRepSummaryRepo.GetSalesRepSummaryAsync(
                connStr, dbLabName,
                filterSalesRepNames.Count > 0 ? filterSalesRepNames : null,
                filterClinicNames.Count > 0 ? filterClinicNames : null,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                ct);

            var rows = result.Rows;
            var totals = new SalesRepSummaryRow
            {
                SalesRepName                = "Grand Total",
                BilledClaimCount            = rows.Sum(r => r.BilledClaimCount),
                PaidClaimCount              = rows.Sum(r => r.PaidClaimCount),
                DeniedClaimCount            = rows.Sum(r => r.DeniedClaimCount),
                OutstandingClaimCount       = rows.Sum(r => r.OutstandingClaimCount),
                TotalBilledCharges          = rows.Sum(r => r.TotalBilledCharges),
                TotalAllowedAmount          = rows.Sum(r => r.TotalAllowedAmount),
                TotalInsurancePaidAmount    = rows.Sum(r => r.TotalInsurancePaidAmount),
                TotalPatientResponsibility  = rows.Sum(r => r.TotalPatientResponsibility),
                TotalDeniedCharges          = rows.Sum(r => r.TotalDeniedCharges),
                TotalOutstandingCharges     = rows.Sum(r => r.TotalOutstandingCharges),
                AverageAllowedAmount        = rows.Count == 0 ? 0 : Math.Round(rows.Average(r => r.AverageAllowedAmount), 2),
                AverageInsurancePaidAmount  = rows.Count == 0 ? 0 : Math.Round(rows.Average(r => r.AverageInsurancePaidAmount), 2),
            };

            using var workbook = SalesRepSummaryExcelExportBuilder.CreateWorkbook(
                rows, totals,
                result.TopCollectedSalesReps, result.TopCollectedClinics,
                result.TopCollectedPayers, result.TopCollectedPanels,
                result.TopDeniedSalesReps, result.TopDeniedClinics,
                result.TopDeniedPayers, result.TopDeniedPanels,
                selectedLab,
                activeFilters: new List<(string, IReadOnlyList<string>?)>
                {
                    ("Sales Rep", filterSalesRepNames is { Count: > 0 } ? filterSalesRepNames : null),
                    ("Clinic", filterClinicNames is { Count: > 0 } ? filterClinicNames : null),
                    ("Payer", filterPayerNames is { Count: > 0 } ? filterPayerNames : null),
                    ("Panel", filterPanelNames is { Count: > 0 } ? filterPanelNames : null),
                    ("DOS From", string.IsNullOrWhiteSpace(filterDosFrom) ? null : new[] { filterDosFrom }),
                    ("DOS To", string.IsNullOrWhiteSpace(filterDosTo) ? null : new[] { filterDosTo }),
                    ("First Bill From", string.IsNullOrWhiteSpace(filterFirstBillFrom) ? null : new[] { filterFirstBillFrom }),
                    ("First Bill To", string.IsNullOrWhiteSpace(filterFirstBillTo) ? null : new[] { filterFirstBillTo }),
                });

            await using var stream = new MemoryStream();
            workbook.SaveAs(stream);
            stream.Position = 0;

            var safeLabName = string.Join("_", selectedLab.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
            var fileName = $"{safeLabName}_SalesRepSummary_{DateTime.Now:yyyyMMddHHmmss}.xlsx";

            return File(
                stream.ToArray(),
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Sales Rep Summary Excel export failed for lab '{LabName}'.", selectedLab);
            TempData["ExportError"] = $"Export failed: {ex.Message}";
            return RedirectToAction(nameof(SalesRepSummary), new { lab });
        }
    }

    /// <summary>Builds a DashboardViewModel from either DB or CSV source.</summary>
    private async Task<DashboardViewModel> BuildDashboardViewModelAsync(
        string selectedLab,
        string? filterPayerName, string? filterPayerType, string? filterPanelName,
        string? filterClinicName, string? filterReferringProvider,
        string? filterDosFrom, string? filterDosTo,
        string? filterFirstBillFrom, string? filterFirstBillTo,
        CancellationToken ct)
    {
        _labSettings.Labs.TryGetValue(selectedLab, out var labConfig);
        var useDb = labConfig is { LineClaimEnable: true }
                    && !string.IsNullOrWhiteSpace(labConfig.DbConnectionString);

        if (useDb)
        {
            var connStr   = labConfig!.DbConnectionString!;
            var dbLabName = string.IsNullOrWhiteSpace(labConfig.DbLabName) ? selectedLab : labConfig.DbLabName;

            DateOnly.TryParse(filterDosFrom, out var dosFrom);
            DateOnly.TryParse(filterDosTo, out var dosTo);
            DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
            DateOnly.TryParse(filterFirstBillTo, out var fbTo);

            var r = await _dashboardRepo.GetDashboardAsync(
                connStr, dbLabName,
                filterPayerName, filterPayerType, filterPanelName, filterClinicName,
                filterReferringProvider,
                dosFrom != default ? dosFrom : null,
                dosTo   != default ? dosTo   : null,
                fbFrom  != default ? fbFrom  : null,
                fbTo    != default ? fbTo    : null,
                ct);

            return new DashboardViewModel
            {
                SelectedLab          = selectedLab,
                FilterPayerName      = filterPayerName,
                FilterPayerType      = filterPayerType,
                FilterPanelName      = filterPanelName,
                FilterClinicName     = filterClinicName,
                FilterReferringProvider = filterReferringProvider,
                FilterDosFrom        = filterDosFrom,
                FilterDosTo          = filterDosTo,
                FilterFirstBillFrom  = filterFirstBillFrom,
                FilterFirstBillTo    = filterFirstBillTo,
                PayerNames           = r.PayerNames,
                PayerTypes           = r.PayerTypes,
                PanelNames           = r.PanelNames,
                ClinicNames          = r.ClinicNames,
                ReferringProviders   = r.ReferringProviders,
                TotalClaims          = r.TotalClaims,
                TotalCharges         = r.TotalCharges,
                TotalPayments        = r.TotalPayments,
                TotalBalance         = r.TotalBalance,
                CollectionNumerator  = r.CollectionNumerator,
                DenialNumerator      = r.DenialNumerator,
                AdjustmentNumerator  = r.AdjustmentNumerator,
                OutstandingNumerator = r.OutstandingNumerator,
                ClaimStatusBreakdown = r.ClaimStatusRows.ToDictionary(s => s.Status, s => s.Claims),
                ClaimStatusRows      = r.ClaimStatusRows,
                TotalLines           = r.TotalLines,
                LineTotalCharges     = r.LineTotalCharges,
                LineTotalPayments    = r.LineTotalPayments,
                LineTotalBalance     = r.LineTotalBalance,
                TopCPTCharges        = r.TopCPTCharges,
                PayStatusBreakdown   = r.PayStatusBreakdown,
                PayerLevelInsights         = r.PayerLevelInsights,
                PanelLevelInsights         = r.PanelLevelInsights,
                ClinicLevelInsights        = r.ClinicLevelInsights,
                ReferringPhysicianInsights = r.ReferringPhysicianInsights,
                DOSMonthly                 = r.DOSMonthly,
                FirstBillMonthly           = r.FirstBillMonthly,
                PayerTypePayments          = r.PayerTypePayments,
                AvgAllowedMonths           = r.AvgAllowedMonths,
                AvgAllowedByPanelMonth     = r.AvgAllowedByPanelMonth,
                TopCptDetail               = r.TopCptDetail,
                SupportsAggregateMode      = labConfig.UseDBDashboard,
            };
        }

        // CSV fallback
        var claimFilePath = string.IsNullOrEmpty(selectedLab) ? null : _resolver.ResolveClaimLevelCsv(selectedLab);
        var lineFilePath  = string.IsNullOrEmpty(selectedLab) ? null : _resolver.ResolveLineLevelCsv(selectedLab);
        var allClaims = claimFilePath is not null ? _csvParser.ParseClaimLevel(claimFilePath) : [];
        var allLines  = lineFilePath  is not null ? _csvParser.ParseLineLevel(lineFilePath)   : [];

        var filtered = allClaims.AsEnumerable();
        if (!string.IsNullOrWhiteSpace(filterPayerName))
            filtered = filtered.Where(x => x.PayerName.Equals(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayerType))
            filtered = filtered.Where(x => x.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPanelName))
            filtered = filtered.Where(x => x.PanelName.Equals(filterPanelName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterClinicName))
            filtered = filtered.Where(x => x.ClinicName.Equals(filterClinicName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterReferringProvider))
            filtered = filtered.Where(x => x.ReferringProvider.Equals(filterReferringProvider, StringComparison.OrdinalIgnoreCase));
        if (DateOnly.TryParse(filterDosFrom, out var csvDosFrom))
            filtered = filtered.Where(x => DateOnly.TryParse(x.DateOfService, out var d) && d >= csvDosFrom);
        if (DateOnly.TryParse(filterDosTo, out var csvDosTo))
            filtered = filtered.Where(x => DateOnly.TryParse(x.DateOfService, out var d) && d <= csvDosTo);
        if (DateOnly.TryParse(filterFirstBillFrom, out var csvFbFrom))
            filtered = filtered.Where(x => DateOnly.TryParse(x.FirstBilledDate, out var d) && d >= csvFbFrom);
        if (DateOnly.TryParse(filterFirstBillTo, out var csvFbTo))
            filtered = filtered.Where(x => DateOnly.TryParse(x.FirstBilledDate, out var d) && d <= csvFbTo);

        var claimRecords = filtered.ToList();

        var lineFiltered = allLines.AsEnumerable();
        if (!string.IsNullOrWhiteSpace(filterPayerName))
            lineFiltered = lineFiltered.Where(x => x.PayerName.Equals(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayerType))
            lineFiltered = lineFiltered.Where(x => x.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPanelName))
            lineFiltered = lineFiltered.Where(x => x.PanelName.Equals(filterPanelName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterClinicName))
            lineFiltered = lineFiltered.Where(x => x.ClinicName.Equals(filterClinicName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterReferringProvider))
            lineFiltered = lineFiltered.Where(x => x.ReferringProvider.Equals(filterReferringProvider, StringComparison.OrdinalIgnoreCase));
        if (DateOnly.TryParse(filterDosFrom, out var csvLDosFrom))
            lineFiltered = lineFiltered.Where(x => DateOnly.TryParse(x.DateOfService, out var d) && d >= csvLDosFrom);
        if (DateOnly.TryParse(filterDosTo, out var csvLDosTo))
            lineFiltered = lineFiltered.Where(x => DateOnly.TryParse(x.DateOfService, out var d) && d <= csvLDosTo);
        if (DateOnly.TryParse(filterFirstBillFrom, out var csvLFbFrom))
            lineFiltered = lineFiltered.Where(x => DateOnly.TryParse(x.FirstBilledDate, out var d) && d >= csvLFbFrom);
        if (DateOnly.TryParse(filterFirstBillTo, out var csvLFbTo))
            lineFiltered = lineFiltered.Where(x => DateOnly.TryParse(x.FirstBilledDate, out var d) && d <= csvLFbTo);

        var lineRecords = lineFiltered.ToList();

        static IReadOnlyList<InsightRow> BuildInsight(IEnumerable<ClaimRecord> records, Func<ClaimRecord, string> keySelector) =>
            records
                .GroupBy(x => { var k = keySelector(x).Trim(); return string.IsNullOrWhiteSpace(k) ? "Unknown" : k; }, StringComparer.OrdinalIgnoreCase)
                .Select(g => new InsightRow(
                    g.GroupBy(x => keySelector(x).Trim(), StringComparer.OrdinalIgnoreCase).OrderByDescending(x => x.Count()).First().Key,
                    g.Count(), g.Sum(x => x.ChargeAmount), g.Sum(x => x.TotalPayments), g.Sum(x => x.TotalBalance)))
                .OrderByDescending(x => x.Charges).Take(15).ToList();

        static IReadOnlyList<(string Month, int Count)> BuildMonthly(IEnumerable<ClaimRecord> records, Func<ClaimRecord, string> dateSelector) =>
            records.Where(x => DateOnly.TryParse(dateSelector(x), out _))
                .GroupBy(x => { DateOnly.TryParse(dateSelector(x), out var d); return d.ToString("yyyy-MM"); })
                .Select(g => (Month: g.Key, Count: g.Count())).OrderBy(x => x.Month).ToList();

        var collectionStatuses = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "Fully Paid", "Partially Paid", "Patient Responsibility", "Patient Payment" };
        var denialStatuses = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "Fully Denied", "Partially Denied" };
        var adjustmentStatuses = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "Complete W/O", "Partially Adjusted" };
        var outstandingStatuses = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "No Response" };

        var topCptDetail = lineRecords
            .Where(x => !string.IsNullOrWhiteSpace(x.CPTCode))
            .GroupBy(x => x.CPTCode)
            .Select(g =>
            {
                var charges = g.Sum(x => x.ChargeAmount);
                var collAllowed = g.Where(x => x.PayStatus.Equals("Paid", StringComparison.OrdinalIgnoreCase)
                    || x.PayStatus.Equals("Patient Responsibility", StringComparison.OrdinalIgnoreCase)).Sum(x => x.AllowedAmount);
                var denCharges = g.Where(x => x.PayStatus.Equals("Denied", StringComparison.OrdinalIgnoreCase)).Sum(x => x.ChargeAmount);
                var noResp = g.Where(x => x.PayStatus.Equals("No Response", StringComparison.OrdinalIgnoreCase)).Sum(x => x.ChargeAmount);
                return new CptDetailRow(g.Key, charges, g.Sum(x => x.AllowedAmount), g.Sum(x => x.InsuranceBalance),
                    charges == 0 ? 0 : Math.Round(collAllowed / charges * 100, 1),
                    charges == 0 ? 0 : Math.Round(denCharges / charges * 100, 1),
                    charges == 0 ? 0 : Math.Round(noResp / charges * 100, 1));
            }).OrderByDescending(x => x.Charges).Take(20).ToList();

        return new DashboardViewModel
        {
            SelectedLab = selectedLab,
            TotalClaims = claimRecords.Count,
            TotalCharges = claimRecords.Sum(x => x.ChargeAmount),
            TotalPayments = claimRecords.Sum(x => x.TotalPayments),
            TotalBalance = claimRecords.Sum(x => x.TotalBalance),
            CollectionNumerator = claimRecords.Where(x => collectionStatuses.Contains(x.ClaimStatus)).Sum(x => x.AllowedAmount),
            DenialNumerator = claimRecords.Where(x => denialStatuses.Contains(x.ClaimStatus)).Sum(x => x.ChargeAmount),
            AdjustmentNumerator = claimRecords.Where(x => adjustmentStatuses.Contains(x.ClaimStatus)).Sum(x => x.InsuranceAdjustments),
            OutstandingNumerator = claimRecords.Where(x => outstandingStatuses.Contains(x.ClaimStatus)).Sum(x => x.ChargeAmount),
            ClaimStatusBreakdown = claimRecords.GroupBy(x => string.IsNullOrWhiteSpace(x.ClaimStatus) ? "Unknown" : x.ClaimStatus).ToDictionary(g => g.Key, g => g.Count()),
            ClaimStatusRows = claimRecords.GroupBy(x => string.IsNullOrWhiteSpace(x.ClaimStatus) ? "Unknown" : x.ClaimStatus)
                .Select(g => new ClaimStatusRow(g.Key, g.Count(), g.Sum(x => x.ChargeAmount), g.Sum(x => x.TotalPayments), g.Sum(x => x.TotalBalance)))
                .OrderByDescending(x => x.Claims).ToList(),
            TotalLines = lineRecords.Count,
            LineTotalCharges = lineRecords.Sum(x => x.ChargeAmount),
            LineTotalPayments = lineRecords.Sum(x => x.TotalPayments),
            LineTotalBalance = lineRecords.Sum(x => x.TotalBalance),
            TopCPTCharges = lineRecords.GroupBy(x => x.CPTCode).ToDictionary(g => g.Key, g => g.Sum(x => x.ChargeAmount))
                .OrderByDescending(kv => kv.Value).Take(10).ToDictionary(kv => kv.Key, kv => kv.Value),
            PayStatusBreakdown = lineRecords.GroupBy(x => string.IsNullOrWhiteSpace(x.PayStatus) ? "Unknown" : x.PayStatus)
                .ToDictionary(g => g.Key, g => g.Count()),
            PayerLevelInsights = BuildInsight(claimRecords, x => x.PayerName),
            PanelLevelInsights = BuildInsight(claimRecords, x => x.PanelName),
            ClinicLevelInsights = BuildInsight(claimRecords, x => x.ClinicName),
            ReferringPhysicianInsights = BuildInsight(claimRecords, x => x.ReferringProvider),
            DOSMonthly = BuildMonthly(claimRecords, x => x.DateOfService),
            FirstBillMonthly = BuildMonthly(claimRecords, x => x.FirstBilledDate),
            PayerTypePayments = claimRecords.Where(x => !string.IsNullOrWhiteSpace(x.PayerType))
                .GroupBy(x => x.PayerType).ToDictionary(g => g.Key, g => g.Sum(x => x.TotalPayments)),
            TopCptDetail = topCptDetail,
        };
    }

    // ?? Production Report ????????????????????????????????????????????????

    /// <summary>
    /// Production Report page � Monthly Claim Volume pivot table.
    /// Source: dbo.ClaimLevelData grouped by PanelName � Year/Month(FirstBilledDate).
    /// </summary>
    public async Task<IActionResult> ProductionReport(
        string? lab,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        string? filterFirstBilledFrom,
        string? filterFirstBilledTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        filterPayerNames = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        if (string.IsNullOrWhiteSpace(selectedLab))
            return View(new ProductionReportViewModel { AvailableLabs = availableLabs });

        if (!_labSettings.Labs.TryGetValue(selectedLab, out var config))
        {
            return View(new ProductionReportViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Configuration not found for {selectedLab}.",
            });
        }

        if (!config.EnableProductionReport)
        {
            return View(new ProductionReportViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Production Report feature is not enabled for {selectedLab}. Please contact your administrator.",
            });
        }

        if (!config.LineClaimEnable)
        {
            return View(new ProductionReportViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Production Report is currently not available for {selectedLab}.",
            });
        }

        var connStr = config.DbConnectionString;
        if (string.IsNullOrWhiteSpace(connStr))
        {
            return View(new ProductionReportViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Production Report is currently not available for {selectedLab}. No connection string configured.",
            });
        }

        DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
        DateOnly.TryParse(filterFirstBillTo, out var fbTo);
        DateOnly.TryParse(filterDosFrom, out var dosFrom);
        DateOnly.TryParse(filterDosTo, out var dosTo);
        DateOnly.TryParse(filterFirstBilledFrom, out var fbldFrom);
        DateOnly.TryParse(filterFirstBilledTo, out var fbldTo);

        // Resolve the per-lab Production Summary rule (e.g. "Rule1" => use ChargeEnteredDate columns).
        var productionRule = config.ProductionSummary?.Rule;
        // Per-lab Weekly Claim Volume rule. Falls back to the monthly Rule when not configured.
        var weekRule = !string.IsNullOrWhiteSpace(config.ProductionSummary?.WeekRule)
            ? config.ProductionSummary!.WeekRule
            : productionRule;
        // Per-lab week boundary (e.g. "Mon to Sun", "Thu to Wed"). Null/empty => Monday-to-Sunday.
        var weekRange = config.ProductionSummary?.WeekRange;

        try
        {
            var monthlyTask = _productionReportRepo.GetMonthlyClaimVolumeAsync(
                connStr,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                fbldFrom != default ? fbldFrom : null,
                fbldTo != default ? fbldTo : null,
                productionRule,
                ct);

            var weeklyTask = _productionReportRepo.GetWeeklyClaimVolumeAsync(
                connStr,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                fbldFrom != default ? fbldFrom : null,
                fbldTo != default ? fbldTo : null,
                weekRule,
                weekRange,
                ct);

            var codingTask = _productionReportRepo.GetCodingAsync(
                connStr,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                ct);

            var payerBreakdownTask = _productionReportRepo.GetPayerBreakdownAsync(
                connStr,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                fbldFrom != default ? fbldFrom : null,
                fbldTo != default ? fbldTo : null,
                productionRule,
                ct);

            var payerPanelTask = _productionReportRepo.GetPayerPanelAsync(
                connStr,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                fbldFrom != default ? fbldFrom : null,
                fbldTo != default ? fbldTo : null,
                productionRule,
                ct);

            var unbilledAgingTask = _productionReportRepo.GetUnbilledAgingAsync(
                connStr,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                fbldFrom != default ? fbldFrom : null,
                fbldTo != default ? fbldTo : null,
                productionRule,
                ct);

            var cptBreakdownTask = _productionReportRepo.GetCptBreakdownAsync(
                connStr,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                fbldFrom != default ? fbldFrom : null,
                fbldTo != default ? fbldTo : null,
                ct);

            await Task.WhenAll(monthlyTask, weeklyTask, codingTask, payerBreakdownTask, payerPanelTask, unbilledAgingTask, cptBreakdownTask);

            var result = monthlyTask.Result;
            var weeklyResult = weeklyTask.Result;
            var codingResult = codingTask.Result;
            var pbResult = payerBreakdownTask.Result;
            var pxpResult = payerPanelTask.Result;
            var uaResult = unbilledAgingTask.Result;
            var cptResult = cptBreakdownTask.Result;

            return View(new ProductionReportViewModel
            {
                AvailableLabs      = availableLabs,
                SelectedLab        = selectedLab,
                ProductionSummaryRule = productionRule,
                ProductionSummaryWeekRule = weekRule,
                ProductionSummaryWeekRange = weekRange,
                FilterPayerNames   = filterPayerNames,
                FilterPanelNames   = filterPanelNames,
                FilterFirstBillFrom = filterFirstBillFrom,
                FilterFirstBillTo  = filterFirstBillTo,
                FilterDosFrom = filterDosFrom,
                FilterDosTo = filterDosTo,
                FilterFirstBilledFrom = filterFirstBilledFrom,
                FilterFirstBilledTo = filterFirstBilledTo,
                PayerNames         = result.PayerNames,
                PanelNames         = result.PanelNames,
                Months             = result.Months,
                Years              = result.Years,
                PanelRows          = result.PanelRows,
                GrandTotalByMonth  = result.GrandTotalByMonth,
                GrandTotalClaims   = result.GrandTotalClaims,
                GrandTotalCharges  = result.GrandTotalCharges,
                WeekColumns             = weeklyResult.WeekColumns,
                WeeklyPanelRows         = weeklyResult.PanelRows,
                WeeklyGrandTotalByWeek  = weeklyResult.GrandTotalByWeek,
                WeeklyGrandTotalClaims  = weeklyResult.GrandTotalClaims,
                WeeklyGrandTotalCharges = weeklyResult.GrandTotalCharges,
                CodingPanelRows         = codingResult.PanelRows,
                CodingGrandTotalClaims  = codingResult.GrandTotalClaims,
                CodingGrandTotalCharges = codingResult.GrandTotalCharges,
                PayerBreakdownMonths    = pbResult.Months,
                PayerBreakdownYears     = pbResult.Years,
                PayerBreakdownRows      = pbResult.PayerRows,
                PayerBreakdownGrandByMonth = pbResult.GrandTotalByMonth,
                PayerBreakdownGrandTotal   = pbResult.GrandTotal,
                PayerPanelColumns          = pxpResult.PanelColumns,
                PayerPanelRows             = pxpResult.PayerRows,
                PayerPanelGrandByPanel     = pxpResult.GrandTotalByPanel,
                PayerPanelGrandTotalClaims = pxpResult.GrandTotalClaims,
                PayerPanelGrandTotalCharges = pxpResult.GrandTotalCharges,
                UnbilledAgingRows              = uaResult.PanelRows,
                UnbilledAgingGrandByBucket     = uaResult.GrandTotalByBucket,
                UnbilledAgingGrandTotalClaims  = uaResult.GrandTotalClaims,
                UnbilledAgingGrandTotalCharges = uaResult.GrandTotalCharges,
                CptBreakdownMonths             = cptResult.Months,
                CptBreakdownYears              = cptResult.Years,
                CptBreakdownRows               = cptResult.CptRows,
                CptBreakdownGrandByMonth       = cptResult.GrandTotalByMonth,
                CptBreakdownGrandTotalUnits    = cptResult.GrandTotalUnits,
                CptBreakdownGrandTotalCharges  = cptResult.GrandTotalCharges,
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Production Report query failed for lab '{LabName}'.", selectedLab);
            return View(new ProductionReportViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Failed to load Production Report: {ex.Message}",
            });
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Production Summary Report — NorthWest only
    // Default (no filters): reads from SP-generated aggregate tables.
    // Filtered: falls back to live ClaimLevelData / LineLevelData queries.
    // Reset filter: returns to aggregate tables.
    // ─────────────────────────────────────────────────────────────────────────

    /// <summary>
    /// Production Summary Report page — NorthWest specific.
    /// Loads from pre-aggregated SP output tables by default.
    /// When the user applies filters the live tables are queried instead.
    /// </summary>
    public async Task<IActionResult> ProductionSummaryReport(
        string? lab,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        bool filterPayerNamesExclude,
        bool filterPanelNamesExclude,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        string? filterFirstBilledFrom,
        string? filterFirstBilledTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs
            .Where(kv => kv.Value.EnableProductionSummaryReport)
            .Select(kv => kv.Key)
            .OrderBy(x => x)
            .ToList();

        var selectedLab = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        filterPayerNames = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        if (string.IsNullOrWhiteSpace(selectedLab))
            return View(new ProductionReportViewModel { AvailableLabs = availableLabs });

        if (!_labSettings.Labs.TryGetValue(selectedLab, out var config))
            return View(new ProductionReportViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Configuration not found for {selectedLab}.",
            });

        if (!config.EnableProductionSummaryReport)
            return View(new ProductionReportViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = "Production Summary Report is not enabled for this lab.",
            });

        if (!config.LineClaimEnable || string.IsNullOrWhiteSpace(config.DbConnectionString))
            return View(new ProductionReportViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Production Summary Report is currently not available for {selectedLab}.",
            });

        var connStr        = config.DbConnectionString;
        var productionRule = config.ProductionSummary?.Rule;
        var weekRule       = !string.IsNullOrWhiteSpace(config.ProductionSummary?.WeekRule)
                             ? config.ProductionSummary!.WeekRule : productionRule;
        var weekRange      = config.ProductionSummary?.WeekRange;

        DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
        DateOnly.TryParse(filterFirstBillTo, out var fbTo);
        DateOnly.TryParse(filterDosFrom, out var dosFrom);
        DateOnly.TryParse(filterDosTo, out var dosTo);
        DateOnly.TryParse(filterFirstBilledFrom, out var fbldFrom);
        DateOnly.TryParse(filterFirstBilledTo, out var fbldTo);

        var hasFilters = filterPayerNames.Count > 0
            || filterPanelNames.Count > 0
            || filterPayerNamesExclude
            || filterPanelNamesExclude
            || dosFrom  != default || dosTo  != default
            || fbFrom   != default || fbTo   != default
            || fbldFrom != default || fbldTo != default;

        // Always load filter option lists from live table so dropdowns are populated
        // regardless of whether the user is viewing aggregate or filtered data.
        var isAugustusLab   = selectedLab.Equals("Augustus_Labs", StringComparison.OrdinalIgnoreCase)
                           || selectedLab.Equals("Augustus",      StringComparison.OrdinalIgnoreCase);
        var isNorthWestLab  = selectedLab.Equals("NorthWest",     StringComparison.OrdinalIgnoreCase);

        // Generic lab repos (Certus, Cove, Elixir, PCRLabsofAmerica, Beech_Tree, Rising_Tides)
        _labSummaryRepos.TryGetValue(selectedLab, out var genericSummaryRepo);

        var optionsTask = isAugustusLab
            ? _augSummaryRepo.GetFilterOptionsAsync(connStr, ct)
            : genericSummaryRepo is not null
                ? genericSummaryRepo.GetFilterOptionsAsync(connStr, ct)
                : _nwSummaryRepo.GetFilterOptionsAsync(connStr, ct);

        try
        {
            var (optionPayers, optionPanels) = await optionsTask;
            ProductionReportResult    monthlyResult;
            WeeklyClaimVolumeResult   weeklyResult;
            CodingResult              codingResult;
            PayerBreakdownResult      pbResult;
            PayerPanelResult          pxpResult;
            UnbilledAgingResult       uaResult;
            CptBreakdownResult        cptResult;

            if (!hasFilters)
            {
                // ── No filters: serve from SP aggregate tables ────────────────
                _logger.LogInformation("ProductionSummaryReport [{Lab}]: loading from aggregate tables.", selectedLab);

                if (isAugustusLab)
                {
                    var t1 = _augSummaryRepo.GetMonthlyAsync(connStr, ct);
                    var t2 = _augSummaryRepo.GetWeeklyAsync(connStr, ct);
                    var t3 = _augSummaryRepo.GetCodingAsync(connStr, ct);
                    var t4 = _augSummaryRepo.GetPayerBreakdownAsync(connStr, ct);
                    var t5 = _augSummaryRepo.GetPayerByPanelAsync(connStr, ct);
                    var t6 = _augSummaryRepo.GetUnbilledAgingAsync(connStr, ct);
                    // CPT always uses live query; pass rule so Augustus gets COUNT(DISTINCT CPTCode)
                    var t7 = _productionReportRepo.GetCptBreakdownAsync(connStr,
                        null, null, null, null, null, null, ct, rule: productionRule);

                    await Task.WhenAll(t1, t2, t3, t4, t5, t6, t7);

                    monthlyResult = t1.Result;
                    weeklyResult  = t2.Result;
                    codingResult  = t3.Result;
                    pbResult      = t4.Result;
                    pxpResult     = t5.Result;
                    uaResult      = t6.Result;
                    cptResult     = t7.Result;
                }
                else if (genericSummaryRepo is not null)
                {
                    // Generic labs: Certus, Cove, Elixir, PCRLabsofAmerica, Beech_Tree, Rising_Tides.
                    // CPT always uses the live query (aggregate table is advisory only).
                    var t1 = genericSummaryRepo.GetMonthlyAsync(connStr, ct);
                    var t2 = genericSummaryRepo.GetWeeklyAsync(connStr, ct);
                    var t3 = genericSummaryRepo.GetCodingAsync(connStr, ct);
                    var t4 = genericSummaryRepo.GetPayerBreakdownAsync(connStr, ct);
                    var t5 = genericSummaryRepo.GetPayerByPanelAsync(connStr, ct);
                    var t6 = genericSummaryRepo.GetUnbilledAgingAsync(connStr, ct);
                    var t7 = _productionReportRepo.GetCptBreakdownAsync(connStr,
                        null, null, null, null, null, null, ct, rule: productionRule);

                    await Task.WhenAll(t1, t2, t3, t4, t5, t6, t7);

                    monthlyResult = t1.Result;
                    weeklyResult  = t2.Result;
                    codingResult  = t3.Result;
                    pbResult      = t4.Result;
                    pxpResult     = t5.Result;
                    uaResult      = t6.Result;
                    cptResult     = t7.Result;
                }
                else
                {
                    // NorthWest (and any future lab added here)
                    var t1 = _nwSummaryRepo.GetMonthlyAsync(connStr, ct);
                    var t2 = _nwSummaryRepo.GetWeeklyAsync(connStr, ct);
                    var t3 = _nwSummaryRepo.GetCodingAsync(connStr, ct);
                    var t4 = _nwSummaryRepo.GetPayerBreakdownAsync(connStr, ct);
                    var t5 = _nwSummaryRepo.GetPayerByPanelAsync(connStr, ct);
                    var t6 = _nwSummaryRepo.GetUnbilledAgingAsync(connStr, ct);
                    // CPT always uses live query
                    var t7 = _productionReportRepo.GetCptBreakdownAsync(connStr,
                        null, null, null, null, null, null, ct, rule: productionRule);

                    await Task.WhenAll(t1, t2, t3, t4, t5, t6, t7);

                    monthlyResult = t1.Result;
                    weeklyResult  = t2.Result;
                    codingResult  = t3.Result;
                    pbResult      = t4.Result;
                    pxpResult     = t5.Result;
                    uaResult      = t6.Result;
                    cptResult     = t7.Result;
                }
            }
            else
            {
                // ── Filters active: query live tables ─────────────────────────
                // When exclude=true, we omit that filter from the SQL query and
                // instead apply the exclusion via post-processing on the results.
                _logger.LogInformation("ProductionSummaryReport [{Lab}]: filters active, querying live tables.", selectedLab);

                var livePayerFilter  = filterPayerNamesExclude  ? null : (filterPayerNames.Count  > 0 ? filterPayerNames  : null);
                var livePanelFilter  = filterPanelNamesExclude  ? null : (filterPanelNames.Count  > 0 ? filterPanelNames  : null);

                var t1 = _productionReportRepo.GetMonthlyClaimVolumeAsync(connStr,
                    livePayerFilter, livePanelFilter,
                    dosFrom != default ? dosFrom : null, dosTo != default ? dosTo : null,
                    fbFrom  != default ? fbFrom  : null, fbTo  != default ? fbTo  : null,
                    fbldFrom != default ? fbldFrom : null, fbldTo != default ? fbldTo : null,
                    productionRule, ct, panelNewStrict: isAugustusLab);

                var t2 = _productionReportRepo.GetWeeklyClaimVolumeAsync(connStr,
                    livePayerFilter, livePanelFilter,
                    dosFrom != default ? dosFrom : null, dosTo != default ? dosTo : null,
                    fbFrom  != default ? fbFrom  : null, fbTo  != default ? fbTo  : null,
                    fbldFrom != default ? fbldFrom : null, fbldTo != default ? fbldTo : null,
                    weekRule, weekRange, ct, panelNewStrict: isAugustusLab);

                var t3 = _productionReportRepo.GetCodingAsync(connStr, livePanelFilter, ct);

                var t4 = _productionReportRepo.GetPayerBreakdownAsync(connStr,
                    livePayerFilter, livePanelFilter,
                    dosFrom != default ? dosFrom : null, dosTo != default ? dosTo : null,
                    fbFrom  != default ? fbFrom  : null, fbTo  != default ? fbTo  : null,
                    fbldFrom != default ? fbldFrom : null, fbldTo != default ? fbldTo : null,
                    productionRule, ct, panelNewStrict: isAugustusLab);

                var t5 = _productionReportRepo.GetPayerPanelAsync(connStr,
                    livePayerFilter, livePanelFilter,
                    dosFrom != default ? dosFrom : null, dosTo != default ? dosTo : null,
                    fbFrom  != default ? fbFrom  : null, fbTo  != default ? fbTo  : null,
                    fbldFrom != default ? fbldFrom : null, fbldTo != default ? fbldTo : null,
                    productionRule, ct, panelNewStrict: isAugustusLab);

                var t6 = _productionReportRepo.GetUnbilledAgingAsync(connStr,
                    livePanelFilter,
                    dosFrom != default ? dosFrom : null, dosTo != default ? dosTo : null,
                    fbFrom  != default ? fbFrom  : null, fbTo  != default ? fbTo  : null,
                    fbldFrom != default ? fbldFrom : null, fbldTo != default ? fbldTo : null,
                    productionRule, ct);

                var t7 = _productionReportRepo.GetCptBreakdownAsync(connStr,
                    dosFrom != default ? dosFrom : null, dosTo != default ? dosTo : null,
                    fbFrom  != default ? fbFrom  : null, fbTo  != default ? fbTo  : null,
                    fbldFrom != default ? fbldFrom : null, fbldTo != default ? fbldTo : null,
                    ct, rule: productionRule);

                await Task.WhenAll(t1, t2, t3, t4, t5, t6, t7);

                monthlyResult = t1.Result;
                weeklyResult  = t2.Result;
                codingResult  = t3.Result;
                pbResult      = t4.Result;
                pxpResult     = t5.Result;
                uaResult      = t6.Result;
                cptResult     = t7.Result;
            }

            // ── Post-process: apply Exclude logic ─────────────────────────────
            if (filterPayerNamesExclude && filterPayerNames.Count > 0)
            {
                var excPayers = filterPayerNames.ToHashSet(StringComparer.OrdinalIgnoreCase);

                foreach (var p in monthlyResult.PanelRows)
                    p.TopPayers.RemoveAll(tp => excPayers.Contains(tp.PayerName));

                foreach (var p in weeklyResult.PanelRows)
                    p.TopPayers.RemoveAll(tp => excPayers.Contains(tp.PayerName));

                pbResult.PayerRows.RemoveAll(r => excPayers.Contains(r.PayerName));
                pxpResult.PayerRows.RemoveAll(r => excPayers.Contains(r.PayerName));

                // Unbilled Aging rows for NW are keyed by PayerName (stored in PanelName slot)
                uaResult.PanelRows.RemoveAll(r => excPayers.Contains(r.PanelName));
            }

            if (filterPanelNamesExclude && filterPanelNames.Count > 0)
            {
                var excPanels = filterPanelNames.ToHashSet(StringComparer.OrdinalIgnoreCase);

                monthlyResult.PanelRows.RemoveAll(p => excPanels.Contains(p.PanelName));
                weeklyResult.PanelRows.RemoveAll(p => excPanels.Contains(p.PanelName));
                codingResult.PanelRows.RemoveAll(p => excPanels.Contains(p.PanelName));

                foreach (var r in pxpResult.PayerRows)
                {
                    foreach (var key in excPanels)
                        r.ByPanel.Remove(key);
                }
            }

            return View(new ProductionReportViewModel
            {
                AvailableLabs              = availableLabs,
                SelectedLab                = selectedLab,
                ProductionSummaryRule      = productionRule,
                ProductionSummaryWeekRule  = weekRule,
                ProductionSummaryWeekRange = weekRange,
                FilterPayerNames           = filterPayerNames,
                FilterPanelNames           = filterPanelNames,
                FilterPayerNamesExclude    = filterPayerNamesExclude,
                FilterPanelNamesExclude    = filterPanelNamesExclude,
                FilterFirstBillFrom        = filterFirstBillFrom,
                FilterFirstBillTo          = filterFirstBillTo,
                FilterDosFrom              = filterDosFrom,
                FilterDosTo                = filterDosTo,
                FilterFirstBilledFrom      = filterFirstBilledFrom,
                FilterFirstBilledTo        = filterFirstBilledTo,
                // Always use the live-queried option lists so dropdowns are never empty
                PayerNames                 = optionPayers,
                PanelNames                 = optionPanels,
                Months                     = monthlyResult.Months,
                Years                      = monthlyResult.Years,
                PanelRows                  = monthlyResult.PanelRows,
                GrandTotalByMonth          = monthlyResult.GrandTotalByMonth,
                GrandTotalClaims           = monthlyResult.GrandTotalClaims,
                GrandTotalCharges          = monthlyResult.GrandTotalCharges,
                WeekColumns                = weeklyResult.WeekColumns,
                WeeklyPanelRows            = weeklyResult.PanelRows,
                WeeklyGrandTotalByWeek     = weeklyResult.GrandTotalByWeek,
                WeeklyGrandTotalClaims     = weeklyResult.GrandTotalClaims,
                WeeklyGrandTotalCharges    = weeklyResult.GrandTotalCharges,
                CodingPanelRows            = codingResult.PanelRows,
                CodingGrandTotalClaims     = codingResult.GrandTotalClaims,
                CodingGrandTotalCharges    = codingResult.GrandTotalCharges,
                PayerBreakdownMonths       = pbResult.Months,
                PayerBreakdownYears        = pbResult.Years,
                PayerBreakdownRows         = pbResult.PayerRows,
                PayerBreakdownGrandByMonth = pbResult.GrandTotalByMonth,
                PayerBreakdownGrandTotal   = pbResult.GrandTotal,
                PayerPanelColumns          = pxpResult.PanelColumns,
                PayerPanelRows             = pxpResult.PayerRows,
                PayerPanelGrandByPanel     = pxpResult.GrandTotalByPanel,
                PayerPanelGrandTotalClaims = pxpResult.GrandTotalClaims,
                PayerPanelGrandTotalCharges = pxpResult.GrandTotalCharges,
                UnbilledAgingRows              = uaResult.PanelRows,
                UnbilledAgingGrandByBucket     = uaResult.GrandTotalByBucket,
                UnbilledAgingGrandTotalClaims  = uaResult.GrandTotalClaims,
                UnbilledAgingGrandTotalCharges = uaResult.GrandTotalCharges,
                CptBreakdownMonths             = cptResult.Months,
                CptBreakdownYears              = cptResult.Years,
                CptBreakdownRows               = cptResult.CptRows,
                CptBreakdownGrandByMonth       = cptResult.GrandTotalByMonth,
                CptBreakdownGrandTotalUnits    = cptResult.GrandTotalUnits,
                CptBreakdownGrandTotalCharges  = cptResult.GrandTotalCharges,
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "ProductionSummaryReport failed for lab '{LabName}'.", selectedLab);
            return View(new ProductionReportViewModel
            {
                AvailableLabs = availableLabs,
                SelectedLab   = selectedLab,
                ErrorMessage  = $"Failed to load Production Summary Report: {ex.Message}",
            });
        }
    }

    /// <summary>
    /// Exports the Production Report data to an Excel file, respecting the current filters.
    /// </summary>
    public async Task<IActionResult> ExportProductionReportExcel(
        string? lab,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo,
        string? filterFirstBilledFrom,
        string? filterFirstBilledTo,
        CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        filterPayerNames = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];
        filterPanelNames = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList() ?? [];

        if (string.IsNullOrWhiteSpace(selectedLab)
            || !_labSettings.Labs.TryGetValue(selectedLab, out var config)
            || !config.EnableProductionReport
            || !config.LineClaimEnable
            || string.IsNullOrWhiteSpace(config.DbConnectionString))
        {
            TempData["ExportError"] = "Production Report export is not available for the selected lab.";
            return RedirectToAction(nameof(ProductionReport), new { lab });
        }

        var connStr   = config.DbConnectionString;

        DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
        DateOnly.TryParse(filterFirstBillTo, out var fbTo);
        DateOnly.TryParse(filterDosFrom, out var dosFrom);
        DateOnly.TryParse(filterDosTo, out var dosTo);
        DateOnly.TryParse(filterFirstBilledFrom, out var fbldFrom);
        DateOnly.TryParse(filterFirstBilledTo, out var fbldTo);

        // Resolve the per-lab Production Summary rule (e.g. "Rule1" => use ChargeEnteredDate columns).
        var productionRule = config.ProductionSummary?.Rule;
        // Per-lab Weekly Claim Volume rule. Falls back to the monthly Rule when not configured.
        var weekRule = !string.IsNullOrWhiteSpace(config.ProductionSummary?.WeekRule)
            ? config.ProductionSummary!.WeekRule
            : productionRule;
        // Per-lab week boundary (e.g. "Mon to Sun", "Thu to Wed"). Null/empty => Monday-to-Sunday.
        var weekRange = config.ProductionSummary?.WeekRange;

        try
        {
            var monthlyTask = _productionReportRepo.GetMonthlyClaimVolumeAsync(
                connStr,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                fbldFrom != default ? fbldFrom : null,
                fbldTo != default ? fbldTo : null,
                productionRule,
                ct);

            var weeklyTask = _productionReportRepo.GetWeeklyClaimVolumeAsync(
                connStr,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                fbldFrom != default ? fbldFrom : null,
                fbldTo != default ? fbldTo : null,
                weekRule,
                weekRange,
                ct);

            var codingTask = _productionReportRepo.GetCodingAsync(
                connStr,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                ct);

            var payerBreakdownTask = _productionReportRepo.GetPayerBreakdownAsync(
                connStr,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                fbldFrom != default ? fbldFrom : null,
                fbldTo != default ? fbldTo : null,
                productionRule,
                ct);

            var payerPanelTask = _productionReportRepo.GetPayerPanelAsync(
                connStr,
                filterPayerNames.Count > 0 ? filterPayerNames : null,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                fbldFrom != default ? fbldFrom : null,
                fbldTo != default ? fbldTo : null,
                productionRule,
                ct);

            var unbilledAgingTask = _productionReportRepo.GetUnbilledAgingAsync(
                connStr,
                filterPanelNames.Count > 0 ? filterPanelNames : null,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                fbldFrom != default ? fbldFrom : null,
                fbldTo != default ? fbldTo : null,
                productionRule,
                ct);

            var cptBreakdownTask = _productionReportRepo.GetCptBreakdownAsync(
                connStr,
                dosFrom != default ? dosFrom : null,
                dosTo != default ? dosTo : null,
                fbFrom != default ? fbFrom : null,
                fbTo != default ? fbTo : null,
                fbldFrom != default ? fbldFrom : null,
                fbldTo != default ? fbldTo : null,
                ct);

            await Task.WhenAll(monthlyTask, weeklyTask, codingTask, payerBreakdownTask, payerPanelTask, unbilledAgingTask, cptBreakdownTask);

            var result        = monthlyTask.Result;
            var weeklyResult  = weeklyTask.Result;
            var codingResult  = codingTask.Result;
            var pbResult      = payerBreakdownTask.Result;
            var pxpResult     = payerPanelTask.Result;
            var uaResult      = unbilledAgingTask.Result;
            var cptResult     = cptBreakdownTask.Result;

            // Fetch raw data for ClaimLevelData and LineLevelData sheets
            var payerFilter = filterPayerNames.Count > 0 ? filterPayerNames : null;
            var panelFilter = filterPanelNames.Count > 0 ? filterPanelNames : null;
            var fbFromFilter = fbFrom != default ? fbFrom : (DateOnly?)null;
            var fbToFilter = fbTo != default ? fbTo : (DateOnly?)null;
            var dosFromFilter = dosFrom != default ? dosFrom : (DateOnly?)null;
            var dosToFilter = dosTo != default ? dosTo : (DateOnly?)null;
            var fbldFromFilter = fbldFrom != default ? fbldFrom : (DateOnly?)null;
            var fbldToFilter = fbldTo != default ? fbldTo : (DateOnly?)null;

            var claimExportTask = _productionReportRepo.GetClaimLevelDataExportAsync(
                connStr, payerFilter, panelFilter, dosFromFilter, dosToFilter, fbFromFilter, fbToFilter, fbldFromFilter, fbldToFilter, ct);
            var lineExportTask = _productionReportRepo.GetLineLevelDataExportAsync(
                connStr, payerFilter, panelFilter, dosFromFilter, dosToFilter, fbFromFilter, fbToFilter, fbldFromFilter, fbldToFilter, ct);

            await Task.WhenAll(claimExportTask, lineExportTask);

            var claimRows = await claimExportTask;
            var lineRows = await lineExportTask;

            var vm = new ProductionReportViewModel
            {
                AvailableLabs       = availableLabs,
                SelectedLab         = selectedLab,
                FilterPayerNames    = filterPayerNames,
                FilterPanelNames    = filterPanelNames,
                FilterFirstBillFrom = filterFirstBillFrom,
                FilterFirstBillTo   = filterFirstBillTo,
                FilterDosFrom = filterDosFrom,
                FilterDosTo = filterDosTo,
                FilterFirstBilledFrom = filterFirstBilledFrom,
                FilterFirstBilledTo = filterFirstBilledTo,
                PayerNames          = result.PayerNames,
                PanelNames          = result.PanelNames,
                Months              = result.Months,
                Years               = result.Years,
                PanelRows           = result.PanelRows,
                GrandTotalByMonth   = result.GrandTotalByMonth,
                GrandTotalClaims    = result.GrandTotalClaims,
                GrandTotalCharges   = result.GrandTotalCharges,
                WeekColumns              = weeklyResult.WeekColumns,
                WeeklyPanelRows          = weeklyResult.PanelRows,
                WeeklyGrandTotalByWeek   = weeklyResult.GrandTotalByWeek,
                WeeklyGrandTotalClaims   = weeklyResult.GrandTotalClaims,
                WeeklyGrandTotalCharges  = weeklyResult.GrandTotalCharges,
                CodingPanelRows          = codingResult.PanelRows,
                CodingGrandTotalClaims   = codingResult.GrandTotalClaims,
                CodingGrandTotalCharges  = codingResult.GrandTotalCharges,
                PayerBreakdownMonths     = pbResult.Months,
                PayerBreakdownYears      = pbResult.Years,
                PayerBreakdownRows       = pbResult.PayerRows,
                PayerBreakdownGrandByMonth = pbResult.GrandTotalByMonth,
                PayerBreakdownGrandTotal   = pbResult.GrandTotal,
                PayerPanelColumns           = pxpResult.PanelColumns,
                PayerPanelRows              = pxpResult.PayerRows,
                PayerPanelGrandByPanel      = pxpResult.GrandTotalByPanel,
                PayerPanelGrandTotalClaims  = pxpResult.GrandTotalClaims,
                PayerPanelGrandTotalCharges = pxpResult.GrandTotalCharges,
                UnbilledAgingRows               = uaResult.PanelRows,
                UnbilledAgingGrandByBucket      = uaResult.GrandTotalByBucket,
                UnbilledAgingGrandTotalClaims   = uaResult.GrandTotalClaims,
                UnbilledAgingGrandTotalCharges  = uaResult.GrandTotalCharges,
                CptBreakdownMonths              = cptResult.Months,
                CptBreakdownYears               = cptResult.Years,
                CptBreakdownRows                = cptResult.CptRows,
                CptBreakdownGrandByMonth        = cptResult.GrandTotalByMonth,
                CptBreakdownGrandTotalUnits     = cptResult.GrandTotalUnits,
                CptBreakdownGrandTotalCharges   = cptResult.GrandTotalCharges,
            };

            using var workbook = ProductionReportExcelExportBuilder.CreateWorkbook(vm, selectedLab, claimRows, lineRows);

            await using var stream = new MemoryStream();
            workbook.SaveAs(stream);
            stream.Position = 0;

            var safeLabName = string.Join("_", selectedLab.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
            var fileName = $"{safeLabName}_ProductionReport_{DateTime.Now:yyyyMMddHHmmss}.xlsx";

            Response.Cookies.Append("prExportDone", "1", new CookieOptions
            {
                Path = "/",
                HttpOnly = false,
                SameSite = SameSiteMode.Lax,
                MaxAge = TimeSpan.FromSeconds(30),
            });

            return File(
                stream.ToArray(),
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Production Report Excel export failed for lab '{LabName}'.", selectedLab);
            TempData["ExportError"] = $"Export failed: {ex.Message}";
            return RedirectToAction(nameof(ProductionReport), new { lab });
        }
    }

    /// <summary>
    /// Normalizes filter parameters: trims empty values from lists and parses date strings.
    /// </summary>
    private static (
        List<string>? ClinicNames, List<string>? SalesRepNames,
        List<string>? PayerNames, List<string>? PanelNames,
        DateOnly? DosFrom, DateOnly? DosTo,
        DateOnly? FirstBillFrom, DateOnly? FirstBillTo)
        NormalizeFilters(
            List<string>? filterClinicNames,
            List<string>? filterSalesRepNames,
            List<string>? filterPayerNames,
            List<string>? filterPanelNames,
            string? filterDosFrom,
            string? filterDosTo,
            string? filterFirstBillFrom,
            string? filterFirstBillTo)
    {
        var cn = filterClinicNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList();
        var sr = filterSalesRepNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList();
        var pn = filterPayerNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList();
        var pl = filterPanelNames?.Where(v => !string.IsNullOrWhiteSpace(v)).ToList();

        DateOnly.TryParse(filterDosFrom, out var dosFrom);
        DateOnly.TryParse(filterDosTo, out var dosTo);
        DateOnly.TryParse(filterFirstBillFrom, out var fbFrom);
        DateOnly.TryParse(filterFirstBillTo, out var fbTo);

        return (
            cn is { Count: > 0 } ? cn : null,
            sr is { Count: > 0 } ? sr : null,
            pn is { Count: > 0 } ? pn : null,
            pl is { Count: > 0 } ? pl : null,
            dosFrom != default ? dosFrom : null,
            dosTo != default ? dosTo : null,
            fbFrom != default ? fbFrom : null,
            fbTo != default ? fbTo : null);
    }

}
