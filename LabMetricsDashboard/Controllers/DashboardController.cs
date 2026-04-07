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

    public DashboardController(
        LabSettings labSettings,
        LabCsvFileResolver resolver,
        CsvParserService csvParser)
    {
        _labSettings = labSettings;
        _resolver = resolver;
        _csvParser = csvParser;
    }

    // GET /Dashboard  or  /Dashboard/Index?lab=PCRLabsofAmerica&filterPayerName=...
    public IActionResult Index(
        string? lab,
        string? filterPayerName,
        string? filterPayerType,
        string? filterPanelName,
        string? filterClinicName,
        string? filterReferringProvider,
        string? filterDosFrom,
        string? filterDosTo,
        string? filterFirstBillFrom,
        string? filterFirstBillTo)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab   = lab ?? availableLabs.FirstOrDefault() ?? string.Empty;

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

        // ?? Rate numerators — each uses the correct ClaimStatus filter per spec ??
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

        // ?? Average Allowed by Panel × Month pivot ????????????????????????????
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

            // Average Allowed by Panel × Month
            AvgAllowedMonths       = avgMonths,
            AvgAllowedByPanelMonth = avgAllowedByPanelMonth,

            // Top CPT By Charges (enriched)
            TopCptDetail = topCptDetail,
        };

        return View(vm);
    }

    // GET /Dashboard/ClaimLevel?lab=PCRLabsofAmerica&...
    public IActionResult ClaimLevel(
        string? lab,
        string? filterPayerName,
        string? filterPayerType,
        string? filterClaimStatus,
        string? filterClinicName,
        string? filterDenialCode,
        int page = 1)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab = lab ?? availableLabs.FirstOrDefault() ?? string.Empty;

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

        var filtered = allRecords.AsEnumerable();

        if (!string.IsNullOrWhiteSpace(filterPayerName))
            filtered = filtered.Where(r => r.PayerName.Contains(filterPayerName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayerType))
            filtered = filtered.Where(r => r.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterClaimStatus))
            filtered = filtered.Where(r => r.ClaimStatus.Equals(filterClaimStatus, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterClinicName))
            filtered = filtered.Where(r => r.ClinicName.Equals(filterClinicName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterDenialCode))
            filtered = filtered.Where(r => r.DenialCode.Contains(filterDenialCode, StringComparison.OrdinalIgnoreCase));

        var filteredList  = filtered.ToList();
        var currentPage   = Math.Max(1, page);
        var pagedRecords  = filteredList.Skip((currentPage - 1) * PageSize).Take(PageSize).ToList();

        var vm = new ClaimLevelViewModel
        {
            AvailableLabs     = availableLabs,
            SelectedLab       = selectedLab,
            FilterPayerName   = filterPayerName,
            FilterPayerType   = filterPayerType,
            FilterClaimStatus = filterClaimStatus,
            FilterClinicName  = filterClinicName,
            FilterDenialCode  = filterDenialCode,
            PayerTypes        = payerTypes,
            ClaimStatuses     = claimStatuses,
            ClinicNames       = clinicNames,
            Records           = pagedRecords,
            Paging            = new PageInfo(currentPage, PageSize, filteredList.Count, allRecords.Count),
            ResolvedFilePath  = claimFilePath
        };

        return View(vm);
    }

    // GET /Dashboard/LineLevel?lab=PCRLabsofAmerica&...
    public IActionResult LineLevel(
        string? lab,
        string? filterPayerName,
        string? filterPayerType,
        string? filterClaimStatus,
        string? filterPayStatus,
        string? filterCPTCode,
        string? filterClinicName,
        string? filterDenialCode,
        int page = 1)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab = lab ?? availableLabs.FirstOrDefault() ?? string.Empty;

        var lineFilePath = string.IsNullOrEmpty(selectedLab) ? null : _resolver.ResolveLineLevelCsv(selectedLab);
        var allRecords   = lineFilePath is not null ? _csvParser.ParseLineLevel(lineFilePath) : [];

        var payerTypes    = allRecords.Select(r => r.PayerType).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(v => v).ToList();

        // Exclude values that look like dates (contain "/" or "-" and are parseable as DateOnly)
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
        if (!string.IsNullOrWhiteSpace(filterPayerType))
            filtered = filtered.Where(r => r.PayerType.Equals(filterPayerType, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterClaimStatus))
            filtered = filtered.Where(r => r.ClaimStatus.Equals(filterClaimStatus, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterPayStatus))
            filtered = filtered.Where(r => r.PayStatus.Equals(filterPayStatus, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterCPTCode))
            filtered = filtered.Where(r => r.CPTCode.Equals(filterCPTCode, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterClinicName))
            filtered = filtered.Where(r => r.ClinicName.Equals(filterClinicName, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filterDenialCode))
            filtered = filtered.Where(r => r.DenialCode.Contains(filterDenialCode, StringComparison.OrdinalIgnoreCase));

        var filteredList  = filtered.ToList();
        var currentPage   = Math.Max(1, page);
        var pagedRecords  = filteredList.Skip((currentPage - 1) * PageSize).Take(PageSize).ToList();

        var vm = new LineLevelViewModel
        {
            AvailableLabs     = availableLabs,
            SelectedLab       = selectedLab,
            FilterPayerName   = filterPayerName,
            FilterPayerType   = filterPayerType,
            FilterClaimStatus = filterClaimStatus,
            FilterPayStatus   = filterPayStatus,
            FilterCPTCode     = filterCPTCode,
            FilterClinicName  = filterClinicName,
            FilterDenialCode  = filterDenialCode,
            PayerTypes        = payerTypes,
            ClaimStatuses     = claimStatuses,
            PayStatuses       = payStatuses,
            ClinicNames       = clinicNames,
            CPTCodes          = cptCodes,
            Records           = pagedRecords,
            Paging            = new PageInfo(currentPage, PageSize, filteredList.Count, allRecords.Count),
            ResolvedFilePath  = lineFilePath
        };

        return View(vm);
    }
}
