using System.Data;
using System.Text.Json;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Saved Views (dbo.ARWB_SavedView): each user's named filter sets per screen. A view belongs to the
/// user who saved it - every query is keyed by UserName, so one user can never read or change
/// another's. At most one view per user and screen is the default (applied when the screen opens).
/// </summary>
public sealed partial class SqlArWorkbenchRepository
{
    public async Task<IReadOnlyList<ArWorkbenchSavedView>> GetSavedViewsAsync(int labId, string userName, string viewKey, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        cmd.CommandText = @"
SELECT SavedViewId, ViewKey, ViewName, FiltersJson, HiddenColumnsJson, IsDefault, CreatedOn, UpdatedOn
FROM dbo.ARWB_SavedView
WHERE UserName = @User AND ViewKey = @ViewKey
ORDER BY IsDefault DESC, ViewName;";
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = userName;
        cmd.Parameters.Add("@ViewKey", SqlDbType.VarChar, 60).Value = viewKey;

        var list = new List<ArWorkbenchSavedView>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            list.Add(new ArWorkbenchSavedView
            {
                SavedViewId = r.GetInt32(0),
                ViewKey = r.GetString(1),
                ViewName = r.GetString(2),
                FiltersJson = r.IsDBNull(3) ? null : r.GetString(3),
                HiddenColumnsJson = r.IsDBNull(4) ? null : r.GetString(4),
                IsDefault = r.GetBoolean(5),
                CreatedOn = r.GetDateTime(6),
                UpdatedOn = r.IsDBNull(7) ? null : r.GetDateTime(7)
            });
        }
        return list;
    }

    /// <summary>Saves a view; the same name on the same screen is overwritten. Returns the view's id.</summary>
    public async Task<(ArWorkbenchSaveResult Result, int? SavedViewId)> SaveViewAsync(int labId, string userName, ArWorkbenchSavedViewInput view, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        await using var cmd = connection.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = @"
DECLARE @Id int = (SELECT SavedViewId FROM dbo.ARWB_SavedView WITH (UPDLOCK, HOLDLOCK)
                   WHERE UserName = @User AND ViewKey = @ViewKey AND ViewName = @ViewName);

IF @Id IS NULL AND (SELECT COUNT(*) FROM dbo.ARWB_SavedView WHERE UserName = @User AND ViewKey = @ViewKey) >= @MaxViews
BEGIN
    SELECT CAST(NULL AS int);
    RETURN;
END;

IF @IsDefault = 1
    UPDATE dbo.ARWB_SavedView SET IsDefault = 0, UpdatedOn = SYSUTCDATETIME()
    WHERE UserName = @User AND ViewKey = @ViewKey AND IsDefault = 1 AND SavedViewId <> ISNULL(@Id, 0);

IF @Id IS NULL
BEGIN
    INSERT dbo.ARWB_SavedView (UserName, ViewKey, ViewName, FiltersJson, HiddenColumnsJson, IsDefault)
    VALUES (@User, @ViewKey, @ViewName, @FiltersJson, @HiddenColumnsJson, @IsDefault);
    SET @Id = CAST(SCOPE_IDENTITY() AS int);
END
ELSE
    UPDATE dbo.ARWB_SavedView
    SET FiltersJson = @FiltersJson, HiddenColumnsJson = @HiddenColumnsJson, IsDefault = @IsDefault, UpdatedOn = SYSUTCDATETIME()
    WHERE SavedViewId = @Id;

SELECT @Id;";
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = userName;
        cmd.Parameters.Add("@ViewKey", SqlDbType.VarChar, 60).Value = view.ViewKey;
        cmd.Parameters.Add("@ViewName", SqlDbType.NVarChar, 120).Value = view.ViewName;
        cmd.Parameters.Add("@FiltersJson", SqlDbType.NVarChar, -1).Value = (object?)view.FiltersJson ?? DBNull.Value;
        cmd.Parameters.Add("@HiddenColumnsJson", SqlDbType.NVarChar, -1).Value = (object?)view.HiddenColumnsJson ?? DBNull.Value;
        cmd.Parameters.Add("@IsDefault", SqlDbType.Bit).Value = view.IsDefault;
        cmd.Parameters.Add("@MaxViews", SqlDbType.Int).Value = ArWorkbenchSavedViewRules.MaxViewsPerScreen;

        var id = await cmd.ExecuteScalarAsync(ct);
        if (id is not int savedViewId)
        {
            await tx.RollbackAsync(ct);
            return (ArWorkbenchSaveResult.Conflict($"You already have {ArWorkbenchSavedViewRules.MaxViewsPerScreen} saved views on this screen. Delete one first."), null);
        }
        await tx.CommitAsync(ct);
        return (ArWorkbenchSaveResult.Ok($"View '{view.ViewName}' saved."), savedViewId);
    }

    public async Task<ArWorkbenchSaveResult> UpdateSavedViewAsync(int labId, string userName, int savedViewId, string? newName, bool? isDefault, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        await using var cmd = connection.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = @"
DECLARE @ViewKey varchar(60) = (SELECT ViewKey FROM dbo.ARWB_SavedView WITH (UPDLOCK, HOLDLOCK)
                                WHERE SavedViewId = @Id AND UserName = @User);
IF @ViewKey IS NULL BEGIN SELECT 'notfound'; RETURN; END;

IF @NewName IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.ARWB_SavedView
                                    WHERE UserName = @User AND ViewKey = @ViewKey AND ViewName = @NewName AND SavedViewId <> @Id)
