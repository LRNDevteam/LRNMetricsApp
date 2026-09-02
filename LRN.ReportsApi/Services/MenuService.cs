using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

public interface IMenuRepository
{
    Task<IReadOnlyList<MenuItemDto>> GetMenusForRolesAsync(IEnumerable<string> roleNames, CancellationToken ct);
    Task<IReadOnlyList<MenuRouteDto>> GetManagedRoutesAsync(CancellationToken ct);

    Task<IReadOnlyList<MenuItemDto>> GetAllMenuItemsAsync(CancellationToken ct);
    Task<MenuItemDto?> GetMenuItemAsync(int menuItemId, CancellationToken ct);
    Task<int> CreateMenuItemAsync(MenuItemSaveRequest request, string userName, CancellationToken ct);
    Task<bool> UpdateMenuItemAsync(int menuItemId, MenuItemSaveRequest request, string userName, CancellationToken ct);
    Task<bool> SetMenuItemDisabledAsync(int menuItemId, bool isDisabled, string userName, CancellationToken ct);
    Task<bool> SoftDeleteMenuItemAsync(int menuItemId, string userName, CancellationToken ct);

    Task<IReadOnlyList<MenuRoleOptionDto>> GetRolesAsync(CancellationToken ct);
    Task<IReadOnlyList<int>> GetRoleMenuIdsAsync(int roleId, CancellationToken ct);
    Task ReplaceRoleMenusAsync(int roleId, IReadOnlyCollection<int> menuIds, string userName, CancellationToken ct);

    /// <summary>
    /// Explicit feature settings for the current user, resolved across all of their roles:
    /// any role that enables a feature wins over a role that disables it. Features with no
    /// row for any of the user's roles are omitted so the caller can apply its own default.
    /// </summary>
    Task<IReadOnlyList<RoleFeatureDto>> GetFeaturesForRolesAsync(IEnumerable<string> roleNames, CancellationToken ct);
    Task<IReadOnlyList<RoleFeatureDto>> GetRoleFeaturesAsync(int roleId, CancellationToken ct);
    Task ReplaceRoleFeaturesAsync(int roleId, IReadOnlyCollection<RoleFeatureDto> features, string userName, CancellationToken ct);
}

public sealed class SqlMenuRepository : IMenuRepository
{
    private const string SelectColumns = @"
        m.MenuItemId, m.ParentMenuItemId, m.MenuName, m.ControllerName, m.ActionName, m.AreaName,
        m.IconClass, m.IconImagePath, m.MenuOrder, m.ActiveFrom, m.ActiveTo, m.IsDisabled,
        m.CreatedBy, m.CreatedOn, m.ModifiedBy, m.ModifiedOn";

    private readonly string _connectionString;

    public SqlMenuRepository(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("DefaultConnection is not configured.");
    }

    private SqlConnection Open() => new(_connectionString);

    public async Task<IReadOnlyList<MenuItemDto>> GetMenusForRolesAsync(IEnumerable<string> roleNames, CancellationToken ct)
    {
        var roles = roleNames
            .Where(r => !string.IsNullOrWhiteSpace(r))
            .Select(r => r.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (roles.Count == 0) return Array.Empty<MenuItemDto>();

        var roleParams = roles.Select((_, i) => "@Role" + i).ToList();
        var sql = $@"
SELECT DISTINCT {SelectColumns}
FROM dbo.MenuItems m
INNER JOIN dbo.UserRoleMenu rm ON rm.MenuItemId = m.MenuItemId
INNER JOIN dbo.Roles r ON r.RoleID = rm.RoleId
WHERE r.RoleName IN ({string.Join(",", roleParams)})
  AND ISNULL(r.IsActive, 0) = 1
  AND m.IsDeleted = 0
  AND (m.ActiveFrom IS NULL OR m.ActiveFrom <= @Today)
  AND (m.ActiveTo   IS NULL OR m.ActiveTo   >= @Today)
ORDER BY m.MenuOrder, m.MenuName;";

        var result = new List<MenuItemDto>();
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Today", DateTime.Today);
        for (var i = 0; i < roles.Count; i++) cmd.Parameters.AddWithValue("@Role" + i, roles[i]);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) result.Add(Map(reader));
        return result;
    }

