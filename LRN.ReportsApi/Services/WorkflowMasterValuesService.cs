using System.Data;
using System.Text.RegularExpressions;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

/// <summary>
/// One of the seven workflow master lists. <see cref="SuperMasterColumn"/> is the column in
/// dbo.DenialMapperSuperMaster that stores a value from this list as plain text; it drives both the
/// usage count and <see cref="MaxLength"/>, which is that column's width — a longer master value
/// could be picked in the Denial Mapper and then fail to save.
/// </summary>
public sealed record WorkflowMasterType(
    string Key,
    string Label,
    string Description,
    bool IsActionCategory,
    int MaxLength,
    string SuperMasterColumn,
    string? FormatHint = null);

public sealed record WorkflowMasterValidated(string Value, string? ActionCode, int? SortOrder, bool IsActive);

public sealed record WorkflowMasterValidation(string? Error, WorkflowMasterValidated? Result)
{
    public static WorkflowMasterValidation Fail(string error) => new(error, null);
}

/// <summary>
/// The catalogue of master lists and the rules a value must meet. Kept free of SQL so it can be
/// unit-tested and so the API and the database script agree on one definition.
/// </summary>
public static class WorkflowMasterValueRules
{
    public const int ActionCodeMaxLength = 100;
    public const int MaxSortOrder = 1_000_000;

    // The LookupType keys are the ones already stored in dbo.DenialMapperLookupMaster; they are
    // data, not labels, and must not be renamed. Order is the order the screen lists them in.
    public static readonly IReadOnlyList<WorkflowMasterType> Types =
    [
        new("DenialClassification", "Classification", "Denial classification assigned to each denial code.", false, 100, "DenialClassification"),
        new("CoverageStatus", "Coverage Status", "Payer policy coverage outcome for the billed service.", false, 100, "CoverageStatus"),
        new("ICDComplianceStatus", "ICD Compliance", "Whether the billed diagnosis codes satisfy the payer policy.", false, 100, "ICDComplianceStatus"),
        new("DenialValidity", "Denial Validity", "Whether the denial is valid under the payer policy.", false, 100, "DenialValidity"),
        new("ActionCategory", "Action Category", "Follow-up action for the denial, with its action code.", true, 100, "ActionCategory"),
        new("SLADays", "SLA", "Days allowed to work the denial.", false, 50, "SLA", "Whole number of days, e.g. 7 days"),
        new("Priority", "Priority", "Work priority for the denial.", false, 50, "Priority")
    ];

