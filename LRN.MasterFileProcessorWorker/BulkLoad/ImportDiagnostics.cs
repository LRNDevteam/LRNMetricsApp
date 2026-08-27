using System.Data;
using Microsoft.Data.SqlClient;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>
/// Preflight check for the line/claim bulk copy, runnable without processing a file.
/// <para>
/// Run with: <c>LRN.MasterFileProcessorWorker.exe --diagnose</c>
/// </para>
/// <para>
/// Answers "is the change working or not" directly, instead of having to infer it from empty tables
/// after a full run. Every check reports the specific setting or object that is wrong.
/// </para>
/// </summary>
public static class ImportDiagnostics
{
    private static int _fail;

    public static async Task<int> RunAsync(
        LineClaimImportOptions options,
        ImportOptions importOptions,
        IConfiguration configuration,
        LabMappingLoader loader,
        string contentRoot,
        CancellationToken ct)
    {
        _fail = 0;

        Console.WriteLine();
        Console.WriteLine("Line/Claim bulk copy - preflight");
        Console.WriteLine(new string('=', 78));

        // 1. master switch
        Section("1. Worker configuration");
        Report("LineClaimImport:Enabled", options.Enabled,
            options.Enabled ? "on" : "OFF - nothing will be copied and nothing will be logged");

        var mappingFolder = Path.IsPathRooted(options.LabMappingsFolder)
            ? options.LabMappingsFolder
            : Path.Combine(contentRoot, options.LabMappingsFolder);

        Report("Lab mappings folder", Directory.Exists(mappingFolder), mappingFolder);

        // 1b. secrets that only Key Vault supplies. A missing secret here fails every lab at the
        // first Graph call, so it is worth catching before a file is ever touched.
        var vaultUri = configuration["KeyVault:VaultUri"];
        Report("KeyVault:VaultUri", !string.IsNullOrWhiteSpace(vaultUri),
            string.IsNullOrWhiteSpace(vaultUri)
                ? "not set - secrets must come from appsettings.Secrets.json or environment variables"
                : vaultUri!);

        var sp = importOptions.SharePoint;
        Report("SharePoint:Enabled", sp.Enabled, sp.Enabled ? "on" : "OFF - no file will be downloaded");

        if (sp.Enabled)
        {
            foreach (var (name, value) in new[]
                     {
                         ("TenantId", sp.TenantId),
                         ("ClientId", sp.ClientId),
                         ("ClientSecret", sp.ClientSecret)
                     })
            {
                Report($"SharePoint:{name}", !string.IsNullOrWhiteSpace(value),
                    string.IsNullOrWhiteSpace(value)
                        ? $"missing - create the Key Vault secret 'MasterFileProcessor--SharePoint--{name}'"
                        : MaskSecret(value));
            }
        }

        // 2. mappings
        Section("2. Lab mapping files");
        IReadOnlyList<LabMappingConfig> mappings = Array.Empty<LabMappingConfig>();

        try
        {
            mappings = loader.LoadAll(mappingFolder);
            Report("All mapping files valid", true, $"{mappings.Count} file(s)");
        }
        catch (Exception ex)
        {
            Report("All mapping files valid", false, ex.Message.Replace(Environment.NewLine, " "));
            return Finish();
        }

        // 3. LRNMaster
        Section("3. LRNMaster");
        var master = configuration.GetConnectionString("DefaultConnection");
        Report("ConnectionStrings:DefaultConnection", !string.IsNullOrWhiteSpace(master), Mask(master));

        if (string.IsNullOrWhiteSpace(master))
            return Finish();

        var masterOk = await CanConnectAsync(master!, ct);
        Report("LRNMaster reachable", masterOk.Ok, masterOk.Detail);

        var hasLabsTable = false;

        if (masterOk.Ok)
        {
            hasLabsTable = await TableExistsAsync(master!, "dbo.Labs", ct);

            // Optional: when it is absent the worker falls back to MasterFileProcessor:Labs.
            Console.WriteLine($"  {(hasLabsTable ? "ok  " : "note")} {"dbo.Labs exists",-42} " +
                              (hasLabsTable ? "" : "absent - falling back to MasterFileProcessor:Labs"));

            foreach (var table in new[] { "dbo.ReportRunIdInfoLog", "dbo.ReportsWorkflowTracker" })
            {
                var exists = await TableExistsAsync(master!, table, ct);
                Report($"{table} exists", exists, exists ? "" : "run sql/LRNMaster/*.sql");
            }
        }

        // 4. per-lab
        Section("4. Labs configured in MasterFileProcessor:Labs");

        var labs = importOptions.Labs ?? new List<LabFileMap>();
        if (labs.Count == 0)
            Report("At least one lab configured", false, "MasterFileProcessor:Labs is empty");

        foreach (var lab in labs)
        {
            Console.WriteLine();
            Console.WriteLine($"  --- Lab {lab.LabId} '{lab.LabName}' ---");

            var mapping = mappings.FirstOrDefault(m => m.LabId == lab.LabId);
            Report($"  mapping with LabId {lab.LabId}", mapping is not null,
                mapping?.SourceFile ?? $"no *FieldMappings.json declares \"LabId\": {lab.LabId}");

            if (mapping is null) continue;

            foreach (var (levelName, level) in new[]
                     {
                         (FileTypes.LineLevel, mapping.LineLevel),
                         (FileTypes.ClaimLevel, mapping.ClaimLevel)
                     })
            {
                if (level is null)
                {
                    Report($"  [{levelName}] section present", false, "missing from the mapping JSON");
                    continue;
                }

                // CreateCsv is NOT part of this: it controls the file only, never the load.
                var willLoad = level.Enabled && level.BulkCopyToTable;

                if (willLoad)
                {
                    Report($"  [{levelName}] will bulk copy", true, $"-> {level.SqlTableName}");
                }
                else
                {
                    // A level switched off on purpose is not a failure - say so without counting it.
                    var why = !level.Enabled ? "Enabled=false" : "BulkCopyToTable=false";
                    Console.WriteLine($"  note   {$"  [{levelName}] will bulk copy",-42} " +
                                      $"skipped by config ({why}) - set it true in the lab's *FieldMappings.json to load");
                }
            }

            // connection: same precedence the worker uses
            var labConn = FirstNonBlank(
                GetLabValue(configuration, lab, "LabDbConnectionString"),
                configuration.GetConnectionString(GetLabValue(configuration, lab, "LabDbConnectionKey") ?? ""));

            if (hasLabsTable)
            {
                var labMasterKey = await LabsConnectionKeyAsync(master!, lab.LabId, ct);
                Report("  active row in dbo.Labs", labMasterKey is not null,
                    labMasterKey is null ? "no row with IsActive = 1 -> lab is skipped" : $"ConnectionKey='{labMasterKey}'");

                if (string.IsNullOrWhiteSpace(labConn) && !string.IsNullOrWhiteSpace(labMasterKey))
                    labConn = configuration.GetConnectionString(labMasterKey!);
            }

            Report("  lab connection string", !string.IsNullOrWhiteSpace(labConn), Mask(labConn));

            if (string.IsNullOrWhiteSpace(labConn)) continue;

            var labOk = await CanConnectAsync(labConn!, ct);
            Report("  lab database reachable", labOk.Ok, labOk.Detail);

            if (!labOk.Ok) continue;

            var catalog = CatalogOf(labConn!);
            if (!string.IsNullOrWhiteSpace(mapping.DatabaseName) &&
                !string.Equals(catalog, mapping.DatabaseName, StringComparison.OrdinalIgnoreCase))
            {
                Report("  DatabaseName matches connection", false,
                    $"mapping says '{mapping.DatabaseName}' but the connection targets '{catalog}' - the generated sql/Labs/<db>/ scripts may target the wrong database");
            }

            foreach (var table in new[] { "dbo.LineClaimFileLogs" }
                         .Concat(new[] { mapping.LineLevel, mapping.ClaimLevel }
                             .Where(l => l is { Enabled: true, BulkCopyToTable: true })
                             .Select(l => l!.SqlTableName)))
            {
                var exists = await TableExistsAsync(labConn!, table, ct);
                Report($"  {table} exists", exists, exists ? "" : $"run sql/Labs/{catalog}/*.sql");
            }

            var hasStatus = await ColumnExistsAsync(labConn!, "dbo.LineClaimFileLogs", "Status", ct);
            Report("  LineClaimFileLogs.Status column", hasStatus,
                hasStatus ? "" : "optional - run sql/Labs/_Common/02_LineClaimFileLogs.sql to record load outcomes");

            // Column drift. Table existence is not enough: a table left over from an earlier
            // iteration is skipped by CREATE TABLE IF NOT EXISTS, and the load then fails mid-swap
            // with 'Invalid column name'. Compare what the mapping needs against what is there.
            foreach (var (levelName, level) in new[]
                     {
                         (FileTypes.LineLevel, mapping.LineLevel),
                         (FileTypes.ClaimLevel, mapping.ClaimLevel)
                     })
            {
                if (level is not { Enabled: true, BulkCopyToTable: true }) continue;

                var expected = level.Fields.Select(f => f.SqlColumn)
                    .Concat(AuditColumns.Names)
                    .Where(c => !string.IsNullOrWhiteSpace(c))
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToList();

                foreach (var table in new[] { level.SqlTableName })
                {
                    var actual = await ColumnNamesAsync(labConn!, table, ct);
                    if (actual.Count == 0) continue;   // table missing - already reported above

                    var missing = expected
                        .Where(c => !actual.Contains(c))
                        .OrderBy(c => c, StringComparer.OrdinalIgnoreCase)
                        .ToList();

                    Report($"  [{levelName}] {table} columns", missing.Count == 0,
                        missing.Count == 0
                            ? $"{expected.Count} mapped columns present"
                            : $"{missing.Count} missing ({string.Join(", ", missing.Take(6))}{(missing.Count > 6 ? ", ..." : "")}) " +
                              $"- re-run sql/Labs/{catalog}/*.sql, which adds missing columns to existing tables");
                }
            }
        }

        return Finish();
    }

