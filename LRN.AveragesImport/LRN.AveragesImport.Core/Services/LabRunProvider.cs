using System.Data;
using System.Text;
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
    /// and resolves each against the configured lab mapping (LabId + source connection).
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

        var configured = settings.Labs.Where(l => !string.IsNullOrWhiteSpace(l.LabName)).ToList();

        var labsByName = configured
            .ToDictionary(l => l.LabName.Trim(), l => l, StringComparer.OrdinalIgnoreCase);

        // The SP reports display names ("Augustus Labs", "PCR Labs of America") while the
        // config uses compact ones ("Augustus_Labs", "PCRLabsofAmerica"), and Beech_Tree /
        // BeechTree differ the other way. Matching on letters and digits only bridges both
        // without having to keep the two spellings in sync by hand. Exact match still wins;
        // this is only the fallback. A normalized key claimed by two configured labs is
        // dropped from the fallback map so an ambiguous name never silently picks one.
        var labsByNormalizedName = configured
            .GroupBy(l => NormalizeLabName(l.LabName), StringComparer.Ordinal)
            .Where(g => g.Count() == 1)
            .ToDictionary(g => g.Key, g => g.Single(), StringComparer.Ordinal);

        foreach (var ambiguous in configured
                     .GroupBy(l => NormalizeLabName(l.LabName), StringComparer.Ordinal)
                     .Where(g => g.Count() > 1))
        {
            _logger.LogWarning(
                "Configured labs {LabNames} all reduce to '{Normalized}' — name-normalizing fallback disabled for them; " +
                "their ImportSettings:Labs LabName must match the SP exactly",
                string.Join(", ", ambiguous.Select(l => l.LabName)), ambiguous.Key);
        }

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
                    if (!labsByNormalizedName.TryGetValue(NormalizeLabName(labName), out mapping))
                    {
                        _logger.LogWarning(
                            "Lab {LabName} (run {RunId}) returned by SP has no entry in ImportSettings:Labs — skipping",
                            labName, runId);
                        continue;
                    }

                    _logger.LogInformation(
                        "SP lab {SpLabName} matched configured lab {ConfiguredLabName} (LabId {LabId}) by name normalization",
                        labName, mapping.LabName, mapping.LabId);
                }

                if (string.IsNullOrWhiteSpace(mapping.ConnectionString))
                {
                    _logger.LogWarning(
                        "Lab {LabName} (LabId {LabId}, run {RunId}) has no ConnectionString in ImportSettings:Labs — " +
                        "its averages cannot be aggregated; skipping",
                        labName, mapping.LabId, runId);
                    continue;
                }

                runs.Add(new LabRunInfo
                {
                    RunId = runId.Trim(),
                    LabName = labName,
                    LabId = mapping.LabId,
                    ConnectionString = mapping.ConnectionString,
                    StartTimeIst = GetDateTime(reader, "StartTimeIST"),
                    EndTimeIst = GetDateTime(reader, "EndTimeIST")
                });
            }
        }

        // Same two-step comparison as the lookup above, or a lab matched by normalization
        // would still be reported here as missing.
        var seenNormalized = spLabNames.Select(NormalizeLabName).ToHashSet(StringComparer.Ordinal);
        foreach (var lab in settings.Labs)
        {
            if (!seenNormalized.Contains(NormalizeLabName(lab.LabName ?? string.Empty)))
                _logger.LogInformation("Configured lab {LabName} (LabId {LabId}) had no row from the SP this cycle",
                    lab.LabName, lab.LabId);
        }

        return runs;
    }

    /// <summary>
    /// Reduces a lab name to its letters and digits, lower-cased, so that spacing and
    /// separator differences between the SP and the config do not break the match:
    /// "Augustus Labs", "Augustus_Labs" and "augustuslabs" all reduce to "augustuslabs".
    /// </summary>
    private static string NormalizeLabName(string name)
    {
        var buffer = new StringBuilder(name.Length);
        foreach (var c in name)
            if (char.IsLetterOrDigit(c))
                buffer.Append(char.ToLowerInvariant(c));
        return buffer.ToString();
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
