using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Master File Maintenance: the dbo.ARWB_MasterListItem lists and the dbo.ARWB_DenialCodeCategoryMap
/// code map, in the lab database. Same behaviour as the Denial Workflow's Workflow Master Values
/// (SqlWorkflowMasterValuesRepository) and Denial Code Master screens: each write reads the rows it
/// checks under an update lock held to commit, so duplicate / last-active / in-use checks cannot race
/// a second admin.
///
/// Claims are not reclassified here. dbo.ARWB_usp_LoadClaimsFromSource applies the map on the next
/// Data Processing run, or at once with @ReprocessAll = 1 (the screen's "Apply to claims").
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private const int MaxImportErrorsShown = 50;

    private sealed record ListRow(string Value, int SortOrder, bool IsActive);

    private sealed record CodeRow(string DenialCode, string DenialCategory, string? DenialReason, bool IsActive);

    // ==========================================================================================
    // Master lists
    // ==========================================================================================

    public async Task<ArWorkbenchMasterValuesResponse> GetMasterValuesAsync(int labId, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        var byType = ArWorkbenchMasterRules.Types.ToDictionary(t => t.Key, _ => new List<ArWorkbenchMasterValue>(), StringComparer.OrdinalIgnoreCase);

        await using (var cmd = new SqlCommand("SELECT ListType, ItemValue, SortOrder, IsActive, CreatedOn, CreatedBy, UpdatedOn, UpdatedBy FROM dbo.ARWB_MasterListItem;", connection))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                // A ListType this screen does not maintain (WORKFLOW_STATUS, AGING_BUCKET, ...) is system data; leave it alone.
                if (!byType.TryGetValue(r.GetString(0), out var list)) continue;
                list.Add(new ArWorkbenchMasterValue
                {
                    Value = r.GetString(1),
                    SortOrder = r.GetInt32(2),
                    IsActive = r.GetBoolean(3),
                    CreatedOn = Utc(r, 4),
                    CreatedBy = Str(r, 5),
                    UpdatedOn = Utc(r, 6),
                    UpdatedBy = Str(r, 7)
                });
            }
        }

        // Every list's usage in one pass rather than one scan per value. Keyed case-insensitively
        // because the GROUP BY runs under the database collation.
        var usage = new Dictionary<(string, string), int>(CaseInsensitivePair.Instance);
        await using (var cmd = new SqlCommand(AllUsageSql, connection) { CommandTimeout = 120 })
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                var key = (r.GetString(0), r.GetString(1));
                usage[key] = usage.GetValueOrDefault(key) + r.GetInt32(2);
            }
        }

        return new ArWorkbenchMasterValuesResponse
        {
            Lists = ArWorkbenchMasterRules.Types.Select(t => new ArWorkbenchMasterList
            {
                Type = t.Key,
                Label = t.Label,
                Description = t.Description,
                MaxLength = t.MaxLength,
                IsCodeList = t.IsCodeList,
                FormatHint = t.FormatHint,
                UsageLabel = t.UsageLabel,
                ReservedValues = t.ReservedValues.ToList(),
                Values = byType[t.Key]
                    .Select(v => { v.UsageCount = usage.GetValueOrDefault((t.Key, v.Value.Trim())); return v; })
                    .OrderBy(v => v.SortOrder)
                    .ThenBy(v => v.Value, StringComparer.OrdinalIgnoreCase)
                    .ToList()
            }).ToList()
        };
    }

    public async Task<ArWorkbenchSaveResult> AddMasterValueAsync(int labId, ArWorkbenchMasterType type, ArWorkbenchMasterValidated value, string user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);

        var rows = await LockListAsync(connection, tx, type.Key, ct);
        var duplicate = FindDuplicate(type, rows, value.Value, except: null);
        if (duplicate is not null) return ArWorkbenchSaveResult.Conflict(DuplicateMessage(type, value.Value, duplicate));

        var sortOrder = value.SortOrder ?? (rows.Count == 0 ? 10 : rows.Max(x => x.SortOrder) + 10);
        await using (var cmd = new SqlCommand(@"
INSERT INTO dbo.ARWB_MasterListItem (ListType, ItemValue, SortOrder, IsActive, CreatedBy, UpdatedOn, UpdatedBy)
VALUES (@Type, @Value, @Sort, @Active, @User, SYSUTCDATETIME(), @User);", connection, tx))
        {
            cmd.Parameters.Add("@Type", SqlDbType.VarChar, 50).Value = type.Key;
            cmd.Parameters.Add("@Value", SqlDbType.NVarChar, 400).Value = value.Value;
            cmd.Parameters.Add("@Sort", SqlDbType.Int).Value = sortOrder;
            cmd.Parameters.Add("@Active", SqlDbType.Bit).Value = value.IsActive;
            cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user, 256);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
        return ArWorkbenchSaveResult.Ok($"\"{value.Value}\" added to {type.Label}.{AppliesOnSync(type)}");
    }

    public async Task<ArWorkbenchSaveResult> UpdateMasterValueAsync(int labId, ArWorkbenchMasterType type, string originalValue, ArWorkbenchMasterValidated value, string user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);

        var rows = await LockListAsync(connection, tx, type.Key, ct);
        var original = FindExact(rows, originalValue);
        if (original is null)
            return ArWorkbenchSaveResult.NotFound($"\"{originalValue}\" no longer exists in {type.Label} — someone may have changed it. Reload the page and try again.");

        var renamed = !string.Equals(original.Value, value.Value, StringComparison.Ordinal);
        var deactivating = original.IsActive && !value.IsActive;

        // The workbench's own rules compare against these values by text.
        if (ArWorkbenchMasterRules.IsReserved(type, original.Value) && (renamed || deactivating))
            return ArWorkbenchSaveResult.Conflict($"\"{original.Value}\" is used by the AR Workbench's own rules, so it cannot be {(renamed ? "renamed" : "deactivated")}.");

        var usage = await UsageAsync(connection, tx, type, original.Value, ct);
        if (renamed)
        {
            var duplicate = FindDuplicate(type, rows, value.Value, except: original);
            if (duplicate is not null) return ArWorkbenchSaveResult.Conflict(DuplicateMessage(type, value.Value, duplicate));

            // Claims, notes and requests store the text itself, not a key. Renaming a value they use
            // would leave every one of them holding a value that is no longer in the list.
            if (usage > 0)
                return ArWorkbenchSaveResult.Conflict(
                    $"\"{original.Value}\" is used by {Records(usage)} ({type.UsageLabel}), so it cannot be renamed. " +
                    $"Add \"{value.Value}\" as a new value, then deactivate \"{original.Value}\".");
        }

        if (deactivating && rows.Count(x => x.IsActive) <= 1)
            return ArWorkbenchSaveResult.Conflict($"{type.Label} must keep at least one active value. Add or activate another value first.");

        var sortOrder = value.SortOrder ?? original.SortOrder;
        if (!renamed && sortOrder == original.SortOrder && value.IsActive == original.IsActive)
            return ArWorkbenchSaveResult.Ok($"No changes to \"{value.Value}\".");

        await using (var cmd = new SqlCommand(@"
UPDATE dbo.ARWB_MasterListItem
SET ItemValue = @Value, SortOrder = @Sort, IsActive = @Active, UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @User
WHERE ListType = @Type AND ItemValue = @Original;", connection, tx))
        {
            cmd.Parameters.Add("@Type", SqlDbType.VarChar, 50).Value = type.Key;
            cmd.Parameters.Add("@Original", SqlDbType.NVarChar, 400).Value = original.Value;
            cmd.Parameters.Add("@Value", SqlDbType.NVarChar, 400).Value = value.Value;
            cmd.Parameters.Add("@Sort", SqlDbType.Int).Value = sortOrder;
            cmd.Parameters.Add("@Active", SqlDbType.Bit).Value = value.IsActive;
            cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user, 256);
            if (await cmd.ExecuteNonQueryAsync(ct) == 0)
                return ArWorkbenchSaveResult.NotFound($"\"{originalValue}\" no longer exists in {type.Label}. Reload the page and try again.");
        }

        await tx.CommitAsync(ct);

        var message = original.IsActive != value.IsActive && !renamed && sortOrder == original.SortOrder
            ? $"\"{value.Value}\" {(value.IsActive ? "activated" : "deactivated")} in {type.Label}."
            : $"\"{value.Value}\" updated in {type.Label}.";
        if (deactivating && usage > 0)
            message += $" The {Records(usage)} already using it are unchanged; it is just no longer offered.";
        return ArWorkbenchSaveResult.Ok(message + AppliesOnSync(type));
    }

    public async Task<ArWorkbenchSaveResult> DeleteMasterValueAsync(int labId, ArWorkbenchMasterType type, string value, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);

        var rows = await LockListAsync(connection, tx, type.Key, ct);
        var existing = FindExact(rows, value);
        if (existing is null)
            return ArWorkbenchSaveResult.NotFound($"\"{value}\" no longer exists in {type.Label}. Reload the page and try again.");
        if (ArWorkbenchMasterRules.IsReserved(type, existing.Value))
            return ArWorkbenchSaveResult.Conflict($"\"{existing.Value}\" is used by the AR Workbench's own rules, so it cannot be deleted.");

        var usage = await UsageAsync(connection, tx, type, existing.Value, ct);
        if (usage > 0)
            return ArWorkbenchSaveResult.Conflict($"\"{existing.Value}\" is used by {Records(usage)} ({type.UsageLabel}), so it cannot be deleted. Deactivate it instead — it stops being offered, and the records keep their value.");
        if (existing.IsActive && rows.Count(x => x.IsActive) <= 1)
            return ArWorkbenchSaveResult.Conflict($"\"{existing.Value}\" is the last active value in {type.Label} and cannot be deleted. Add or activate another value first.");

        await using (var cmd = new SqlCommand("DELETE dbo.ARWB_MasterListItem WHERE ListType = @Type AND ItemValue = @Value;", connection, tx))
        {
            cmd.Parameters.Add("@Type", SqlDbType.VarChar, 50).Value = type.Key;
            cmd.Parameters.Add("@Value", SqlDbType.NVarChar, 400).Value = existing.Value;
            await cmd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
        return ArWorkbenchSaveResult.Ok($"\"{existing.Value}\" deleted from {type.Label}.{AppliesOnSync(type)}");
    }

    /// <summary>The list under an update lock held to the end of the transaction.</summary>
    private static async Task<List<ListRow>> LockListAsync(SqlConnection connection, SqlTransaction tx, string listType, CancellationToken ct)
    {
        var rows = new List<ListRow>();
        await using var cmd = new SqlCommand("SELECT ItemValue, SortOrder, IsActive FROM dbo.ARWB_MasterListItem WITH (UPDLOCK, HOLDLOCK) WHERE ListType = @Type;", connection, tx);
        cmd.Parameters.Add("@Type", SqlDbType.VarChar, 50).Value = listType;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) rows.Add(new ListRow(r.GetString(0), r.GetInt32(1), r.GetBoolean(2)));
        return rows;
    }

    private static ListRow? FindExact(List<ListRow> rows, string value) =>
        rows.FirstOrDefault(x => string.Equals(x.Value, value, StringComparison.Ordinal))
        ?? rows.FirstOrDefault(x => string.Equals(x.Value, value?.Trim(), StringComparison.OrdinalIgnoreCase));

    private static ListRow? FindDuplicate(ArWorkbenchMasterType type, List<ListRow> rows, string value, ListRow? except)
    {
        var key = ArWorkbenchMasterRules.Normalize(type, value);
        return rows.FirstOrDefault(x => !ReferenceEquals(x, except) && ArWorkbenchMasterRules.Normalize(type, x.Value) == key);
    }

    private static string DuplicateMessage(ArWorkbenchMasterType type, string value, ListRow duplicate)
    {
        var inactive = duplicate.IsActive ? "" : " (inactive — activate it instead)";
        if (string.Equals(duplicate.Value, value, StringComparison.OrdinalIgnoreCase))
            return $"\"{value}\" already exists in {type.Label}{inactive}.";
        return type.IsCodeList
            ? $"\"{value}\" is the same denial code as existing value \"{duplicate.Value}\" once the CO / PR / PI / OA prefix is removed{inactive}."
            : $"\"{value}\" is the same as existing value \"{duplicate.Value}\" once spacing, hyphens and slashes are ignored{inactive}.";
    }

    private static readonly string AllUsageSql = string.Join("\nUNION ALL\n",
        ArWorkbenchMasterRules.Types.SelectMany(t => t.Usage.Select(u =>
            $"SELECT CONVERT(varchar(50), '{t.Key}') AS ListType, LTRIM(RTRIM({u.Column})) AS Val, COUNT(*) AS Cnt " +
            $"FROM {u.Table} WHERE {u.Column} IS NOT NULL{(u.Filter is null ? "" : $" AND {u.Filter}")} GROUP BY LTRIM(RTRIM({u.Column}))"))) + ";";

    private static async Task<int> UsageAsync(SqlConnection connection, SqlTransaction tx, ArWorkbenchMasterType type, string value, CancellationToken ct)
    {
        if (type.Usage.Count == 0) return 0;
        // Tables and columns come from the fixed catalogue in ArWorkbenchMasterRules, never from input.
        var sql = "SELECT " + string.Join(" + ", type.Usage.Select(u =>
            $"(SELECT COUNT(*) FROM {u.Table} WHERE {u.Column} = @Value{(u.Filter is null ? "" : $" AND {u.Filter}")})")) + ";";
        await using var cmd = new SqlCommand(sql, connection, tx) { CommandTimeout = 120 };
        cmd.Parameters.Add("@Value", SqlDbType.NVarChar, 400).Value = value.Trim();
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
    }

    private static string AppliesOnSync(ArWorkbenchMasterType type) =>
        type.IsCodeList ? " Claims pick this up on the next Data Processing run (or Apply to claims on the Denial Code Master page)." : "";

    private static string Records(int count) => count == 1 ? "1 record" : $"{count:N0} records";

    // ==========================================================================================
    // Denial Code Master (dbo.ARWB_DenialCodeCategoryMap)
    // ==========================================================================================

    private static readonly Dictionary<string, string[]> DenialCodeSort = new(StringComparer.OrdinalIgnoreCase)
    {
        // Numeric CARC codes in number order, then RARC / other codes alphabetically.
        ["denialCode"] = ["CASE WHEN m.DenialCode NOT LIKE N'%[^0-9]%' THEN 0 ELSE 1 END", "TRY_CONVERT(bigint, CASE WHEN m.DenialCode NOT LIKE N'%[^0-9]%' THEN m.DenialCode END)", "m.DenialCode"],
        ["denialCategory"] = ["m.DenialCategory"],
        ["denialReason"] = ["m.DenialReason"],
        ["isActive"] = ["m.IsActive"],
        ["claimCount"] = ["ISNULL(cnt.Claims, 0)"],
        ["updatedOn"] = ["COALESCE(m.UpdatedOn, m.CreatedOn)"]
    };

    // The lab's Denial Workflow dbo.DenialCodeMaster descriptions keyed by normalized code - read
    // exactly as dbo.ARWB_usp_LoadClaimsFromSource reads them (its #dcm), which prefers them over
    // the map's own DenialReason.
    private const string WorkflowDescriptionsSql = @"
