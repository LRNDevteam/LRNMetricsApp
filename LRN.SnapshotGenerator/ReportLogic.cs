using System.Data;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

namespace LRN.SnapshotGenerator;

/// <summary>A stored procedure, view or function of the lab database a report ran, as it was defined that week.</summary>
public sealed record ReportLogicObject(string Name, string Type, string Sha256, DateTime ModifiedOnUtc);

/// <summary>
/// The report logic a snapshot was produced with: the LRN Metrics build that ran the page's code, and
/// every lab-database object the report executed - directly or through another procedure - with a hash
/// of its definition. A later change to the report (a new split in LIS Summary, a rewritten procedure)
/// shows up as a difference from the previous week's snapshot; the earlier snapshots keep the data and
/// the logic version they were captured with.
/// </summary>
public sealed class ReportLogicVersion
{
    public string? AppVersion { get; set; }
    public List<ReportLogicObject> Objects { get; set; } = [];

    /// <summary>What differs from <paramref name="previous"/>; empty when nothing did or there is no previous snapshot.</summary>
    public List<string> ChangesSince(ReportLogicVersion? previous)
    {
        var changes = new List<string>();
        if (previous is null) return changes;

        var before = previous.Objects.ToDictionary(o => o.Name, StringComparer.OrdinalIgnoreCase);
        var now = Objects.ToDictionary(o => o.Name, StringComparer.OrdinalIgnoreCase);
        foreach (var o in Objects.OrderBy(o => o.Name, StringComparer.OrdinalIgnoreCase))
        {
            if (!before.TryGetValue(o.Name, out var old))
                changes.Add($"Added: {o.Name}");
            else if (!string.Equals(old.Sha256, o.Sha256, StringComparison.OrdinalIgnoreCase))
                changes.Add($"Changed: {o.Name} (modified {o.ModifiedOnUtc:yyyy-MM-dd HH:mm} UTC)");
        }
        foreach (var o in previous.Objects.Where(o => !now.ContainsKey(o.Name)).OrderBy(o => o.Name, StringComparer.OrdinalIgnoreCase))
            changes.Add($"No longer used: {o.Name}");

        if (!string.IsNullOrWhiteSpace(previous.AppVersion) && !string.Equals(previous.AppVersion, AppVersion, StringComparison.Ordinal))
            changes.Add($"LRN Metrics build: {previous.AppVersion} -> {AppVersion}");
        return changes;
    }

    /// <summary>The LabMetricsDashboard build the report code comes from.</summary>
    public static string CurrentAppVersion()
    {
        var assembly = typeof(LabMetricsDashboard.Models.LabSettings).Assembly;
        var version = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
                      ?? assembly.GetName().Version?.ToString() ?? "unknown";
        try
        {
            var built = File.GetLastWriteTimeUtc(assembly.Location);
            return $"{version} (built {built:yyyy-MM-dd HH:mm} UTC)";
        }
        catch
        {
            return version;
        }
    }
}