    public static WorkflowMasterType? Find(string? key) =>
        Types.FirstOrDefault(t => string.Equals(t.Key, key?.Trim(), StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Mirrors the NormalizedValue computed column on dbo.DenialMapperLookupMaster
    /// (upper-case, trimmed, with hyphens, spaces and slashes removed), so "Non Covered" and
    /// "Non-Covered" count as the same value — the exact duplication that list was normalised to remove.
    /// </summary>
    public static string Normalize(string? value) =>
        (value ?? string.Empty).Trim()
            .Replace("-", string.Empty)
            .Replace(" ", string.Empty)
            .Replace("/", string.Empty)
            .ToUpperInvariant();

    // "7", "7 days", "7days" and "7 Day" are all accepted and stored as "7 days".
    private static readonly Regex SlaPattern = new(@"^(\d{1,3})\s*(days?)?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static WorkflowMasterValidation Validate(WorkflowMasterType type, WorkflowMasterValueSaveRequest? request)
    {
        if (request is null) return WorkflowMasterValidation.Fail("A value is required.");

        var value = (request.Value ?? string.Empty).Trim();
        if (value.Length == 0) return WorkflowMasterValidation.Fail($"{type.Label} value is required.");
        if (value.Any(char.IsControl)) return WorkflowMasterValidation.Fail($"{type.Label} value cannot contain line breaks or control characters.");

        if (type.Key == "SLADays")
        {
            // The rest of the product reads SLA as a day count, and every existing value is "N days".
            // Free text such as "one week" would be accepted here and silently mean nothing downstream.
            var match = SlaPattern.Match(value);
            if (!match.Success) return WorkflowMasterValidation.Fail("SLA must be a whole number of days, for example \"7 days\".");
            var days = int.Parse(match.Groups[1].Value);
            value = days == 1 ? "1 day" : $"{days} days";
        }

        if (value.Length > type.MaxLength)
            return WorkflowMasterValidation.Fail($"{type.Label} value cannot be longer than {type.MaxLength} characters.");

        string? actionCode = null;
        if (type.IsActionCategory)
        {
            actionCode = (request.ActionCode ?? string.Empty).Trim();
            if (actionCode.Length == 0) return WorkflowMasterValidation.Fail("Action code is required for an action category.");
            if (actionCode.Any(char.IsControl)) return WorkflowMasterValidation.Fail("Action code cannot contain line breaks or control characters.");
            if (actionCode.Length > ActionCodeMaxLength)
                return WorkflowMasterValidation.Fail($"Action code cannot be longer than {ActionCodeMaxLength} characters.");
        }

        if (request.SortOrder is < 0 or > MaxSortOrder)
            return WorkflowMasterValidation.Fail($"Sort order must be between 0 and {MaxSortOrder:N0}.");

        return new(null, new WorkflowMasterValidated(value, actionCode, request.SortOrder, request.IsActive));
    }
}

public enum WorkflowMasterSaveStatus { Ok, NotFound, Conflict }

public sealed record WorkflowMasterSaveResult(WorkflowMasterSaveStatus Status, string Message)
{
    public static WorkflowMasterSaveResult Ok(string message) => new(WorkflowMasterSaveStatus.Ok, message);
    public static WorkflowMasterSaveResult NotFound(string message) => new(WorkflowMasterSaveStatus.NotFound, message);
    public static WorkflowMasterSaveResult Conflict(string message) => new(WorkflowMasterSaveStatus.Conflict, message);
}

public interface IWorkflowMasterValuesRepository
{
    Task<WorkflowMasterValuesResponse> GetAllAsync(CancellationToken ct);
    Task<WorkflowMasterSaveResult> AddAsync(WorkflowMasterType type, WorkflowMasterValidated value, string user, string role, CancellationToken ct);
    Task<WorkflowMasterSaveResult> UpdateAsync(WorkflowMasterType type, string originalValue, WorkflowMasterValidated value, string user, string role, CancellationToken ct);
    Task<WorkflowMasterSaveResult> DeleteAsync(WorkflowMasterType type, string value, string user, string role, CancellationToken ct);
}

/// <summary>
/// Maintains the workflow master lists in LRNMaster. These are the same two tables the Denial
/// Mapper has always read its dropdowns from — dbo.DenialMapperLookupMaster (six lists, keyed by
/// LookupType) and dbo.DenialMapperActionCategoryMaster (Action Category + code) — so a change made
/// here is what the mapper offers on its next load. There is deliberately no second copy.
/// </summary>
public sealed class SqlWorkflowMasterValuesRepository(IConfiguration configuration) : IWorkflowMasterValuesRepository
{
    private SqlConnection Open() => new(configuration.GetConnectionString("DefaultConnection")
        ?? configuration.GetConnectionString("LabMetrics")
        ?? throw new InvalidOperationException("A central DefaultConnection or LabMetrics connection string is required for workflow master values."));

    // Table shapes. Only these constants are ever spliced into SQL — never request input.
    private sealed record Shape(string Table, string ValueColumn, string TypeFilter, bool HasCode);

    private static readonly Shape LookupShape = new("dbo.DenialMapperLookupMaster", "LookupValue", "LookupType=@Type", false);
    private static readonly Shape ActionShape = new("dbo.DenialMapperActionCategoryMaster", "ActionCategory", "1=1", true);

    private static Shape ShapeOf(WorkflowMasterType type) => type.IsActionCategory ? ActionShape : LookupShape;

    private sealed record Row(string Value, string? ActionCode, int SortOrder, bool IsActive);

    public async Task<WorkflowMasterValuesResponse> GetAllAsync(CancellationToken ct)
    {
        await using var c = Open();
        await c.OpenAsync(ct);
        await SqlDenialMapperRepository.EnsureMasterDataSchemaAsync(c, ct);

        var byType = WorkflowMasterValueRules.Types.ToDictionary(t => t.Key, _ => new List<WorkflowMasterValue>(), StringComparer.OrdinalIgnoreCase);

        await using (var cmd = new SqlCommand("SELECT LookupType,LookupValue,SortOrder,IsActive,CreatedOn,CreatedBy,ModifiedOn,ModifiedBy FROM dbo.DenialMapperLookupMaster", c))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                // A LookupType this screen does not know about is left alone rather than shown.
                if (!byType.TryGetValue(r.GetString(0), out var list) || string.Equals(r.GetString(0), "ActionCategory", StringComparison.OrdinalIgnoreCase)) continue;
                list.Add(ReadValue(r, valueOrdinal: 1, codeOrdinal: null));
            }
        }

        await using (var cmd = new SqlCommand("SELECT ActionCategory,ActionCode,SortOrder,IsActive,CreatedOn,CreatedBy,ModifiedOn,ModifiedBy FROM dbo.DenialMapperActionCategoryMaster", c))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
                byType["ActionCategory"].Add(ReadValue(r, valueOrdinal: 0, codeOrdinal: 1));
        }

        var usageAvailable = await SuperMasterExistsAsync(c, null, ct);
        if (usageAvailable)
        {
            var usage = await ReadAllUsageAsync(c, ct);
            foreach (var type in WorkflowMasterValueRules.Types)
                foreach (var item in byType[type.Key])
                    item.UsageCount = usage.GetValueOrDefault((type.Key, item.Value.Trim()));
        }

        return new WorkflowMasterValuesResponse
        {
            UsageAvailable = usageAvailable,
            Lists = WorkflowMasterValueRules.Types.Select(t => new WorkflowMasterList
            {
                Type = t.Key,
                Label = t.Label,
                Description = t.Description,
                HasActionCode = t.IsActionCategory,
                MaxLength = t.MaxLength,
                FormatHint = t.FormatHint,
                Values = byType[t.Key]
                    .OrderBy(v => v.SortOrder)
                    .ThenBy(v => v.Value, StringComparer.OrdinalIgnoreCase)
                    .ToList()
            }).ToList()
        };
    }

