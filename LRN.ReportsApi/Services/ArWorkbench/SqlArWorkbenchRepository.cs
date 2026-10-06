using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArWorkbench;

public interface IArWorkbenchRepository
{
    /// <param name="siteAdminRole">
    /// The caller's LRN Metrics admin role (Super Admin / Admin / LRN Admin / Lab Admin) when they
    /// hold one, else null. Lab access is the controller's job; this only grants every page.
    /// </param>
    Task<ArWorkbenchUserContext?> GetUserContextAsync(int labId, string userName, string? siteAdminRole, CancellationToken ct);
    Task<ArWorkbenchQueueSummary> GetQueueSummaryAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct);
    Task<ArWorkbenchDashboard> GetDashboardAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct);
    Task<ArWorkbenchPagedResult<ArWorkbenchClaimRow>> GetClaimsAsync(ArWorkbenchClaimFilter filter, ArWorkbenchUserContext user, CancellationToken ct);
    Task<ArWorkbenchFilterOptions> GetFilterOptionsAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct);
    Task<ArWorkbenchClaimDetail?> GetClaimDetailAsync(int labId, long claimKey, ArWorkbenchUserContext user, CancellationToken ct);
    Task<ArWorkbenchMasterData> GetMasterDataAsync(int labId, CancellationToken ct);
    Task<IReadOnlyList<ArWorkbenchRefreshRun>> GetRefreshRunsAsync(int labId, int top, CancellationToken ct);
    /// <param name="reprocessAll">Re-derive every claim's denial category and queue from the current master data.</param>
    Task<ArWorkbenchRefreshRun?> RunRefreshAsync(int labId, string runBy, string? note, CancellationToken ct, bool reprocessAll = false);

    // My Work / Follow-Up Management tiles (SqlArWorkbenchRepository.WorkSummary.cs)
    Task<ArWorkbenchWorkSummary> GetWorkSummaryAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct);

    // Central Denial Code Master (SqlArWorkbenchRepository.CodeMaster.cs) - LRNMaster
    Task<(bool Installed, IReadOnlyList<ArWorkbenchCodeMasterRow> Rows)> GetCodeMasterAsync(CancellationToken ct);
    Task<IReadOnlyList<ArWorkbenchCodeMasterRow>> GetCodeMasterInfoAsync(IReadOnlyCollection<string> codes, CancellationToken ct);
    Task<ArWorkbenchSaveResult> SaveCodeMasterRowAsync(ArWorkbenchCodeMasterRow row, bool isNew, string user, CancellationToken ct);
    Task<ArWorkbenchSaveResult> DeleteCodeMasterRowAsync(string code, CancellationToken ct);
    Task<ArWorkbenchSaveResult> ApplyCodeMasterImportAsync(ArWorkbenchCodeMasterMerge merge, string user, CancellationToken ct);
    Task<IReadOnlyList<string>> GetLabNonCollectibleCodesAsync(int labId, CancellationToken ct);
    Task<(int Recalculated, int Flagged)> ApplyNonCollectibleCodesAsync(int labId, IReadOnlyList<string> toAdd, IReadOnlyList<string> toDeactivate, string user, CancellationToken ct);

    // Automatic Adjustment (SqlArWorkbenchRepository.AutoAdjust.cs)
    Task<ArWorkbenchAdjustmentResult> ProcessAutoAdjustmentsAsync(int labId, IReadOnlyList<long>? claimKeys, bool previewOnly, ArWorkbenchUserContext user, CancellationToken ct);
    Task<int> MarkAdjustmentsPostedAsync(int labId, IReadOnlyList<long> claimKeys, ArWorkbenchUserContext user, CancellationToken ct);

    // User Management (SqlArWorkbenchRepository.Users.cs) - LRNMaster user tables
    Task<IReadOnlyList<ArWorkbenchLabOption>> GetAllLabsAsync(CancellationToken ct);
    Task<IReadOnlySet<int>> GetUserLabIdsAsync(int labUserId, CancellationToken ct);
    Task<IReadOnlyList<ArWorkbenchRoleOption>> GetAssignableRolesAsync(CancellationToken ct);
    Task<IReadOnlyList<ArWorkbenchManagedUser>> GetManagedUsersAsync(int? callerLabUserId, bool allLabs, IReadOnlyList<ArWorkbenchLabOption> manageableLabs, CancellationToken ct);
    Task<(ArWorkbenchSaveResult Result, int? LabUserId)> CreateWorkbenchUserAsync(string userName, string passwordHash, string email, int roleId, IReadOnlyList<int> labIds, string createdBy, CancellationToken ct);
    Task<ArWorkbenchSaveResult> UpdateWorkbenchUserAsync(int labUserId, string email, int roleId, IReadOnlyList<int> requestedLabIds, bool isActive, string? passwordHash,
        int? callerLabUserId, bool allLabs, IReadOnlySet<int> manageableLabIds, string modifiedBy, CancellationToken ct);

    // Saved Views (SqlArWorkbenchRepository.SavedViews.cs)
    Task<IReadOnlyList<ArWorkbenchSavedView>> GetSavedViewsAsync(int labId, string userName, string viewKey, CancellationToken ct);
    Task<(ArWorkbenchSaveResult Result, int? SavedViewId)> SaveViewAsync(int labId, string userName, ArWorkbenchSavedViewInput view, CancellationToken ct);
    Task<ArWorkbenchSaveResult> UpdateSavedViewAsync(int labId, string userName, int savedViewId, string? newName, bool? isDefault, CancellationToken ct);
    Task<ArWorkbenchSaveResult> DeleteSavedViewAsync(int labId, string userName, int savedViewId, CancellationToken ct);

    // Follow-up notes, insights, timely-filing limits (SqlArWorkbenchRepository.FollowUp.cs)
    Task<(ArWorkbenchSaveStatus Status, string Message, ArWorkbenchFollowUpResult? Result)> LogFollowUpAsync(int labId, long claimKey, ArWorkbenchFollowUpRequest request, ArWorkbenchUserContext user, CancellationToken ct);
    Task<IReadOnlyList<ArWorkbenchInsightRow>> GetInsightsAsync(int labId, CancellationToken ct);
    Task<ArWorkbenchTflSettings> GetTflSettingsAsync(int labId, CancellationToken ct);
    Task<ArWorkbenchSaveResult> SaveTflThresholdAsync(int labId, string? originalClass, string financialClass, int days, string user, CancellationToken ct);
    Task<ArWorkbenchSaveResult> DeleteTflThresholdAsync(int labId, string financialClass, CancellationToken ct);
    Task<ArWorkbenchSaveResult> SaveTflDefaultsAsync(int labId, int defaultDays, int riskWindowDays, string user, CancellationToken ct);

    // Assignment Management (SqlArWorkbenchRepository.Assignment.cs)
    Task<IReadOnlyList<ArWorkbenchAgent>> GetAgentsAsync(int labId, CancellationToken ct);
    Task<ArWorkbenchAssignmentOverview> GetAssignmentOverviewAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct);
    Task<ArWorkbenchBatchPreview> PreviewBatchAsync(int labId, ArWorkbenchBatchCriteria criteria, ArWorkbenchUserContext user, CancellationToken ct);
    Task<ArWorkbenchAssignResult> CreateBatchAsync(int labId, ArWorkbenchBatchCreateRequest request, ArWorkbenchAgent agent, ArWorkbenchUserContext user, CancellationToken ct);
    Task<ArWorkbenchAssignResult> AssignClaimsAsync(int labId, ArWorkbenchAssignRequest request, ArWorkbenchAgent agent, ArWorkbenchUserContext user, CancellationToken ct);
    Task<IReadOnlyList<ArWorkbenchBatch>> GetBatchesAsync(int labId, string? status, int top, CancellationToken ct);
    Task<ArWorkbenchBatchDetail?> GetBatchDetailAsync(int labId, int batchId, ArWorkbenchUserContext user, CancellationToken ct);
    Task<ArWorkbenchSaveResult> CancelBatchAsync(int labId, int batchId, string user, CancellationToken ct);

    // Master File Maintenance (SqlArWorkbenchRepository.Masters.cs)
    Task<ArWorkbenchMasterValuesResponse> GetMasterValuesAsync(int labId, CancellationToken ct);
    Task<ArWorkbenchSaveResult> AddMasterValueAsync(int labId, ArWorkbenchMasterType type, ArWorkbenchMasterValidated value, string user, CancellationToken ct);
    Task<ArWorkbenchSaveResult> UpdateMasterValueAsync(int labId, ArWorkbenchMasterType type, string originalValue, ArWorkbenchMasterValidated value, string user, CancellationToken ct);
    Task<ArWorkbenchSaveResult> DeleteMasterValueAsync(int labId, ArWorkbenchMasterType type, string value, CancellationToken ct);

    Task<ArWorkbenchPagedResult<ArWorkbenchDenialCodeRow>> GetDenialCodesAsync(ArWorkbenchDenialCodeQuery query, CancellationToken ct);
    Task<IReadOnlyList<ArWorkbenchDenialCodeRow>> GetAllDenialCodesAsync(int labId, CancellationToken ct);
    Task<IReadOnlyList<ArWorkbenchUnmappedDenialCode>> GetUnmappedDenialCodesAsync(int labId, CancellationToken ct);
    Task<ArWorkbenchDenialCodeImpact> GetDenialCodeImpactAsync(int labId, string denialCode, CancellationToken ct);
    Task<ArWorkbenchSaveResult> SaveDenialCodeAsync(int labId, string? originalDenialCode, ArWorkbenchDenialCodeValidated value, string user, CancellationToken ct);
    Task<ArWorkbenchSaveResult> DeleteDenialCodeAsync(int labId, string denialCode, CancellationToken ct);
    Task<ArWorkbenchDenialCodeImportResult> ImportDenialCodesAsync(int labId, IReadOnlyList<ArWorkbenchDenialCodeImportRow> rows, int skippedCount, string user, CancellationToken ct);
}