    // ---------------- helpers ----------------

    private static int Finish()
    {
        Console.WriteLine();
        Console.WriteLine(new string('=', 78));
        Console.WriteLine(_fail == 0
            ? "All checks passed - a run should load rows."
            : $"{_fail} check(s) failed. Fix the FAIL lines above; each names the setting or object.");
        Console.WriteLine();
        return _fail == 0 ? 0 : 1;
    }

    private static void Section(string title)
    {
        Console.WriteLine();
        Console.WriteLine(title);
    }

    private static void Report(string name, bool ok, string? detail)
    {
        if (!ok) _fail++;
        var mark = ok ? "ok  " : "FAIL";
        Console.WriteLine($"  {mark} {name,-42} {detail}");
    }

    private static string? FirstNonBlank(params string?[] values) =>
        values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));

    /// <summary>
    /// Reads a per-lab setting straight from configuration, the same way the worker's own
    /// GetLabConfigValue does. LabFileMap does not declare LabDbConnectionString as a property, so
    /// reflection over the bound object finds nothing - the value only exists in the raw config.
    /// </summary>
    private static string? GetLabValue(IConfiguration configuration, LabFileMap lab, string key)
    {
        foreach (var section in configuration.GetSection("MasterFileProcessor:Labs").GetChildren())
        {
            if (section.GetValue<int?>("LabId") == lab.LabId ||
                string.Equals(section.GetValue<string>("LabName"), lab.LabName, StringComparison.OrdinalIgnoreCase))
            {
                return section.GetValue<string>(key);
            }
        }

        return null;
    }

    private static string Mask(string? connectionString)
    {
        if (string.IsNullOrWhiteSpace(connectionString)) return "(not set)";

        try
        {
            var b = new SqlConnectionStringBuilder(connectionString);
            return $"{b.DataSource}/{b.InitialCatalog}";
        }
        catch
        {
            return "(unparseable)";
        }
    }

    /// <summary>Enough of a value to recognise it, never enough to use it.</summary>
    private static string MaskSecret(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return "(not set)";
        return value.Length <= 8
            ? $"set ({value.Length} chars)"
            : $"{value[..4]}...{value[^2..]} ({value.Length} chars)";
    }

    private static string CatalogOf(string connectionString)
    {
        try { return new SqlConnectionStringBuilder(connectionString).InitialCatalog; }
        catch { return ""; }
    }

    private static async Task<(bool Ok, string Detail)> CanConnectAsync(string connectionString, CancellationToken ct)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            return (true, $"{conn.DataSource}/{conn.Database}");
        }
        catch (Exception ex)
        {
            return (false, ex.Message.Split(Environment.NewLine)[0]);
        }
    }

    private static async Task<bool> TableExistsAsync(string connectionString, string tableName, CancellationToken ct)
    {
        var parts = tableName.Replace("[", "").Replace("]", "").Split('.', 2);
        var schema = parts.Length == 2 ? parts[0] : "dbo";
        var table = parts.Length == 2 ? parts[1] : parts[0];

        const string sql = @"
SELECT COUNT(1) FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = @Schema AND t.name = @Table;";

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await using var cmd = new SqlCommand(sql, conn);
            cmd.Parameters.Add("@Schema", SqlDbType.NVarChar, 128).Value = schema;
            cmd.Parameters.Add("@Table", SqlDbType.NVarChar, 128).Value = table;
            await conn.OpenAsync(ct);
            return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) > 0;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Column names of a table, or empty when the table does not exist.</summary>
    private static async Task<HashSet<string>> ColumnNamesAsync(string connectionString, string tableName, CancellationToken ct)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var parts = tableName.Replace("[", "").Replace("]", "").Split('.', 2);
        var schema = parts.Length == 2 ? parts[0] : "dbo";
        var table = parts.Length == 2 ? parts[1] : parts[0];

        const string sql = @"