    public async Task<WorkflowMasterSaveResult> AddAsync(WorkflowMasterType type, WorkflowMasterValidated value, string user, string role, CancellationToken ct)
    {
        await using var c = Open();
        await c.OpenAsync(ct);
        await SqlDenialMapperRepository.EnsureMasterDataSchemaAsync(c, ct);
        await using var tx = (SqlTransaction)await c.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);

        var shape = ShapeOf(type);
        var rows = await LockRowsAsync(c, tx, shape, type, ct);

        var duplicate = FindNormalizedDuplicate(rows, value.Value, except: null);
        if (duplicate is not null)
            return WorkflowMasterSaveResult.Conflict(DuplicateMessage(type, value.Value, duplicate));

        var sortOrder = value.SortOrder ?? (rows.Count == 0 ? 10 : rows.Max(x => x.SortOrder) + 10);

        var insert = shape.HasCode
            ? "INSERT dbo.DenialMapperActionCategoryMaster(ActionCategory,ActionCode,SortOrder,IsActive,CreatedBy,ModifiedBy,ModifiedOn) VALUES(@Value,@Code,@Sort,@Active,@User,@User,SYSUTCDATETIME())"
            : "INSERT dbo.DenialMapperLookupMaster(LookupType,LookupValue,SortOrder,IsActive,CreatedBy,ModifiedBy,ModifiedOn) VALUES(@Type,@Value,@Sort,@Active,@User,@User,SYSUTCDATETIME())";
        await using (var cmd = new SqlCommand(insert, c, tx))
        {
            cmd.Parameters.Add("@Type", SqlDbType.NVarChar, 50).Value = type.Key;
            cmd.Parameters.Add("@Value", SqlDbType.NVarChar, 255).Value = value.Value;
            cmd.Parameters.Add("@Code", SqlDbType.NVarChar, 100).Value = (object?)value.ActionCode ?? DBNull.Value;
            cmd.Parameters.Add("@Sort", SqlDbType.Int).Value = sortOrder;
            cmd.Parameters.Add("@Active", SqlDbType.Bit).Value = value.IsActive;
            cmd.Parameters.Add("@User", SqlDbType.NVarChar, 200).Value = Truncate(user, 200);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        await AuditAsync(c, tx, "MasterValueAdded", type, "Value", null, Describe(type, value.Value, value.ActionCode), user, role, ct);
        await tx.CommitAsync(ct);
        return WorkflowMasterSaveResult.Ok($"\"{value.Value}\" added to {type.Label}.");
    }