/// <summary>
/// Reads the dbo.ARWB_* tables in a lab database. Every claim-reading query goes through
/// <see cref="AppendScope"/>, so clinic / provider access grants and the agent's own-caseload
/// restriction are enforced in SQL - never only in the UI.
///
/// Derived state (queue, recovery, lifecycle flags) is NOT computed here. It is written by
/// dbo.ARWB_usp_RecalculateClaimState, the single implementation of those rules; this class only reads it.
/// </summary>
public sealed partial class SqlArWorkbenchRepository : IArWorkbenchRepository
{
    private const int MaxPageSize = 500;

    private static readonly Dictionary<string, string> SortColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        ["claimId"] = "w.ClaimID",
        ["patientId"] = "w.PatientID",
        ["dateOfService"] = "w.DateOfService",
        ["payerName"] = "w.PayerName",
        ["panelName"] = "w.PanelName",
        ["clinicName"] = "w.ClinicName",
        ["lastFollowUpDate"] = "w.LastFollowUpDate",
        ["remainingAR"] = "w.RemainingAR",
        ["revenueExpectation"] = "w.RevenueExpectation",
        ["recoveredAmount"] = "w.RecoveredAmount",
        ["insuranceBalance"] = "w.InsuranceBalance",
        ["agingDays"] = "w.AgingDays",
        ["priority"] = "CASE w.Priority WHEN 'High' THEN 3 WHEN 'Medium' THEN 2 ELSE 1 END",
        ["nextFollowUpDate"] = "w.NextFollowUpDate",
        ["daysSinceLastTouch"] = $"DATEDIFF(day, {UntouchedSinceSql()}, SYSUTCDATETIME())",
        ["workflowStatus"] = "w.WorkflowStatus",
        ["denialCategory"] = "w.DenialCategory"
    };

    /// <summary>
    /// When a person last worked the claim. System entries - the claim sync's "Claim Identified" and
    /// "Source Data Updated", auto-processing - are not touches: every claim gets one on each sync,
    /// which would make every claim look freshly worked. A claim nobody has worked counts from when
    /// it entered AR (first billed, else date of service, else first sync). Days Untouched, its sort
    /// and the "untouched N+ days" filter all use this one definition.
    /// </summary>
    internal static string UntouchedSinceSql(string alias = "w") =>
        $"COALESCE((SELECT MAX(ta.ActivityOn) FROM dbo.ARWB_ClaimActivity ta WHERE ta.ClaimKey = {alias}.ClaimKey AND ta.IsSystem = 0), " +
        $"CONVERT(datetime2(0), {alias}.FirstBilledDate), CONVERT(datetime2(0), {alias}.DateOfService), {alias}.FirstIdentifiedOn)";

    /// <summary>
    /// The mockup's "Awaiting Payer Response" (MW_AWAITING_PAYER_FIX): the last note's fix /
    /// resolution means the ball is with the payer.
    /// </summary>
    internal static readonly string[] AwaitingPayerResolutions =
        ["Pending Payer Adjudication", "Resubmitted - E", "Resubmitted - F", "Resubmitted - P", "Reconsideration Submitted", "Appealed"];

    private readonly IReadOnlyDictionary<int, string> _labConnectionsById;
    private readonly string _masterConnectionString;

    public SqlArWorkbenchRepository(IConfiguration configuration)
    {
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster.");

        var labItems = configuration.GetSection("LabConfig:LabsID").Get<List<LabConfigItem>>() ?? [];
        _labConnectionsById = labItems
            .Where(x => x.Id > 0 && x.IsActive)
            .GroupBy(x => x.Id)
            .ToDictionary(g => g.Key, g => LabConnectionResolver.Resolve(configuration, g.First().Id, g.First().Name, g.First().ConnectionKey));
    }

    private sealed class LabConfigItem
    {
        public int Id { get; set; }
        public string Name { get; set; } = string.Empty;
        public string ConnectionKey { get; set; } = string.Empty;
        public bool IsActive { get; set; } = true;
    }

    private async Task<SqlConnection> OpenLabAsync(int labId, CancellationToken ct)
    {
        if (labId <= 0) throw new InvalidOperationException("LabId is required.");
        if (!_labConnectionsById.TryGetValue(labId, out var cs) || string.IsNullOrWhiteSpace(cs))
            throw new InvalidOperationException($"No lab database connection string is configured for LabId {labId}.");

        var connection = new SqlConnection(cs);
        await connection.OpenAsync(ct);

        await using var probe = new SqlCommand("SELECT OBJECT_ID(N'dbo.ARWB_Claim', N'U');", connection);
        if (await probe.ExecuteScalarAsync(ct) is null or DBNull)
        {
            await connection.DisposeAsync();
            throw new InvalidOperationException(
                $"AR Workbench tables are not installed for LabId {labId}. Run LRN.ReportsApi/Sql/ArWorkbench scripts 01-07 (or ARWB_Lab_Database_Setup_Merged.sql) in that lab database.");
        }
        return connection;
    }

    // ==========================================================================================
    // User context
    // ==========================================================================================

    /// <summary>
    /// Builds the user from the existing LRNMaster user tables (dbo.LabUsers, dbo.UserRoles,
    /// dbo.Roles, dbo.RoleFeatureAccess). Apart from the site admin roles (see siteAdminRole), ONLY
    /// the 8 "AR Workbench - ..." roles count. Returns null for a user who holds none of them.
    ///
    /// A site admin (Super Admin / Admin / LRN Admin for every lab, Lab Admin for their assigned
    /// labs) gets every permission and the whole lab, whatever AR Workbench roles they hold.
    ///
    /// Several AR Workbench roles combine: permissions are the union, and the widest scope wins
    /// (any unscoped role -> whole lab; otherwise clinic, then provider).
    /// </summary>
    public async Task<ArWorkbenchUserContext?> GetUserContextAsync(int labId, string userName, string? siteAdminRole, CancellationToken ct)
    {
        // Fail early with the setup message if the lab has not been prepared.
        await using (await OpenLabAsync(labId, ct)) { }

        const string sql = @"
DECLARE @LabUserID int =
(
    SELECT TOP (1) u.LabUserID
    FROM dbo.LabUsers u
    WHERE ISNULL(u.IsActive, 0) = 1 AND (u.UserName = @UserName OR u.Email = @UserName)
    ORDER BY CASE WHEN u.UserName = @UserName THEN 0 ELSE 1 END, u.LabUserID
);

SELECT u.LabUserID, u.UserName,
       NULLIF(LTRIM(RTRIM(CONCAT(ISNULL(u.FirstName, ''), ' ', ISNULL(u.LastName, '')))), '') AS DisplayName
FROM dbo.LabUsers u
WHERE u.LabUserID = @LabUserID;

-- The user's AR Workbench roles and each role's enabled ARWorkbench.* features.
SELECT r.RoleName, fa.FeatureKey
FROM dbo.UserRoles ur
INNER JOIN dbo.Roles r              ON r.RoleID  = ur.RoleID
INNER JOIN dbo.RoleFeatureAccess fa ON fa.RoleId = r.RoleID
WHERE ur.LabUserID = @LabUserID
  AND ISNULL(r.IsActive, 0) = 1
  AND r.RoleName LIKE @RolePrefix + N'%'
  AND fa.FeatureKey LIKE N'ARWorkbench.%'
  AND fa.IsEnabled = 1
ORDER BY r.RoleName;

IF OBJECT_ID(N'dbo.ARWB_UserScope', N'U') IS NOT NULL
    SELECT s.ClinicName, s.ProviderName
    FROM dbo.ARWB_UserScope s
    WHERE s.LabUserID = @LabUserID AND s.LabId = @LabId;
ELSE
    SELECT CAST(NULL AS nvarchar(500)) AS ClinicName, CAST(NULL AS nvarchar(500)) AS ProviderName WHERE 1 = 0;";

        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, master);
        cmd.Parameters.Add("@UserName", SqlDbType.NVarChar, 255).Value = userName.Trim();
        cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
        cmd.Parameters.Add("@RolePrefix", SqlDbType.NVarChar, 100).Value = ArWorkbenchFeatures.RolePrefix;
        await using var reader = await cmd.ExecuteReaderAsync(ct);

        var user = new ArWorkbenchUserContext { LabId = labId, UserName = userName, DisplayName = userName };
        if (await reader.ReadAsync(ct))
        {
            user.LabUserId = reader.GetInt32(0);
            user.UserName = reader.GetString(1);
            user.DisplayName = reader.IsDBNull(2) ? user.UserName : reader.GetString(2);
        }

        var roles = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var role = reader.GetString(0);
            if (!roles.TryGetValue(role, out var keys)) roles[role] = keys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            keys.Add(reader.GetString(1));
        }

        string? clinic = null, provider = null;
        await reader.NextResultAsync(ct);
        if (await reader.ReadAsync(ct))
        {
            clinic = reader.IsDBNull(0) ? null : reader.GetString(0);
            provider = reader.IsDBNull(1) ? null : reader.GetString(1);
        }

        // A role only counts once it has ARWorkbench.Access.
        var workbenchRoles = roles.Where(r => r.Value.Contains(ArWorkbenchFeatures.Access)).ToList();

        if (!string.IsNullOrWhiteSpace(siteAdminRole))
        {
            // Checked before the clinic / provider fail-closed below: a site admin who also holds a
            // viewer role must still see the whole lab.
            user.Permissions = new ArWorkbenchPermissions
            {
                Assign = true, EditClaim = true, QaDecide = true, Approve = true, ManageUsers = true,
                ViewAudit = true, ManageSettings = true, AllClients = true, ViewClientMgmt = true
            };
            user.Access = new ArWorkbenchAccessScope { Level = "client" };
            user.RoleCode = "admin";
            user.SiteAdmin = true;
            user.RoleNames = workbenchRoles.Select(r => DisplayRoleName(r.Key)).Prepend(siteAdminRole).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            user.RoleLabel = string.Join(", ", user.RoleNames);
            return user;
        }

        if (workbenchRoles.Count == 0) return null;

        var features = new HashSet<string>(workbenchRoles.SelectMany(r => r.Value), StringComparer.OrdinalIgnoreCase);
        user.Permissions = new ArWorkbenchPermissions
        {
            Assign = features.Contains(ArWorkbenchFeatures.Assign),
            EditClaim = features.Contains(ArWorkbenchFeatures.EditClaim),
            QaDecide = features.Contains(ArWorkbenchFeatures.QaDecide),
            Approve = features.Contains(ArWorkbenchFeatures.Approve),
            ManageUsers = features.Contains(ArWorkbenchFeatures.ManageUsers),
            ViewAudit = features.Contains(ArWorkbenchFeatures.ViewAudit),
            ManageSettings = features.Contains(ArWorkbenchFeatures.ManageSettings),
            AllClients = features.Contains(ArWorkbenchFeatures.AllClients),
            ViewClientMgmt = features.Contains(ArWorkbenchFeatures.ViewClientMgmt)
        };

        var anyUnscoped = workbenchRoles.Any(r => !r.Value.Contains(ArWorkbenchFeatures.ScopeClinic) && !r.Value.Contains(ArWorkbenchFeatures.ScopeProvider));
        if (anyUnscoped)
        {
            user.Access = new ArWorkbenchAccessScope { Level = "client" };
        }
        else if (features.Contains(ArWorkbenchFeatures.ScopeClinic) && !string.IsNullOrWhiteSpace(clinic))
        {
            user.Access = new ArWorkbenchAccessScope { Level = "clinic", Clinic = clinic };
        }
        else if (features.Contains(ArWorkbenchFeatures.ScopeProvider) && !string.IsNullOrWhiteSpace(provider))
        {
            user.Access = new ArWorkbenchAccessScope { Level = "provider", Provider = provider };
        }
        else
        {
            // Fails closed: a Clinic / Provider Viewer with no clinic / provider set for this lab
            // must not fall back to seeing the whole lab.
            throw new UnauthorizedAccessException(
                "Your AR Workbench role is limited to a clinic or provider, but none is set for you in this lab. Ask an administrator to set it.");
        }

        user.RoleNames = workbenchRoles.Select(r => DisplayRoleName(r.Key)).OrderBy(n => n).ToList();
        user.RoleCode = DeriveRoleCode(user.Permissions);
        user.RoleLabel = string.Join(", ", user.RoleNames);
        return user;
    }

    /// <summary>
    /// Mockup role (admin, manager, lead, agent, qa, viewer), derived from the combined permissions
    /// so dbo.RoleFeatureAccess is the one source of truth. Highest capability wins. The Team Lead
    /// can approve CIPs too (handoff 15.2), so a manager is Approve plus ViewAudit.
    /// </summary>
    private static string DeriveRoleCode(ArWorkbenchPermissions p)
        => p.ManageUsers ? "admin"
         : p.Approve && p.ViewAudit ? "manager"
         : p.Assign ? "lead"
         : p.QaDecide ? "qa"
         : p.EditClaim ? "agent"
         : "viewer";

    // "AR Workbench - RCM Manager" -> "RCM Manager"
    private static string DisplayRoleName(string roleName)
        => roleName.StartsWith(ArWorkbenchFeatures.RolePrefix, StringComparison.OrdinalIgnoreCase)
            ? roleName[ArWorkbenchFeatures.RolePrefix.Length..]
            : roleName;

    /// <summary>UserName -> "First Last" from dbo.LabUsers, for agent columns.</summary>
    private async Task<Dictionary<string, string>> GetDisplayNamesAsync(IEnumerable<string?> userNames, CancellationToken ct)
    {
        var names = userNames.Where(n => !string.IsNullOrWhiteSpace(n)).Select(n => n!).Distinct(StringComparer.OrdinalIgnoreCase).Take(1000).ToList();
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (names.Count == 0) return result;

        await using var master = new SqlConnection(_masterConnectionString);
        await master.OpenAsync(ct);
        await using var cmd = master.CreateCommand();
        var paramNames = new List<string>();
        for (var i = 0; i < names.Count; i++)
        {
            paramNames.Add("@U" + i);
            cmd.Parameters.Add("@U" + i, SqlDbType.NVarChar, 255).Value = names[i];
        }
        cmd.CommandText = $@"
SELECT u.UserName, NULLIF(LTRIM(RTRIM(CONCAT(ISNULL(u.FirstName, ''), ' ', ISNULL(u.LastName, '')))), '')
FROM dbo.LabUsers u
WHERE u.UserName IN ({string.Join(",", paramNames)});";

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            if (!reader.IsDBNull(1)) result[reader.GetString(0)] = reader.GetString(1);
        }
        return result;
    }

    // ==========================================================================================
    // Scope - applied to every claim-reading query
    // ==========================================================================================

    /// <summary>
    /// Client-level access is the whole lab here (each lab database is one client), and lab access is
    /// already checked by the controller, so only clinic and provider narrow further. An AR Agent
    /// sees only their own assigned caseload.
    /// </summary>
    private static string AppendScope(SqlCommand cmd, ArWorkbenchUserContext user, string alias = "w")
    {
        var level = (user.Access.Level ?? "all").ToLowerInvariant();
        var clauses = new List<string>();

        if (level == "clinic")
        {
            clauses.Add($"{alias}.ClinicName = @ScopeClinic");
            cmd.Parameters.Add("@ScopeClinic", SqlDbType.NVarChar, 500).Value = user.Access.Clinic ?? string.Empty;
        }
        else if (level == "provider")
        {
            clauses.Add($"{alias}.ReferringProvider = @ScopeProvider");
            cmd.Parameters.Add("@ScopeProvider", SqlDbType.NVarChar, 500).Value = user.Access.Provider ?? string.Empty;
        }

        if (string.Equals(user.RoleCode, "agent", StringComparison.OrdinalIgnoreCase))
        {
            clauses.Add($"{alias}.AssignedAgentUser = @ScopeAgent");
            cmd.Parameters.Add("@ScopeAgent", SqlDbType.NVarChar, 256).Value = user.UserName;
        }

        return clauses.Count == 0 ? string.Empty : " AND " + string.Join(" AND ", clauses);
    }

    // ==========================================================================================
    // Queues
    // ==========================================================================================

    public async Task<ArWorkbenchQueueSummary> GetQueueSummaryAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var scope = AppendScope(cmd, user);

        cmd.CommandText = $@"
