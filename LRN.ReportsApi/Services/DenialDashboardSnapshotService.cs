using LRN.ReportsApi.Models;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services;

public interface IDenialDashboardSnapshotService
{
    /// <summary>Null when a weekly/monthly snapshot for the period already exists.</summary>
    Task<DenialDashboardSnapshotInfo?> SaveSnapshotAsync(int labId, DenialDashboardSnapshotUploadRequest request, CancellationToken ct);
}

/// <summary>
/// Stores a Denial Dashboard snapshot LabMetricsDashboard already built and applies retention
/// (spec 4h-4i) - the newest N active snapshots per period type are kept, everything older is
/// archived (never deleted). Mirrors DenialSummarySnapshotService's retention step exactly, against
/// a separate table (dbo.DenialDashboardSnapshot) with its own (lower) retention defaults.
/// </summary>
public sealed class DenialDashboardSnapshotService : IDenialDashboardSnapshotService
{
    private readonly IDenialDashboardSnapshotRepository _repo;
    private readonly DenialDashboardSnapshotOptions _options;
    private readonly ILogger<DenialDashboardSnapshotService> _logger;

    public DenialDashboardSnapshotService(IDenialDashboardSnapshotRepository repo, IOptions<DenialDashboardSnapshotOptions> options, ILogger<DenialDashboardSnapshotService> logger)
    {
        _repo = repo;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<DenialDashboardSnapshotInfo?> SaveSnapshotAsync(int labId, DenialDashboardSnapshotUploadRequest request, CancellationToken ct)
    {
        var periodType = DenialSummarySnapshotPeriodTypes.Canonical(request.PeriodType) ?? DenialSummarySnapshotPeriodTypes.OnDemand;

        if (periodType != DenialSummarySnapshotPeriodTypes.OnDemand
            && await _repo.PeriodSnapshotExistsAsync(labId, periodType, request.PeriodStart, ct))
            return null;

        var info = new DenialDashboardSnapshotInfo
        {
            LabId = labId,
            PeriodType = periodType,
            PeriodStart = request.PeriodStart.Date,
            PeriodEnd = request.PeriodEnd.Date,
            FileName = request.FileName,
            SizeBytes = request.Content.LongLength,
            CreatedBy = request.CreatedBy,
            CreatedOn = DateTime.UtcNow
        };

        var id = await _repo.InsertSnapshotAsync(labId, info, request.Content, ct);
        if (id is null) return null;
        info.SnapshotId = id.Value;

        await ApplyRetentionAsync(labId, ct);
        return info;
    }

    private async Task ApplyRetentionAsync(int labId, CancellationToken ct)
    {
        var active = await _repo.GetSnapshotsAsync(labId, includeArchived: false, ct);
        var toArchive = SelectForArchive(active, _options);
        var archived = await _repo.ArchiveSnapshotsAsync(labId, toArchive, ct);
        if (archived > 0)
            _logger.LogInformation("Archived {Count} Denial Dashboard snapshot(s) for lab {LabId} past retention.", archived, labId);
    }

    /// <summary>The active snapshots to archive: for each period type, everything past the newest N.</summary>
    private static IReadOnlyList<long> SelectForArchive(IEnumerable<DenialDashboardSnapshotInfo> snapshots, DenialDashboardSnapshotOptions options)
    {
        var archive = new List<long>();

        foreach (var group in snapshots.GroupBy(s => s.PeriodType, StringComparer.OrdinalIgnoreCase))
        {
            var keep = (DenialSummarySnapshotPeriodTypes.Canonical(group.Key) ?? group.Key) switch
            {
                DenialSummarySnapshotPeriodTypes.Weekly => options.WeeklyRetention,
                DenialSummarySnapshotPeriodTypes.Monthly => options.MonthlyRetention,
                _ => options.OnDemandRetention
            };
            if (keep <= 0) continue;

            archive.AddRange(group
                .OrderByDescending(s => s.PeriodStart)
                .ThenByDescending(s => s.CreatedOn)
                .ThenByDescending(s => s.SnapshotId)
                .Skip(keep)
                .Select(s => s.SnapshotId));
        }

        return archive;
    }
}
