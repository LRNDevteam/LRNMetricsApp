using Microsoft.Data.SqlClient;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>One active lab, joined from dbo.Labs to its mapping JSON and its connection string.</summary>
public sealed record ResolvedLab(
    int LabId,
    string LabName,
    string ConnectionKey,
    string ConnectionString,
    LabMappingConfig Mapping);

/// <summary>
/// Resolves the authoritative lab list from <c>LRNMaster.dbo.Labs</c> and joins each row to its
/// mapping JSON.
/// <para>
/// dbo.Labs is the single global lab registry, shared by the Master File Processor, the
/// Denial Processor, LRN Metrics and the LRN API. Every other candidate list in the repo
/// disagreed with it, so nothing else is trusted for LabId.
/// </para>
/// <para>
/// The connection string comes from configuration under <c>Labs.ConnectionKey</c>; it is never
/// read from the mapping JSON and never hard-coded.
/// </para>
/// </summary>
public sealed class LabRegistry
{
    private const string LabMasterSql = @"
SELECT  LabId,
        LabName,
        ConnectionKey
FROM    dbo.Labs
WHERE   IsActive = 1
ORDER BY LabId;";

    private readonly IConfiguration _configuration;
    private readonly LabMappingLoader _loader;
    private readonly ILogger<LabRegistry> _logger;
    private readonly string _masterConnectionString;

    public LabRegistry(IConfiguration configuration, LabMappingLoader loader, ILogger<LabRegistry> logger)
    {
        _configuration = configuration;
        _loader = loader;
        _logger = logger;

        _masterConnectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("Missing DefaultConnection connection string (LRNMaster).");
    }

    /// <summary>
    /// Resolves ONE lab for the bulk copy. Returns null (with a reason logged) when the lab cannot be
    /// resolved, so a lab that is not set up never stops the rest of the run.
    /// </summary>
    /// <param name="labConnectionStringOverride">
    /// The lab's connection string as the worker already resolves it from
    /// <c>MasterFileProcessor:Labs[].LabDbConnectionString</c>. This takes precedence over
    /// Labs.ConnectionKey, because that is where per-lab connection strings actually live in
    /// this repo - dbo.Labs is authoritative for WHICH labs are active, not for how to reach them.
    /// </param>
    public async Task<ResolvedLab?> TryResolveLabAsync(
        int labId,
        string? labConnectionStringOverride,
        string mappingFolderPath,
        CancellationToken ct)
    {
        var mappings = LoadMappingsCached(mappingFolderPath);
        var mapping = mappings.FirstOrDefault(m => m.LabId == labId);

        if (mapping is null)
        {
            _logger.LogWarning(
                "Lab {LabId}: no mapping file in {Folder} declares \"LabId\": {LabId}. Bulk copy skipped. " +
                "Add the LabId to that lab's *FieldMappings.json.",
                labId, mappingFolderPath, labId);
            return null;
        }

        // dbo.Labs gates which labs are active WHEN IT EXISTS. It is not present on every
        // deployment, so its absence must not disable the whole feature - fall back to the lab list
        // in MasterFileProcessor:Labs, which is what the rest of this worker already iterates.
        var active = await TryReadLabsAsync(labId, ct).ConfigureAwait(false);

        if (active is { IsActive: false })
        {
            _logger.LogInformation(
                "Lab {LabId}: dbo.Labs row has IsActive = 0. Bulk copy skipped.", labId);
            return null;
        }

        var connectionString = FirstNonBlank(
            labConnectionStringOverride,
            ResolveConnectionString(active?.ConnectionKey ?? ""));

        if (string.IsNullOrWhiteSpace(connectionString))
        {
            _logger.LogWarning(
                "Lab {LabId} '{LabName}': no connection string. Set MasterFileProcessor:Labs[].LabDbConnectionString " +
                "for this lab, or add a ConnectionStrings entry matching Labs.ConnectionKey. Bulk copy skipped.",
                labId, mapping.LabName ?? active?.LabName ?? "");
            return null;
        }

        var labName = FirstNonBlank(active?.LabName, mapping.LabName) ?? $"Lab{labId}";

        return new ResolvedLab(labId, labName, active?.ConnectionKey ?? "", connectionString!, mapping);
    }