BEGIN SELECT 'duplicate'; RETURN; END;

IF @IsDefault = 1
    UPDATE dbo.ARWB_SavedView SET IsDefault = 0, UpdatedOn = SYSUTCDATETIME()
    WHERE UserName = @User AND ViewKey = @ViewKey AND IsDefault = 1 AND SavedViewId <> @Id;

UPDATE dbo.ARWB_SavedView
SET ViewName = ISNULL(@NewName, ViewName), IsDefault = ISNULL(@IsDefault, IsDefault), UpdatedOn = SYSUTCDATETIME()
WHERE SavedViewId = @Id;

SELECT 'ok';";
        cmd.Parameters.Add("@Id", SqlDbType.Int).Value = savedViewId;
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = userName;
        cmd.Parameters.Add("@NewName", SqlDbType.NVarChar, 120).Value = (object?)newName ?? DBNull.Value;
        cmd.Parameters.Add("@IsDefault", SqlDbType.Bit).Value = (object?)isDefault ?? DBNull.Value;

        var outcome = (string?)await cmd.ExecuteScalarAsync(ct);
        if (outcome != "ok")
        {
            await tx.RollbackAsync(ct);
            return outcome == "duplicate"
                ? ArWorkbenchSaveResult.Conflict($"You already have a view named '{newName}' on this screen.")
                : ArWorkbenchSaveResult.NotFound("That saved view no longer exists.");
        }
        await tx.CommitAsync(ct);
        return ArWorkbenchSaveResult.Ok("View updated.");
    }

    public async Task<ArWorkbenchSaveResult> DeleteSavedViewAsync(int labId, string userName, int savedViewId, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        cmd.CommandText = "DELETE dbo.ARWB_SavedView WHERE SavedViewId = @Id AND UserName = @User;";
        cmd.Parameters.Add("@Id", SqlDbType.Int).Value = savedViewId;
        cmd.Parameters.Add("@User", SqlDbType.NVarChar, 256).Value = userName;
        return await cmd.ExecuteNonQueryAsync(ct) > 0
            ? ArWorkbenchSaveResult.Ok("View deleted.")
            : ArWorkbenchSaveResult.NotFound("That saved view no longer exists.");
    }
}

/// <summary>A validated view to save.</summary>
public sealed record ArWorkbenchSavedViewInput(string ViewKey, string ViewName, string? FiltersJson, string? HiddenColumnsJson, bool IsDefault);

/// <summary>What a saved view must be: a known screen, a short name, and JSON the screen wrote.</summary>
public static class ArWorkbenchSavedViewRules
{
    public const int MaxViewsPerScreen = 50;
    public const int MaxNameLength = 120;
    public const int MaxJsonLength = 20_000;

    /// <summary>The screens with a filter bar that can be saved (dbo.ARWB_SavedView.ViewKey).</summary>
    public static readonly IReadOnlySet<string> ViewKeys = new HashSet<string>(StringComparer.Ordinal)
    {
        "workqueue", "mywork", "followup", "assignment", "qa", "cip", "agent-requests", "audit", "vault"
    };

    public static string? NormalizeViewKey(string? viewKey)
    {
        var key = viewKey?.Trim().ToLowerInvariant();
        return key is not null && ViewKeys.Contains(key) ? key : null;
    }

    /// <summary>Trims and collapses inner spacing; null when the name is empty or too long.</summary>
    public static string? NormalizeName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return null;
        var clean = string.Join(' ', name.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return clean.Length <= MaxNameLength ? clean : null;
    }

    public static (ArWorkbenchSavedViewInput? View, string? Error) Validate(ArWorkbenchSavedViewRequest? request)
    {
        if (request is null) return (null, "Send the view to save.");
        var key = NormalizeViewKey(request.ViewKey);
        if (key is null) return (null, "Unknown screen for a saved view.");
        var name = NormalizeName(request.ViewName);
        if (name is null) return (null, $"Give the view a name of 1 to {MaxNameLength} characters.");
        if (!IsJsonObject(request.FiltersJson, required: true)) return (null, "The view's filters are missing or not valid.");
        if (!IsJsonArray(request.HiddenColumnsJson)) return (null, "The view's hidden columns are not valid.");
        return (new ArWorkbenchSavedViewInput(key, name, request.FiltersJson!.Trim(),
            string.IsNullOrWhiteSpace(request.HiddenColumnsJson) ? null : request.HiddenColumnsJson.Trim(), request.IsDefault), null);
    }

    private static bool IsJsonObject(string? json, bool required) => IsJson(json, JsonValueKind.Object, required);
    private static bool IsJsonArray(string? json) => IsJson(json, JsonValueKind.Array, required: false);

    private static bool IsJson(string? json, JsonValueKind kind, bool required)
    {
        if (string.IsNullOrWhiteSpace(json)) return !required;
        if (json.Length > MaxJsonLength) return false;
        try
        {
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.ValueKind == kind;
        }
        catch (JsonException)
        {
            return false;
        }
    }
}
