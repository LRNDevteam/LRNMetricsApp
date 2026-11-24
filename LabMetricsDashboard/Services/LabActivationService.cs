using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Keeps <see cref="LabSettings.Labs"/> in step with Admin &gt; Manage Labs: a lab whose
/// LRNMaster <c>dbo.Labs.IsActive = 0</c> is taken out of every lab picker, the navbar lab
/// dropdown, the Report Control Board and the per-lab background services. Switching it back on
/// restores it with no restart.
///
/// <para>
/// dbo.Labs rows are matched to lab config keys by LabId through <c>LabConfig:LabsID</c>, then by
/// name (spaces, underscores and case ignored) for a config key with no LabsID entry.
/// </para>
/// <para>
/// Refreshed every minute (so every web server picks up a change made on another one) and
/// immediately after a lab is saved on Manage Labs. If LRNMaster cannot be read, the last known
/// list is kept: a database blip neither re-shows switched-off labs nor hides every lab.
/// </para>
/// </summary>
public sealed class LabActivationService
{
    private const string Sql = @"
IF OBJECT_ID('dbo.Labs', 'U') IS NOT NULL
    SELECT LabId, ISNULL(LabName, '') FROM dbo.Labs WHERE IsActive = 0;";

    private readonly LabSettings _labSettings;
    private readonly LabConfigOptions _labConfig;
    private readonly string? _connectionString;
    private readonly ILogger<LabActivationService> _logger;

    public LabActivationService(
        LabSettings labSettings,
        LabConfigOptions labConfig,
        IConfiguration configuration,
        ILogger<LabActivationService> logger)
    {
        _labSettings = labSettings;
        _labConfig = labConfig;
        _connectionString = configuration.GetConnectionString("DefaultConnection");
        _logger = logger;
    }

    public async Task RefreshAsync(CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(_connectionString)) return;

        var inactiveRows = new List<(int LabId, string LabName)>();
        try
        {
            await using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(Sql, conn) { CommandTimeout = 30 };
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
                inactiveRows.Add((r.GetInt32(0), r.GetString(1)));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex, "Could not read inactive labs from dbo.Labs; keeping the last known list ({Labs}).",
                string.Join(", ", _labSettings.InactiveLabs));
            return;
        }

        var inactive = MapToConfigKeys(_labSettings.AllLabs.Keys, inactiveRows, _labConfig);

        if (!inactive.SetEquals(_labSettings.InactiveLabs))
        {
            _labSettings.InactiveLabs = inactive;
            _logger.LogInformation("Inactive labs (Admin > Manage Labs): {Labs}",
                inactive.Count == 0 ? "none" : string.Join(", ", inactive.OrderBy(x => x)));
        }
    }

    /// <summary>The config keys of <paramref name="configKeys"/> that one of the inactive dbo.Labs rows names.</summary>
    internal static HashSet<string> MapToConfigKeys(
        IEnumerable<string> configKeys,
        IReadOnlyCollection<(int LabId, string LabName)> inactiveRows,
        LabConfigOptions labConfig)
    {
        var inactiveIds = inactiveRows.Select(r => r.LabId).ToHashSet();
        var inactiveNames = inactiveRows.Select(r => Squash(r.LabName)).Where(n => n.Length > 0).ToHashSet();

        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var key in configKeys)
        {
            // LabsID decides when the key has an entry there: a name that happens to look alike
            // must not switch off a lab whose own LabId is active.
            if (labConfig.GetLabIdByName(key) is int id)
            {
                if (inactiveIds.Contains(id)) result.Add(key);
            }
            else if (inactiveNames.Contains(Squash(key)))
            {
                result.Add(key);
            }
        }
        return result;
    }

    private static string Squash(string value) =>
        new((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());
}

/// <summary>Loads the inactive labs before the first request, then re-reads them every minute.</summary>
public sealed class LabActivationRefresher : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromMinutes(1);
    private readonly LabActivationService _service;

    public LabActivationRefresher(LabActivationService service) => _service = service;

    public override async Task StartAsync(CancellationToken cancellationToken)
    {
        // Before the app starts serving, so the first page never shows an inactive lab.
        await _service.RefreshAsync(cancellationToken);
        await base.StartAsync(cancellationToken);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(Interval);
        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken))
                await _service.RefreshAsync(stoppingToken);
        }
        catch (OperationCanceledException)
        {
            // shutdown
        }
    }
}