    private static string? FirstNonBlank(params string?[] values) =>
        values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));

    /// <summary>
    /// The mapping for one lab, without touching the database. Used by the worker to decide which
    /// CSVs to produce, which must not depend on LRNMaster being reachable.
    /// </summary>
    public LabMappingConfig? TryGetMapping(int labId, string mappingFolderPath) =>
        LoadMappingsCached(mappingFolderPath).FirstOrDefault(m => m.LabId == labId);

    private IReadOnlyList<LabMappingConfig>? _cachedMappings;
    private string? _cachedMappingFolder;

    /// <summary>Mapping files change only on deploy; loading them per lab per run is wasted work.</summary>
    private IReadOnlyList<LabMappingConfig> LoadMappingsCached(string mappingFolderPath)
    {
        if (_cachedMappings is not null &&
            string.Equals(_cachedMappingFolder, mappingFolderPath, StringComparison.OrdinalIgnoreCase))
        {
            return _cachedMappings;
        }

        _cachedMappings = _loader.LoadAll(mappingFolderPath);
        _cachedMappingFolder = mappingFolderPath;
        return _cachedMappings;
    }

    private sealed record LabsRow(string LabName, string ConnectionKey, bool IsActive);

    /// <summary>
    /// Reads the dbo.Labs row, or null when the table does not exist, the row is absent, or the
    /// read fails. Null means "dbo.Labs has nothing to say about this lab", not "skip the lab".
    /// </summary>
    private async Task<LabsRow?> TryReadLabsAsync(int labId, CancellationToken ct)
    {
        const string sql = @"
IF OBJECT_ID('dbo.Labs', 'U') IS NOT NULL
    SELECT TOP (1) LabName, ISNULL(ConnectionKey, ''), IsActive
    FROM   dbo.Labs
    WHERE  LabId = @LabId;";

        try
        {
            await using var conn = new SqlConnection(_masterConnectionString);
            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
            cmd.Parameters.Add("@LabId", System.Data.SqlDbType.Int).Value = labId;

            await conn.OpenAsync(ct).ConfigureAwait(false);
            await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

            if (!await reader.ReadAsync(ct).ConfigureAwait(false))
                return null;

            return new LabsRow(
                reader.IsDBNull(0) ? "" : reader.GetString(0).Trim(),
                reader.IsDBNull(1) ? "" : reader.GetString(1).Trim(),
                !reader.IsDBNull(2) && reader.GetBoolean(2));
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex,
                "Lab {LabId}: could not read LRNMaster.dbo.Labs; continuing with the configured lab settings.", labId);
            return null;
        }
    }

    /// <summary>
    /// Returns every active lab that has a usable mapping. A lab that cannot be resolved is logged
    /// and skipped rather than throwing, so one bad row never stops the other labs loading.
    /// </summary>
    public async Task<IReadOnlyList<ResolvedLab>> GetActiveLabsAsync(string mappingFolderPath, CancellationToken ct)
    {
        var mappings = LoadMappingsCached(mappingFolderPath);
        var rows = await ReadLabsAsync(ct).ConfigureAwait(false);

        var resolved = new List<ResolvedLab>();

        foreach (var (labId, labName, connectionKey) in rows)
        {
            var mapping = MatchMapping(mappings, labId, labName);

            if (mapping is null)
            {
                _logger.LogWarning(
                    "LabMaster lab {LabId} '{LabName}' has no mapping file in the LabMappings folder. Skipping bulk load for this lab.",
                    labId, labName);
                continue;
            }

            var connectionString = ResolveConnectionString(connectionKey);

            if (string.IsNullOrWhiteSpace(connectionString))
            {
                _logger.LogWarning(
                    "LabMaster lab {LabId} '{LabName}' has ConnectionKey '{Key}' but no matching connection string in configuration. Skipping bulk load for this lab.",
                    labId, labName, connectionKey);
                continue;
            }

            resolved.Add(new ResolvedLab(labId, labName, connectionKey, connectionString!, mapping));
        }

        var unused = mappings
            .Where(m => !resolved.Any(r => ReferenceEquals(r.Mapping, m)))
            .Select(m => m.SourceFile)
            .ToList();

        if (unused.Count > 0)
        {
            _logger.LogInformation(
                "Mapping files not matched to any active LabMaster row (ignored): {Files}",
                string.Join(", ", unused));
        }

        return resolved;
    }

    private async Task<List<(int LabId, string LabName, string ConnectionKey)>> ReadLabsAsync(CancellationToken ct)
    {
        var rows = new List<(int, string, string)>();

        await using var conn = new SqlConnection(_masterConnectionString);
        await using var cmd = new SqlCommand(LabMasterSql, conn) { CommandTimeout = 60 };

        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        while (await reader.ReadAsync(ct).ConfigureAwait(false))
        {
            rows.Add((
                reader.GetInt32(0),
                reader.IsDBNull(1) ? "" : reader.GetString(1).Trim(),
                reader.IsDBNull(2) ? "" : reader.GetString(2).Trim()));
        }

        return rows;
    }

    /// <summary>
    /// LabId wins; then LabName; then the file-name stem. The stem fallback exists because the
    /// current file names do not match lab names exactly (PCRLOA / PCRLabsofAmerica,
    /// PHILIFE / PhiLife, InHEalthDTR / InHealthDTR).
    /// </summary>
    private static LabMappingConfig? MatchMapping(IReadOnlyList<LabMappingConfig> mappings, int labId, string labName)
    {
        var byId = mappings.FirstOrDefault(m => m.LabId == labId);
        if (byId is not null)
            return byId;

        var byName = mappings.FirstOrDefault(m =>
            !string.IsNullOrWhiteSpace(m.LabName) &&
            string.Equals(Squash(m.LabName!), Squash(labName), StringComparison.OrdinalIgnoreCase));

        if (byName is not null)
            return byName;

        var stem = Squash(labName);

        return mappings.FirstOrDefault(m =>
        {
            var fileStem = Squash(Path.GetFileNameWithoutExtension(m.SourceFile).Replace("FieldMappings", "", StringComparison.OrdinalIgnoreCase));
            return fileStem.Length > 0 && string.Equals(fileStem, stem, StringComparison.OrdinalIgnoreCase);
        });
    }

    private static string Squash(string value) =>
        new(value.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());

    /// <summary>ConnectionStrings:&lt;key&gt; first, then a bare configuration key of the same name.</summary>
    private string? ResolveConnectionString(string connectionKey)
    {
        if (string.IsNullOrWhiteSpace(connectionKey))
            return null;

        return _configuration.GetConnectionString(connectionKey)
            ?? _configuration[connectionKey];
    }
}