    public async Task<WorkflowMasterSaveResult> UpdateAsync(WorkflowMasterType type, string originalValue, WorkflowMasterValidated value, string user, string role, CancellationToken ct)
    {
        await using var c = Open();
        await c.OpenAsync(ct);
        await SqlDenialMapperRepository.EnsureMasterDataSchemaAsync(c, ct);
        await using var tx = (SqlTransaction)await c.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);

        var shape = ShapeOf(type);
        var rows = await LockRowsAsync(c, tx, shape, type, ct);
        var original = FindExact(rows, originalValue);
        if (original is null)
            return WorkflowMasterSaveResult.NotFound($"\"{originalValue}\" no longer exists in {type.Label} — someone may have changed it. Reload the page and try again.");

        var renamed = !string.Equals(original.Value, value.Value, StringComparison.Ordinal);
        var usage = await UsageAsync(c, tx, type, original.Value, ct);

        if (renamed)
        {
            var duplicate = FindNormalizedDuplicate(rows, value.Value, except: original);
            if (duplicate is not null)
                return WorkflowMasterSaveResult.Conflict(DuplicateMessage(type, value.Value, duplicate));

            // Super Master rows store the text itself, not a key. Renaming a value they use would
            // leave every one of them holding a value that is no longer in the list — the mapper
            // would show those fields blank the next time anyone edited the row.
            if (usage > 0)
                return WorkflowMasterSaveResult.Conflict(
                    $"\"{original.Value}\" is used by {Mappings(usage)} in the Super Master, so it cannot be renamed. " +
                    $"Add \"{value.Value}\" as a new value, move those mappings to it, then deactivate \"{original.Value}\".");
        }

        if (original.IsActive && !value.IsActive && rows.Count(x => x.IsActive) <= 1)
            return WorkflowMasterSaveResult.Conflict($"{type.Label} must keep at least one active value — the Denial Mapper needs something to offer. Add or activate another value first.");

        var sortOrder = value.SortOrder ?? original.SortOrder;

        var update = shape.HasCode
            ? "UPDATE dbo.DenialMapperActionCategoryMaster SET ActionCategory=@Value,ActionCode=@Code,SortOrder=@Sort,IsActive=@Active,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHERE ActionCategory=@Original"
            : "UPDATE dbo.DenialMapperLookupMaster SET LookupValue=@Value,SortOrder=@Sort,IsActive=@Active,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHERE LookupType=@Type AND LookupValue=@Original";
        await using (var cmd = new SqlCommand(update, c, tx))
        {
            cmd.Parameters.Add("@Type", SqlDbType.NVarChar, 50).Value = type.Key;
            cmd.Parameters.Add("@Original", SqlDbType.NVarChar, 255).Value = original.Value;
            cmd.Parameters.Add("@Value", SqlDbType.NVarChar, 255).Value = value.Value;
            cmd.Parameters.Add("@Code", SqlDbType.NVarChar, 100).Value = (object?)value.ActionCode ?? DBNull.Value;
            cmd.Parameters.Add("@Sort", SqlDbType.Int).Value = sortOrder;
            cmd.Parameters.Add("@Active", SqlDbType.Bit).Value = value.IsActive;
            cmd.Parameters.Add("@User", SqlDbType.NVarChar, 200).Value = Truncate(user, 200);
            if (await cmd.ExecuteNonQueryAsync(ct) == 0)
                return WorkflowMasterSaveResult.NotFound($"\"{originalValue}\" no longer exists in {type.Label}. Reload the page and try again.");
        }

