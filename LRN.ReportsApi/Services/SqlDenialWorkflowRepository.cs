using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

public sealed class SqlDenialWorkflowRepository : IDenialWorkflowRepository
{
	private readonly IConfiguration _configuration;
	private readonly string _masterConnectionString;
	private readonly IReadOnlyDictionary<int, string> _labNamesById;
	private readonly IReadOnlyDictionary<int, string> _labConnectionsById;

	public SqlDenialWorkflowRepository(IConfiguration configuration)
	{
		_configuration = configuration;
		_masterConnectionString = configuration.GetConnectionString("DefaultConnection")
			?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster.");

		var labItems = configuration.GetSection("LabConfig:LabsID").Get<List<LabConfigItem>>() ?? [];
		if (labItems.Count == 0) labItems = DefaultActiveLabs();

		_labNamesById = labItems
			.Where(x => x.Id > 0 && x.IsActive && !string.IsNullOrWhiteSpace(x.Name))
			.GroupBy(x => x.Id)
			.ToDictionary(g => g.Key, g => g.First().Name.Trim());

		_labConnectionsById = labItems
			.Where(x => x.Id > 0 && x.IsActive)
			.GroupBy(x => x.Id)
			.ToDictionary(g => g.Key, g => ResolveLabConnectionString(configuration, g.First().Id, g.First().Name, g.First().ConnectionKey));
	}

	private SqlConnection OpenMaster() => new(_masterConnectionString);

	private SqlConnection OpenLab(int labId)
	{
		if (labId <= 0) throw new InvalidOperationException("LabId is required.");
		if (_labConnectionsById.TryGetValue(labId, out var conn) && !string.IsNullOrWhiteSpace(conn))
			return new SqlConnection(conn);

		throw new InvalidOperationException($"No lab database connection string is configured for LabId {labId}. Add LabConfig:LabsID and a matching ConnectionStrings entry.");
	}

	public Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsAsync(CancellationToken ct)
	{
		IReadOnlyList<DenialWorkflowLabOption> rows = _labNamesById
			.OrderBy(x => x.Value)
			.ThenBy(x => x.Key)
			.Select(x => new DenialWorkflowLabOption { LabId = x.Key, LabName = x.Value })
			.ToList();
		return Task.FromResult(rows);
	}

	public async Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsForUserAsync(string userName, CancellationToken ct)
	{
		if (string.IsNullOrWhiteSpace(userName))
			return await GetLabsAsync(ct);

		const string sql = @"
IF OBJECT_ID('dbo.UserLabs') IS NOT NULL AND OBJECT_ID('dbo.LabUsers') IS NOT NULL
BEGIN
    SELECT DISTINCT CAST(ul.LabId AS int) AS LabId
    FROM dbo.UserLabs ul
    INNER JOIN dbo.LabUsers u ON u.LabUserID = ul.LabUserID
    WHERE ISNULL(u.IsActive,0)=1
      AND (ISNULL(u.UserName,'')=@UserName OR ISNULL(u.Email,'')=@UserName)
    ORDER BY LabId;
END";

		var allowedIds = new HashSet<int>();
		await using var con = OpenMaster();
		await con.OpenAsync(ct);
		await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
		cmd.Parameters.AddWithValue("@UserName", userName.Trim());
		await using var rd = await cmd.ExecuteReaderAsync(ct);
		while (await rd.ReadAsync(ct))
		{
			var id = GetInt(rd, "LabId");
			if (id > 0) allowedIds.Add(id);
		}

		var allLabs = await GetLabsAsync(ct);
		if (allowedIds.Count == 0) return allLabs;
		return allLabs.Where(x => allowedIds.Contains(x.LabId)).ToList();
	}

	public async Task<DenialWorkflowDashboardSummary> GetDashboardSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct)
	{
		var where = BuildCommonWhere(filter, "t", includeStatus: true, includeAssigned: true);
		var sql = $@"
IF OBJECT_ID('tempdb..#TaskBoardBase') IS NOT NULL DROP TABLE #TaskBoardBase;

SELECT
    InsuranceBalance = ISNULL(t.InsuranceBalance, 0),
    StatusValue = LTRIM(RTRIM(ISNULL(t.Status, ''))),
    DenialClassification = COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.DenialClassification, ''))), ''), 'Unclassified'),
    AssignedTo = COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo, ''))), ''), 'Unassigned'),
    ActionCategory = LTRIM(RTRIM(ISNULL(t.ActionCategory, ''))),
    DueDate = t.DueDate
INTO #TaskBoardBase
FROM dbo.DenialTaskBoard t
WHERE (t.LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) {where.WhereClause};

SELECT
    TotalDenials = COUNT(1),
    OutstandingAmount = ISNULL(SUM(InsuranceBalance), 0),
    OpenInProgressCount = SUM(CASE WHEN LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END),
    ClosedCount = SUM(CASE WHEN LOWER(StatusValue) IN ('closed', 'completed') THEN 1 ELSE 0 END)
FROM #TaskBoardBase;

;WITH ClassRaw AS
(
    SELECT
        Classification = DenialClassification,
        [Count] = COUNT(1),
        Outstanding = ISNULL(SUM(InsuranceBalance), 0),
        [Open] = SUM(CASE WHEN LOWER(StatusValue) IN ('', 'new', 'open', 'pending review', 'verification pending') THEN 1 ELSE 0 END),
        InProgress = SUM(CASE WHEN LOWER(StatusValue) IN ('in-progress', 'in progress', 'progress') OR LOWER(StatusValue) LIKE '%progress%' THEN 1 ELSE 0 END),
        Closed = SUM(CASE WHEN LOWER(StatusValue) IN ('closed', 'completed') THEN 1 ELSE 0 END)
    FROM #TaskBoardBase
    GROUP BY DenialClassification
), Tot AS
(
    SELECT TotalCount = NULLIF(SUM([Count]), 0) FROM ClassRaw
)
SELECT
    Classification,
    [Count],
    Outstanding,
    [Open],
    InProgress,
    Closed,
    PercentageOfTotal = CAST(CASE WHEN Tot.TotalCount IS NULL THEN 0 ELSE ([Count] * 100.0 / Tot.TotalCount) END AS decimal(9,2))
FROM ClassRaw
CROSS JOIN Tot
ORDER BY [Count] DESC, Outstanding DESC;

;WITH ActionRaw AS
(
    SELECT
        ActionCategory = COALESCE(NULLIF(ActionCategory, ''), 'Unclassified'),
        [Count] = COUNT(1),
        Outstanding = ISNULL(SUM(InsuranceBalance), 0)
    FROM #TaskBoardBase
    GROUP BY COALESCE(NULLIF(ActionCategory, ''), 'Unclassified')
), ActionTot AS
(
    SELECT TotalCount = NULLIF(SUM([Count]), 0) FROM ActionRaw
)
SELECT
    ActionCategory,
    [Count],
    Outstanding,
    PercentageOfTotal = CAST(CASE WHEN ActionTot.TotalCount IS NULL THEN 0 ELSE ([Count] * 100.0 / ActionTot.TotalCount) END AS decimal(9,2))
FROM ActionRaw
CROSS JOIN ActionTot
ORDER BY [Count] DESC, Outstanding DESC;

SELECT
    ReviewerName = AssignedTo,
    TotalAssigned = COUNT(1),
    Closed = SUM(CASE WHEN LOWER(StatusValue) IN ('closed', 'completed') THEN 1 ELSE 0 END),
    Pending = SUM(CASE WHEN LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END)
FROM #TaskBoardBase
GROUP BY AssignedTo
ORDER BY CASE WHEN AssignedTo = 'Unassigned' THEN 0 ELSE 1 END, TotalAssigned DESC;