CREATE TABLE #dcm (DenialCode nvarchar(50) NOT NULL PRIMARY KEY, DenialDescription nvarchar(1000) NULL);
IF OBJECT_ID(N'dbo.DenialCodeMaster', N'U') IS NOT NULL
   AND COL_LENGTH(N'dbo.DenialCodeMaster', N'DenialCode') IS NOT NULL
   AND COL_LENGTH(N'dbo.DenialCodeMaster', N'DenialDescription') IS NOT NULL
    EXEC sys.sp_executesql N'
INSERT INTO #dcm (DenialCode, DenialDescription)
SELECT n.DenialCode, MAX(LEFT(dm.DenialDescription, 1000))
FROM dbo.DenialCodeMaster dm
CROSS APPLY dbo.ARWB_tvf_NormalizeDenialCode(CONVERT(nvarchar(200), dm.DenialCode)) n
WHERE dm.DenialDescription IS NOT NULL AND n.DenialCode IS NOT NULL
GROUP BY n.DenialCode;';";

    private const string DenialCodeSelect = @"
SELECT m.DenialCode, m.DenialCategory, m.DenialReason, dcm.DenialDescription, m.IsActive, ISNULL(cnt.Claims, 0) AS Claims,
       m.CreatedOn, m.CreatedBy, m.UpdatedOn, m.UpdatedBy
