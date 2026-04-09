using System.Text.Json;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;

namespace LabMetricsDashboard.Services;

public class MockDenialRecordRepository : IDenialRecordRepository
{
    private readonly IWebHostEnvironment _environment;
    private readonly JsonSerializerOptions _jsonOptions = new() { PropertyNameCaseInsensitive = true };
    private IReadOnlyList<DenialRecord>? _cache;
    private readonly object _syncRoot = new();

    public MockDenialRecordRepository(IWebHostEnvironment environment)
    {
        _environment = environment;
    }

    public async Task<IReadOnlyList<LabOption>> GetLabsAsync(CancellationToken cancellationToken = default)
    {
        var records = await GetOrLoadAsync(cancellationToken);
        var labs = records
            .GroupBy(x => new { x.LabId, x.LabName })
            .Select(x => new LabOption
            {
                LabId = x.Key.LabId,
                LabName = string.IsNullOrWhiteSpace(x.Key.LabName) ? $"Lab {x.Key.LabId}" : x.Key.LabName,
                ConnectionKey = "DefaultConnection"
            })
            .OrderBy(x => x.LabName)
            .ToList();

        if (labs.Count == 0)
        {
            labs.Add(new LabOption { LabId = 1, LabName = "Sample Lab", ConnectionKey = "DefaultConnection" });
        }

        return labs;
    }

    public async Task<IReadOnlyList<DenialRecord>> GetByLabAsync(int labId, CancellationToken cancellationToken = default)
    {
        var records = await GetOrLoadAsync(cancellationToken);
        return records.Where(x => x.LabId == labId).ToList();
    }

    public async Task<IReadOnlyList<DenialInsightRecord>> GetInsightsByLabAsync(int labId, CancellationToken cancellationToken = default)
    {
        var records = await GetByLabAsync(labId, cancellationToken);
        return records.GroupBy(x => new { x.DenialCode, x.DenialDescription })
            .Select(g => new DenialInsightRecord
            {
                DenialCodes = g.Key.DenialCode,
                Descriptions = g.Key.DenialDescription,
                NoOfDenialCount = g.Count(),
                NoOfClaimsCount = g.Select(x => x.ClaimId).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(),
                TotalBalance = g.Sum(x => x.EffectiveTotalBalance),
                HighImpactInsurance = g.GroupBy(x => x.PayerName).OrderByDescending(x => x.Sum(r => r.InsuranceBalance)).Select(x => x.Key).FirstOrDefault() ?? string.Empty,
                InsuranceBalance = g.Sum(x => x.InsuranceBalance),
                ImpactPercentage = 0,
                ActionCategory = g.Select(x => x.EffectiveActionCategory).FirstOrDefault() ?? string.Empty,
                ActionCode = g.Select(x => x.ActionCode).FirstOrDefault() ?? string.Empty,
                Action = g.Select(x => x.RecommendedAction).FirstOrDefault() ?? string.Empty,
                Task = g.Select(x => x.Task).FirstOrDefault() ?? string.Empty,
                LabId = labId,
                LabName = g.Select(x => x.LabName).FirstOrDefault() ?? "Sample Lab",
                RunId = g.Select(x => x.RunId).FirstOrDefault() ?? "SAMPLE-RUN"
            })
            .ToList();
    }