    public async Task<IReadOnlyList<MenuRouteDto>> GetManagedRoutesAsync(CancellationToken ct)
    {
        const string sql = @"
SELECT DISTINCT ISNULL(m.AreaName, N'') AS AreaName, m.ControllerName, m.ActionName
FROM dbo.MenuItems m
WHERE m.IsDeleted = 0
  AND m.ControllerName IS NOT NULL AND LTRIM(RTRIM(m.ControllerName)) <> N''
  AND m.ActionName     IS NOT NULL AND LTRIM(RTRIM(m.ActionName))     <> N'';";

        var result = new List<MenuRouteDto>();
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            result.Add(new MenuRouteDto
            {
                AreaName = reader.GetString(0),
                ControllerName = reader.GetString(1),
                ActionName = reader.GetString(2)
            });
        }
        return result;
    }

    public async Task<IReadOnlyList<MenuItemDto>> GetAllMenuItemsAsync(CancellationToken ct)
    {
        var sql = $@"
SELECT {SelectColumns}
FROM dbo.MenuItems m
WHERE m.IsDeleted = 0
ORDER BY ISNULL(m.ParentMenuItemId, m.MenuItemId), m.ParentMenuItemId, m.MenuOrder, m.MenuName;";

        var result = new List<MenuItemDto>();
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) result.Add(Map(reader));
        return result;
    }

    public async Task<MenuItemDto?> GetMenuItemAsync(int menuItemId, CancellationToken ct)
    {
        var sql = $"SELECT {SelectColumns} FROM dbo.MenuItems m WHERE m.MenuItemId = @Id AND m.IsDeleted = 0;";
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", menuItemId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? Map(reader) : null;
    }

    public async Task<int> CreateMenuItemAsync(MenuItemSaveRequest request, string userName, CancellationToken ct)
    {
        Validate(request);
        const string sql = @"
INSERT INTO dbo.MenuItems
    (ParentMenuItemId, MenuName, ControllerName, ActionName, AreaName, IconClass, IconImagePath,
     MenuOrder, ActiveFrom, ActiveTo, IsDisabled, CreatedBy)
VALUES
    (@ParentMenuItemId, @MenuName, @ControllerName, @ActionName, @AreaName, @IconClass, @IconImagePath,
     @MenuOrder, @ActiveFrom, @ActiveTo, @IsDisabled, @UserName);
SELECT CONVERT(INT, SCOPE_IDENTITY());";

        await using var conn = Open();
        await conn.OpenAsync(ct);
        await EnsureValidParentAsync(conn, request.ParentMenuItemId, menuItemId: null, ct);
        await using var cmd = new SqlCommand(sql, conn);
        AddSaveParameters(cmd, request, userName);
        try
        {
            var id = await cmd.ExecuteScalarAsync(ct);
            return Convert.ToInt32(id);
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            throw new ArgumentException("A menu with this name already exists at the same level.");
        }
    }

    public async Task<bool> UpdateMenuItemAsync(int menuItemId, MenuItemSaveRequest request, string userName, CancellationToken ct)
    {
        Validate(request);
        if (request.ParentMenuItemId == menuItemId)
            throw new ArgumentException("A menu cannot be its own parent.");

        const string sql = @"
UPDATE dbo.MenuItems SET
    ParentMenuItemId = @ParentMenuItemId,
    MenuName         = @MenuName,
    ControllerName   = @ControllerName,
    ActionName       = @ActionName,
    AreaName         = @AreaName,
    IconClass        = @IconClass,
    IconImagePath    = @IconImagePath,
    MenuOrder        = @MenuOrder,
    ActiveFrom       = @ActiveFrom,
    ActiveTo         = @ActiveTo,
    IsDisabled       = @IsDisabled,
    ModifiedBy       = @UserName,
    ModifiedOn       = SYSDATETIME()
WHERE MenuItemId = @Id AND IsDeleted = 0;";

        await using var conn = Open();
        await conn.OpenAsync(ct);
        await EnsureValidParentAsync(conn, request.ParentMenuItemId, menuItemId, ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", menuItemId);
        AddSaveParameters(cmd, request, userName);
        try
        {
            return await cmd.ExecuteNonQueryAsync(ct) > 0;
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            throw new ArgumentException("A menu with this name already exists at the same level.");
        }
    }

    public async Task<bool> SetMenuItemDisabledAsync(int menuItemId, bool isDisabled, string userName, CancellationToken ct)
    {
        const string sql = @"
UPDATE dbo.MenuItems
SET IsDisabled = @IsDisabled, ModifiedBy = @UserName, ModifiedOn = SYSDATETIME()
WHERE MenuItemId = @Id AND IsDeleted = 0;";
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", menuItemId);
        cmd.Parameters.AddWithValue("@IsDisabled", isDisabled);
        cmd.Parameters.AddWithValue("@UserName", userName);
        return await cmd.ExecuteNonQueryAsync(ct) > 0;
    }

    public async Task<bool> SoftDeleteMenuItemAsync(int menuItemId, string userName, CancellationToken ct)
    {
        // Deleting a parent while it still has visible children is blocked (safer and clearer
        // than cascading the delete - see spec §4.1 validation rules).
        const string childCheckSql = @"
SELECT COUNT(1) FROM dbo.MenuItems WHERE ParentMenuItemId = @Id AND IsDeleted = 0;";
        const string sql = @"
UPDATE dbo.MenuItems
SET IsDeleted = 1, ModifiedBy = @UserName, ModifiedOn = SYSDATETIME()
WHERE MenuItemId = @Id AND IsDeleted = 0;";

        await using var conn = Open();
        await conn.OpenAsync(ct);

        await using (var check = new SqlCommand(childCheckSql, conn))
        {
            check.Parameters.AddWithValue("@Id", menuItemId);
            var children = Convert.ToInt32(await check.ExecuteScalarAsync(ct));
            if (children > 0)
                throw new ArgumentException("This menu still has submenus. Delete or move its submenus first.");
        }

        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", menuItemId);
        cmd.Parameters.AddWithValue("@UserName", userName);
        return await cmd.ExecuteNonQueryAsync(ct) > 0;
    }

    public async Task<IReadOnlyList<MenuRoleOptionDto>> GetRolesAsync(CancellationToken ct)
    {
        const string sql = @"
SELECT RoleID, RoleName, ISNULL(IsActive, 0) AS IsActive
FROM dbo.Roles
WHERE ISNULL(IsActive, 0) = 1
ORDER BY RoleName;";

        var result = new List<MenuRoleOptionDto>();
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            result.Add(new MenuRoleOptionDto
            {
                RoleId = reader.GetInt32(0),
                RoleName = reader.GetString(1),
                IsActive = reader.GetBoolean(2)
            });
        }
        return result;
    }

    public async Task<IReadOnlyList<int>> GetRoleMenuIdsAsync(int roleId, CancellationToken ct)
    {
        const string sql = @"
SELECT rm.MenuItemId
FROM dbo.UserRoleMenu rm
INNER JOIN dbo.MenuItems m ON m.MenuItemId = rm.MenuItemId AND m.IsDeleted = 0
WHERE rm.RoleId = @RoleId;";

        var result = new List<int>();
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@RoleId", roleId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) result.Add(reader.GetInt32(0));
        return result;
    }

    public async Task ReplaceRoleMenusAsync(int roleId, IReadOnlyCollection<int> menuIds, string userName, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct);

        await using (var delete = new SqlCommand("DELETE FROM dbo.UserRoleMenu WHERE RoleId = @RoleId;", conn, tx))
        {
            delete.Parameters.AddWithValue("@RoleId", roleId);
            await delete.ExecuteNonQueryAsync(ct);
        }

        // Mapping convention: granting a submenu requires its parent to be granted too,
        // so the render query stays simple. Enforce it server-side.
        var idSet = new HashSet<int>(menuIds);
        if (idSet.Count > 0)
        {
            var idParams = idSet.Select((_, i) => "@M" + i).ToList();
            var parentSql = $@"
SELECT DISTINCT ParentMenuItemId FROM dbo.MenuItems
WHERE MenuItemId IN ({string.Join(",", idParams)}) AND ParentMenuItemId IS NOT NULL AND IsDeleted = 0;";
            await using var parents = new SqlCommand(parentSql, conn, tx);
            var ids = idSet.ToList();
            for (var i = 0; i < ids.Count; i++) parents.Parameters.AddWithValue("@M" + i, ids[i]);
            await using var reader = await parents.ExecuteReaderAsync(ct);
            var parentIds = new List<int>();
            while (await reader.ReadAsync(ct)) parentIds.Add(reader.GetInt32(0));
            await reader.CloseAsync();
            foreach (var pid in parentIds) idSet.Add(pid);

            const string insertSql = @"
INSERT INTO dbo.UserRoleMenu (RoleId, MenuItemId, CreatedBy)
SELECT @RoleId, m.MenuItemId, @UserName
FROM dbo.MenuItems m
WHERE m.MenuItemId = @MenuItemId AND m.IsDeleted = 0;";
            foreach (var menuItemId in idSet)
            {
                await using var insert = new SqlCommand(insertSql, conn, tx);
                insert.Parameters.AddWithValue("@RoleId", roleId);
                insert.Parameters.AddWithValue("@MenuItemId", menuItemId);
                insert.Parameters.AddWithValue("@UserName", userName);
                await insert.ExecuteNonQueryAsync(ct);
            }
        }

        await tx.CommitAsync(ct);
    }

    // ── Role feature access (non-menu UI elements) ─────────────────────────

    public async Task<IReadOnlyList<RoleFeatureDto>> GetFeaturesForRolesAsync(IEnumerable<string> roleNames, CancellationToken ct)
    {
        var roles = roleNames
            .Where(r => !string.IsNullOrWhiteSpace(r))
            .Select(r => r.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (roles.Count == 0) return Array.Empty<RoleFeatureDto>();

        var roleParams = roles.Select((_, i) => "@Role" + i).ToList();
        var sql = $@"
SELECT   fa.FeatureKey, CONVERT(BIT, MAX(CONVERT(INT, fa.IsEnabled))) AS IsEnabled
FROM     dbo.RoleFeatureAccess fa
INNER JOIN dbo.Roles r ON r.RoleID = fa.RoleId
WHERE    r.RoleName IN ({string.Join(",", roleParams)})
  AND    ISNULL(r.IsActive, 0) = 1
GROUP BY fa.FeatureKey;";

        var result = new List<RoleFeatureDto>();
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        for (var i = 0; i < roles.Count; i++) cmd.Parameters.AddWithValue("@Role" + i, roles[i]);
        try
        {
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                var key = reader.GetString(0);
                if (!MenuFeatureCatalog.IsKnown(key)) continue; // stale row from a removed feature
                result.Add(new RoleFeatureDto { FeatureKey = key, IsEnabled = reader.GetBoolean(1) });
            }
        }
        catch (SqlException ex) when (ex.Number == 208)
        {
            // Table not deployed yet. This runs on every page render, so an un-migrated
            // database must read as "nothing decided" and let the host apply its default,
            // rather than failing the navbar. The admin endpoints below still surface the
            // error, which is where an admin needs to see it.
            return Array.Empty<RoleFeatureDto>();
        }
        return result;
    }

    public async Task<IReadOnlyList<RoleFeatureDto>> GetRoleFeaturesAsync(int roleId, CancellationToken ct)
    {
        const string sql = @"
SELECT FeatureKey, IsEnabled FROM dbo.RoleFeatureAccess WHERE RoleId = @RoleId;";

        var result = new List<RoleFeatureDto>();
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@RoleId", roleId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var key = reader.GetString(0);
            if (!MenuFeatureCatalog.IsKnown(key)) continue;
            result.Add(new RoleFeatureDto { FeatureKey = key, IsEnabled = reader.GetBoolean(1) });
        }
        return result;
    }

    public async Task ReplaceRoleFeaturesAsync(int roleId, IReadOnlyCollection<RoleFeatureDto> features, string userName, CancellationToken ct)
    {
        foreach (var feature in features)
        {
            if (!MenuFeatureCatalog.IsKnown(feature.FeatureKey))
                throw new ArgumentException($"Unknown feature '{feature.FeatureKey}'.");
        }

        // Full replace, like ReplaceRoleMenusAsync: a feature the admin left on "Default"
        // is simply absent from the payload, and its row must go away so the host falls
        // back to menu access again.
        const string insertSql = @"
INSERT dbo.RoleFeatureAccess (RoleId, FeatureKey, IsEnabled, CreatedBy)
VALUES (@RoleId, @FeatureKey, @IsEnabled, @UserName);";

        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct);

        await using (var delete = new SqlCommand("DELETE FROM dbo.RoleFeatureAccess WHERE RoleId = @RoleId;", conn, tx))
        {
            delete.Parameters.AddWithValue("@RoleId", roleId);
            await delete.ExecuteNonQueryAsync(ct);
        }

        foreach (var feature in features.GroupBy(f => f.FeatureKey, StringComparer.OrdinalIgnoreCase).Select(g => g.Last()))
        {
            await using var cmd = new SqlCommand(insertSql, conn, tx);
            cmd.Parameters.AddWithValue("@RoleId", roleId);
            cmd.Parameters.AddWithValue("@FeatureKey", feature.FeatureKey);
            cmd.Parameters.AddWithValue("@IsEnabled", feature.IsEnabled);
            cmd.Parameters.AddWithValue("@UserName", userName);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
    }

    private static void Validate(MenuItemSaveRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.MenuName))
            throw new ArgumentException("Menu name is required.");
        if (request.MenuName.Trim().Length > 100)
            throw new ArgumentException("Menu name must be 100 characters or fewer.");

        var hasController = !string.IsNullOrWhiteSpace(request.ControllerName);
        var hasAction = !string.IsNullOrWhiteSpace(request.ActionName);
        if (hasController != hasAction)
            throw new ArgumentException("Controller and Action must be provided together (both or neither).");

        if (request.ActiveFrom.HasValue && request.ActiveTo.HasValue && request.ActiveFrom.Value.Date > request.ActiveTo.Value.Date)
            throw new ArgumentException("Active From must be on or before Active To.");
    }

    private static async Task EnsureValidParentAsync(SqlConnection conn, int? parentMenuItemId, int? menuItemId, CancellationToken ct)
    {
        if (!parentMenuItemId.HasValue) return;

        // Two-level hierarchy: the chosen parent must itself be top-level.
        const string parentSql = @"
SELECT ParentMenuItemId FROM dbo.MenuItems WHERE MenuItemId = @ParentId AND IsDeleted = 0;";
        await using (var cmd = new SqlCommand(parentSql, conn))
        {
            cmd.Parameters.AddWithValue("@ParentId", parentMenuItemId.Value);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            if (!await reader.ReadAsync(ct))
                throw new ArgumentException("The selected parent menu does not exist.");
            if (!reader.IsDBNull(0))
                throw new ArgumentException("Only top-level menus can be selected as a parent (two-level limit).");
        }

        // A menu that already has children cannot itself be moved under a parent.
        if (menuItemId.HasValue)
        {
            const string childSql = @"
SELECT COUNT(1) FROM dbo.MenuItems WHERE ParentMenuItemId = @Id AND IsDeleted = 0;";
            await using var cmd = new SqlCommand(childSql, conn);
            cmd.Parameters.AddWithValue("@Id", menuItemId.Value);
            var children = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
            if (children > 0)
                throw new ArgumentException("This menu has submenus and must stay top-level (two-level limit).");
        }
    }

    private static void AddSaveParameters(SqlCommand cmd, MenuItemSaveRequest request, string userName)
    {
        cmd.Parameters.AddWithValue("@ParentMenuItemId", (object?)request.ParentMenuItemId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@MenuName", request.MenuName.Trim());
        cmd.Parameters.AddWithValue("@ControllerName", NullIfEmpty(request.ControllerName));
        cmd.Parameters.AddWithValue("@ActionName", NullIfEmpty(request.ActionName));
        cmd.Parameters.AddWithValue("@AreaName", NullIfEmpty(request.AreaName));
        cmd.Parameters.AddWithValue("@IconClass", NullIfEmpty(request.IconClass));
        cmd.Parameters.AddWithValue("@IconImagePath", NullIfEmpty(request.IconImagePath));
        cmd.Parameters.AddWithValue("@MenuOrder", request.MenuOrder);
        cmd.Parameters.AddWithValue("@ActiveFrom", (object?)request.ActiveFrom?.Date ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ActiveTo", (object?)request.ActiveTo?.Date ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@IsDisabled", request.IsDisabled);
        cmd.Parameters.AddWithValue("@UserName", userName);
    }

    private static object NullIfEmpty(string? value)
        => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

    private static MenuItemDto Map(SqlDataReader r) => new()
    {
        MenuItemId = r.GetInt32(r.GetOrdinal("MenuItemId")),
        ParentMenuItemId = r.IsDBNull(r.GetOrdinal("ParentMenuItemId")) ? null : r.GetInt32(r.GetOrdinal("ParentMenuItemId")),
        MenuName = r.GetString(r.GetOrdinal("MenuName")),
        ControllerName = r.IsDBNull(r.GetOrdinal("ControllerName")) ? null : r.GetString(r.GetOrdinal("ControllerName")),
        ActionName = r.IsDBNull(r.GetOrdinal("ActionName")) ? null : r.GetString(r.GetOrdinal("ActionName")),
        AreaName = r.IsDBNull(r.GetOrdinal("AreaName")) ? null : r.GetString(r.GetOrdinal("AreaName")),
        IconClass = r.IsDBNull(r.GetOrdinal("IconClass")) ? null : r.GetString(r.GetOrdinal("IconClass")),
        IconImagePath = r.IsDBNull(r.GetOrdinal("IconImagePath")) ? null : r.GetString(r.GetOrdinal("IconImagePath")),
        MenuOrder = r.GetInt32(r.GetOrdinal("MenuOrder")),
        ActiveFrom = r.IsDBNull(r.GetOrdinal("ActiveFrom")) ? null : r.GetDateTime(r.GetOrdinal("ActiveFrom")),
        ActiveTo = r.IsDBNull(r.GetOrdinal("ActiveTo")) ? null : r.GetDateTime(r.GetOrdinal("ActiveTo")),
        IsDisabled = r.GetBoolean(r.GetOrdinal("IsDisabled")),
        CreatedBy = r.IsDBNull(r.GetOrdinal("CreatedBy")) ? null : r.GetString(r.GetOrdinal("CreatedBy")),
        CreatedOn = r.IsDBNull(r.GetOrdinal("CreatedOn")) ? null : r.GetDateTime(r.GetOrdinal("CreatedOn")),
        ModifiedBy = r.IsDBNull(r.GetOrdinal("ModifiedBy")) ? null : r.GetString(r.GetOrdinal("ModifiedBy")),
        ModifiedOn = r.IsDBNull(r.GetOrdinal("ModifiedOn")) ? null : r.GetDateTime(r.GetOrdinal("ModifiedOn"))
    };
}