SELECT QueueId, ParentQueueId, QueueLabel, IsPriority, SortOrder, BadgeClass
FROM dbo.ARWB_ArQueue
ORDER BY SortOrder;

SELECT w.ArQueueId, w.ArSubQueueId, COUNT(*) AS ClaimCount, SUM(w.RemainingAR) AS RemainingAR
FROM dbo.ARWB_Claim w
WHERE 1 = 1 {scope}
GROUP BY w.ArQueueId, w.ArSubQueueId;

SELECT
    COUNT(*),
    ISNULL(SUM(w.InitialInsuranceAR), 0),
    ISNULL(SUM(w.RecoveredAmount), 0),
    ISNULL(SUM(w.RemainingAR), 0),
    SUM(CASE WHEN w.WorkflowStatus = 'Unassigned' AND w.IsOpenInsuranceAR = 1 THEN 1 ELSE 0 END),
    SUM(CASE WHEN w.ArQueueId = 'submittedqa' THEN 1 ELSE 0 END),
    SUM(CASE WHEN w.IsRefollowupDue = 1 AND w.WorkflowStatus IN ('Assigned', 'QA Rejected', 'Completed') AND w.IsOpenInsuranceAR = 1 THEN 1 ELSE 0 END)
FROM dbo.ARWB_Claim w
WHERE 1 = 1 {scope};";

        var nodes = new Dictionary<string, ArWorkbenchQueueNode>(StringComparer.OrdinalIgnoreCase);
        var summary = new ArWorkbenchQueueSummary();

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var node = new ArWorkbenchQueueNode
            {
                QueueId = reader.GetString(0),
                ParentQueueId = reader.IsDBNull(1) ? null : reader.GetString(1),
                Label = reader.GetString(2),
                IsPriority = reader.GetBoolean(3),
                SortOrder = reader.GetInt32(4),
                BadgeClass = reader.IsDBNull(5) ? null : reader.GetString(5)
            };
            nodes[node.QueueId] = node;
        }

        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var count = reader.GetInt32(2);
            var ar = reader.IsDBNull(3) ? 0m : reader.GetDecimal(3);
            if (!reader.IsDBNull(0) && nodes.TryGetValue(reader.GetString(0), out var top))
            {
                top.ClaimCount += count;
                top.RemainingAR += ar;
            }
            if (!reader.IsDBNull(1) && nodes.TryGetValue(reader.GetString(1), out var sub))
            {
                sub.ClaimCount += count;
                sub.RemainingAR += ar;
            }
        }

        await reader.NextResultAsync(ct);
        if (await reader.ReadAsync(ct))
        {
            summary.TotalClaims = reader.GetInt32(0);
            summary.TotalInitialAR = reader.GetDecimal(1);
            summary.TotalRecovered = reader.GetDecimal(2);
            summary.TotalRemainingAR = reader.GetDecimal(3);
            summary.UnassignedOpen = reader.IsDBNull(4) ? 0 : reader.GetInt32(4);
            summary.AwaitingQa = reader.IsDBNull(5) ? 0 : reader.GetInt32(5);
            summary.RefollowupDue = reader.IsDBNull(6) ? 0 : reader.GetInt32(6);
        }

        foreach (var node in nodes.Values.Where(n => n.ParentQueueId is not null))
        {
            if (nodes.TryGetValue(node.ParentQueueId!, out var parent)) parent.Sub.Add(node);
        }
        summary.Queues = nodes.Values
            .Where(n => n.ParentQueueId is null)
            .OrderBy(n => n.SortOrder)
            .ToList();
        foreach (var top in summary.Queues) top.Sub = top.Sub.OrderBy(s => s.SortOrder).ToList();

        return summary;
    }

    // ==========================================================================================
    // Dashboard
    // ==========================================================================================

    // The mockup's denial category -> Key Observations tag and recommended action (DENIAL_CATEGORY_ACTION).
    private static readonly Dictionary<string, (string Tag, string Action)> DenialCategoryActions = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Additional Documentation Required"] = ("Appeal / MR", "Submit the requested medical records / documentation to the payer via the appropriate channel (portal, fax, etc.)."),
        ["Medical Necessity"] = ("Appeal / MR", "Review clinical documentation for medical necessity support and file an appeal with supporting notes."),
        ["Coding-Related Denials"] = ("Review", "Verify the CPT / modifier / diagnosis combination on file and rebill a corrected claim if warranted."),
        ["Eligibility Issues"] = ("Review", "Re-verify patient eligibility and coordination of benefits; rebill the correct payer if one is identified."),
        ["Authorization Required"] = ("Review", "Check whether a referral / prior authorization is on file; submit it with medical records if available, or adjust off if not."),
        ["Timely Filing"] = ("Appeal / MR", "Document proof of timely submission and file a timely-filing exception appeal."),
        ["Duplicate Claims"] = ("Review", "Confirm whether this is a true duplicate; void the claim or provide the original claim reference if not."),
        ["Payer Processing Issues"] = ("Review", "LRN currently investigating - contact the payer to confirm claim receipt and expedite processing."),
        ["Partially Paid Claims"] = ("Review", "Validate the expected allowable against the contract and file an underpayment appeal if warranted."),
        ["Unresponsive Payers"] = ("Review", "Escalate follow-up with the payer provider line; consider a formal status inquiry."),
        ["Other"] = ("Review", "Review payer remittance remarks and determine the appropriate corrective action.")
    };

    private static readonly string[] WorkflowStatusOrder = ["Unassigned", "Assigned", "Submitted for QA", "QA Rejected", "Completed"];

    /// <summary>
    /// Every tile, chart and table of the mockup's System Administrator dashboard in one round trip.
    /// All result sets carry the same scope clause, so a scoped user's dashboard only counts their claims.
    /// </summary>
    public async Task<ArWorkbenchDashboard> GetDashboardAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var scope = AppendScope(cmd, user);
        cmd.Parameters.Add("@Today", SqlDbType.Date).Value = DateTime.Today;

        cmd.CommandText = $@"