;WITH Sla AS
(
    SELECT
        SortOrder = 1,
        Label = 'Appeal SLA',
        [Count] = SUM(CASE WHEN ActionCategory LIKE '%Appeal%' THEN 1 ELSE 0 END),
        [Status] = CASE WHEN SUM(CASE WHEN ActionCategory LIKE '%Appeal%' AND DueDate IS NOT NULL AND CAST(DueDate AS date) < CAST(GETDATE() AS date) AND LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END) > 0
                        THEN CONCAT(SUM(CASE WHEN ActionCategory LIKE '%Appeal%' AND DueDate IS NOT NULL AND CAST(DueDate AS date) < CAST(GETDATE() AS date) AND LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END), ' overdue')
                        ELSE 'On Track' END
    FROM #TaskBoardBase
    UNION ALL
    SELECT
        2,
        'Rebill SLA',
        SUM(CASE WHEN ActionCategory LIKE '%Rebill%' THEN 1 ELSE 0 END),
        CASE WHEN SUM(CASE WHEN ActionCategory LIKE '%Rebill%' AND DueDate IS NOT NULL AND CAST(DueDate AS date) < CAST(GETDATE() AS date) AND LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END) > 0
             THEN CONCAT(SUM(CASE WHEN ActionCategory LIKE '%Rebill%' AND DueDate IS NOT NULL AND CAST(DueDate AS date) < CAST(GETDATE() AS date) AND LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END), ' overdue')
             ELSE 'On Track' END
    FROM #TaskBoardBase
    UNION ALL
    SELECT
        3,
        'Write-off SLA',
        SUM(CASE WHEN ActionCategory LIKE '%Write%' OR ActionCategory LIKE '%Write-off%' OR ActionCategory LIKE '%Write Off%' THEN 1 ELSE 0 END),
        CASE WHEN SUM(CASE WHEN (ActionCategory LIKE '%Write%' OR ActionCategory LIKE '%Write-off%' OR ActionCategory LIKE '%Write Off%') AND DueDate IS NOT NULL AND CAST(DueDate AS date) < CAST(GETDATE() AS date) AND LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END) > 0
             THEN CONCAT(SUM(CASE WHEN (ActionCategory LIKE '%Write%' OR ActionCategory LIKE '%Write-off%' OR ActionCategory LIKE '%Write Off%') AND DueDate IS NOT NULL AND CAST(DueDate AS date) < CAST(GETDATE() AS date) AND LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END), ' overdue')
             ELSE 'On Track' END
    FROM #TaskBoardBase
    UNION ALL
    SELECT
        4,
        'Appeal Success Rate',
        CAST(CASE WHEN SUM(CASE WHEN ActionCategory LIKE '%Appeal%' THEN 1 ELSE 0 END) = 0 THEN 0
                  ELSE SUM(CASE WHEN ActionCategory LIKE '%Appeal%' AND LOWER(StatusValue) IN ('closed', 'completed') THEN 1 ELSE 0 END) * 100.0 / SUM(CASE WHEN ActionCategory LIKE '%Appeal%' THEN 1 ELSE 0 END)
             END AS int),
        'closed claims'
    FROM #TaskBoardBase
)
SELECT Label, ISNULL([Count], 0) [Count], [Status]
FROM Sla
ORDER BY SortOrder;

