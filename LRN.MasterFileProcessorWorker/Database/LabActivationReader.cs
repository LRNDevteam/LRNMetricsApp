using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace LRN.MasterFileProcessorWorker.Database;

/// <summary>
/// Which of this worker's labs are switched off in LRN Metrics (Admin &gt; Manage Labs), i.e.
/// <c>LRNMaster.dbo.Labs.IsActive = 0</c>.
///
/// <para>
/// MasterFileProcessor:Labs in configuration says which labs this instance CAN run; dbo.Labs says
/// which of them SHOULD run. An inactive lab is skipped for the whole pass - no SharePoint lookup,
/// no run log, no reports, no AR Workbench sync - and picks up again on the first pass after it is
/// re-enabled. No restart or configuration change is needed either way.
/// </para>
/// <para>
/// Read once per pass. When LRNMaster cannot be read the last answer is kept (or, before the first
/// successful read, nothing is treated as inactive): a database blip must not quietly start
/// processing labs that were switched off, nor stop every lab that was on.
/// </para>
/// </summary>
public sealed class LabActivationReader
{
    private const string Sql = @"
IF OBJECT_ID('dbo.Labs', 'U') IS NOT NULL
    SELECT LabId, ISNULL(LabName, '') FROM dbo.Labs WHERE IsActive = 0;";

    private readonly string _masterConnectionString;
    private readonly ILogger<LabActivationReader> _logger;
    private IReadOnlyDictionary<int, string> _lastKnown = new Dictionary<int, string>();

    public LabActivationReader(IConfiguration configuration, ILogger<LabActivationReader> logger)
    {
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("Missing DefaultConnection connection string (LRNMaster).");
        _logger = logger;
    }

    /// <summary>LabId -&gt; dbo.Labs name for every inactive lab.</summary>
    public async Task<IReadOnlyDictionary<int, string>> GetInactiveLabsAsync(CancellationToken ct)
    {
        try
        {
            var inactive = new Dictionary<int, string>();

            await using var conn = new SqlConnection(_masterConnectionString);
            await using var cmd = new SqlCommand(Sql, conn) { CommandTimeout = 60 };
            await conn.OpenAsync(ct).ConfigureAwait(false);
            await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

            while (await reader.ReadAsync(ct).ConfigureAwait(false))
                inactive[reader.GetInt32(0)] = reader.GetString(1).Trim();

            _lastKnown = inactive;
            return inactive;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _logger.LogWarning(ex,
                "Could not read inactive labs from LRNMaster.dbo.Labs; using the last known list ({Count} lab(s)).",
                _lastKnown.Count);
            return _lastKnown;
        }
    }
}