-- 0. KPI tiles
SELECT
    COUNT(*),
    SUM(CASE WHEN DATEDIFF(day, w.FirstBilledDate, @Today) BETWEEN 0 AND 7  THEN 1 ELSE 0 END),
    SUM(CASE WHEN DATEDIFF(day, w.FirstBilledDate, @Today) BETWEEN 8 AND 14 THEN 1 ELSE 0 END),
    ISNULL(SUM(w.RemainingAR), 0),
    SUM(CASE WHEN w.WorkflowStatus = 'Unassigned' THEN 1 ELSE 0 END),
    SUM(CASE WHEN w.WorkflowStatus = 'Assigned' THEN 1 ELSE 0 END),
    SUM(CASE WHEN w.WorkflowStatus = 'Submitted for QA' THEN 1 ELSE 0 END),
    SUM(CASE WHEN w.WorkflowStatus = 'QA Rejected' THEN 1 ELSE 0 END),
    SUM(CASE WHEN w.IsWorkComplete = 1 THEN 1 ELSE 0 END),
    ISNULL(SUM(w.RecoveredAmount), 0),
    ISNULL(SUM(CASE WHEN w.IsFinanciallyClosed = 0 THEN w.PotentialRecovery ELSE 0 END), 0),
    SUM(CASE WHEN w.NextFollowUpDate < @Today AND w.IsFinanciallyClosed = 0 THEN 1 ELSE 0 END),
    ISNULL(SUM(w.InitialInsuranceAR), 0),
    SUM(CASE WHEN w.WorkedStatus = 'Worked' THEN 1 ELSE 0 END)
FROM dbo.ARWB_Claim w
WHERE 1 = 1 {scope};

-- 1. Data refresh (latest successful load)
SELECT TOP (1) CompletedOn, SourcePeriodStart, SourcePeriodEnd
FROM dbo.ARWB_RefreshRun
WHERE RunStatus = 'Succeeded'
ORDER BY RefreshRunId DESC;

-- 2. Denial Category Distribution (outstanding balance)
SELECT ISNULL(NULLIF(w.DenialCategory, N''), N'Other'), COUNT(*), ISNULL(SUM(w.RemainingAR), 0)
FROM dbo.ARWB_Claim w
WHERE 1 = 1 {scope}
GROUP BY ISNULL(NULLIF(w.DenialCategory, N''), N'Other')
ORDER BY SUM(w.RemainingAR) DESC;

-- 3. AR Aging Distribution: bucket order from master data, then counts
SELECT ItemValue FROM dbo.ARWB_MasterListItem WHERE ListType = 'AGING_BUCKET' AND IsActive = 1 ORDER BY SortOrder;
SELECT w.AgingBucket, COUNT(*), ISNULL(SUM(w.RemainingAR), 0)
FROM dbo.ARWB_Claim w
WHERE w.AgingBucket IS NOT NULL {scope}
GROUP BY w.AgingBucket;

-- 4. Claim Workflow Status
SELECT w.WorkflowStatus, COUNT(*), ISNULL(SUM(w.RemainingAR), 0)
FROM dbo.ARWB_Claim w
WHERE 1 = 1 {scope}
GROUP BY w.WorkflowStatus;

-- 5. Claim Queue Volumes: workable leaves with an open insurance balance
SELECT w.ArQueueId, w.ArSubQueueId, t.QueueLabel, s.QueueLabel, COUNT(*), ISNULL(SUM(w.RemainingAR), 0)
FROM dbo.ARWB_Claim w
INNER JOIN dbo.ARWB_ArQueue t ON t.QueueId = w.ArQueueId
LEFT  JOIN dbo.ARWB_ArQueue s ON s.QueueId = w.ArSubQueueId
WHERE w.IsOpenInsuranceAR = 1 AND w.ArQueueId NOT IN ('closed', 'patientar') {scope}
GROUP BY w.ArQueueId, w.ArSubQueueId, t.QueueLabel, s.QueueLabel, t.SortOrder, s.SortOrder
ORDER BY t.SortOrder, s.SortOrder;

-- 6. AR Collections Progress: revenue expectation (initial insurance AR) per top-level queue
SELECT w.ArQueueId, t.QueueLabel, COUNT(*), ISNULL(SUM(w.InitialInsuranceAR), 0), ISNULL(SUM(w.RecoveredAmount), 0)
FROM dbo.ARWB_Claim w
INNER JOIN dbo.ARWB_ArQueue t ON t.QueueId = w.ArQueueId
WHERE 1 = 1 {scope}
GROUP BY w.ArQueueId, t.QueueLabel, t.SortOrder
ORDER BY t.SortOrder;

-- 7. Denial code highlights: open, still-unassigned claims grouped by PRIMARY denial code, so
--    assigned claims drop out of the insight (handoff 2.2)
SELECT w.PrimaryDenialCode, w.PayerName, w.DenialCategory, w.DenialReason, w.PanelName, COUNT(*), ISNULL(SUM(w.RemainingAR), 0)
FROM dbo.ARWB_Claim w
WHERE w.IsOpenInsuranceAR = 1 AND w.WorkflowStatus = 'Unassigned' AND w.PrimaryDenialCode IS NOT NULL {scope}
GROUP BY w.PrimaryDenialCode, w.PayerName, w.DenialCategory, w.DenialReason, w.PanelName;