    public Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsByLabAsync(int labId, int page, int pageSize, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
    {
        var records = ApplyLineItemFilters(BuildLineItems(), filters).ToList();
        return Task.FromResult<IReadOnlyList<DenialLineItemRecord>>(records.Skip((Math.Max(page, 1) - 1) * Math.Max(pageSize, 1)).Take(Math.Max(pageSize, 1)).ToList());
    }

    public Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsForExportByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
        => Task.FromResult<IReadOnlyList<DenialLineItemRecord>>(ApplyLineItemFilters(BuildLineItems(), filters).ToList());

    public Task<IReadOnlyList<DenialBreakdownSourceRecord>> GetBreakdownSourceByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
        => Task.FromResult<IReadOnlyList<DenialBreakdownSourceRecord>>(ApplyLineItemFilters(BuildLineItems(), filters)
            .Select(x => new DenialBreakdownSourceRecord
            {
                DenialDate = x.DenialDate,
                VisitNumber = x.VisitNumber,
                InsuranceBalance = x.InsuranceBalance,
                TotalBalance = x.TotalBalance
            })
            .Where(x => x.DenialDate.HasValue)
            .ToList());

    public async Task<int> GetLineItemCountByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
    {
        var items = await GetLineItemsForExportByLabAsync(labId, filters, cancellationToken);
        return items.Count;
    }

    public Task<IReadOnlyList<string>> GetPayerNamesByLabAsync(int labId, CancellationToken cancellationToken = default)
        => Task.FromResult<IReadOnlyList<string>>(["Sample Payer", "Blue Shield"]);

    public Task<IReadOnlyList<string>> GetPanelNamesByLabAsync(int labId, CancellationToken cancellationToken = default)
        => Task.FromResult<IReadOnlyList<string>>(["Blood", "Tox"]);

    public async Task<DenialFilterAutocompleteOptions> GetFilterAutocompleteOptionsAsync(int labId, CancellationToken cancellationToken = default)
    {
        var taskRecords = (await GetOrLoadAsync(cancellationToken)).Where(x => x.LabId == labId);
        var lineItems = BuildLineItems();

        static IReadOnlyList<string> DistinctValues(IEnumerable<string?> values)
            => values
                .Where(x => !string.IsNullOrWhiteSpace(x))
                .Select(x => x!.Trim())
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(x => x)
                .ToList();

        return new DenialFilterAutocompleteOptions
        {
            PayerNames = DistinctValues(taskRecords.Select(x => x.PayerName).Concat(lineItems.Select(x => x.PayerName))),
            PayerTypes = DistinctValues(taskRecords.Select(x => x.PayerType).Concat(lineItems.Select(x => x.PayerType))),
            PanelNames = DistinctValues(taskRecords.Select(x => x.PanelName).Concat(lineItems.Select(x => x.PanelName))),
            ReferringProviders = DistinctValues(taskRecords.Select(x => x.ReferringProvider).Concat(lineItems.Select(x => x.ReferringProvider))),
            ClinicNames = DistinctValues(taskRecords.Select(x => x.ClinicName).Concat(lineItems.Select(x => x.ClinicName))),
            SalesRepnames = DistinctValues(taskRecords.Select(x => x.SalesRepname).Concat(lineItems.Select(x => x.SalesRepname)))
        };
    }

    public Task<string?> GetCurrentRunIdAsync(int labId, CancellationToken cancellationToken = default)
        => Task.FromResult<string?>("SAMPLE-RUN");

    public Task<string?> GetLatestExportFilePathForLabAsync(int labId, CancellationToken cancellationToken = default)
    {
        var samplePath = Path.Combine(_environment.ContentRootPath, "Data", "denials.sample.json");
        return Task.FromResult<string?>(File.Exists(samplePath) ? samplePath : null);
    }

    public async Task<TaskBoardUploadResult> UpdateTaskBoardAsync(int labId, IReadOnlyList<TaskBoardCsvUpdate> updates, CancellationToken cancellationToken = default)
    {
        var records = (await GetOrLoadAsync(cancellationToken)).ToList();
        var result = new TaskBoardUploadResult { TotalRows = updates?.Count ?? 0 };
        if (updates is null || updates.Count == 0) return result;

        foreach (var update in updates)
        {
            var record = records.FirstOrDefault(x =>
                x.LabId == labId &&
                (string.IsNullOrWhiteSpace(update.RunId) || string.Equals(x.RunId, update.RunId, StringComparison.OrdinalIgnoreCase)) &&
                ((!string.IsNullOrWhiteSpace(update.UniqueTrackId) && string.Equals(x.UniqueTrackId, update.UniqueTrackId, StringComparison.OrdinalIgnoreCase))
                 || (string.IsNullOrWhiteSpace(update.UniqueTrackId) && string.Equals(x.TaskId, update.TaskId, StringComparison.OrdinalIgnoreCase))));

            if (record is null)
            {
                result.SkippedRows++;
                continue;
            }

            record.Status = update.Status ?? string.Empty;
            record.AssignedTo = update.AssignedTo ?? string.Empty;
            record.DateCompleted = update.DateCompleted;
            result.UpdatedRows++;
        }

        _cache = records;
        return result;
    }

    private IEnumerable<DenialLineItemRecord> ApplyLineItemFilters(IEnumerable<DenialLineItemRecord> records, DenialDashboardFilters filters)
    {
        var statusSet = ParseSelection(filters.Status, true);
        var prioritySet = ParseSelection(filters.Priority, true);
        var actionSet = ParseSelection(filters.ActionCategory, true);
        var classSet = ParseSelection(filters.Classification, true);
        var payerSet = ParseSelection(filters.PayerName, false);
        var payerTypeSet = ParseSelection(filters.PayerType, false);
        var panelSet = ParseSelection(filters.PanelName, false);
        var providerSet = ParseSelection(filters.ReferringProvider, false);
        var clinicSet = ParseSelection(filters.ClinicName, false);
        var salesSet = ParseSelection(filters.SalesRepname, false);

        var query = records;
        if (statusSet.Count > 0) query = query.Where(x => statusSet.Contains(x.TaskStatus ?? string.Empty));
        if (prioritySet.Count > 0) query = query.Where(x => prioritySet.Contains(x.CleanPriority ?? string.Empty));
        if (actionSet.Count > 0) query = query.Where(x => actionSet.Contains(x.CleanActionCategory ?? string.Empty));
        if (classSet.Count > 0) query = query.Where(x => classSet.Contains(x.CleanDenialClassification ?? string.Empty));
        if (payerSet.Count > 0) query = query.Where(x => payerSet.Contains(x.PayerName ?? string.Empty));
        if (payerTypeSet.Count > 0) query = query.Where(x => payerTypeSet.Contains(x.PayerType ?? string.Empty));
        if (panelSet.Count > 0) query = query.Where(x => panelSet.Contains(x.PanelName ?? string.Empty));
        if (providerSet.Count > 0) query = query.Where(x => providerSet.Contains(x.ReferringProvider ?? string.Empty));
        if (clinicSet.Count > 0) query = query.Where(x => clinicSet.Contains(x.ClinicName ?? string.Empty));
        if (salesSet.Count > 0) query = query.Where(x => salesSet.Contains(x.SalesRepname ?? string.Empty));
        if (filters.DateOfServiceFrom.HasValue) query = query.Where(x => x.DateOfService.HasValue && x.DateOfService.Value.Date >= filters.DateOfServiceFrom.Value.Date);
        if (filters.DateOfServiceTo.HasValue) query = query.Where(x => x.DateOfService.HasValue && x.DateOfService.Value.Date <= filters.DateOfServiceTo.Value.Date);
        if (filters.FirstBilledDateFrom.HasValue) query = query.Where(x => x.FirstBilledDate.HasValue && x.FirstBilledDate.Value.Date >= filters.FirstBilledDateFrom.Value.Date);
        if (filters.FirstBilledDateTo.HasValue) query = query.Where(x => x.FirstBilledDate.HasValue && x.FirstBilledDate.Value.Date <= filters.FirstBilledDateTo.Value.Date);
        return query;
    }

    private static HashSet<string> ParseSelection(string? raw, bool allowAll)
    {
        if (string.IsNullOrWhiteSpace(raw)) return new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var items = raw.Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (allowAll && items.Contains("(All)")) items.Clear();
        return items;
    }

    private List<DenialLineItemRecord> BuildLineItems() =>
    [
        new()
        {
            AccessionNo = "ACC-1001", VisitNumber = "VIS-5001", CptCode = "80307", DateOfService = DateTime.Today.AddDays(-10),
            FirstBilledDate = DateTime.Today.AddDays(-8), DenialDate = DateTime.Today.AddDays(-7), PanelName = "Tox", PayerName = "Sample Payer", PayerType = "Commercial",
            DenialCodeNormalized = "CO16", DenialDescription = "Missing or invalid information.", BilledAmount = 144.28m, AllowedAmount = 60.90m,
            InsuranceBalance = 83.38m, TotalBalance = 83.38m, DenialClassification = "CO16: Billing", DenialType = "Claim Level Denial",
            ActionCategory = "CO16: Billing Related Denial", ActionCode = "CO16: RB", RecommendedAction = "Correct and resubmit",
            TaskGuidance = "Review claim and resubmit", TaskStatus = "Open", Priority = "CO16: High", SlaDays = "7", PatientId = "PAT-001",
            ReferringProvider = "Dr Smith", ClinicName = "West Clinic", SalesRepname = "Ava", LabName = "Sample Lab", RunId = "SAMPLE-RUN"
        },
        new()
        {
            AccessionNo = "ACC-1002", VisitNumber = "VIS-5002", CptCode = "81001", DateOfService = DateTime.Today.AddDays(-7),
            FirstBilledDate = DateTime.Today.AddDays(-5), DenialDate = DateTime.Today.AddDays(-4), PanelName = "Blood", PayerName = "Blue Shield", PayerType = "Government",
            DenialCodeNormalized = "CO97", DenialDescription = "Bundled service denial.", BilledAmount = 210.00m, AllowedAmount = 120.00m,
            InsuranceBalance = 75m, TotalBalance = 75m, DenialClassification = "CO97: Coding", DenialType = "Line Level Denial",
            ActionCategory = "CO97: Coding Related Denial", ActionCode = "CO97: CR", RecommendedAction = "Review coding",
            TaskGuidance = "Validate service combination", TaskStatus = "Open", Priority = "CO97: Medium", SlaDays = "5", PatientId = "PAT-002",
            ReferringProvider = "Dr John", ClinicName = "North Clinic", SalesRepname = "Ben", LabName = "Sample Lab", RunId = "SAMPLE-RUN"
        }
    ];

    private Task<IReadOnlyList<DenialRecord>> GetOrLoadAsync(CancellationToken cancellationToken = default)
    {
        if (_cache is not null) return Task.FromResult(_cache);

        lock (_syncRoot)
        {
            if (_cache is not null) return Task.FromResult(_cache);

            _cache =
            [
                new DenialRecord
                {
                    LabId = 1, LabName = "Sample Lab", RunId = "SAMPLE-RUN", TaskId = "T-1001", UniqueTrackId = "UT-1001", ClaimId = "CL-1",
                    DenialCode = "CO16", DenialDescription = "Missing information", DenialClassification = "Billing", ActionCode = "CO16: RB",
                    RecommendedAction = "Correct and resubmit", ActionCategory = "Billing Related Denial", Task = "Review claim",
                    Priority = "High", Status = "Open", InsuranceBalance = 120m, TotalBalance = 160m, DueDate = DateTime.Today.AddDays(3),
                    DateOpened = DateTime.Today.AddDays(-4), PayerName = "Sample Payer", PayerType = "Commercial", PanelName = "Tox",
                    SalesRepname = "Ava", ClinicName = "West Clinic", ReferringProvider = "Dr Smith", FirstBilledDate = DateTime.Today.AddDays(-10),
                    DateOfService = DateTime.Today.AddDays(-15)
                },
                new DenialRecord
                {
                    LabId = 1, LabName = "Sample Lab", RunId = "SAMPLE-RUN", TaskId = "T-1002", UniqueTrackId = "UT-1002", ClaimId = "CL-2",
                    DenialCode = "CO97", DenialDescription = "Bundled service denial", DenialClassification = "Coding", ActionCode = "CO97: CR",
                    RecommendedAction = "Review coding", ActionCategory = "Coding Related Denial", Task = "Validate service combination",
                    Priority = "Medium", Status = "Open", InsuranceBalance = 75m, TotalBalance = 75m, DueDate = DateTime.Today.AddDays(1),
                    DateOpened = DateTime.Today.AddDays(-3), PayerName = "Blue Shield", PayerType = "Government", PanelName = "Blood",
                    SalesRepname = "Ben", ClinicName = "North Clinic", ReferringProvider = "Dr John", FirstBilledDate = DateTime.Today.AddDays(-7),
                    DateOfService = DateTime.Today.AddDays(-12)
                }
            ];
        }

        return Task.FromResult(_cache!);
    }
}
