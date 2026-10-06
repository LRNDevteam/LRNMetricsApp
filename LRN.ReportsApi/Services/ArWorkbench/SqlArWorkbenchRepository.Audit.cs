using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// T067 Audit Logs (mockup App.views.audit): the cross-claim view of dbo.ARWB_ClaimActivity - the
/// activity spine every workflow change writes to (assignment, follow-up, QA, CIP, adjustments,
/// bulk updates, sync). Read-only, within the caller's claim scope.
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    private static readonly Dictionary<string, string> AuditSortColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        ["activityOn"] = "a.ActivityOn", ["claimId"] = "w.ClaimID", ["userName"] = "a.UserName", ["actionType"] = "a.ActionType", ["labName"] = "w.LabName"
    };

    public async Task<ArWorkbenchAuditPage> GetAuditLogAsync(ArWorkbenchAuditFilter filter, ArWorkbenchUserContext user, bool withOptions, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(filter.LabId, ct);
        await using var cmd = connection.CreateCommand();
        cmd.CommandTimeout = 180;
        var scope = AppendScope(cmd, user);
        var where = BuildAuditWhere(cmd, filter);
        var page = Math.Max(1, filter.Page);
        var pageSize = Math.Clamp(filter.PageSize, 5, 50_000);
        var order = AuditSortColumns.TryGetValue(filter.SortBy ?? string.Empty, out var col) ? col : "a.ActivityOn";
        var dir = filter.SortDesc ? "DESC" : "ASC";
        cmd.Parameters.Add("@Offset", SqlDbType.Int).Value = (page - 1) * pageSize;
        cmd.Parameters.Add("@PageSize", SqlDbType.Int).Value = pageSize;

        cmd.CommandText = $@"
SELECT COUNT_BIG(*) FROM dbo.ARWB_ClaimActivity a INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = a.ClaimKey WHERE {where} {scope};

SELECT a.ActivityId, a.ActivityOn, w.ClaimKey, w.ClaimID, w.LabName, a.UserName, a.RoleCode, a.ActionType, a.PreviousValue, a.NewValue, a.Detail, a.IsSystem
FROM dbo.ARWB_ClaimActivity a
INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = a.ClaimKey
WHERE {where} {scope}
ORDER BY {order} {dir}, a.ActivityId {dir}
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
{(withOptions ? $@"
SELECT TOP (500) a.UserName, COUNT(*) FROM dbo.ARWB_ClaimActivity a INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = a.ClaimKey WHERE 1 = 1 {scope} GROUP BY a.UserName ORDER BY a.UserName;
SELECT TOP (500) a.ActionType, COUNT(*) FROM dbo.ARWB_ClaimActivity a INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = a.ClaimKey WHERE 1 = 1 {scope} GROUP BY a.ActionType ORDER BY a.ActionType;
SELECT TOP (500) w.LabName, COUNT(*) FROM dbo.ARWB_ClaimActivity a INNER JOIN dbo.ARWB_Claim w ON w.ClaimKey = a.ClaimKey WHERE w.LabName IS NOT NULL {scope} GROUP BY w.LabName ORDER BY w.LabName;" : "")}";

        var result = new ArWorkbenchAuditPage { Rows = new ArWorkbenchPagedResult<ArWorkbenchAuditRow> { Page = page, PageSize = pageSize } };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (await r.ReadAsync(ct)) result.Rows.TotalCount = (int)Math.Min(int.MaxValue, r.GetInt64(0));
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct))
        {
            result.Rows.Items.Add(new ArWorkbenchAuditRow
            {
                ActivityId = r.GetInt64(0), ActivityOn = r.GetDateTime(1), ClaimKey = r.GetInt64(2), ClaimID = r.GetString(3), LabName = Str(r, 4),
                UserName = r.GetString(5), RoleCode = Str(r, 6), ActionType = r.GetString(7), PreviousValue = Str(r, 8), NewValue = Str(r, 9),
                Detail = Str(r, 10), IsSystem = r.GetBoolean(11)
            });
        }
        if (withOptions)
        {
            async Task<List<ArWorkbenchFilterOption>> Options()
            {
                await r.NextResultAsync(ct);
                var list = new List<ArWorkbenchFilterOption>();
                while (await r.ReadAsync(ct))
                    if (!r.IsDBNull(0)) list.Add(new ArWorkbenchFilterOption { Value = r.GetString(0), Label = r.GetString(0), Count = r.GetInt32(1) });
                return list;
            }
            result.Users = await Options();
            result.Actions = await Options();
            result.Clients = await Options();
        }
        return result;
    }

    private static string BuildAuditWhere(SqlCommand cmd, ArWorkbenchAuditFilter f)
    {
        var where = new List<string> { "1 = 1" };
        void AddIn(string column, string prefix, IEnumerable<string>? values, int size)
        {
            var list = (values ?? []).Where(v => !string.IsNullOrWhiteSpace(v)).Select(v => v.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).Take(100).ToList();
            if (list.Count == 0) return;
            for (var i = 0; i < list.Count; i++) cmd.Parameters.Add($"@{prefix}{i}", SqlDbType.NVarChar, size).Value = list[i];
            where.Add($"{column} IN ({string.Join(", ", list.Select((_, i) => $"@{prefix}{i}"))})");
        }
        AddIn("a.UserName", "Au", f.User, 256);
        AddIn("a.ActionType", "Aa", f.Action, 200);
        AddIn("w.LabName", "Ac", f.Client, 500);
        if (!f.IncludeSystem) where.Add("a.IsSystem = 0");
        if (f.From is { } from)
        {
            where.Add("a.ActivityOn >= @From");
            cmd.Parameters.Add("@From", SqlDbType.DateTime2).Value = from.Date;
        }
        if (f.To is { } to)
        {
            where.Add("a.ActivityOn < @To");
            cmd.Parameters.Add("@To", SqlDbType.DateTime2).Value = to.Date.AddDays(1);
        }
        if (!string.IsNullOrWhiteSpace(f.Search))
        {
            where.Add("(w.ClaimID LIKE @Search OR a.UserName LIKE @Search OR a.ActionType LIKE @Search OR a.Detail LIKE @Search)");
            cmd.Parameters.Add("@Search", SqlDbType.NVarChar, 210).Value = "%" + f.Search.Trim().Replace("[", "[[]").Replace("%", "[%]").Replace("_", "[_]") + "%";
        }
        return string.Join(" AND ", where);
    }
}