-- 8. Agent Productivity
SELECT w.AssignedAgentUser,
       COUNT(*),
       SUM(CASE WHEN w.IsWorkComplete = 1 THEN 1 ELSE 0 END),
       SUM(CASE WHEN w.WorkflowStatus IN ('Submitted for QA', 'QA Rejected') THEN 1 ELSE 0 END),
       ISNULL(SUM(w.RecoveredAmount), 0)
FROM dbo.ARWB_Claim w
WHERE NULLIF(w.AssignedAgentUser, N'') IS NOT NULL {scope}
GROUP BY w.AssignedAgentUser
ORDER BY SUM(w.RecoveredAmount) DESC;";

        var d = new ArWorkbenchDashboard();
        static int Int(SqlDataReader r, int i) => r.IsDBNull(i) ? 0 : r.GetInt32(i);
        static decimal Dec(SqlDataReader r, int i) => r.IsDBNull(i) ? 0m : r.GetDecimal(i);
        static string? Str(SqlDataReader r, int i) => r.IsDBNull(i) ? null : r.GetString(i);

        await using var reader = await cmd.ExecuteReaderAsync(ct);

        if (await reader.ReadAsync(ct))
        {
            d.TotalClaims = Int(reader, 0);
            d.IdentifiedThisWeek = Int(reader, 1);
            d.IdentifiedLastWeek = Int(reader, 2);
            d.TotalOutstandingAR = Dec(reader, 3);
            d.Unassigned = Int(reader, 4);
            d.InProgress = Int(reader, 5);
            d.AwaitingQa = Int(reader, 6);
            d.QaRejected = Int(reader, 7);
            d.Completed = Int(reader, 8);
            d.TotalRecovered = Dec(reader, 9);
            d.PotentialRecovery = Dec(reader, 10);
            d.OverdueFollowUps = Int(reader, 11);
            d.TotalInitialAR = Dec(reader, 12);
            d.Worked = Int(reader, 13);
        }

        await reader.NextResultAsync(ct);
        if (await reader.ReadAsync(ct))
        {
            d.DataRefreshedOn = reader.IsDBNull(0) ? null : reader.GetDateTime(0);
            d.SourcePeriodStart = reader.IsDBNull(1) ? null : reader.GetDateTime(1);
            d.SourcePeriodEnd = reader.IsDBNull(2) ? null : reader.GetDateTime(2);
        }

        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var label = reader.GetString(0);
            d.DenialCategories.Add(new ArWorkbenchDashboardBar { Label = label, Key = label, Count = Int(reader, 1), Amount = Dec(reader, 2) });
        }

        await reader.NextResultAsync(ct);
        var bucketOrder = new List<string>();
        while (await reader.ReadAsync(ct)) bucketOrder.Add(reader.GetString(0));
        await reader.NextResultAsync(ct);
        var buckets = new Dictionary<string, ArWorkbenchDashboardBar>(StringComparer.OrdinalIgnoreCase);
        while (await reader.ReadAsync(ct))
        {
            var label = reader.GetString(0);
            buckets[label] = new ArWorkbenchDashboardBar { Label = label, Count = Int(reader, 1), Amount = Dec(reader, 2) };
        }
        // Every configured bucket shows (zero included) in master-data order; any bucket the
        // procedure wrote that is not in the list still shows, at the end.
        d.AgingBuckets = bucketOrder.Select(b => buckets.GetValueOrDefault(b) ?? new ArWorkbenchDashboardBar { Label = b })
            .Concat(buckets.Values.Where(b => !bucketOrder.Contains(b.Label, StringComparer.OrdinalIgnoreCase)))
            .ToList();

        await reader.NextResultAsync(ct);
        var statuses = new Dictionary<string, ArWorkbenchDashboardBar>(StringComparer.OrdinalIgnoreCase);
        while (await reader.ReadAsync(ct))
        {
            var label = reader.GetString(0);
            statuses[label] = new ArWorkbenchDashboardBar { Label = label, Key = label, Count = Int(reader, 1), Amount = Dec(reader, 2) };
        }
        d.WorkflowStatuses = WorkflowStatusOrder.Select(s => statuses.GetValueOrDefault(s) ?? new ArWorkbenchDashboardBar { Label = s, Key = s }).ToList();

        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var top = reader.GetString(0);
            var sub = Str(reader, 1);
            var subLabel = Str(reader, 3);
            d.QueueVolumes.Add(new ArWorkbenchDashboardBar
            {
                Label = subLabel is null ? reader.GetString(2) : $"{reader.GetString(2)} — {subLabel}",
                Key = $"{top}|{sub}",
                Count = Int(reader, 4),
                Amount = Dec(reader, 5)
            });
        }

        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            d.ArProgress.Add(new ArWorkbenchDashboardBar
            {
                Key = reader.GetString(0) + "|",
                Label = reader.GetString(1),
                Count = Int(reader, 2),
                Amount = Dec(reader, 3)
            });
        }

        await reader.NextResultAsync(ct);
        var highlightRows = new List<(string Code, string? Payer, string? Category, string? Reason, string? Panel, int Count, decimal Balance)>();
        while (await reader.ReadAsync(ct))
        {
            var codes = reader.GetString(0).Split([',', ';', '|'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            foreach (var code in codes.Distinct(StringComparer.OrdinalIgnoreCase))
                highlightRows.Add((code, Str(reader, 1), Str(reader, 2), Str(reader, 3), Str(reader, 4), Int(reader, 5), Dec(reader, 6)));
        }
        d.DenialHighlights = BuildDenialHighlights(highlightRows).Take(5).ToList();

        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            d.Agents.Add(new ArWorkbenchAgentProductivity
            {
                UserName = reader.GetString(0),
                Assigned = Int(reader, 1),
                Completed = Int(reader, 2),
                AwaitingReview = Int(reader, 3),
                Recovery = Dec(reader, 4)
            });
        }
        await reader.DisposeAsync();

        var names = await GetDisplayNamesAsync(d.Agents.Select(a => a.UserName), ct);
        foreach (var agent in d.Agents) agent.DisplayName = names.GetValueOrDefault(agent.UserName) ?? agent.UserName;

        return d;
    }

    /// <summary>
    /// The mockup's Key Observations rollup (App.buildDenialCodeHighlights): per denial code, claim
    /// count, open balance, the payer carrying the largest share, and the category's recommended
    /// action. The observation uses the most common panel, the service line on the claim.
    /// </summary>
    private static IEnumerable<ArWorkbenchDenialHighlight> BuildDenialHighlights(
        List<(string Code, string? Payer, string? Category, string? Reason, string? Panel, int Count, decimal Balance)> rows)
    {
        static string? MostCommon(IEnumerable<(string? Value, int Weight)> values)
            => values.Where(v => !string.IsNullOrWhiteSpace(v.Value))
                .GroupBy(v => v.Value!, StringComparer.OrdinalIgnoreCase)
                .OrderByDescending(g => g.Sum(v => v.Weight))
                .Select(g => g.Key)
                .FirstOrDefault();

        return rows
            .GroupBy(r => r.Code, StringComparer.OrdinalIgnoreCase)
            .Select(g =>
            {
                var balance = g.Sum(r => r.Balance);
                var topPayer = g.GroupBy(r => r.Payer ?? "Unknown payer", StringComparer.OrdinalIgnoreCase)
                    .Select(p => (Payer: p.Key, Balance: p.Sum(r => r.Balance)))
                    .OrderByDescending(p => p.Balance)
                    .First();
                var category = MostCommon(g.Select(r => (r.Category, r.Count))) ?? "Other";
                var action = DenialCategoryActions.GetValueOrDefault(category, DenialCategoryActions["Other"]);
                var panel = MostCommon(g.Select(r => (r.Panel, r.Count)));
                return new ArWorkbenchDenialHighlight
                {
                    Code = g.Key,
                    Description = MostCommon(g.Select(r => (r.Reason, r.Count))),
                    Count = g.Sum(r => r.Count),
                    Balance = balance,
                    TopPayer = topPayer.Payer,
                    TopPayerBalance = topPayer.Balance,
                    ImpactPct = balance > 0 ? topPayer.Balance / balance : 0,
                    Observation = $"Per review, the majority of denied claims are for {panel ?? "this service line"}.",
                    Category = action.Tag,
                    Action = action.Action
                };
            })
            .OrderByDescending(h => h.Balance);
    }

    // ==========================================================================================
    // Claims
    // ==========================================================================================

    public async Task<ArWorkbenchPagedResult<ArWorkbenchClaimRow>> GetClaimsAsync(ArWorkbenchClaimFilter filter, ArWorkbenchUserContext user, CancellationToken ct)
    {
        var page = Math.Max(1, filter.Page);
        var pageSize = Math.Clamp(filter.PageSize <= 0 ? 50 : filter.PageSize, 1, MaxPageSize);

        await using var connection = await OpenLabAsync(filter.LabId, ct);
        await using var cmd = connection.CreateCommand();

        var where = BuildClaimFilter(cmd, filter);
        var scope = AppendScope(cmd, user);
        var orderColumn = SortColumns.TryGetValue(filter.SortBy ?? string.Empty, out var col) ? col : "w.RemainingAR";
        var direction = filter.SortDesc ? "DESC" : "ASC";

        cmd.Parameters.Add("@Offset", SqlDbType.Int).Value = (page - 1) * pageSize;
        cmd.Parameters.Add("@PageSize", SqlDbType.Int).Value = pageSize;

        // Filter, count and page on the claim table, then read only the page's rows through the
        // worklist view (its QA / CIP / request lookups) and each claim's first CPT line.
        cmd.CommandText = $@"
SELECT COUNT(*) FROM dbo.ARWB_Claim w WHERE {where} {scope};

WITH pg AS
(
    SELECT w.ClaimKey, Seq = ROW_NUMBER() OVER (ORDER BY {orderColumn} {direction}, w.ClaimKey)
    FROM dbo.ARWB_Claim w
    WHERE {where} {scope}
    ORDER BY {orderColumn} {direction}, w.ClaimKey
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY
)
SELECT
    v.ClaimKey, v.ClaimID, v.LabName, v.PatientID, v.PatientName, v.PayerName, v.PayerType, v.ClinicName, v.ReferringProvider, v.PanelName,
    v.DateOfService, v.DenialCode, v.DenialCategory, v.DenialReason, v.SourceClaimStatus, v.ChargeAmount, v.InsuranceBalance, v.PatientBalance,
    v.InitialInsuranceAR, v.RevenueExpectation, v.RecoveredAmount, v.RemainingAR, v.WorkflowStatus, v.Priority, v.AssignedAgentUser,
    v.LastFollowUpDate, v.NextFollowUpDate, v.FixResolution, v.AgingDays, v.AgingBucket,
    v.IsTflRisk, v.IsNonCollectible, tw.HasNonCollectibleDenial, v.ArQueueId, v.ArQueueLabel, v.ArQueueBadgeClass,
    v.ArSubQueueId, v.ArSubQueueLabel, DATEDIFF(day, {UntouchedSinceSql("tw")}, SYSUTCDATETIME()) AS DaysSinceLastTouch,
    v.QaStatus, v.OpenCipCases, v.PendingAgentRequests,
    v.LineCount, cpt.CPTCode AS FirstCptCode
FROM pg
INNER JOIN dbo.ARWB_vw_ClaimWorklist v ON v.ClaimKey = pg.ClaimKey
INNER JOIN dbo.ARWB_Claim tw ON tw.ClaimKey = pg.ClaimKey
OUTER APPLY (SELECT TOP (1) l.CPTCode FROM dbo.ARWB_ClaimLine l WHERE l.ClaimKey = pg.ClaimKey ORDER BY l.LineNumber) cpt
ORDER BY pg.Seq;";

        var result = new ArWorkbenchPagedResult<ArWorkbenchClaimRow> { Page = page, PageSize = pageSize };
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (await reader.ReadAsync(ct)) result.TotalCount = reader.GetInt32(0);
        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            string? S(string name) => Str(reader, reader.GetOrdinal(name));
            DateTime? D(string name) => Date(reader, reader.GetOrdinal(name));
            decimal M(string name) => reader.GetDecimal(reader.GetOrdinal(name));
            int? N(string name) => Int(reader, reader.GetOrdinal(name));
            bool B(string name) => reader.GetBoolean(reader.GetOrdinal(name));

            result.Items.Add(new ArWorkbenchClaimRow
            {
                ClaimKey = reader.GetInt64(reader.GetOrdinal("ClaimKey")),
                ClaimID = S("ClaimID") ?? string.Empty,
                LabName = S("LabName"),
                PatientID = S("PatientID"),
                PatientName = S("PatientName"),
                PayerName = S("PayerName"),
                PayerType = S("PayerType"),
                ClinicName = S("ClinicName"),
                ReferringProvider = S("ReferringProvider"),
                PanelName = S("PanelName"),
                DateOfService = D("DateOfService"),
                DenialCode = S("DenialCode"),
                DenialCategory = S("DenialCategory"),
                DenialReason = S("DenialReason"),
                SourceClaimStatus = S("SourceClaimStatus"),
                ChargeAmount = M("ChargeAmount"),
                InsuranceBalance = M("InsuranceBalance"),
                PatientBalance = M("PatientBalance"),
                InitialInsuranceAR = M("InitialInsuranceAR"),
                RevenueExpectation = M("RevenueExpectation"),
                RecoveredAmount = M("RecoveredAmount"),
                RemainingAR = M("RemainingAR"),
                WorkflowStatus = S("WorkflowStatus") ?? string.Empty,
                Priority = S("Priority"),
                AssignedAgentUser = S("AssignedAgentUser"),
                LastFollowUpDate = D("LastFollowUpDate"),
                NextFollowUpDate = D("NextFollowUpDate"),
                FixResolution = S("FixResolution"),
                AgingDays = N("AgingDays"),
                AgingBucket = S("AgingBucket"),
                IsTflRisk = B("IsTflRisk"),
                IsNonCollectible = B("IsNonCollectible"),
                HasNonCollectibleDenial = B("HasNonCollectibleDenial"),
                ArQueueId = S("ArQueueId"),
                ArQueueLabel = S("ArQueueLabel"),
                ArQueueBadgeClass = S("ArQueueBadgeClass"),
                ArSubQueueId = S("ArSubQueueId"),
                ArSubQueueLabel = S("ArSubQueueLabel"),
                DaysSinceLastTouch = N("DaysSinceLastTouch"),
                QaStatus = S("QaStatus"),
                OpenCipCases = N("OpenCipCases") ?? 0,
                PendingAgentRequests = N("PendingAgentRequests") ?? 0,
                LineCount = N("LineCount") ?? 0,
                FirstCptCode = S("FirstCptCode")
            });
        }

        // Agent names live in LRNMaster.dbo.LabUsers, not in the lab database.
        await reader.DisposeAsync();
        var names = await GetDisplayNamesAsync(result.Items.Select(i => i.AssignedAgentUser), ct);
        foreach (var item in result.Items)
        {
            if (item.AssignedAgentUser is not null && names.TryGetValue(item.AssignedAgentUser, out var name))
                item.AssignedAgentName = name;
        }
        return result;
    }

    /// <summary>
    /// The Work Queue WHERE clause over dbo.ARWB_Claim (alias w). Each list filter is an IN over
    /// parameters; an empty list adds nothing ("All"). Values are trimmed, de-duplicated and capped.
    /// </summary>
    private static string BuildClaimFilter(SqlCommand cmd, ArWorkbenchClaimFilter filter)
    {
        var where = new List<string> { "1 = 1" };

        static List<string> Clean(IEnumerable<string>? values)
            => (values ?? [])
                .Where(v => !string.IsNullOrWhiteSpace(v))
                .Select(v => v.Trim())
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .Take(ArWorkbenchClaimFilter.MaxValuesPerFilter)
                .ToList();

        // nullToken: a value that stands for "column IS NULL" (no agent, no denial category, ...)
        void AddIn(string column, string prefix, IEnumerable<string>? values, int size, string? nullToken = null)
        {
            var list = Clean(values);
            if (list.Count == 0) return;
            var includeNull = nullToken is not null && list.Remove(nullToken);
            var names = new List<string>();
            for (var i = 0; i < list.Count; i++)
            {
                var name = $"@{prefix}{i}";
                names.Add(name);
                cmd.Parameters.Add(name, SqlDbType.NVarChar, size).Value = list[i];
            }
            var parts = new List<string>();
            if (names.Count > 0) parts.Add($"{column} IN ({string.Join(", ", names)})");
            if (includeNull) parts.Add($"{column} IS NULL");
            where.Add("(" + string.Join(" OR ", parts) + ")");
        }

        // AR queue leaves: "queue" or "queue|sub"
        var queues = Clean(filter.Queue);
        if (queues.Count > 0)
        {
            var parts = new List<string>();
            for (var i = 0; i < queues.Count; i++)
            {
                var pieces = queues[i].Split('|', 2);
                cmd.Parameters.Add($"@Q{i}", SqlDbType.VarChar, 40).Value = pieces[0];
                if (pieces.Length == 2 && pieces[1].Length > 0)
                {
                    cmd.Parameters.Add($"@QS{i}", SqlDbType.VarChar, 40).Value = pieces[1];
                    parts.Add($"(w.ArQueueId = @Q{i} AND w.ArSubQueueId = @QS{i})");
                }
                else
                {
                    parts.Add($"w.ArQueueId = @Q{i}");
                }
            }
            where.Add("(" + string.Join(" OR ", parts) + ")");
        }

        AddIn("w.WorkflowStatus", "St", filter.Status, 30);
        AddIn("w.PayerName", "Py", filter.Payer, 500, ArWorkbenchFilterValues.None);
        AddIn("w.DenialCategory", "Ca", filter.Category, 200, ArWorkbenchFilterValues.None);
        AddIn("w.AssignedAgentUser", "Ag", filter.Agent, 256, ArWorkbenchClaimFilter.UnassignedAgent);
        AddIn("w.Priority", "Pr", filter.Priority, 10);
        AddIn("w.AgingBucket", "Ab", filter.Aging, 50);
        AddIn("w.PanelName", "Pn", filter.Panel, 500, ArWorkbenchFilterValues.None);
        AddIn("w.ClinicName", "Cl", filter.Clinic, 500, ArWorkbenchFilterValues.None);

        if (filter.OpenInsuranceArOnly) where.Add("w.IsOpenInsuranceAR = 1");
        if (filter.TflRiskOnly) where.Add("w.IsTflRisk = 1");
        if (filter.AssignedOnly) where.Add("w.AssignedAgentUser IS NOT NULL");
        if (filter.FollowUpActionableOnly) where.Add("w.IsFollowUpActionable = 1");
        if (filter.ActiveOnly) where.Add("w.IsFinanciallyClosed = 0");
        if (filter.NonCollectibleOnly) where.Add("w.HasNonCollectibleDenial = 1");
        if (filter.AwaitingPayerOnly)
        {
            var names = new List<string>();
            for (var i = 0; i < AwaitingPayerResolutions.Length; i++)
            {
                names.Add($"@Ap{i}");
                cmd.Parameters.Add($"@Ap{i}", SqlDbType.NVarChar, 200).Value = AwaitingPayerResolutions[i];
            }
            where.Add($"w.FixResolution IN ({string.Join(", ", names)})");
        }
        switch ((filter.FollowUpWindow ?? string.Empty).Trim().ToLowerInvariant())
        {
            case "overdue": where.Add("w.NextFollowUpDate < CONVERT(date, SYSUTCDATETIME())"); break;
            case "today": where.Add("w.NextFollowUpDate = CONVERT(date, SYSUTCDATETIME())"); break;
            case "upcoming": where.Add("w.NextFollowUpDate > CONVERT(date, SYSUTCDATETIME())"); break;
            case "none": where.Add("w.NextFollowUpDate IS NULL"); break;
        }
        AddIn("w.FixResolution", "Fx", filter.FixResolution, 200, ArWorkbenchFilterValues.None);
        AddIn("w.SourceClaimStatus", "Ss", filter.SourceStatus, 200, ArWorkbenchFilterValues.None);
        if (filter.MinDaysUntouched is > 0)
        {
            where.Add($"{UntouchedSinceSql()} <= DATEADD(day, -@MinUntouched, SYSUTCDATETIME())");
            cmd.Parameters.Add("@MinUntouched", SqlDbType.Int).Value = Math.Min(filter.MinDaysUntouched.Value, 36_500);
        }
        if (!string.IsNullOrWhiteSpace(filter.Search))
        {
            where.Add("(w.ClaimID LIKE @Search OR w.PatientID LIKE @Search OR w.PatientName LIKE @Search OR w.AccessionNumber LIKE @Search OR w.DenialCode LIKE @Search OR w.ReferringProvider LIKE @Search)");
            cmd.Parameters.Add("@Search", SqlDbType.NVarChar, 210).Value = "%" + filter.Search.Trim().Replace("[", "[[]").Replace("%", "[%]").Replace("_", "[_]") + "%";
        }

        return string.Join(" AND ", where);
    }

    /// <summary>
    /// Option lists for every Work Queue filter popover, counted over the caller's scoped claims, so a
    /// clinic viewer or agent only sees values that exist in their own data.
    /// </summary>
    public async Task<ArWorkbenchFilterOptions> GetFilterOptionsAsync(int labId, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        var scope = AppendScope(cmd, user);

        cmd.CommandText = $@"
-- 0. AR queue leaves: a sub-queue, or a top-level queue that has none
SELECT CASE WHEN s.QueueId IS NULL THEN t.QueueId ELSE t.QueueId + '|' + s.QueueId END,
       CASE WHEN s.QueueId IS NULL THEN t.QueueLabel ELSE t.QueueLabel + N' · ' + s.QueueLabel END,
       ISNULL(cnt.Claims, 0)
FROM dbo.ARWB_ArQueue t
LEFT JOIN dbo.ARWB_ArQueue s ON s.ParentQueueId = t.QueueId
OUTER APPLY (SELECT Claims = COUNT(*) FROM dbo.ARWB_Claim w
             WHERE w.ArQueueId = t.QueueId AND (s.QueueId IS NULL OR w.ArSubQueueId = s.QueueId) {scope}) cnt
WHERE t.ParentQueueId IS NULL
ORDER BY t.SortOrder, s.SortOrder;

-- 1..5. Distinct values with counts (NULL is the 'none' option)
SELECT w.PayerName, COUNT(*) FROM dbo.ARWB_Claim w WHERE 1 = 1 {scope} GROUP BY w.PayerName ORDER BY w.PayerName;
SELECT w.PanelName, COUNT(*) FROM dbo.ARWB_Claim w WHERE 1 = 1 {scope} GROUP BY w.PanelName ORDER BY w.PanelName;
SELECT w.ClinicName, COUNT(*) FROM dbo.ARWB_Claim w WHERE 1 = 1 {scope} GROUP BY w.ClinicName ORDER BY w.ClinicName;
SELECT w.DenialCategory, COUNT(*) FROM dbo.ARWB_Claim w WHERE 1 = 1 {scope} GROUP BY w.DenialCategory ORDER BY w.DenialCategory;
SELECT w.AssignedAgentUser, COUNT(*) FROM dbo.ARWB_Claim w WHERE 1 = 1 {scope} GROUP BY w.AssignedAgentUser ORDER BY w.AssignedAgentUser;

-- 6..8. Fixed lists in master-data order, with counts
SELECT m.ItemValue, ISNULL(c.Claims, 0)
FROM dbo.ARWB_MasterListItem m
OUTER APPLY (SELECT Claims = COUNT(*) FROM dbo.ARWB_Claim w WHERE w.WorkflowStatus = m.ItemValue {scope}) c
WHERE m.ListType = 'WORKFLOW_STATUS' AND m.IsActive = 1 ORDER BY m.SortOrder;
SELECT p.Priority, ISNULL(c.Claims, 0)
FROM (VALUES ('High', 1), ('Medium', 2), ('Low', 3)) p (Priority, Ord)
OUTER APPLY (SELECT Claims = COUNT(*) FROM dbo.ARWB_Claim w WHERE w.Priority = p.Priority {scope}) c
ORDER BY p.Ord;
SELECT m.ItemValue, ISNULL(c.Claims, 0)
FROM dbo.ARWB_MasterListItem m
OUTER APPLY (SELECT Claims = COUNT(*) FROM dbo.ARWB_Claim w WHERE w.AgingBucket = m.ItemValue {scope}) c
WHERE m.ListType = 'AGING_BUCKET' AND m.IsActive = 1 ORDER BY m.SortOrder;

-- 9..10. Last note's fix / resolution, and the ingested source claim status
SELECT w.FixResolution, COUNT(*) FROM dbo.ARWB_Claim w WHERE 1 = 1 {scope} GROUP BY w.FixResolution ORDER BY w.FixResolution;
SELECT w.SourceClaimStatus, COUNT(*) FROM dbo.ARWB_Claim w WHERE 1 = 1 {scope} GROUP BY w.SourceClaimStatus ORDER BY w.SourceClaimStatus;";

        var options = new ArWorkbenchFilterOptions();
        await using var reader = await cmd.ExecuteReaderAsync(ct);

        async Task<List<ArWorkbenchFilterOption>> ReadAsync(string? noneValue = null, string? noneLabel = null)
        {
            var list = new List<ArWorkbenchFilterOption>();
            while (await reader.ReadAsync(ct))
            {
                var count = reader.GetInt32(reader.FieldCount - 1);
                if (reader.IsDBNull(0))
                {
                    if (noneValue is not null && count > 0)
                        list.Insert(0, new ArWorkbenchFilterOption { Value = noneValue, Label = noneLabel ?? "(blank)", Count = count });
                    continue;
                }
                var value = reader.GetString(0);
                var label = reader.FieldCount > 2 ? reader.GetString(1) : value;
                list.Add(new ArWorkbenchFilterOption { Value = value, Label = label, Count = count });
            }
            await reader.NextResultAsync(ct);
            return list;
        }

        options.Queues = await ReadAsync();
        options.Payers = await ReadAsync(ArWorkbenchFilterValues.None, "(No payer)");
        options.Panels = await ReadAsync(ArWorkbenchFilterValues.None, "(No panel)");
        options.Clinics = await ReadAsync(ArWorkbenchFilterValues.None, "(No clinic)");
        options.Categories = await ReadAsync(ArWorkbenchFilterValues.None, "(No denial)");
        options.Agents = await ReadAsync(ArWorkbenchClaimFilter.UnassignedAgent, "Unassigned");
        options.Statuses = await ReadAsync();
        options.Priorities = await ReadAsync();
        options.AgingBuckets = await ReadAsync();
        options.FixResolutions = await ReadAsync(ArWorkbenchFilterValues.None, "(No follow-up yet)");
        options.SourceStatuses = await ReadAsync(ArWorkbenchFilterValues.None, "(No status)");
        await reader.DisposeAsync();

        // Agent options show the person's name; the value stays the LabUsers.UserName.
        var names = await GetDisplayNamesAsync(options.Agents.Select(a => a.Value), ct);
        foreach (var a in options.Agents)
        {
            if (names.TryGetValue(a.Value, out var name)) a.Label = name;
        }
        return options;
    }

    public async Task<ArWorkbenchClaimDetail?> GetClaimDetailAsync(int labId, long claimKey, ArWorkbenchUserContext user, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = connection.CreateCommand();
        cmd.Parameters.Add("@ClaimKey", SqlDbType.BigInt).Value = claimKey;
        var scope = AppendScope(cmd, user);

        // The scope check runs once, on the claim row; the child queries only run for a claim the
        // caller is allowed to see.
        cmd.CommandText = $@"
DECLARE @Allowed bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.ARWB_Claim w WHERE w.ClaimKey = @ClaimKey {scope}) THEN 1 ELSE 0 END;

