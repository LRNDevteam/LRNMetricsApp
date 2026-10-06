using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// T038 Nightly inventory snapshot (GAP-6): dbo.ARWB_usp_SnapshotQueues recalculates every claim
/// (aging, TFL, re-follow-up due move with the calendar) and stores one row per claim per day in
/// dbo.ARWB_QueueSnapshot - the base for trend and movement reporting.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private const int SnapshotTimeoutSeconds = 1800;

    public IReadOnlyList<int> GetConfiguredLabIds() => _labConnectionsById.Keys.OrderBy(id => id).ToList();

    /// <summary>The snapshot dates on file, newest first, with what each captured.</summary>
    public async Task<IReadOnlyList<ArWorkbenchSnapshotDay>> GetSnapshotHistoryAsync(int labId, int top, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(@"
SELECT TOP (@Top) s.SnapshotDate, COUNT(*) AS Claims,
       SUM(CASE WHEN s.RemainingAR > 0.005 THEN 1 ELSE 0 END) AS OpenClaims,
       ISNULL(SUM(s.RemainingAR), 0) AS RemainingAR,
       SUM(CASE WHEN s.AssignedAgentUser IS NOT NULL THEN 1 ELSE 0 END) AS AssignedClaims
FROM dbo.ARWB_QueueSnapshot s
GROUP BY s.SnapshotDate
ORDER BY s.SnapshotDate DESC;", connection) { CommandTimeout = 300 };
        cmd.Parameters.Add("@Top", SqlDbType.Int).Value = Math.Clamp(top, 1, 400);
        var list = new List<ArWorkbenchSnapshotDay>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            list.Add(new ArWorkbenchSnapshotDay
            {
                SnapshotDate = r.GetDateTime(0),
                Claims = r.GetInt32(1),
                OpenClaims = r.GetInt32(2),
                RemainingAR = r.GetDecimal(3),
                AssignedClaims = r.GetInt32(4)
            });
        }
        return list;
    }

    public async Task<bool> HasSnapshotAsync(int labId, DateTime date, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand("SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.ARWB_QueueSnapshot WHERE SnapshotDate = @D) THEN 1 ELSE 0 END;", connection);
        cmd.Parameters.Add("@D", SqlDbType.Date).Value = date.Date;
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) == 1;
    }

    /// <summary>Runs the snapshot for a date (re-running replaces that date). Returns the rows captured.</summary>
    public async Task<int> RunSnapshotAsync(int labId, DateTime date, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        // One run per lab at a time, even with several API instances.
        await using (var lockCmd = new SqlCommand(
            "DECLARE @r int; EXEC @r = sp_getapplock @Resource = N'ARWB_SnapshotQueues', @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 0; SELECT @r;",
            connection))
        {
            if (Convert.ToInt32(await lockCmd.ExecuteScalarAsync(ct)) < 0)
                throw new InvalidOperationException("A snapshot is already running for this lab.");
        }
        await using var cmd = new SqlCommand("dbo.ARWB_usp_SnapshotQueues", connection)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = SnapshotTimeoutSeconds
        };
        cmd.Parameters.Add("@SnapshotDate", SqlDbType.Date).Value = date.Date;
        cmd.Parameters.Add("@Recalculate", SqlDbType.Bit).Value = true;
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));   // the session lock ends with the connection
    }
}

public sealed class ArWorkbenchSnapshotDay
{
    public DateTime SnapshotDate { get; set; }
    public int Claims { get; set; }
    public int OpenClaims { get; set; }
    public decimal RemainingAR { get; set; }
    public int AssignedClaims { get; set; }
}

public sealed class ArWorkbenchSnapshotOptions
{
    public bool ScheduleEnabled { get; set; } = true;
    /// <summary>Local hour (0-23) from which the day's snapshot is taken.</summary>
    public int RunAtHour { get; set; } = 1;
    public int CheckIntervalMinutes { get; set; } = 30;
    /// <summary>Blank = server local time.</summary>
    public string? TimeZoneId { get; set; }

    public DateTime LocalNow(DateTime utcNow)
    {
        if (string.IsNullOrWhiteSpace(TimeZoneId)) return utcNow.ToLocalTime();
        try { return TimeZoneInfo.ConvertTimeFromUtc(utcNow, TimeZoneInfo.FindSystemTimeZoneById(TimeZoneId)); }
        catch (TimeZoneNotFoundException) { return utcNow.ToLocalTime(); }
    }

    /// <summary>The date whose snapshot is due now, or null before RunAtHour.</summary>
    public DateTime? DueDate(DateTime utcNow)
    {
        var local = LocalNow(utcNow);
        return local.Hour >= Math.Clamp(RunAtHour, 0, 23) ? local.Date : null;
    }
}

/// <summary>
/// Nightly: for each configured lab with the AR Workbench installed, take today's snapshot once
/// (on the first check after RunAtHour). A lab without the tables is skipped quietly.
/// </summary>
public sealed class ArWorkbenchSnapshotScheduler : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ArWorkbenchSnapshotOptions _options;
    private readonly ILogger<ArWorkbenchSnapshotScheduler> _logger;

    public ArWorkbenchSnapshotScheduler(IServiceScopeFactory scopeFactory, IOptions<ArWorkbenchSnapshotOptions> options, ILogger<ArWorkbenchSnapshotScheduler> logger)
    {
        _scopeFactory = scopeFactory;
        _options = options.Value;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.ScheduleEnabled)
        {
            _logger.LogInformation("AR Workbench nightly snapshot is disabled (ArWorkbenchSnapshots:ScheduleEnabled).");
            return;
        }
        try { await Task.Delay(TimeSpan.FromMinutes(3), stoppingToken); }
        catch (OperationCanceledException) { return; }

        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(Math.Max(5, _options.CheckIntervalMinutes)));
        try
        {
            do { await RunDueAsync(stoppingToken); }
            while (await timer.WaitForNextTickAsync(stoppingToken));
        }
        catch (OperationCanceledException)
        {
            // shutdown
        }
    }

    private async Task RunDueAsync(CancellationToken ct)
    {
        if (_options.DueDate(DateTime.UtcNow) is not { } date) return;
        using var scope = _scopeFactory.CreateScope();
        var repo = scope.ServiceProvider.GetRequiredService<IArWorkbenchRepository>();
        IReadOnlySet<int> inactive;
        try { inactive = await repo.GetInactiveClientLabIdsAsync(ct); }
        catch (SqlException ex) { _logger.LogWarning(ex, "AR Workbench snapshot: client activation lookup failed; taking every lab."); inactive = new HashSet<int>(); }
        foreach (var labId in repo.GetConfiguredLabIds())
        {
            if (inactive.Contains(labId)) continue;     // deactivated client (T068)
            try
            {
                if (await repo.HasSnapshotAsync(labId, date, ct)) continue;
                var rows = await repo.RunSnapshotAsync(labId, date, ct);
                _logger.LogInformation("AR Workbench snapshot {Date:yyyy-MM-dd} for lab {LabId}: {Rows} claims.", date, labId, rows);
            }
            catch (InvalidOperationException ex)
            {
                // Not installed for this lab, no connection string, or already running elsewhere.
                _logger.LogDebug("AR Workbench snapshot skipped for lab {LabId}: {Reason}", labId, ex.Message);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogError(ex, "AR Workbench snapshot failed for lab {LabId}.", labId);
            }
        }
    }
}