SELECT c.name FROM sys.columns c
JOIN sys.tables t  ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = @Schema AND t.name = @Table;";

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await using var cmd = new SqlCommand(sql, conn);
            cmd.Parameters.Add("@Schema", SqlDbType.NVarChar, 128).Value = schema;
            cmd.Parameters.Add("@Table", SqlDbType.NVarChar, 128).Value = table;
            await conn.OpenAsync(ct);
            await using var reader = await cmd.ExecuteReaderAsync(ct);

            while (await reader.ReadAsync(ct))
                names.Add(reader.GetString(0));
        }
        catch
        {
            // Treated as "unknown"; table existence is reported separately.
        }

        return names;
    }

    private static async Task<bool> ColumnExistsAsync(string connectionString, string table, string column, CancellationToken ct)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await using var cmd = new SqlCommand("SELECT COL_LENGTH(@Table, @Column);", conn);
            cmd.Parameters.Add("@Table", SqlDbType.NVarChar, 256).Value = table;
            cmd.Parameters.Add("@Column", SqlDbType.NVarChar, 128).Value = column;
            await conn.OpenAsync(ct);

            // COL_LENGTH returns SMALLINT (boxes as short), and NULL when the column is absent.
            var result = await cmd.ExecuteScalarAsync(ct);
            return result is not null && result is not DBNull;
        }
        catch
        {
            return false;
        }
    }

    private static async Task<string?> LabsConnectionKeyAsync(string masterConnectionString, int labId, CancellationToken ct)
    {
        const string sql = "SELECT TOP (1) ISNULL(ConnectionKey,'') FROM dbo.Labs WHERE LabId = @LabId AND IsActive = 1;";

        try
        {
            await using var conn = new SqlConnection(masterConnectionString);
            await using var cmd = new SqlCommand(sql, conn);
            cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
            await conn.OpenAsync(ct);
            return await cmd.ExecuteScalarAsync(ct) as string;
        }
        catch
        {
            return null;
        }
    }
}