SELECT w.* FROM dbo.ARWB_vw_ClaimWorklist w WHERE w.ClaimKey = @ClaimKey AND @Allowed = 1;

SELECT t.TemplateLabel, s.StageOrder, s.StageName
FROM dbo.ARWB_Claim c
INNER JOIN dbo.ARWB_WorkflowTemplate t      ON t.TemplateKey = c.WorkflowTemplateKey
INNER JOIN dbo.ARWB_WorkflowTemplateStage s ON s.TemplateKey = t.TemplateKey
WHERE c.ClaimKey = @ClaimKey AND @Allowed = 1
ORDER BY s.StageOrder;

SELECT LineNumber, CPTCode, Units, Modifier, ChargeAmount, AllowedAmount, InsurancePayment, InsuranceAdjustments,
       InsuranceBalance, PatientBalance, LineClaimStatus, PayStatus, DenialCode, DenialDate, ICDCode
FROM dbo.ARWB_ClaimLine WHERE ClaimKey = @ClaimKey AND @Allowed = 1 ORDER BY LineNumber;

SELECT ActivityId, ActivityOn, ActionType, Detail, UserName, RoleCode, IsSystem
FROM dbo.ARWB_ClaimActivity WHERE ClaimKey = @ClaimKey AND @Allowed = 1 ORDER BY ActivityOn DESC, ActivityId DESC;