/// <summary>Reads the definitions of the objects a report ran from the lab database.</summary>
public static partial class ReportLogicFingerprint
{
    public static async Task<ReportLogicVersion> CaptureAsync(
        string labConnectionString, IReadOnlyList<RecordedSqlCommand> commands, CancellationToken ct)
    {
        var version = new ReportLogicVersion { AppVersion = ReportLogicVersion.CurrentAppVersion() };

        // Only the lab database's own objects: commands to LRNMaster (notes, run log) are not the report's logic.
        var lab = new SqlConnectionStringBuilder(labConnectionString);
        var names = commands
            .Where(c => string.Equals(c.Database, lab.InitialCatalog, StringComparison.OrdinalIgnoreCase))
            .SelectMany(ObjectNames)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (names.Count == 0) return version;

        // The objects named, then what they reference in turn (a procedure calling another), five levels deep.
        // Tables, and names that are not objects (alias.column), have no sys.sql_modules row and drop out.
        // The names travel as XML (<names><n>dbo.x</n>...</names>): unlike STRING_SPLIT it works at any
        // database compatibility level.
        const string sql = @"
WITH names AS (
    SELECT n.value(N'.', N'nvarchar(300)') AS Name FROM @Names.nodes(N'/names/n') AS t(n)
),
roots AS (
    SELECT o.object_id
    FROM sys.objects o
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE s.name + N'.' + o.name IN (SELECT Name FROM names)
),
tree AS (
    SELECT object_id, 0 AS lvl FROM roots
    UNION ALL
    SELECT d.referenced_id, t.lvl + 1
    FROM tree t
    JOIN sys.sql_expression_dependencies d ON d.referencing_id = t.object_id
    WHERE d.referenced_id IS NOT NULL AND t.lvl < 5
)
SELECT s.name + N'.' + o.name, o.type_desc, m.definition, o.modify_date
FROM (SELECT DISTINCT object_id FROM tree) x
JOIN sys.objects o ON o.object_id = x.object_id
JOIN sys.schemas s ON s.schema_id = o.schema_id
JOIN sys.sql_modules m ON m.object_id = o.object_id
OPTION (MAXRECURSION 200);";

        await using var conn = new SqlConnection(labConnectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        cmd.Parameters.Add("@Names", SqlDbType.Xml).Value = new System.Xml.Linq.XElement("names",
            names.Select(n => new System.Xml.Linq.XElement("n", n))).ToString(System.Xml.Linq.SaveOptions.DisableFormatting);
        await conn.OpenAsync(ct);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            var definition = r.IsDBNull(2) ? "" : r.GetString(2).Replace("\r\n", "\n");
            version.Objects.Add(new ReportLogicObject(
                r.GetString(0),
                r.GetString(1),
                Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(definition))).ToLowerInvariant(),
                DateTime.SpecifyKind(r.GetDateTime(3), DateTimeKind.Utc)));
        }
        version.Objects.Sort((a, b) => StringComparer.OrdinalIgnoreCase.Compare(a.Name, b.Name));
        return version;
    }

    /// <summary>
    /// schema.name candidates in one command: the procedure itself, or every two-part name and every
    /// one-part EXEC target (dbo) in its text. Over-matching is harmless - a name that is not a module
    /// finds nothing.
    /// </summary>
    internal static IEnumerable<string> ObjectNames(RecordedSqlCommand command)
    {
        if (command.CommandType == CommandType.StoredProcedure)
        {
            var parts = command.CommandText.Split('.').Select(p => p.Trim().Trim('[', ']')).ToArray();
            if (parts.Length == 1) yield return $"dbo.{parts[0]}";
            else if (parts.Length >= 2) yield return $"{parts[^2]}.{parts[^1]}";
            yield break;
        }

        foreach (Match m in TwoPartName().Matches(command.CommandText))
        {
            var schema = m.Groups["s1"].Success ? m.Groups["s1"].Value : m.Groups["s2"].Value;
            var name = m.Groups["n1"].Success ? m.Groups["n1"].Value : m.Groups["n2"].Value;
            yield return $"{schema}.{name}";
        }
        foreach (Match m in ExecOnePart().Matches(command.CommandText))
            yield return $"dbo.{m.Groups["name"].Value}";
    }

    // [schema].[name] or schema.name, not part of a three-part name.
    [GeneratedRegex(@"(?<![\w\]@#.])(?:\[(?<s1>[^\]]+)\]|(?<s2>[A-Za-z_]\w*))\s*\.\s*(?:\[(?<n1>[^\]]+)\]|(?<n2>[A-Za-z_]\w*))(?![\w.\[])")]
    private static partial Regex TwoPartName();

    // EXEC usp_Name / EXECUTE [usp_Name] with no schema.
    [GeneratedRegex(@"\bEXEC(?:UTE)?\s+(?:@\w+\s*=\s*)?\[?(?<name>[A-Za-z_]\w*)\b\]?(?!\s*\.)", RegexOptions.IgnoreCase)]
    private static partial Regex ExecOnePart();
}