        // One audit row per field that actually changed, so the Audit Log reads as a change history.
        var changes = 0;
        if (renamed)
            changes += await AuditAsync(c, tx, "MasterValueUpdated", type, "Value", original.Value, value.Value, user, role, ct);
        if (shape.HasCode && !string.Equals(original.ActionCode, value.ActionCode, StringComparison.Ordinal))
            changes += await AuditAsync(c, tx, "MasterValueUpdated", type, "Action Code", original.ActionCode, value.ActionCode, user, role, ct, remarksValue: value.Value);
        if (original.SortOrder != sortOrder)
            changes += await AuditAsync(c, tx, "MasterValueUpdated", type, "Sort Order", original.SortOrder.ToString(), sortOrder.ToString(), user, role, ct, remarksValue: value.Value);
        if (original.IsActive != value.IsActive)
            changes += await AuditAsync(c, tx, value.IsActive ? "MasterValueActivated" : "MasterValueDeactivated", type, "Status",
                original.IsActive ? "Active" : "Inactive", value.IsActive ? "Active" : "Inactive", user, role, ct, remarksValue: value.Value);

        await tx.CommitAsync(ct);

        if (changes == 0) return WorkflowMasterSaveResult.Ok($"No changes to \"{value.Value}\".");

        var message = original.IsActive != value.IsActive && changes == 1
            ? $"\"{value.Value}\" {(value.IsActive ? "activated" : "deactivated")} in {type.Label}."
            : $"\"{value.Value}\" updated in {type.Label}.";

        // Worth saying, not worth blocking: a new action code is what the mapper suggests from now on,
        // but the mappings already saved keep the code they were saved with.
        if (shape.HasCode && usage > 0 && !string.Equals(original.ActionCode, value.ActionCode, StringComparison.Ordinal))
            message += $" The {Mappings(usage)} already using it keep action code \"{original.ActionCode}\" until they are edited.";
        if (original.IsActive && !value.IsActive && usage > 0)
            message += $" The {Mappings(usage)} already using it are unchanged; it is just no longer offered for new ones.";