SELECT FollowUpId, ClaimType, FollowUpType, FollowUpClaimStatus, DenialRootCause, FixResolution, FollowUpComment,
       NextFollowUpDate, CreatedBy, CreatedOn
FROM dbo.ARWB_ClaimFollowUp WHERE ClaimKey = @ClaimKey AND @Allowed = 1 ORDER BY CreatedOn DESC;";

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;

        var detail = new ArWorkbenchClaimDetail();
        for (var i = 0; i < reader.FieldCount; i++)
            detail.Claim[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);

        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            detail.WorkflowTemplateLabel ??= reader.GetString(0);
            detail.WorkflowStages.Add(new ArWorkbenchTemplateStage { StageOrder = reader.GetByte(1), StageName = reader.GetString(2) });
        }

        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            detail.Lines.Add(new ArWorkbenchClaimLine
            {
                LineNumber = reader.GetInt32(0),
                CPTCode = Str(reader, 1),
                Units = reader.IsDBNull(2) ? null : reader.GetDecimal(2),
                Modifier = Str(reader, 3),
                ChargeAmount = reader.GetDecimal(4),
                AllowedAmount = reader.GetDecimal(5),
                InsurancePayment = reader.GetDecimal(6),
                InsuranceAdjustments = reader.GetDecimal(7),
                InsuranceBalance = reader.GetDecimal(8),
                PatientBalance = reader.GetDecimal(9),
                LineClaimStatus = Str(reader, 10),
                PayStatus = Str(reader, 11),
                DenialCode = Str(reader, 12),
                DenialDate = Date(reader, 13),
                ICDCode = Str(reader, 14)
            });
        }

        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            detail.Activity.Add(new ArWorkbenchActivity
            {
                ActivityId = reader.GetInt64(0),
                ActivityOn = reader.GetDateTime(1),
                ActionType = reader.GetString(2),
                Detail = Str(reader, 3),
                UserName = reader.GetString(4),
                RoleCode = Str(reader, 5),
                IsSystem = reader.GetBoolean(6)
            });
        }

        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            detail.FollowUps.Add(new ArWorkbenchFollowUp
            {
                FollowUpId = reader.GetInt64(0),
                ClaimType = Str(reader, 1),
                FollowUpType = Str(reader, 2),
                FollowUpClaimStatus = reader.GetString(3),
                DenialRootCause = Str(reader, 4),
                FixResolution = reader.GetString(5),
                FollowUpComment = Str(reader, 6),
                NextFollowUpDate = Date(reader, 7),
                CreatedBy = reader.GetString(8),
                CreatedOn = reader.GetDateTime(9)
            });
        }

        await reader.DisposeAsync();
        var agent = detail.Claim.TryGetValue("AssignedAgentUser", out var a) ? a as string : null;
        var names = await GetDisplayNamesAsync(new[] { agent }, ct);
        detail.Claim["AssignedAgentName"] = agent is not null && names.TryGetValue(agent, out var n) ? n : null;

        return detail;
    }

    // ==========================================================================================
    // Master data and data processing
    // ==========================================================================================

    public async Task<ArWorkbenchMasterData> GetMasterDataAsync(int labId, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        const string sql = @"
SELECT ListType, ItemValue FROM dbo.ARWB_MasterListItem WHERE IsActive = 1 ORDER BY ListType, SortOrder, ItemValue;
SELECT ClaimStatus, FixResolution FROM dbo.ARWB_FixResolutionByStatus ORDER BY ClaimStatus, SortOrder, FixResolution;
SELECT SettingKey, SettingValue FROM dbo.ARWB_AppSetting;";

        await using var cmd = new SqlCommand(sql, connection);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var data = new ArWorkbenchMasterData();

        while (await reader.ReadAsync(ct))
        {
            var type = reader.GetString(0);
            if (!data.Lists.TryGetValue(type, out var list)) data.Lists[type] = list = new List<string>();
            list.Add(reader.GetString(1));
        }
        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var status = reader.GetString(0);
            if (!data.FixResolutionsByStatus.TryGetValue(status, out var list)) data.FixResolutionsByStatus[status] = list = new List<string>();
            list.Add(reader.GetString(1));
        }
        await reader.NextResultAsync(ct);
        while (await reader.ReadAsync(ct)) data.Settings[reader.GetString(0)] = reader.GetString(1);

        return data;
    }

    public async Task<IReadOnlyList<ArWorkbenchRefreshRun>> GetRefreshRunsAsync(int labId, int top, CancellationToken ct)
    {
        await using var connection = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand(RefreshRunSelect("TOP (@Top)") + " ORDER BY RefreshRunId DESC;", connection);
        cmd.Parameters.Add("@Top", SqlDbType.Int).Value = Math.Clamp(top, 1, 100);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var rows = new List<ArWorkbenchRefreshRun>();
        while (await reader.ReadAsync(ct)) rows.Add(ReadRefreshRun(reader));
        return rows;
    }

    public async Task<ArWorkbenchRefreshRun?> RunRefreshAsync(int labId, string runBy, string? note, CancellationToken ct, bool reprocessAll = false)
    {
        await using var connection = await OpenLabAsync(labId, ct);

        // The load can take minutes on a large lab. Run it to completion, then read the run row back.
        await using (var cmd = new SqlCommand("dbo.ARWB_usp_LoadClaimsFromSource", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 1800 })
        {
            cmd.Parameters.Add("@RunBy", SqlDbType.NVarChar, 256).Value = runBy;
            cmd.Parameters.Add("@Note", SqlDbType.NVarChar, 1000).Value = (object?)note ?? DBNull.Value;
            cmd.Parameters.Add("@ReprocessAll", SqlDbType.Bit).Value = reprocessAll;
            await cmd.ExecuteNonQueryAsync(ct);
        }

        await using var read = new SqlCommand(RefreshRunSelect("TOP (1)") + " ORDER BY RefreshRunId DESC;", connection);
        await using var reader = await read.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? ReadRefreshRun(reader) : null;
    }

    private static string RefreshRunSelect(string top) => $@"
