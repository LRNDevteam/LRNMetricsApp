using System.Data;
using LRN.AveragesImport.Core.Configuration;
using LRN.AveragesImport.Core.Data;
using LRN.AveragesImport.Core.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.AveragesImport.Core.Services;

public interface ILabRunProvider
{
    /// <summary>
    /// Calls sp_GetRecentSuccessRunByLab, keeps only OverallStatus = 'SUCCESS' rows,
    /// and resolves each against the configured lab mapping (LabId + FolderName).
    /// </summary>
    Task<IReadOnlyList<LabRunInfo>> GetSuccessRunsAsync(CancellationToken ct);
}

public sealed class LabRunProvider : ILabRunProvider
{
    private readonly ISqlConnectionFactory _connectionFactory;
    private readonly ILogger<LabRunProvider> _logger;
    private readonly IOptions<ImportSettings> _settings;

    public LabRunProvider(
        ISqlConnectionFactory connectionFactory,
        ILogger<LabRunProvider> logger,
        IOptions<ImportSettings> settings)
    {
        _connectionFactory = connectionFactory;
        _logger = logger;
        _settings = settings;
    }

    public async Task<IReadOnlyList<LabRunInfo>> GetSuccessRunsAsync(CancellationToken ct)
    {
        var settings = _settings.Value;

        var labsByName = settings.Labs
            .Where(l => !string.IsNullOrWhiteSpace(l.LabName))
            .ToDictionary(l => l.LabName.Trim(), l => l, StringComparer.OrdinalIgnoreCase);

        var runs = new List<LabRunInfo>();
        var spLabNames = new List<string>();

        await using (var connection = _connectionFactory.Create())
        {
            await connection.OpenAsync(ct);

            await using var command = new SqlCommand(settings.StoredProcedure, connection)
            {
                CommandType = CommandType.StoredProcedure,
                CommandTimeout = 120
            };

            await using var reader = await command.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                var runId = GetString(reader, "RunID");
                var labName = GetString(reader, "LabName")?.Trim();
                var status = GetString(reader, "OverallStatus")?.Trim();

                if (string.IsNullOrWhiteSpace(runId) || string.IsNullOrWhiteSpace(labName))
                {
                    _logger.LogWarning("SP row skipped: RunID or LabName is blank (RunID={RunId}, LabName={LabName})",
                        runId, labName);
                    continue;
                }

                spLabNames.Add(labName);

                if (!string.Equals(status, "SUCCESS", StringComparison.OrdinalIgnoreCase))
                {
                    _logger.LogInformation("Skipping lab {LabName} run {RunId}: OverallStatus is {Status}",
                        labName, runId, status);
                    continue;
                }

                if (!labsByName.TryGetValue(labName, out var mapping))
                {
                    _logger.LogWarning(
                        "Lab {LabName} (run {RunId}) returned by SP has no entry in ImportSettings:Labs — skipping",
                        labName, runId);
                    continue;
                }

                runs.Add(new LabRunInfo
                {
                    RunId = runId.Trim(),
                    LabName = labName,
                    LabId = mapping.LabId,
                    FolderName = mapping.FolderName,
                    StartTimeIst = GetDateTime(reader, "StartTimeIST"),
                    EndTimeIst = GetDateTime(reader, "EndTimeIST")
                });
            }
        }

        foreach (var configured in settings.Labs)
        {
            if (!spLabNames.Any(n => string.Equals(n, configured.LabName?.Trim(), StringComparison.OrdinalIgnoreCase)))
                _logger.LogInformation("Configured lab {LabName} (LabId {LabId}) had no row from the SP this cycle",
                    configured.LabName, configured.LabId);
        }

        return runs;
    }

    private static string? GetString(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetValue(ordinal).ToString();
    }

    private static DateTime? GetDateTime(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetDateTime(ordinal);
    }
}