        return WorkflowMasterSaveResult.Ok(message);
    }

    public async Task<WorkflowMasterSaveResult> DeleteAsync(WorkflowMasterType type, string value, string user, string role, CancellationToken ct)
    {
        await using var c = Open();
        await c.OpenAsync(ct);
        await SqlDenialMapperRepository.EnsureMasterDataSchemaAsync(c, ct);
        await using var tx = (SqlTransaction)await c.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);

        var shape = ShapeOf(type);
        var rows = await LockRowsAsync(c, tx, shape, type, ct);
        var existing = FindExact(rows, value);
        if (existing is null)
            return WorkflowMasterSaveResult.NotFound($"\"{value}\" no longer exists in {type.Label}. Reload the page and try again.");

        var usage = await UsageAsync(c, tx, type, existing.Value, ct);
        if (usage > 0)
            return WorkflowMasterSaveResult.Conflict($"\"{existing.Value}\" is used by {Mappings(usage)} in the Super Master, so it cannot be deleted. Deactivate it instead — it stops being offered, and the existing mappings keep their value.");

        // Also what stops a list — and so the whole table — ever being emptied, which would make the
        // fresh-database seed in EnsureMasterDataSchemaAsync put the defaults back.
        if (existing.IsActive && rows.Count(x => x.IsActive) <= 1)
            return WorkflowMasterSaveResult.Conflict($"\"{existing.Value}\" is the last active value in {type.Label} and cannot be deleted. Add or activate another value first.");

        var delete = shape.HasCode
            ? "DELETE dbo.DenialMapperActionCategoryMaster WHERE ActionCategory=@Value"
            : "DELETE dbo.DenialMapperLookupMaster WHERE LookupType=@Type AND LookupValue=@Value";
        await using (var cmd = new SqlCommand(delete, c, tx))
        {
            cmd.Parameters.Add("@Type", SqlDbType.NVarChar, 50).Value = type.Key;
            cmd.Parameters.Add("@Value", SqlDbType.NVarChar, 255).Value = existing.Value;
            await cmd.ExecuteNonQueryAsync(ct);
        }

        await AuditAsync(c, tx, "MasterValueDeleted", type, "Value", Describe(type, existing.Value, existing.ActionCode), null, user, role, ct);
        await tx.CommitAsync(ct);
        return WorkflowMasterSaveResult.Ok($"\"{existing.Value}\" deleted from {type.Label}.");
    }

    // ── helpers ────────────────────────────────────────────────────────────────────────────────

    private static WorkflowMasterValue ReadValue(SqlDataReader r, int valueOrdinal, int? codeOrdinal) => new()
    {
        Value = r.GetString(valueOrdinal),
        ActionCode = codeOrdinal is { } co && !r.IsDBNull(co) ? r.GetString(co) : null,
        SortOrder = r.GetInt32(2),
        IsActive = r.GetBoolean(3),
        CreatedOn = r.IsDBNull(4) ? null : DateTime.SpecifyKind(r.GetDateTime(4), DateTimeKind.Utc),
        CreatedBy = r.IsDBNull(5) ? null : r.GetString(5),
        ModifiedOn = r.IsDBNull(6) ? null : DateTime.SpecifyKind(r.GetDateTime(6), DateTimeKind.Utc),
        ModifiedBy = r.IsDBNull(7) ? null : r.GetString(7)
    };

    /// <summary>
    /// Reads the list under an update lock held to the end of the transaction, so the duplicate and
    /// last-active checks cannot race a second admin saving the same list at the same moment.
    /// </summary>
    private static async Task<List<Row>> LockRowsAsync(SqlConnection c, SqlTransaction tx, Shape shape, WorkflowMasterType type, CancellationToken ct)
    {
        var code = shape.HasCode ? "ActionCode" : "CAST(NULL AS nvarchar(100))";
        var sql = $"SELECT {shape.ValueColumn},{code},SortOrder,IsActive FROM {shape.Table} WITH (UPDLOCK, HOLDLOCK) WHERE {shape.TypeFilter}";
        var rows = new List<Row>();
        await using var cmd = new SqlCommand(sql, c, tx);
        cmd.Parameters.Add("@Type", SqlDbType.NVarChar, 50).Value = type.Key;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new Row(r.GetString(0), r.IsDBNull(1) ? null : r.GetString(1), r.GetInt32(2), r.GetBoolean(3)));
        return rows;
    }

    private static Row? FindExact(List<Row> rows, string value) =>
        rows.FirstOrDefault(x => string.Equals(x.Value, value, StringComparison.Ordinal))
        ?? rows.FirstOrDefault(x => string.Equals(x.Value, value, StringComparison.OrdinalIgnoreCase));

    private static Row? FindNormalizedDuplicate(List<Row> rows, string value, Row? except)
    {
        var key = WorkflowMasterValueRules.Normalize(value);
        return rows.FirstOrDefault(x => !ReferenceEquals(x, except) && WorkflowMasterValueRules.Normalize(x.Value) == key);
    }

    private static string DuplicateMessage(WorkflowMasterType type, string value, Row duplicate) =>
        string.Equals(duplicate.Value, value, StringComparison.OrdinalIgnoreCase)
            ? $"\"{value}\" already exists in {type.Label}{(duplicate.IsActive ? "" : " (inactive — activate it instead)")}."
            : $"\"{value}\" is the same as existing {type.Label} value \"{duplicate.Value}\" once spacing, hyphens and slashes are ignored{(duplicate.IsActive ? "" : " (inactive — activate it instead)")}.";

    private static async Task<bool> SuperMasterExistsAsync(SqlConnection c, SqlTransaction? tx, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("SELECT CASE WHEN OBJECT_ID('dbo.DenialMapperSuperMaster','U') IS NULL THEN 0 ELSE 1 END", c, tx);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) == 1;
    }

    /// <summary>Every list's usage in one pass over the Super Master rather than one scan per value.</summary>
    private static async Task<Dictionary<(string Type, string Value), int>> ReadAllUsageAsync(SqlConnection c, CancellationToken ct)
    {
        // Keyed case-insensitively because the GROUP BY runs under the database collation.
        var usage = new Dictionary<(string, string), int>(new CaseInsensitivePairComparer());
        await using var cmd = new SqlCommand(AllUsageSql, c) { CommandTimeout = 120 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            var key = (r.GetString(0), r.GetString(1));
            usage[key] = usage.GetValueOrDefault(key) + r.GetInt32(2);
        }
        return usage;
    }

    internal const string AllUsageSql = """
            SELECT v.LookupType, LTRIM(RTRIM(v.Val)) AS Val, COUNT(*) AS Cnt
            FROM dbo.DenialMapperSuperMaster s
            CROSS APPLY (VALUES
                ('DenialClassification', s.DenialClassification),
                ('CoverageStatus',       s.CoverageStatus),
                ('ICDComplianceStatus',  s.ICDComplianceStatus),
                ('DenialValidity',       s.DenialValidity),
                ('ActionCategory',       s.ActionCategory),
                ('SLADays',              s.SLA),
                ('Priority',             s.Priority)) v(LookupType, Val)
            WHERE s.IsActive = 1 AND v.Val IS NOT NULL
            GROUP BY v.LookupType, LTRIM(RTRIM(v.Val))
            """;

    private static async Task<int> UsageAsync(SqlConnection c, SqlTransaction tx, WorkflowMasterType type, string value, CancellationToken ct)
    {
        if (!await SuperMasterExistsAsync(c, tx, ct)) return 0;
        // SuperMasterColumn comes from the fixed catalogue in WorkflowMasterValueRules, never from input.
        var sql = $"SELECT COUNT(*) FROM dbo.DenialMapperSuperMaster WHERE IsActive=1 AND LTRIM(RTRIM({type.SuperMasterColumn}))=@Value";
        await using var cmd = new SqlCommand(sql, c, tx) { CommandTimeout = 120 };
        cmd.Parameters.Add("@Value", SqlDbType.NVarChar, 255).Value = value.Trim();
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
    }

    /// <summary>
    /// Writes to dbo.DenialMapperAuditLog, which the Denial Mapper's Audit Log screen already lists,
    /// so master changes show up beside the mapping changes they affect. LabId stays NULL: these
    /// lists are central, and a NULL lab is what makes the rows visible in the admin (all-labs) view.
    /// </summary>
    private static async Task<int> AuditAsync(SqlConnection c, SqlTransaction tx, string eventType, WorkflowMasterType type, string field,
        string? from, string? to, string user, string role, CancellationToken ct, string? remarksValue = null)
    {
        const string sql = """
            IF OBJECT_ID('dbo.DenialMapperAuditLog','U') IS NOT NULL
            INSERT dbo.DenialMapperAuditLog(EventType,LabId,SuperMasterId,DenialCode,FieldName,FromValue,ToValue,PerformedBy,PerformedRole,Remarks)
            VALUES(@Event,NULL,NULL,NULL,@Field,@From,@To,@User,@Role,@Remarks)
            """;
        await using var cmd = new SqlCommand(sql, c, tx);
        cmd.Parameters.Add("@Event", SqlDbType.NVarChar, 100).Value = eventType;
        cmd.Parameters.Add("@Field", SqlDbType.NVarChar, 100).Value = Truncate($"{type.Label}: {field}", 100);
        cmd.Parameters.Add("@From", SqlDbType.NVarChar, -1).Value = (object?)from ?? DBNull.Value;
        cmd.Parameters.Add("@To", SqlDbType.NVarChar, -1).Value = (object?)to ?? DBNull.Value;
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 200).Value = Truncate(user, 200);
        cmd.Parameters.Add("@Role", SqlDbType.NVarChar, 100).Value = Truncate(role, 100);
        cmd.Parameters.Add("@Remarks", SqlDbType.NVarChar, 1000).Value = Truncate($"Workflow master: {type.Label}{(remarksValue is null ? "" : $" = {remarksValue}")}", 1000);
        await cmd.ExecuteNonQueryAsync(ct);
        return 1;
    }

    private static string Describe(WorkflowMasterType type, string value, string? actionCode) =>
        type.IsActionCategory && !string.IsNullOrWhiteSpace(actionCode) ? $"{value} ({actionCode})" : value;

    private static string Mappings(int count) => count == 1 ? "1 active mapping" : $"{count:N0} active mappings";

    private static string Truncate(string? value, int max)
    {
        var v = value ?? string.Empty;
        return v.Length <= max ? v : v[..max];
    }

    private sealed class CaseInsensitivePairComparer : IEqualityComparer<(string, string)>
    {
        public bool Equals((string, string) x, (string, string) y) =>
            StringComparer.OrdinalIgnoreCase.Equals(x.Item1, y.Item1) && StringComparer.OrdinalIgnoreCase.Equals(x.Item2, y.Item2);

        public int GetHashCode((string, string) obj) =>
            HashCode.Combine(StringComparer.OrdinalIgnoreCase.GetHashCode(obj.Item1), StringComparer.OrdinalIgnoreCase.GetHashCode(obj.Item2));
    }
}