SELECT {top} RefreshRunId, SourceRunId, SourceFileName, SourcePeriodStart, SourcePeriodEnd, RunStatus, StartedOn, CompletedOn,
       SourceClaimRows, SourceLineRows, ClaimsInserted, ClaimsUpdated, ClaimsUnchanged, ClaimsNoLongerInSource, ClaimsLinesReloaded,
       RunBy, ErrorMessage
FROM dbo.ARWB_RefreshRun";

    private static ArWorkbenchRefreshRun ReadRefreshRun(SqlDataReader r) => new()
    {
        RefreshRunId = r.GetInt32(0),
        SourceRunId = Str(r, 1),
        SourceFileName = Str(r, 2),
        SourcePeriodStart = Date(r, 3),
        SourcePeriodEnd = Date(r, 4),
        RunStatus = r.GetString(5),
        StartedOn = r.GetDateTime(6),
        CompletedOn = Date(r, 7),
        SourceClaimRows = Int(r, 8),
        SourceLineRows = Int(r, 9),
        ClaimsInserted = Int(r, 10),
        ClaimsUpdated = Int(r, 11),
        ClaimsUnchanged = Int(r, 12),
        ClaimsNoLongerInSource = Int(r, 13),
        ClaimsLinesReloaded = Int(r, 14),
        RunBy = Str(r, 15),
        ErrorMessage = Str(r, 16)
    };

    private static string? Str(SqlDataReader r, int i) => r.IsDBNull(i) ? null : r.GetString(i);
    private static DateTime? Date(SqlDataReader r, int i) => r.IsDBNull(i) ? null : r.GetDateTime(i);
    private static int? Int(SqlDataReader r, int i) => r.IsDBNull(i) ? null : r.GetInt32(i);
}