FROM dbo.ARWB_DenialCodeCategoryMap m
LEFT JOIN #dcm dcm ON dcm.DenialCode = m.DenialCode
LEFT JOIN (SELECT PrimaryDenialCode AS DenialCode, COUNT(*) AS Claims
           FROM dbo.ARWB_Claim WHERE PrimaryDenialCode IS NOT NULL GROUP BY PrimaryDenialCode) cnt ON cnt.DenialCode = m.DenialCode";

    public async Task<ArWorkbenchPagedResult<ArWorkbenchDenialCodeRow>> GetDenialCodesAsync(ArWorkbenchDenialCodeQuery query, CancellationToken ct)
    {
        var page = Math.Max(1, query.Page);
        var pageSize = Math.Clamp(query.PageSize, 1, MaxPageSize);

        await using var connection = await OpenLabAsync(query.LabId, ct);
        await using var cmd = connection.CreateCommand();

        var where = new List<string>();
        if (!string.IsNullOrWhiteSpace(query.Search))
        {
            // "CO-197" finds 197: the search is also tried as a normalized code.
            where.Add(@"(m.DenialCode LIKE @Search ESCAPE '\' OR m.DenialCategory LIKE @Search ESCAPE '\' OR m.DenialReason LIKE @Search ESCAPE '\'
       OR dcm.DenialDescription LIKE @Search ESCAPE '\' OR m.DenialCode = @SearchCode)");
            cmd.Parameters.Add("@Search", SqlDbType.NVarChar, 410).Value = $"%{EscapeLike(query.Search.Trim())}%";
            cmd.Parameters.Add("@SearchCode", SqlDbType.NVarChar, 200).Value = (object?)ArWorkbenchMasterRules.NormalizeDenialCode(query.Search) ?? DBNull.Value;
        }
        if (string.Equals(query.Status, "active", StringComparison.OrdinalIgnoreCase)) where.Add("m.IsActive = 1");
        else if (string.Equals(query.Status, "inactive", StringComparison.OrdinalIgnoreCase)) where.Add("m.IsActive = 0");
        if (!string.IsNullOrWhiteSpace(query.Category))
        {
            where.Add("m.DenialCategory = @Category");
            cmd.Parameters.Add("@Category", SqlDbType.NVarChar, 200).Value = query.Category.Trim();
        }

        var whereSql = where.Count == 0 ? "" : " WHERE " + string.Join(" AND ", where);
        var dir = query.SortDesc ? " DESC" : " ASC";
        var sort = DenialCodeSort.TryGetValue(query.SortBy ?? "", out var exprs) ? exprs : DenialCodeSort["denialCode"];
        // m.DenialCode breaks ties for a stable page order; SQL Server rejects it twice in one ORDER BY.
        var orderBy = string.Join(", ", sort.Select(e => e + dir)) + (sort.Contains("m.DenialCode") ? "" : ", m.DenialCode");

        cmd.Parameters.Add("@Offset", SqlDbType.Int).Value = (page - 1) * pageSize;
        cmd.Parameters.Add("@PageSize", SqlDbType.Int).Value = pageSize;
        cmd.CommandText = $@"{WorkflowDescriptionsSql}

SELECT COUNT(*) FROM dbo.ARWB_DenialCodeCategoryMap m LEFT JOIN #dcm dcm ON dcm.DenialCode = m.DenialCode{whereSql};

{DenialCodeSelect}{whereSql}
ORDER BY {orderBy}
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;";

        var result = new ArWorkbenchPagedResult<ArWorkbenchDenialCodeRow> { Page = page, PageSize = pageSize };
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (await reader.ReadAsync(ct)) result.TotalCount = reader.GetInt32(0);
        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct)) result.Items.Add(ReadDenialCodeRow(reader));
        return result;
    }

    public async Task<IReadOnlyList<ArWorkbenchDenialCodeRow>> GetAllDenialCodesAsync(int labId, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand($"{WorkflowDescriptionsSql}\n{DenialCodeSelect}\nORDER BY {string.Join(", ", DenialCodeSort["denialCode"])};", connection) { CommandTimeout = 120 };
        var rows = new List<ArWorkbenchDenialCodeRow>();
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) rows.Add(ReadDenialCodeRow(reader));
        return rows;
    }

    private static ArWorkbenchDenialCodeRow ReadDenialCodeRow(SqlDataReader r) => new()
    {
        DenialCode = r.GetString(0),
        DenialCategory = r.GetString(1),
        DenialReason = Str(r, 2),
        WorkflowDescription = Str(r, 3),
        IsActive = r.GetBoolean(4),
        ClaimCount = r.GetInt32(5),
        CreatedOn = Utc(r, 6),
        CreatedBy = Str(r, 7),
        UpdatedOn = Utc(r, 8),
        UpdatedBy = Str(r, 9)
    };

    /// <summary>Primary denial codes on synced claims with no active mapping - they fall into 'Other'. Most claims first.</summary>
    public async Task<IReadOnlyList<ArWorkbenchUnmappedDenialCode>> GetUnmappedDenialCodesAsync(int labId, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(@"
SELECT TOP (500) c.PrimaryDenialCode, MAX(c.PrimaryDenialCodeRaw), MAX(c.DenialReason), COUNT(*), ISNULL(SUM(c.RemainingAR), 0),
       MAX(CASE WHEN m.DenialCode IS NULL THEN 0 ELSE 1 END)
FROM dbo.ARWB_Claim c
LEFT JOIN dbo.ARWB_DenialCodeCategoryMap m ON m.DenialCode = c.PrimaryDenialCode
WHERE c.PrimaryDenialCode IS NOT NULL AND (m.DenialCode IS NULL OR m.IsActive = 0)
GROUP BY c.PrimaryDenialCode
ORDER BY COUNT(*) DESC, c.PrimaryDenialCode;", connection) { CommandTimeout = 120 };

        var rows = new List<ArWorkbenchUnmappedDenialCode>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new ArWorkbenchUnmappedDenialCode
            {
                DenialCode = r.GetString(0),
                SampleRawCode = Str(r, 1),
                DenialReason = Str(r, 2),
                ClaimCount = r.GetInt32(3),
                RemainingAR = r.GetDecimal(4),
                HasInactiveMapping = r.GetInt32(5) == 1
            });
        }
        return rows;
    }

    /// <summary>What a change to one code's mapping reaches when claims are next reclassified.</summary>
    public async Task<ArWorkbenchDenialCodeImpact> GetDenialCodeImpactAsync(int labId, string denialCode, CancellationToken ct)
    {
        var code = ArWorkbenchMasterRules.NormalizeDenialCode(denialCode) ?? denialCode.Trim();
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(@"
SELECT DenialCategory FROM dbo.ARWB_DenialCodeCategoryMap WHERE DenialCode = @Code;

SELECT COUNT(*),
       ISNULL(SUM(CASE WHEN c.AssignedAgentUser IS NOT NULL THEN 1 ELSE 0 END), 0),
       ISNULL(SUM(CASE WHEN c.IsDenialCategoryManual = 1 THEN 1 ELSE 0 END), 0)
FROM dbo.ARWB_Claim c WHERE c.PrimaryDenialCode = @Code;

SELECT COUNT(*) FROM dbo.ARWB_ClaimLineDenial WHERE DenialCode = @Code;

SELECT ISNULL(q.QueueLabel, N'(No queue)'), COUNT(*), ISNULL(SUM(CASE WHEN c.AssignedAgentUser IS NOT NULL THEN 1 ELSE 0 END), 0)
FROM dbo.ARWB_Claim c
LEFT JOIN dbo.ARWB_ArQueue q ON q.QueueId = c.ArQueueId
WHERE c.PrimaryDenialCode = @Code
GROUP BY q.QueueLabel, q.SortOrder
ORDER BY q.SortOrder;", connection) { CommandTimeout = 120 };
        cmd.Parameters.Add("@Code", SqlDbType.NVarChar, 50).Value = code;

        var impact = new ArWorkbenchDenialCodeImpact { DenialCode = code };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (await r.ReadAsync(ct)) impact.CurrentCategory = r.GetString(0);
        await r.NextResultAsync(ct);
        if (await r.ReadAsync(ct))
        {
            impact.AffectedClaims = r.GetInt32(0);
            impact.AssignedClaims = r.GetInt32(1);
            impact.ManualCategoryClaims = r.GetInt32(2);
        }
        await r.NextResultAsync(ct);
        if (await r.ReadAsync(ct)) impact.AffectedLines = r.GetInt32(0);
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct))
            impact.Queues.Add(new ArWorkbenchDenialCodeImpactQueue { QueueLabel = r.GetString(0), ClaimCount = r.GetInt32(1), AssignedCount = r.GetInt32(2) });
        return impact;
    }

    public async Task<ArWorkbenchSaveResult> SaveDenialCodeAsync(int labId, string? originalDenialCode, ArWorkbenchDenialCodeValidated value, string user, CancellationToken ct)
    {
        var isAdd = string.IsNullOrWhiteSpace(originalDenialCode);
        var original = isAdd ? null : ArWorkbenchMasterRules.NormalizeDenialCode(originalDenialCode) ?? originalDenialCode!.Trim();

        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);

        var categories = await LockListAsync(connection, tx, ArWorkbenchMasterRules.DenialCategoryType, ct);
        var rows = await LockCodeRowsAsync(connection, tx, original is null ? new[] { value.DenialCode } : new[] { original, value.DenialCode }, ct);

        var existing = original is null ? null : rows.FirstOrDefault(r => SameCode(r.DenialCode, original));
        if (!isAdd && existing is null)
            return ArWorkbenchSaveResult.NotFound($"Denial code {original} no longer exists — someone may have changed it. Reload the page and try again.");

        var category = ResolveCategory(categories, value.DenialCategory, existing?.DenialCategory, out var categoryError);
        if (category is null) return ArWorkbenchSaveResult.Invalid(categoryError!);

        var clash = rows.FirstOrDefault(r => SameCode(r.DenialCode, value.DenialCode) && !ReferenceEquals(r, existing));
        if (clash is not null)
            return ArWorkbenchSaveResult.Conflict(
                $"Denial code {clash.DenialCode} is already mapped to \"{clash.DenialCategory}\"{(clash.IsActive ? "" : " (inactive — edit that row instead)")}.");

        if (existing is not null
            && string.Equals(existing.DenialCode, value.DenialCode, StringComparison.Ordinal)
            && string.Equals(existing.DenialCategory, category, StringComparison.Ordinal)
            && string.Equals(existing.DenialReason, value.DenialReason, StringComparison.Ordinal)
            && existing.IsActive == value.IsActive)
            return ArWorkbenchSaveResult.Ok($"No changes to denial code {value.DenialCode}.");

        await using (var cmd = new SqlCommand(isAdd
            ? @"INSERT INTO dbo.ARWB_DenialCodeCategoryMap (DenialCode, DenialCategory, DenialReason, IsActive, CreatedBy, UpdatedOn, UpdatedBy)
                VALUES (@Code, @Category, @Reason, @Active, @User, SYSUTCDATETIME(), @User);"
            : @"UPDATE dbo.ARWB_DenialCodeCategoryMap
                SET DenialCode = @Code, DenialCategory = @Category, DenialReason = @Reason, IsActive = @Active, UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @User
                WHERE DenialCode = @Original;", connection, tx))
        {
            cmd.Parameters.Add("@Original", SqlDbType.NVarChar, 50).Value = (object?)existing?.DenialCode ?? DBNull.Value;
            cmd.Parameters.Add("@Code", SqlDbType.NVarChar, 50).Value = value.DenialCode;
            cmd.Parameters.Add("@Category", SqlDbType.NVarChar, 200).Value = category;
            cmd.Parameters.Add("@Reason", SqlDbType.NVarChar, 1000).Value = (object?)value.DenialReason ?? DBNull.Value;
            cmd.Parameters.Add("@Active", SqlDbType.Bit).Value = value.IsActive;
            cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user, 256);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
        return ArWorkbenchSaveResult.Ok($"Denial code {value.DenialCode} {(isAdd ? "added" : "saved")}. {ReclassifyNote}");
    }

    public async Task<ArWorkbenchSaveResult> DeleteDenialCodeAsync(int labId, string denialCode, CancellationToken ct)
    {
        var code = ArWorkbenchMasterRules.NormalizeDenialCode(denialCode) ?? denialCode.Trim();
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand("DELETE dbo.ARWB_DenialCodeCategoryMap WHERE DenialCode = @Code;", connection);
        cmd.Parameters.Add("@Code", SqlDbType.NVarChar, 50).Value = code;
        return await cmd.ExecuteNonQueryAsync(ct) == 0
            ? ArWorkbenchSaveResult.NotFound($"Denial code {code} no longer exists. Reload the page and try again.")
            : ArWorkbenchSaveResult.Ok($"Denial code {code} deleted. Its claims fall into '{ArWorkbenchMasterRules.FallbackDenialCategory}' when they are next reclassified.");
    }

    /// <summary>
    /// Upserts the workbook's rows: new codes are inserted, existing codes updated, codes not in the
    /// file left alone. As in the Denial Workflow import, any invalid row fails the whole file and
    /// nothing is written; rows repeating a code are merged, the last one in the file winning.
    /// </summary>
    public async Task<ArWorkbenchDenialCodeImportResult> ImportDenialCodesAsync(int labId, IReadOnlyList<ArWorkbenchDenialCodeImportRow> rows, int skippedCount, string user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);

        var categories = await LockListAsync(connection, tx, ArWorkbenchMasterRules.DenialCategoryType, ct);
        var existing = (await LockCodeRowsAsync(connection, tx, null, ct)).ToDictionary(r => r.DenialCode, StringComparer.OrdinalIgnoreCase);

        var errors = new List<string>();
        var byCode = new Dictionary<string, CodeRow>(StringComparer.OrdinalIgnoreCase);
        var valid = 0;
        foreach (var row in rows)
        {
            var active = ArWorkbenchMasterRules.ParseActive(row.Active);
            if (active is null)
            {
                errors.Add($"Row {row.RowNumber}: Active must be Yes or No (found \"{row.Active}\").");
                continue;
            }

            var validation = ArWorkbenchMasterRules.ValidateDenialCode(new ArWorkbenchDenialCodeSaveRequest
            {
                DenialCode = row.DenialCode, DenialCategory = row.DenialCategory, DenialReason = row.DenialReason, IsActive = active.Value
            });
            if (validation.Error is not null)
            {
                errors.Add($"Row {row.RowNumber}: {validation.Error}");
                continue;
            }

            var v = validation.Result!;
            var category = ResolveCategory(categories, v.DenialCategory, existing.GetValueOrDefault(v.DenialCode)?.DenialCategory, out var categoryError);
            if (category is null)
            {
                errors.Add($"Row {row.RowNumber} ({v.DenialCode}): {categoryError}");
                continue;
            }

            valid++;
            byCode[v.DenialCode] = new CodeRow(v.DenialCode, category, v.DenialReason, v.IsActive);
        }

        if (errors.Count > 0)
        {
            var shown = errors.Take(MaxImportErrorsShown).ToList();
            if (errors.Count > shown.Count) shown.Add($"…and {errors.Count - shown.Count:N0} more.");
            return new ArWorkbenchDenialCodeImportResult { SkippedCount = skippedCount, FailedCount = errors.Count, Errors = shown };
        }

        var result = new ArWorkbenchDenialCodeImportResult { SkippedCount = skippedCount, MergedDuplicateCount = valid - byCode.Count };
        var changes = new DataTable();
        changes.Columns.Add("DenialCode", typeof(string));
        changes.Columns.Add("DenialCategory", typeof(string));
        changes.Columns.Add("DenialReason", typeof(string));
        changes.Columns.Add("IsActive", typeof(bool));
        changes.Columns.Add("IsNew", typeof(bool));

        foreach (var row in byCode.Values)
        {
            if (!existing.TryGetValue(row.DenialCode, out var current))
                result.InsertedCount++;
            else if (string.Equals(current.DenialCategory, row.DenialCategory, StringComparison.Ordinal)
                     && string.Equals(current.DenialReason, row.DenialReason, StringComparison.Ordinal)
                     && current.IsActive == row.IsActive)
            {
                result.UnchangedCount++;
                continue;
            }
            else
                result.UpdatedCount++;

            changes.Rows.Add(row.DenialCode, row.DenialCategory, (object?)row.DenialReason ?? DBNull.Value, row.IsActive, current is null);
        }

        if (changes.Rows.Count > 0)
        {
            await using (var create = new SqlCommand(@"
CREATE TABLE #import (DenialCode nvarchar(50) NOT NULL PRIMARY KEY, DenialCategory nvarchar(200) NOT NULL,
                      DenialReason nvarchar(1000) NULL, IsActive bit NOT NULL, IsNew bit NOT NULL);", connection, tx))
                await create.ExecuteNonQueryAsync(ct);

            using (var bulk = new SqlBulkCopy(connection, SqlBulkCopyOptions.Default, tx) { DestinationTableName = "#import", BulkCopyTimeout = 300 })
            {
                foreach (DataColumn column in changes.Columns) bulk.ColumnMappings.Add(column.ColumnName, column.ColumnName);
                await bulk.WriteToServerAsync(changes, ct);
            }

            await using var apply = new SqlCommand(@"
UPDATE m
SET m.DenialCategory = i.DenialCategory, m.DenialReason = i.DenialReason, m.IsActive = i.IsActive,
    m.UpdatedOn = SYSUTCDATETIME(), m.UpdatedBy = @User
FROM dbo.ARWB_DenialCodeCategoryMap m
INNER JOIN #import i ON i.DenialCode = m.DenialCode
WHERE i.IsNew = 0;

INSERT INTO dbo.ARWB_DenialCodeCategoryMap (DenialCode, DenialCategory, DenialReason, IsActive, CreatedBy, UpdatedOn, UpdatedBy)
SELECT i.DenialCode, i.DenialCategory, i.DenialReason, i.IsActive, @User, SYSUTCDATETIME(), @User
FROM #import i
WHERE i.IsNew = 1;

DROP TABLE #import;", connection, tx) { CommandTimeout = 300 };
            apply.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = Truncate(user, 256);
            await apply.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
        return result;
    }

    private const string ReclassifyNote = "Claims are reclassified on the next Data Processing run, or use Apply to claims.";

    /// <summary>Code-map rows under an update lock: the given codes, or every row when codes is null.</summary>
    private static async Task<List<CodeRow>> LockCodeRowsAsync(SqlConnection connection, SqlTransaction tx, IReadOnlyList<string>? codes, CancellationToken ct)
    {
        await using var cmd = new SqlCommand { Connection = connection, Transaction = tx };
        var filter = "";
        if (codes is not null)
        {
            var names = new List<string>();
            for (var i = 0; i < codes.Count; i++)
            {
                names.Add($"@C{i}");
                cmd.Parameters.Add($"@C{i}", SqlDbType.NVarChar, 50).Value = codes[i];
            }
            filter = $" WHERE DenialCode IN ({string.Join(", ", names)})";
        }
        cmd.CommandText = $"SELECT DenialCode, DenialCategory, DenialReason, IsActive FROM dbo.ARWB_DenialCodeCategoryMap WITH (UPDLOCK, HOLDLOCK){filter};";

        var rows = new List<CodeRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) rows.Add(new CodeRow(r.GetString(0), r.GetString(1), Str(r, 2), r.GetBoolean(3)));
        return rows;
    }

    /// <summary>
    /// The category as stored on the Denial Categories list (its own casing), or null with the reason.
    /// An inactive category is accepted only where the code already has it - deactivating a category
    /// stops it being offered, it does not force existing mappings off it.
    /// </summary>
    private static string? ResolveCategory(List<ListRow> categories, string requested, string? currentCategory, out string? error)
    {
        var match = categories.FirstOrDefault(c => string.Equals(c.Value, requested, StringComparison.OrdinalIgnoreCase));
        error = null;
        if (match is null)
        {
            error = $"\"{requested}\" is not on the Denial Categories list. Add it in Master Values first.";
            return null;
        }
        if (!match.IsActive && !string.Equals(currentCategory, match.Value, StringComparison.OrdinalIgnoreCase))
        {
            error = $"\"{match.Value}\" is an inactive Denial Category. Activate it in Master Values, or choose another category.";
            return null;
        }
        return match.Value;
    }

    private static bool SameCode(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    private static DateTime? Utc(SqlDataReader r, int i) => r.IsDBNull(i) ? null : DateTime.SpecifyKind(r.GetDateTime(i), DateTimeKind.Utc);

    private static string EscapeLike(string value) =>
        value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("%", "\\%", StringComparison.Ordinal)
             .Replace("_", "\\_", StringComparison.Ordinal).Replace("[", "\\[", StringComparison.Ordinal);

    private static string Truncate(string? value, int max)
    {
        var v = value ?? string.Empty;
        return v.Length <= max ? v : v[..max];
    }

    private sealed class CaseInsensitivePair : IEqualityComparer<(string, string)>
    {
        public static readonly CaseInsensitivePair Instance = new();

        public bool Equals((string, string) x, (string, string) y) =>
            StringComparer.OrdinalIgnoreCase.Equals(x.Item1, y.Item1) && StringComparer.OrdinalIgnoreCase.Equals(x.Item2, y.Item2);

        public int GetHashCode((string, string) obj) =>
            HashCode.Combine(StringComparer.OrdinalIgnoreCase.GetHashCode(obj.Item1), StringComparer.OrdinalIgnoreCase.GetHashCode(obj.Item2));
    }
}
