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
        var records = BuildLineItems();
        records = ApplyLineItemFilters(records, filters).ToList();
        return Task.FromResult<IReadOnlyList<DenialLineItemRecord>>(records.Skip((Math.Max(page, 1) - 1) * Math.Max(pageSize, 1)).Take(Math.Max(pageSize, 1)).ToList());
    }

    public Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsForExportByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
    {
        return Task.FromResult<IReadOnlyList<DenialLineItemRecord>>(ApplyLineItemFilters(BuildLineItems(), filters).ToList());
    }

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
        static string NormalizeMappedValue(string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return string.Empty;
            var trimmed = value.Trim();
            var colonIndex = trimmed.IndexOf(':');
            if (colonIndex <= 0 || colonIndex >= trimmed.Length - 1) return trimmed;
            var prefix = trimmed[..colonIndex].Trim();
            var suffix = trimmed[(colonIndex + 1)..].Trim();
            var looksLikeDenialCode = prefix.Any(char.IsDigit) && prefix.Any(char.IsLetter) && prefix.Length <= 30 && !suffix.Contains(':');
            return looksLikeDenialCode ? suffix : trimmed;
        }

        bool StartsWithOrAll(string? source, string? term) => string.IsNullOrWhiteSpace(term) || (!string.IsNullOrWhiteSpace(source) && source.StartsWith(term.Trim(), StringComparison.OrdinalIgnoreCase));

        var query = records;
        if (filters.Status != "(All)") query = query.Where(x => string.Equals(x.TaskStatus, filters.Status, StringComparison.OrdinalIgnoreCase));
        if (filters.Priority != "(All)") query = query.Where(x => string.Equals(NormalizeMappedValue(x.Priority), filters.Priority, StringComparison.OrdinalIgnoreCase));
        if (filters.ActionCategory != "(All)") query = query.Where(x => string.Equals(NormalizeMappedValue(x.ActionCategory), filters.ActionCategory, StringComparison.OrdinalIgnoreCase));
        if (filters.Classification != "(All)") query = query.Where(x => string.Equals(NormalizeMappedValue(x.DenialClassification), filters.Classification, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filters.PayerName)) query = query.Where(x => StartsWithOrAll(x.PayerName, filters.PayerName));
        if (!string.IsNullOrWhiteSpace(filters.PayerType)) query = query.Where(x => StartsWithOrAll(x.PayerType, filters.PayerType));
        if (!string.IsNullOrWhiteSpace(filters.PanelName)) query = query.Where(x => StartsWithOrAll(x.PanelName, filters.PanelName));
        if (!string.IsNullOrWhiteSpace(filters.ReferringProvider)) query = query.Where(x => StartsWithOrAll(x.ReferringProvider, filters.ReferringProvider));
        if (!string.IsNullOrWhiteSpace(filters.ClinicName)) query = query.Where(x => StartsWithOrAll(x.ClinicName, filters.ClinicName));
        if (!string.IsNullOrWhiteSpace(filters.SalesRepname)) query = query.Where(x => StartsWithOrAll(x.SalesRepname, filters.SalesRepname));
        if (filters.DateOfServiceFrom.HasValue) query = query.Where(x => x.DateOfService.HasValue && x.DateOfService.Value.Date >= filters.DateOfServiceFrom.Value.Date);
        if (filters.DateOfServiceTo.HasValue) query = query.Where(x => x.DateOfService.HasValue && x.DateOfService.Value.Date <= filters.DateOfServiceTo.Value.Date);
        if (filters.FirstBilledDateFrom.HasValue) query = query.Where(x => x.FirstBilledDate.HasValue && x.FirstBilledDate.Value.Date >= filters.FirstBilledDateFrom.Value.Date);
        if (filters.FirstBilledDateTo.HasValue) query = query.Where(x => x.FirstBilledDate.HasValue && x.FirstBilledDate.Value.Date <= filters.FirstBilledDateTo.Value.Date);
        return query;
    }

    private List<DenialLineItemRecord> BuildLineItems() =>
    [
        new()
        {
            AccessionNo = "ACC-1001", VisitNumber = "VIS-5001", CptCode = "80307", DateOfService = DateTime.Today.AddDays(-10),
            FirstBilledDate = DateTime.Today.AddDays(-8), PanelName = "Tox", PayerName = "Sample Payer", PayerType = "Commercial",
            DenialCodeNormalized = "CO16", DenialDescription = "Missing or invalid information.", BilledAmount = 144.28m, AllowedAmount = 60.90m,
            InsuranceBalance = 83.38m, TotalBalance = 83.38m, DenialClassification = "Billing", DenialType = "Claim Level Denial",
            ActionCategory = "Billing Related Denial", ActionCode = "CO16: RB", RecommendedAction = "Correct and resubmit",
            TaskGuidance = "Review claim and resubmit", TaskStatus = "Open", Priority = "High", SlaDays = "7", PatientId = "PAT-001",
            ReferringProvider = "Dr Smith", ClinicName = "West Clinic", SalesRepname = "Ava", LabName = "Sample Lab", RunId = "SAMPLE-RUN"
        },
        new()
        {
            AccessionNo = "ACC-1002", VisitNumber = "VIS-5002", CptCode = "81001", DateOfService = DateTime.Today.AddDays(-7),
            FirstBilledDate = DateTime.Today.AddDays(-5), PanelName = "Blood", PayerName = "Blue Shield", PayerType = "Government",
            DenialCodeNormalized = "CO97", DenialDescription = "Bundled service denial.", BilledAmount = 210.00m, AllowedAmount = 120.00m,
            InsuranceBalance = 75m, TotalBalance = 75m, DenialClassification = "Coding", DenialType = "Line Level Denial",
            ActionCategory = "Coding Related Denial", ActionCode = "CO97: CR", RecommendedAction = "Review coding",
            TaskGuidance = "Validate service combination", TaskStatus = "Open", Priority = "Medium", SlaDays = "5", PatientId = "PAT-002",
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