DROP TABLE #TaskBoardBase;";
		var result = new DenialWorkflowDashboardSummary();
		var cls = new List<DenialClassificationSummaryRow>();
		var reviewers = new List<ReviewerWorkflowSummaryRow>();
		var actions = new List<ActionCategorySummaryRow>();
		var sla = new List<SlaSummaryRow>();
		await using var con = OpenLab(filter.LabId); await con.OpenAsync(ct);
		await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
		AddFilterParams(cmd, filter); AddExtraParams(cmd, where.Parameters);
		await using var rd = await cmd.ExecuteReaderAsync(ct);
		if (await rd.ReadAsync(ct))
		{
			result.TotalDenials = GetInt(rd, "TotalDenials");
			result.OutstandingAmount = GetDecimal(rd, "OutstandingAmount");
			result.OpenInProgressCount = GetInt(rd, "OpenInProgressCount");
			result.ClosedCount = GetInt(rd, "ClosedCount");
		}
		if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) cls.Add(new DenialClassificationSummaryRow { Classification = GetString(rd, "Classification"), Count = GetInt(rd, "Count"), Outstanding = GetDecimal(rd, "Outstanding"), Open = GetInt(rd, "Open"), InProgress = GetInt(rd, "InProgress"), Closed = GetInt(rd, "Closed"), PercentageOfTotal = GetDecimal(rd, "PercentageOfTotal") });
		if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) actions.Add(new ActionCategorySummaryRow { ActionCategory = GetString(rd, "ActionCategory"), Count = GetInt(rd, "Count"), Outstanding = GetDecimal(rd, "Outstanding"), PercentageOfTotal = GetDecimal(rd, "PercentageOfTotal") });
		if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) reviewers.Add(new ReviewerWorkflowSummaryRow { ReviewerName = GetString(rd, "ReviewerName"), TotalAssigned = GetInt(rd, "TotalAssigned"), Closed = GetInt(rd, "Closed"), Pending = GetInt(rd, "Pending") });
		if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) sla.Add(new SlaSummaryRow { Label = GetString(rd, "Label"), Count = GetInt(rd, "Count"), Status = GetString(rd, "Status") });
		result.DenialClassifications = cls; result.ActionCategories = actions; result.AnalystWorkload = reviewers; result.SlaTiles = sla;
		return result;
	}

	public async Task<DenialWorkflowFilterOptions> GetFilterOptionsAsync(int labId, CancellationToken ct)
	{
		const string sql = @"
SELECT DISTINCT LTRIM(RTRIM(ISNULL(Status,''))) Value FROM dbo.DenialTaskBoard WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) AND NULLIF(LTRIM(RTRIM(ISNULL(Status,''))),'') IS NOT NULL ORDER BY Value;
SELECT DISTINCT LTRIM(RTRIM(ISNULL(ActionCategory,''))) Value FROM dbo.DenialTaskBoard WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) AND NULLIF(LTRIM(RTRIM(ISNULL(ActionCategory,''))),'') IS NOT NULL ORDER BY Value;
SELECT DISTINCT LTRIM(RTRIM(ISNULL(Priority,''))) Value FROM dbo.DenialTaskBoard WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) AND NULLIF(LTRIM(RTRIM(ISNULL(Priority,''))),'') IS NOT NULL ORDER BY Value;
SELECT DISTINCT TOP (200) LTRIM(RTRIM(ISNULL(DenialCode,''))) Value FROM dbo.DenialTaskBoard WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) AND NULLIF(LTRIM(RTRIM(ISNULL(DenialCode,''))),'') IS NOT NULL ORDER BY Value;
SELECT DISTINCT TOP (300) LTRIM(RTRIM(ISNULL(PayerName,''))) Value FROM dbo.DenialTaskBoard WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) AND NULLIF(LTRIM(RTRIM(ISNULL(PayerName,''))),'') IS NOT NULL ORDER BY Value;";
		var result = new DenialWorkflowFilterOptions();
		await using var con = OpenLab(labId); await con.OpenAsync(ct);
		await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
		cmd.Parameters.AddWithValue("@LabId", labId);
		await using var rd = await cmd.ExecuteReaderAsync(ct);
		result.Statuses = await ReadStringListAsync(rd, ct);
		await rd.NextResultAsync(ct); result.ActionCategories = await ReadStringListAsync(rd, ct);
		await rd.NextResultAsync(ct); result.Priorities = await ReadStringListAsync(rd, ct);
		await rd.NextResultAsync(ct); result.DenialCodes = await ReadStringListAsync(rd, ct);
		await rd.NextResultAsync(ct); result.PayerNames = await ReadStringListAsync(rd, ct);
		return result;
	}

	public async Task<IReadOnlyList<ReviewerOption>> GetReviewerOptionsAsync(int labId, CancellationToken ct)
	{
		const string sql = @"
SELECT DISTINCT
    lu.LabUserID,
    ISNULL(lu.UserName, '') AS UserName,
    LTRIM(RTRIM(CONCAT(ISNULL(lu.FirstName, ''), ' ', ISNULL(lu.LastName, '')))) AS DisplayName
FROM dbo.LabUsers lu
LEFT JOIN dbo.UserRoles ur ON lu.LabUserID = ur.LabUserID
LEFT JOIN dbo.UserLabs ul ON lu.LabUserID = ul.LabUserID
WHERE (@LabId <= 0 OR ul.LabId = @LabId)
  AND ur.RoleID = 5
ORDER BY DisplayName, UserName;";
		var rows = new List<ReviewerOption>();
		await using var con = OpenMaster();
		await con.OpenAsync(ct);
		await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
		cmd.Parameters.AddWithValue("@LabId", labId);
		await using var rd = await cmd.ExecuteReaderAsync(ct);
		while (await rd.ReadAsync(ct))
		{
			var displayName = GetString(rd, "DisplayName");
			var userName = GetString(rd, "UserName");
			rows.Add(new ReviewerOption
			{
				LabUserId = GetInt(rd, "LabUserID"),
				UserName = userName,
				DisplayName = string.IsNullOrWhiteSpace(displayName) ? userName : displayName,
				Email = string.Empty
			});
		}
		return rows;
	}

	public async Task<IReadOnlyList<WorkflowTaskRow>> GetActiveTasksAsync(int labId, CancellationToken ct)
	{
		var filter = new DenialWorkflowFilter { LabId = labId, Page = 1, PageSize = 500000 };
		return (await GetTasksAsync(filter, ct)).Items;
	}

	public async Task<IReadOnlyList<WorkflowTaskRow>> GetHistoryTasksByUidAsync(int labId, IEnumerable<string> uniqueTrackIds, CancellationToken ct)
	{
		var keys = uniqueTrackIds.Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
		if (keys.Count == 0) return [];
		var sql = $@"SELECT h.TaskID, h.UniqueTrackId, h.LabId, h.RunId, h.NewStatus Status, h.NewAssignedTo AssignedTo, h.Comments ReviewerComments,
               '' ClaimID, '' PatientId, '' CPTCode, '' DenialCode, '' DenialDescription, '' DenialClassification, '' ActionCode, '' RecommendedAction, '' ActionCategory, '' Task, '' Priority, CAST(0 AS decimal(18,2)) InsuranceBalance,
               CAST(NULL AS date) DateOpened, CAST(NULL AS date) DueDate, CAST(NULL AS date) DateCompleted, '' SLAStatus, '' LabName, CAST(NULL AS datetime2) CreatedOn,
               '' SalesRepname, '' ClinicName, '' ReferringProvider, '' PayerName, '' PayerNameNormalized, NULL PayerCode, '' PayerType, NULL FirstBilledDate, NULL ChargeEnteredDate, '' BillingProvider, '' PanelName, NULL DateOfService, NULL ReviewerUpdatedOn, '' ReviewerUpdatedBy
FROM dbo.DenialTaskHistory h
JOIN (SELECT UniqueTrackId, MAX(HistoryId) HistoryId FROM dbo.DenialTaskHistory WHERE LabId=@LabId GROUP BY UniqueTrackId) latest ON latest.HistoryId=h.HistoryId
WHERE h.LabId=@LabId AND h.UniqueTrackId IN ({string.Join(',', keys.Select((_, i) => "@p" + i))})";
		var rows = new List<WorkflowTaskRow>();
		await using var con = OpenLab(labId); await con.OpenAsync(ct);
		await using var cmd = new SqlCommand(sql, con); cmd.Parameters.AddWithValue("@LabId", labId);
		for (var i = 0; i < keys.Count; i++) cmd.Parameters.AddWithValue("@p" + i, keys[i]);
		await using var rd = await cmd.ExecuteReaderAsync(ct);
		while (await rd.ReadAsync(ct)) rows.Add(ReadTask(rd));
		return rows;
	}

	public async Task<DenialWorkflowSummary> GetSummaryAsync(int labId, string role, string userName, CancellationToken ct)
	{
		var reviewerWhere = IsReviewerOnly(role) ? " AND ISNULL(AssignedTo,'')=@UserName" : "";
		var verificationReviewerWhere = IsReviewerOnly(role) ? " AND ISNULL(AssignedTo,'')=@UserName" : "";
		var sql = $@"
SELECT
Assigned = SUM(CASE WHEN ISNULL(AssignedTo,'')<>'' AND ISNULL(Status,'') NOT IN ('Closed','Completed') THEN 1 ELSE 0 END),
Completed = SUM(CASE WHEN ISNULL(Status,'') IN ('Closed','Completed') THEN 1 ELSE 0 END),
Pending = SUM(CASE WHEN ISNULL(Status,'') NOT IN ('Closed','Completed') THEN 1 ELSE 0 END),
Unassigned = SUM(CASE WHEN ISNULL(AssignedTo,'')='' AND ISNULL(Status,'') NOT IN ('Closed','Completed') THEN 1 ELSE 0 END)
FROM dbo.DenialTaskBoard WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) {reviewerWhere};
SELECT VerificationPending = COUNT(1) FROM dbo.DenialVerificationTask WHERE LabId=@LabId {verificationReviewerWhere};";
		await using var con = OpenLab(labId); await con.OpenAsync(ct);
		await using var cmd = new SqlCommand(sql, con); cmd.Parameters.AddWithValue("@LabId", labId); cmd.Parameters.AddWithValue("@UserName", userName ?? string.Empty);
		var s = new DenialWorkflowSummary();
		await using var rd = await cmd.ExecuteReaderAsync(ct);
		if (await rd.ReadAsync(ct)) { s.Assigned = GetInt(rd, "Assigned"); s.Completed = GetInt(rd, "Completed"); s.Pending = GetInt(rd, "Pending"); s.Unassigned = GetInt(rd, "Unassigned"); }
		if (await rd.NextResultAsync(ct) && await rd.ReadAsync(ct)) s.VerificationPending = GetInt(rd, "VerificationPending");
		return s;
	}

	public async Task<IReadOnlyList<ReviewerWorkflowSummaryRow>> GetReviewerSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct)
	{
		var sql = @"SELECT ReviewerName = COALESCE(NULLIF(AssignedTo,''), 'Unassigned'),
TotalAssigned = COUNT(1),
Closed = SUM(CASE WHEN ISNULL(Status,'') IN ('Closed','Completed') THEN 1 ELSE 0 END),
Pending = SUM(CASE WHEN ISNULL(Status,'') NOT IN ('Closed','Completed') THEN 1 ELSE 0 END)
FROM dbo.DenialTaskBoard
WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId))
GROUP BY COALESCE(NULLIF(AssignedTo,''), 'Unassigned')
ORDER BY TotalAssigned DESC;";
		var rows = new List<ReviewerWorkflowSummaryRow>();
		await using var con = OpenLab(filter.LabId); await con.OpenAsync(ct);
		await using var cmd = new SqlCommand(sql, con); cmd.Parameters.AddWithValue("@LabId", filter.LabId);
		await using var rd = await cmd.ExecuteReaderAsync(ct);
		while (await rd.ReadAsync(ct)) rows.Add(new ReviewerWorkflowSummaryRow { ReviewerName = GetString(rd, "ReviewerName"), TotalAssigned = GetInt(rd, "TotalAssigned"), Closed = GetInt(rd, "Closed"), Pending = GetInt(rd, "Pending") });
		return rows;
	}

	public async Task<PagedResult<DenialWorkflowInsightRow>> GetInsightsAsync(DenialWorkflowFilter filter, CancellationToken ct)
	{
		filter.PageSize = 100; if (filter.Page <= 0) filter.Page = 1;
		var where = BuildCommonWhere(filter, "i", includeStatus: false, includeAssigned: true);
		var sql = $@"
SELECT COUNT(1) FROM dbo.DenialInsight i WHERE (ISNULL(i.LabId,@LabId)=@LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialInsight WHERE ISNULL(LabId,@LabId)=@LabId)) {where.WhereClause};
SELECT i.DenialCodes,i.Descriptions,i.NoOfDenialCount,i.NoOfClaimsCount,i.TotalBalance,i.HighImpactInsurance,i.InsuranceBalance,i.ImpactPercentage,i.ActionCategory,i.ActionCode,i.Action,i.Task,i.Feedback,i.Responsibility,i.DiscussionDate,i.ETA,i.LabName,i.LabId,i.RunId,i.CreatedOn,i.AssignedTo,i.ResponsibilityReviewer
FROM dbo.DenialInsight i
WHERE (ISNULL(i.LabId,@LabId)=@LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialInsight WHERE ISNULL(LabId,@LabId)=@LabId)) {where.WhereClause}
ORDER BY i.InsuranceBalance DESC, i.DenialCodes
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;";
		var result = new PagedResult<DenialWorkflowInsightRow> { Page = filter.Page, PageSize = filter.PageSize };
		await using var con = OpenLab(filter.LabId); await con.OpenAsync(ct);
		await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 }; AddFilterParams(cmd, filter); AddExtraParams(cmd, where.Parameters); AddPagingParams(cmd, filter);
		await using var rd = await cmd.ExecuteReaderAsync(ct);
		if (await rd.ReadAsync(ct)) result.TotalCount = rd[0] == DBNull.Value ? 0 : Convert.ToInt32(rd[0]);
		if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) result.Items.Add(ReadInsight(rd));
		return result;
	}

	public async Task<PagedResult<WorkflowTaskRow>> GetTasksAsync(DenialWorkflowFilter filter, CancellationToken ct)
	{
		filter.PageSize = filter.PageSize <= 0 ? 100 : Math.Min(filter.PageSize, 500000); if (filter.Page <= 0) filter.Page = 1;
		var where = BuildCommonWhere(filter, "t", includeStatus: true, includeAssigned: true);
		var sql = $@"
SELECT COUNT(1) FROM dbo.DenialTaskBoard t WHERE (t.LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) {where.WhereClause};
SELECT t.TaskID,t.UniqueTrackId,t.ClaimID,t.PatientId,t.CPTCode,t.DenialCode,t.DenialDescription,t.DenialClassification,t.ActionCode,t.RecommendedAction,t.ActionCategory,t.Task,t.Priority,t.InsuranceBalance,t.IsCurrentDenial,t.SLADays,t.Status,t.DateOpened,t.DueDate,t.DateCompleted,t.DaysRemaining,t.SLAStatus,t.AssignedTo,t.LabId,t.LabName,t.RunId,t.CreatedOn,t.SalesRepname,t.ClinicName,t.ReferringProvider,t.PayerName,t.PayerNameNormalized,t.PayerCode,t.PayerType,t.FirstBilledDate,t.ChargeEnteredDate,t.BillingProvider,t.PanelName,t.DateOfService,t.ReviewerComments,t.ReviewerUpdatedOn,t.ReviewerUpdatedBy
FROM dbo.DenialTaskBoard t
WHERE (t.LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) {where.WhereClause}
ORDER BY CASE WHEN ISNULL(t.AssignedTo,'')='' THEN 0 ELSE 1 END, t.DueDate, t.TaskID
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;";
		var result = new PagedResult<WorkflowTaskRow> { Page = filter.Page, PageSize = filter.PageSize };
		await using var con = OpenLab(filter.LabId); await con.OpenAsync(ct);
		await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 }; AddFilterParams(cmd, filter); AddExtraParams(cmd, where.Parameters); AddPagingParams(cmd, filter);
		await using var rd = await cmd.ExecuteReaderAsync(ct);
		if (await rd.ReadAsync(ct)) result.TotalCount = rd[0] == DBNull.Value ? 0 : Convert.ToInt32(rd[0]);
		if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) result.Items.Add(ReadTask(rd));
		return result;
	}

	public async Task<PagedResult<VerificationTaskRow>> GetVerificationAsync(
  DenialWorkflowFilter filter,
  CancellationToken ct)
	{
		filter.PageSize = 100;

		if (filter.Page <= 0)
			filter.Page = 1;

		var where = BuildCommonWhere(filter, "v", includeStatus: true, includeAssigned: true);

		var sql = $@"
			IF OBJECT_ID('dbo.DenialVerificationTask') IS NULL
			BEGIN
			SELECT CAST(0 AS int) TotalCount;
			SELECT TOP 0
				CAST(NULL AS bigint) VerificationId,
				CAST('' AS nvarchar(100)) TaskID;

			RETURN;
			END;

			SELECT COUNT(1)
			FROM dbo.DenialVerificationTask v
			WHERE (v.LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialVerificationTask WHERE LabId = @LabId)) {where.WhereClause};

			SELECT
			v.VerificationId,
			v.TaskID,
			v.UniqueTrackId,
			v.ClaimID,
			v.PatientId,
			v.CPTCode,
			v.DenialCode,
			v.DenialDescription,
			v.DenialClassification,
			v.ActionCode,
			v.RecommendedAction,
			v.ActionCategory,
			v.Task,
			v.Priority,
			v.InsuranceBalance,
			v.IsCurrentDenial,
			v.SLADays,
			v.Status,
			v.DateOpened,
			v.DueDate,
			v.DateCompleted,
			v.DaysRemaining,
			v.SLAStatus,
			v.AssignedTo,
			v.LabId,
			v.LabName,
			v.RunId,
			v.CreatedOn,
			v.SalesRepname,
			v.ClinicName,
			v.ReferringProvider,
			v.PayerName,
			v.PayerNameNormalized,
			v.PayerCode,
			v.PayerType,
			v.FirstBilledDate,
			v.ChargeEnteredDate,
			v.BillingProvider,
			v.PanelName,
			v.DateOfService,
			v.ReviewerComments,
			v.ReviewerUpdatedOn,
			v.ReviewerUpdatedBy,


			VerificationStatus =
				CASE
					WHEN COL_LENGTH('dbo.DenialVerificationTask','VerificationStatus') IS NOT NULL
					THEN v.VerificationStatus
					ELSE ''
				END,

			VerificationComments =
				CASE
					WHEN COL_LENGTH('dbo.DenialVerificationTask','VerificationComments') IS NOT NULL
					THEN v.VerificationComments
					ELSE ''
				END,

			OriginalRunId =
				CASE
					WHEN COL_LENGTH('dbo.DenialVerificationTask','OriginalRunId') IS NOT NULL
					THEN v.OriginalRunId
					ELSE ''
				END,

			MissingDetectedRunId =
				CASE
					WHEN COL_LENGTH('dbo.DenialVerificationTask','MissingDetectedRunId') IS NOT NULL
					THEN v.MissingDetectedRunId
					ELSE ''
				END,

			MovedOn =
				CASE
					WHEN COL_LENGTH('dbo.DenialVerificationTask','MovedOn') IS NOT NULL
					THEN v.MovedOn
					ELSE NULL
				END,

			VerifiedBy =
				CASE
					WHEN COL_LENGTH('dbo.DenialVerificationTask','VerifiedBy') IS NOT NULL
					THEN v.VerifiedBy
					ELSE ''
				END,

			VerifiedOn =
				CASE
					WHEN COL_LENGTH('dbo.DenialVerificationTask','VerifiedOn') IS NOT NULL
					THEN v.VerifiedOn
					ELSE NULL
				END


			FROM dbo.DenialVerificationTask v
			WHERE (v.LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialVerificationTask WHERE LabId = @LabId)) {where.WhereClause}

			ORDER BY
			v.VerificationId DESC

			OFFSET @Offset ROWS
			FETCH NEXT @PageSize ROWS ONLY;
			";

		var result = new PagedResult<VerificationTaskRow>
		{
			Page = filter.Page,
			PageSize = filter.PageSize
		};

		await using var con = OpenLab(filter.LabId);

		await con.OpenAsync(ct);

		await using var cmd = new SqlCommand(sql, con)
		{
			CommandTimeout = 180
		};

		AddFilterParams(cmd, filter);
		AddExtraParams(cmd, where.Parameters);
		AddPagingParams(cmd, filter);

		await using var rd = await cmd.ExecuteReaderAsync(ct);

		if (await rd.ReadAsync(ct))
			result.TotalCount = rd[0] == DBNull.Value ? 0 : Convert.ToInt32(rd[0]);

		if (await rd.NextResultAsync(ct))
		{
			while (await rd.ReadAsync(ct))
				result.Items.Add(ReadVerification(rd));
		}

		return result;
	}


	public async Task UpsertActiveTaskAsync(DenialTaskImportRow row, WorkflowTaskRow? existing, int labId, string labName, string runId, string taskId, CancellationToken ct)
	{
		const string sql = @"IF EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId=@LabId AND UniqueTrackId=@UniqueTrackId)
UPDATE dbo.DenialTaskBoard SET RunId=@RunId, LabName=@LabName, ClaimID=@ClaimID, PatientId=@PatientId, CPTCode=@CPTCode, DenialCode=@DenialCode, DenialDescription=@DenialDescription, DenialClassification=@DenialClassification, ActionCode=@ActionCode, RecommendedAction=@RecommendedAction, ActionCategory=@ActionCategory, Task=@Task, Priority=@Priority, InsuranceBalance=@InsuranceBalance, SLADays=@SLADays, DueDate=@DueDate, SalesRepname=@SalesRepname, ClinicName=@ClinicName, ReferringProvider=@ReferringProvider, PayerName=@PayerName, PayerNameNormalized=@PayerNameNormalized, PayerCode=@PayerCode, PayerType=@PayerType, FirstBilledDate=@FirstBilledDate, ChargeEnteredDate=@ChargeEnteredDate, BillingProvider=@BillingProvider, PanelName=@PanelName, DateOfService=@DateOfService WHERE LabId=@LabId AND UniqueTrackId=@UniqueTrackId
ELSE
INSERT INTO dbo.DenialTaskBoard(TaskID,UniqueTrackId,ClaimID,PatientId,CPTCode,DenialCode,DenialDescription,DenialClassification,ActionCode,RecommendedAction,ActionCategory,Task,Priority,InsuranceBalance,IsCurrentDenial,SLADays,Status,DateOpened,DueDate,AssignedTo,LabId,LabName,RunId,CreatedOn,SalesRepname,ClinicName,ReferringProvider,PayerName,PayerNameNormalized,PayerCode,PayerType,FirstBilledDate,ChargeEnteredDate,BillingProvider,PanelName,DateOfService)
VALUES(@TaskID,@UniqueTrackId,@ClaimID,@PatientId,@CPTCode,@DenialCode,@DenialDescription,@DenialClassification,@ActionCode,@RecommendedAction,@ActionCategory,@Task,@Priority,@InsuranceBalance,1,@SLADays,'New',@DateOpened,@DueDate,'',@LabId,@LabName,@RunId,SYSDATETIME(),@SalesRepname,@ClinicName,@ReferringProvider,@PayerName,@PayerNameNormalized,@PayerCode,@PayerType,@FirstBilledDate,@ChargeEnteredDate,@BillingProvider,@PanelName,@DateOfService);";
		await using var con = OpenLab(labId); await con.OpenAsync(ct); await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 }; AddTaskParams(cmd, row, labId, labName, runId, taskId); await cmd.ExecuteNonQueryAsync(ct);
	}

	public async Task MoveActiveToVerificationAsync(WorkflowTaskRow task, string currentRunId, string reason, CancellationToken ct)
	{
		const string sql = @"INSERT INTO dbo.DenialVerificationTask(TaskID,UniqueTrackId,ClaimID,PatientId,CPTCode,DenialCode,DenialDescription,DenialClassification,ActionCode,RecommendedAction,ActionCategory,Task,Priority,InsuranceBalance,IsCurrentDenial,SLADays,Status,DateOpened,DueDate,DateCompleted,DaysRemaining,SLAStatus,AssignedTo,LabId,LabName,RunId,CreatedOn,SalesRepname,ClinicName,ReferringProvider,PayerName,PayerNameNormalized,PayerCode,PayerType,FirstBilledDate,ChargeEnteredDate,BillingProvider,PanelName,DateOfService,ReviewerComments,ReviewerUpdatedOn,ReviewerUpdatedBy,VerificationStatus,VerificationComments,OriginalRunId,MissingDetectedRunId,MovedOn)
SELECT TaskID,UniqueTrackId,ClaimID,PatientId,CPTCode,DenialCode,DenialDescription,DenialClassification,ActionCode,RecommendedAction,ActionCategory,Task,Priority,InsuranceBalance,IsCurrentDenial,SLADays,'Verification Pending',DateOpened,DueDate,DateCompleted,DaysRemaining,SLAStatus,AssignedTo,LabId,LabName,RunId,CreatedOn,SalesRepname,ClinicName,ReferringProvider,PayerName,PayerNameNormalized,PayerCode,PayerType,FirstBilledDate,ChargeEnteredDate,BillingProvider,PanelName,DateOfService,ReviewerComments,ReviewerUpdatedOn,ReviewerUpdatedBy,'Verification Pending',@Reason,RunId,@CurrentRunId,SYSDATETIME()
FROM dbo.DenialTaskBoard WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) AND TaskID=@TaskID;
DELETE FROM dbo.DenialTaskBoard WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) AND TaskID=@TaskID;";
		await using var con = OpenLab(task.LabId); await con.OpenAsync(ct); await using var cmd = new SqlCommand(sql, con); cmd.Parameters.AddWithValue("@LabId", task.LabId); cmd.Parameters.AddWithValue("@TaskID", task.TaskId); cmd.Parameters.AddWithValue("@Reason", reason); cmd.Parameters.AddWithValue("@CurrentRunId", currentRunId); await cmd.ExecuteNonQueryAsync(ct);
	}

	public async Task MoveActiveToHistoryAsync(WorkflowTaskRow task, string actionType, string actionBy, string comments, CancellationToken ct)
	{
		await InsertHistoryAsync(task.TaskId, task.UniqueTrackId, task.LabId, task.RunId, actionType, task.Status, task.Status, task.AssignedTo, task.AssignedTo, comments, actionBy, string.Empty, ct);
		await using var con = OpenLab(task.LabId); await con.OpenAsync(ct); await using var cmd = new SqlCommand("DELETE FROM dbo.DenialTaskBoard WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) AND TaskID=@TaskID", con); cmd.Parameters.AddWithValue("@LabId", task.LabId); cmd.Parameters.AddWithValue("@TaskID", task.TaskId); await cmd.ExecuteNonQueryAsync(ct);
	}

	public async Task InsertHistoryAsync(string taskId, string uniqueTrackId, int labId, string runId, string actionType, string oldStatus, string newStatus, string oldAssignedTo, string newAssignedTo, string comments, string actionBy, string snapshotJson, CancellationToken ct)
	{
		const string sql = @"INSERT INTO dbo.DenialTaskHistory(TaskID,UniqueTrackId,LabId,RunId,ActionType,OldStatus,NewStatus,OldAssignedTo,NewAssignedTo,Comments,ActionBy,ActionDate,SnapshotJson) VALUES(@TaskID,@UniqueTrackId,@LabId,@RunId,@ActionType,@OldStatus,@NewStatus,@OldAssignedTo,@NewAssignedTo,@Comments,@ActionBy,SYSDATETIME(),@SnapshotJson);";
		await using var con = OpenLab(labId); await con.OpenAsync(ct); await using var cmd = new SqlCommand(sql, con); cmd.Parameters.AddWithValue("@TaskID", taskId); cmd.Parameters.AddWithValue("@UniqueTrackId", uniqueTrackId); cmd.Parameters.AddWithValue("@LabId", labId); cmd.Parameters.AddWithValue("@RunId", runId); cmd.Parameters.AddWithValue("@ActionType", actionType); cmd.Parameters.AddWithValue("@OldStatus", oldStatus); cmd.Parameters.AddWithValue("@NewStatus", newStatus); cmd.Parameters.AddWithValue("@OldAssignedTo", oldAssignedTo); cmd.Parameters.AddWithValue("@NewAssignedTo", newAssignedTo); cmd.Parameters.AddWithValue("@Comments", comments); cmd.Parameters.AddWithValue("@ActionBy", actionBy); cmd.Parameters.AddWithValue("@SnapshotJson", snapshotJson); await cmd.ExecuteNonQueryAsync(ct);
	}

	public async Task<int> AssignByInsightAsync(AssignInsightRequest request, CancellationToken ct)
	{
		const string sql = @"UPDATE dbo.DenialTaskBoard SET AssignedTo=@ReviewerUserName, Status=CASE WHEN ISNULL(Status,'') IN ('','New') THEN 'Pending Review' ELSE Status END, ReviewerUpdatedBy=@ActionBy, ReviewerUpdatedOn=SYSDATETIME() WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) AND DenialCode=@DenialCode AND ISNULL(PayerName,'')=@PayerName AND (@RunId='' OR RunId=@RunId);";
		await using var con = OpenLab(request.LabId); await con.OpenAsync(ct); await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 }; cmd.Parameters.AddWithValue("@LabId", request.LabId); cmd.Parameters.AddWithValue("@ReviewerUserName", request.ReviewerUserName); cmd.Parameters.AddWithValue("@ActionBy", request.ActionBy); cmd.Parameters.AddWithValue("@DenialCode", request.DenialCode); cmd.Parameters.AddWithValue("@PayerName", request.PayerName); cmd.Parameters.AddWithValue("@RunId", request.RunId ?? string.Empty); return await cmd.ExecuteNonQueryAsync(ct);
	}

	public async Task<int> UpdateTaskAsync(UpdateTaskRequest request, bool isClosed, bool isDuplicate, CancellationToken ct)
	{
		if (isDuplicate)
		{
			var task = (await GetTasksAsync(new DenialWorkflowFilter { LabId = request.LabId, SearchText = request.TaskId, Page = 1, PageSize = 1 }, ct)).Items.FirstOrDefault();
			if (task is null) return 0;
			await MoveActiveToVerificationAsync(task, request.TaskId, request.Comments, ct);
			return 1;
		}
		const string sql = @"UPDATE dbo.DenialTaskBoard SET Status=@Status, ReviewerComments=@Comments, ReviewerUpdatedBy=@ActionBy, ReviewerUpdatedOn=SYSDATETIME(), DateCompleted=CASE WHEN @Status IN ('Closed','Completed') THEN CONVERT(date,GETDATE()) ELSE DateCompleted END WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId = @LabId)) AND TaskID=@TaskID;";
		await using var con = OpenLab(request.LabId); await con.OpenAsync(ct); await using var cmd = new SqlCommand(sql, con); cmd.Parameters.AddWithValue("@LabId", request.LabId); cmd.Parameters.AddWithValue("@TaskID", request.TaskId); cmd.Parameters.AddWithValue("@Status", request.Status); cmd.Parameters.AddWithValue("@Comments", request.Comments ?? string.Empty); cmd.Parameters.AddWithValue("@ActionBy", request.ActionBy ?? string.Empty); return await cmd.ExecuteNonQueryAsync(ct);
	}

	public async Task<int> DecideVerificationAsync(VerificationDecisionRequest request, bool isClosed, CancellationToken ct)
	{
		var sql = request.IsValidDenial
			? @"INSERT INTO dbo.DenialTaskBoard(TaskID,UniqueTrackId,ClaimID,PatientId,CPTCode,DenialCode,DenialDescription,DenialClassification,ActionCode,RecommendedAction,ActionCategory,Task,Priority,InsuranceBalance,IsCurrentDenial,SLADays,Status,DateOpened,DueDate,DateCompleted,DaysRemaining,SLAStatus,AssignedTo,LabId,LabName,RunId,CreatedOn,SalesRepname,ClinicName,ReferringProvider,PayerName,PayerNameNormalized,PayerCode,PayerType,FirstBilledDate,ChargeEnteredDate,BillingProvider,PanelName,DateOfService,ReviewerComments,ReviewerUpdatedOn,ReviewerUpdatedBy)
SELECT TaskID,UniqueTrackId,ClaimID,PatientId,CPTCode,DenialCode,DenialDescription,DenialClassification,ActionCode,RecommendedAction,ActionCategory,Task,Priority,InsuranceBalance,1,SLADays,CASE WHEN @Status='' THEN 'Pending Review' ELSE @Status END,DateOpened,DueDate,NULL,NULL,SLAStatus,AssignedTo,LabId,LabName,RunId,SYSDATETIME(),SalesRepname,ClinicName,ReferringProvider,PayerName,PayerNameNormalized,PayerCode,PayerType,FirstBilledDate,ChargeEnteredDate,BillingProvider,PanelName,DateOfService,@Comments,SYSDATETIME(),@ActionBy FROM dbo.DenialVerificationTask WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialVerificationTask WHERE LabId = @LabId)) AND VerificationId=@VerificationId;
DELETE FROM dbo.DenialVerificationTask WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialVerificationTask WHERE LabId = @LabId)) AND VerificationId=@VerificationId;"
			: @"UPDATE dbo.DenialVerificationTask SET VerificationStatus='Closed', VerificationComments=@Comments, VerifiedOn=SYSDATETIME(), VerifiedBy=@ActionBy WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialVerificationTask WHERE LabId = @LabId)) AND VerificationId=@VerificationId; DELETE FROM dbo.DenialVerificationTask WHERE (LabId = @LabId OR NOT EXISTS (SELECT 1 FROM dbo.DenialVerificationTask WHERE LabId = @LabId)) AND VerificationId=@VerificationId;";
		await using var con = OpenLab(request.LabId); await con.OpenAsync(ct); await using var cmd = new SqlCommand(sql, con); cmd.Parameters.AddWithValue("@LabId", request.LabId); cmd.Parameters.AddWithValue("@VerificationId", request.VerificationId); cmd.Parameters.AddWithValue("@Status", request.Status ?? string.Empty); cmd.Parameters.AddWithValue("@Comments", request.Comments ?? string.Empty); cmd.Parameters.AddWithValue("@ActionBy", request.ActionBy ?? string.Empty); return await cmd.ExecuteNonQueryAsync(ct);
	}


	private static string ResolveLabConnectionString(IConfiguration configuration, int labId, string labName, string? connectionKey = null)
	{
		// First allow an exact per-lab override: ConnectionStrings:Lab_{LabId}
		var byId = configuration.GetConnectionString($"Lab_{labId}");
		if (!string.IsNullOrWhiteSpace(byId)) return byId;

		// Preferred LRN Metrics mapping: LabId -> ConnectionKey -> ConnectionStrings entry.
		if (!string.IsNullOrWhiteSpace(connectionKey))
		{
			var byConnectionKey = configuration.GetConnectionString(connectionKey.Trim());
			if (!string.IsNullOrWhiteSpace(byConnectionKey)) return byConnectionKey;
		}

		var normalized = NormalizeKey(labName);
		var knownKey = normalized switch
		{
			"PCRLABSOFAMERICA" or "PCRLOA" => "PCRLOAConnStr",
			"COVE" => "CoveConnection",
			"INHEALTHDTR" or "INHEALTH" => "InHealthConn",
			"ELIXIR" => "ElixirConnection",
			"CERTUS" or "CERTUSLABORATORIES" => "CertusConnection",
			"BEECHTREE" => "BeechTreeConnStr",
			"AUGUSTUSLABS" or "AUGUSTUS" => "AugustusConnStr",
			"NORTHWEST" or "NWL" => "NWLConnection",
			"PCRDXAL" => "PCRALConnection",
			"PCRDXCO" => "PCRDxConnection",
			"PHILIFE" => "PhiLifeConnStr",
			"RISINGTIDES" => "RisingTidesConnStr",
			_ => string.Empty
		};

		if (!string.IsNullOrWhiteSpace(knownKey))
		{
			var conn = configuration.GetConnectionString(knownKey);
			if (!string.IsNullOrWhiteSpace(conn)) return conn;
		}

		foreach (var section in configuration.GetSection("ConnectionStrings").GetChildren())
		{
			var key = NormalizeKey(section.Key);
			if (key.Contains(normalized, StringComparison.OrdinalIgnoreCase) || normalized.Contains(key.Replace("CONNECTION", "").Replace("CONNSTR", ""), StringComparison.OrdinalIgnoreCase))
				return section.Value ?? string.Empty;
		}

		return string.Empty;
	}

	private static string NormalizeKey(string value)
		=> new string((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

	private sealed class LabConfigItem
	{
		public int Id { get; set; }
		public string Name { get; set; } = string.Empty;
		public string ConnectionKey { get; set; } = string.Empty;
		public bool IsActive { get; set; } = true;
	}

	private static List<LabConfigItem> DefaultActiveLabs() =>
	[
		new() { Id = 2, Name = "InHealth", ConnectionKey = "InHealthConn" },
		new() { Id = 4, Name = "Cove", ConnectionKey = "CoveConnection" },
		new() { Id = 7, Name = "PCRDx - AL", ConnectionKey = "PCRALConnection" },
		new() { Id = 8, Name = "PCRDx - CO", ConnectionKey = "PCRDxConnection" },
		new() { Id = 9, Name = "Rising Tides", ConnectionKey = "RisingTidesConnStr" },
		new() { Id = 10, Name = "BeechTree", ConnectionKey = "BeechTreeConnStr" },
		new() { Id = 12, Name = "Phi Life", ConnectionKey = "PhiLifeConnStr" },
		new() { Id = 13, Name = "PCR Labs of America", ConnectionKey = "PCRLOAConnStr" },
		new() { Id = 16, Name = "Elixir", ConnectionKey = "ElixirConnection" },
		new() { Id = 18, Name = "Certus", ConnectionKey = "CertusConnection" },
		new() { Id = 19, Name = "Augustus Labs", ConnectionKey = "AugustusConnStr" },
		new() { Id = 23, Name = "NorthWest", ConnectionKey = "NWLConnection" }
	];

	private static (string WhereClause, Dictionary<string, object> Parameters) BuildCommonWhere(DenialWorkflowFilter f, string a, bool includeStatus, bool includeAssigned)
	{
		var w = new List<string>(); var p = new Dictionary<string, object>();
		if (IsReviewerOnly(f.Role)) { w.Add($"ISNULL({a}.AssignedTo,'')=@RoleUserName"); p["@RoleUserName"] = f.UserName ?? string.Empty; }
		if (includeStatus && !string.IsNullOrWhiteSpace(f.Status)) { w.Add($"ISNULL({a}.Status,'')=@Status"); p["@Status"] = f.Status.Trim(); }
		if (includeAssigned && !string.IsNullOrWhiteSpace(f.AssignedTo)) { w.Add($"ISNULL({a}.AssignedTo,'')=@AssignedTo"); p["@AssignedTo"] = f.AssignedTo.Trim(); }
		if (includeAssigned && !string.IsNullOrWhiteSpace(f.Reviewer)) { w.Add($"ISNULL({a}.AssignedTo,'')=@Reviewer"); p["@Reviewer"] = f.Reviewer.Trim(); }
		if (!string.IsNullOrWhiteSpace(f.DenialCode)) { w.Add($"ISNULL({a}.DenialCode,'')=@DenialCode"); p["@DenialCode"] = f.DenialCode.Trim(); }
		if (!string.IsNullOrWhiteSpace(f.PayerName)) { w.Add($"ISNULL({a}.PayerName,'')=@PayerName"); p["@PayerName"] = f.PayerName.Trim(); }
		if (!string.IsNullOrWhiteSpace(f.ActionCategory)) { w.Add($"ISNULL({a}.ActionCategory,'')=@ActionCategory"); p["@ActionCategory"] = f.ActionCategory.Trim(); }
		if (!string.IsNullOrWhiteSpace(f.Priority)) { w.Add($"ISNULL({a}.Priority,'')=@Priority"); p["@Priority"] = f.Priority.Trim(); }
		if (!string.IsNullOrWhiteSpace(f.RunId)) { w.Add($"ISNULL({a}.RunId,'')=@RunId"); p["@RunId"] = f.RunId.Trim(); }
		if (f.FromDate.HasValue) { w.Add($"CAST({a}.CreatedOn AS date)>=@FromDate"); p["@FromDate"] = f.FromDate.Value.Date; }
		if (f.ToDate.HasValue) { w.Add($"CAST({a}.CreatedOn AS date)<=@ToDate"); p["@ToDate"] = f.ToDate.Value.Date; }
		if (!string.IsNullOrWhiteSpace(f.SearchText)) { w.Add($"(ISNULL({a}.TaskID,'') LIKE @Search OR ISNULL({a}.ClaimID,'') LIKE @Search OR ISNULL({a}.DenialCode,'') LIKE @Search OR ISNULL({a}.PayerName,'') LIKE @Search)"); p["@Search"] = "%" + f.SearchText.Trim() + "%"; }
		return (w.Count == 0 ? string.Empty : " AND " + string.Join(" AND ", w), p);
	}
	private static void AddFilterParams(SqlCommand cmd, DenialWorkflowFilter f) => cmd.Parameters.AddWithValue("@LabId", f.LabId);
	private static void AddExtraParams(SqlCommand cmd, Dictionary<string, object> ps) { foreach (var kv in ps) cmd.Parameters.AddWithValue(kv.Key, kv.Value); }
	private static void AddPagingParams(SqlCommand cmd, DenialWorkflowFilter f) { cmd.Parameters.AddWithValue("@Offset", (f.Page - 1) * f.PageSize); cmd.Parameters.AddWithValue("@PageSize", f.PageSize); }

	private static WorkflowTaskRow ReadTask(SqlDataReader rd) => new() { TaskId = GetString(rd, "TaskID"), UniqueTrackId = GetString(rd, "UniqueTrackId"), ClaimId = GetString(rd, "ClaimID"), PatientId = GetString(rd, "PatientId"), CptCode = GetString(rd, "CPTCode"), DenialCode = GetString(rd, "DenialCode"), DenialDescription = GetString(rd, "DenialDescription"), DenialClassification = GetString(rd, "DenialClassification"), ActionCode = GetString(rd, "ActionCode"), RecommendedAction = GetString(rd, "RecommendedAction"), ActionCategory = GetString(rd, "ActionCategory"), Task = GetString(rd, "Task"), Priority = GetString(rd, "Priority"), InsuranceBalance = GetDecimal(rd, "InsuranceBalance"), IsCurrentDenial = GetBool(rd, "IsCurrentDenial"), SlaDays = GetNullableInt(rd, "SLADays"), Status = GetString(rd, "Status"), DateOpened = GetDate(rd, "DateOpened"), DueDate = GetDate(rd, "DueDate"), DateCompleted = GetDate(rd, "DateCompleted"), DaysRemaining = GetNullableInt(rd, "DaysRemaining"), SlaStatus = GetString(rd, "SLAStatus"), AssignedTo = GetString(rd, "AssignedTo"), LabId = GetInt(rd, "LabId"), LabName = GetString(rd, "LabName"), RunId = GetString(rd, "RunId"), CreatedOn = GetDate(rd, "CreatedOn"), SalesRepname = GetString(rd, "SalesRepname"), ClinicName = GetString(rd, "ClinicName"), ReferringProvider = GetString(rd, "ReferringProvider"), PayerName = GetString(rd, "PayerName"), PayerNameNormalized = GetString(rd, "PayerNameNormalized"), PayerCode = GetNullableInt(rd, "PayerCode"), PayerType = GetString(rd, "PayerType"), FirstBilledDate = GetDate(rd, "FirstBilledDate"), ChargeEnteredDate = GetDate(rd, "ChargeEnteredDate"), BillingProvider = GetString(rd, "BillingProvider"), PanelName = GetString(rd, "PanelName"), DateOfService = GetDate(rd, "DateOfService"), ReviewerComments = GetString(rd, "ReviewerComments"), ReviewerUpdatedOn = GetDate(rd, "ReviewerUpdatedOn"), ReviewerUpdatedBy = GetString(rd, "ReviewerUpdatedBy") };
	private static VerificationTaskRow ReadVerification(SqlDataReader rd) { var t = ReadTask(rd); return new VerificationTaskRow { TaskId = t.TaskId, UniqueTrackId = t.UniqueTrackId, ClaimId = t.ClaimId, PatientId = t.PatientId, CptCode = t.CptCode, DenialCode = t.DenialCode, DenialDescription = t.DenialDescription, DenialClassification = t.DenialClassification, ActionCode = t.ActionCode, RecommendedAction = t.RecommendedAction, ActionCategory = t.ActionCategory, Task = t.Task, Priority = t.Priority, InsuranceBalance = t.InsuranceBalance, IsCurrentDenial = t.IsCurrentDenial, SlaDays = t.SlaDays, Status = t.Status, DateOpened = t.DateOpened, DueDate = t.DueDate, DateCompleted = t.DateCompleted, DaysRemaining = t.DaysRemaining, SlaStatus = t.SlaStatus, AssignedTo = t.AssignedTo, LabId = t.LabId, LabName = t.LabName, RunId = t.RunId, CreatedOn = t.CreatedOn, SalesRepname = t.SalesRepname, ClinicName = t.ClinicName, ReferringProvider = t.ReferringProvider, PayerName = t.PayerName, PayerNameNormalized = t.PayerNameNormalized, PayerCode = t.PayerCode, PayerType = t.PayerType, FirstBilledDate = t.FirstBilledDate, ChargeEnteredDate = t.ChargeEnteredDate, BillingProvider = t.BillingProvider, PanelName = t.PanelName, DateOfService = t.DateOfService, ReviewerComments = t.ReviewerComments, ReviewerUpdatedOn = t.ReviewerUpdatedOn, ReviewerUpdatedBy = t.ReviewerUpdatedBy, VerificationId = GetLong(rd, "VerificationId"), VerificationStatus = GetString(rd, "VerificationStatus"), VerificationComments = GetString(rd, "VerificationComments"), OriginalRunId = GetString(rd, "OriginalRunId"), MissingDetectedRunId = GetString(rd, "MissingDetectedRunId"), MovedOn = GetDate(rd, "MovedOn"), VerifiedBy = GetString(rd, "VerifiedBy"), VerifiedOn = GetDate(rd, "VerifiedOn") }; }
	private static DenialWorkflowInsightRow ReadInsight(SqlDataReader rd) => new() { DenialCodes = GetString(rd, "DenialCodes"), Descriptions = GetString(rd, "Descriptions"), NoOfDenialCount = GetInt(rd, "NoOfDenialCount"), NoOfClaimsCount = GetInt(rd, "NoOfClaimsCount"), TotalBalance = GetDecimal(rd, "TotalBalance"), HighImpactInsurance = GetString(rd, "HighImpactInsurance"), InsuranceBalance = GetDecimal(rd, "InsuranceBalance"), ImpactPercentage = GetDecimal(rd, "ImpactPercentage"), ActionCategory = GetString(rd, "ActionCategory"), ActionCode = GetString(rd, "ActionCode"), Action = GetString(rd, "Action"), Task = GetString(rd, "Task"), Feedback = GetString(rd, "Feedback"), Responsibility = GetString(rd, "Responsibility"), DiscussionDate = GetDate(rd, "DiscussionDate"), ETA = GetString(rd, "ETA"), LabName = GetString(rd, "LabName"), LabId = GetInt(rd, "LabId"), RunId = GetString(rd, "RunId"), CreatedOn = GetDate(rd, "CreatedOn"), AssignedTo = GetString(rd, "AssignedTo"), ResponsibilityReviewer = GetString(rd, "ResponsibilityReviewer") };
	private static void AddTaskParams(SqlCommand cmd, DenialTaskImportRow r, int labId, string labName, string runId, string taskId) { cmd.Parameters.AddWithValue("@TaskID", taskId); cmd.Parameters.AddWithValue("@LabId", labId); cmd.Parameters.AddWithValue("@LabName", labName); cmd.Parameters.AddWithValue("@RunId", runId); cmd.Parameters.AddWithValue("@UniqueTrackId", r.UniqueTrackId); cmd.Parameters.AddWithValue("@ClaimID", r.ClaimId); cmd.Parameters.AddWithValue("@PatientId", r.PatientId); cmd.Parameters.AddWithValue("@CPTCode", r.CptCode); cmd.Parameters.AddWithValue("@DenialCode", r.DenialCode); cmd.Parameters.AddWithValue("@DenialDescription", r.DenialDescription); cmd.Parameters.AddWithValue("@DenialClassification", r.DenialClassification); cmd.Parameters.AddWithValue("@ActionCode", r.ActionCode); cmd.Parameters.AddWithValue("@RecommendedAction", r.RecommendedAction); cmd.Parameters.AddWithValue("@ActionCategory", r.ActionCategory); cmd.Parameters.AddWithValue("@Task", r.Task); cmd.Parameters.AddWithValue("@Priority", r.Priority); cmd.Parameters.AddWithValue("@InsuranceBalance", r.InsuranceBalance); cmd.Parameters.AddWithValue("@SLADays", (object?)r.SlaDays ?? DBNull.Value); cmd.Parameters.AddWithValue("@DateOpened", (object?)r.DateOpened ?? DateTime.Today); cmd.Parameters.AddWithValue("@DueDate", (object?)r.DueDate ?? DBNull.Value); cmd.Parameters.AddWithValue("@SalesRepname", r.SalesRepname); cmd.Parameters.AddWithValue("@ClinicName", r.ClinicName); cmd.Parameters.AddWithValue("@ReferringProvider", r.ReferringProvider); cmd.Parameters.AddWithValue("@PayerName", r.PayerName); cmd.Parameters.AddWithValue("@PayerNameNormalized", r.PayerNameNormalized); cmd.Parameters.AddWithValue("@PayerCode", (object?)r.PayerCode ?? DBNull.Value); cmd.Parameters.AddWithValue("@PayerType", r.PayerType); cmd.Parameters.AddWithValue("@FirstBilledDate", (object?)r.FirstBilledDate ?? DBNull.Value); cmd.Parameters.AddWithValue("@ChargeEnteredDate", (object?)r.ChargeEnteredDate ?? DBNull.Value); cmd.Parameters.AddWithValue("@BillingProvider", r.BillingProvider); cmd.Parameters.AddWithValue("@PanelName", r.PanelName); cmd.Parameters.AddWithValue("@DateOfService", (object?)r.DateOfService ?? DBNull.Value); }
	private static async Task<IReadOnlyList<string>> ReadStringListAsync(SqlDataReader rd, CancellationToken ct)
	{
		var rows = new List<string>();
		while (await rd.ReadAsync(ct))
		{
			var value = GetString(rd, "Value");
			if (!string.IsNullOrWhiteSpace(value)) rows.Add(value);
		}
		return rows;
	}

	private static bool IsReviewerOnly(string role) => role.Contains("Reviewer", StringComparison.OrdinalIgnoreCase) && !role.Contains("Manager", StringComparison.OrdinalIgnoreCase) && !role.Contains("Admin", StringComparison.OrdinalIgnoreCase);
	private static string GetString(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToString(r[n]) ?? string.Empty : string.Empty;
	private static int GetInt(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToInt32(r[n]) : 0;
	private static int? GetNullableInt(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToInt32(r[n]) : null;
	private static long GetLong(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToInt64(r[n]) : 0L;
	private static decimal GetDecimal(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToDecimal(r[n]) : 0m;
	private static bool GetBool(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value && Convert.ToBoolean(r[n]);
	private static DateTime? GetDate(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToDateTime(r[n]) : null;
	private static bool HasColumn(IDataRecord r, string n) { for (var i = 0; i < r.FieldCount; i++) if (string.Equals(r.GetName(i), n, StringComparison.OrdinalIgnoreCase)) return true; return false; }
}
