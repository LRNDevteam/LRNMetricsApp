using System;
using System.Collections.Generic;
using System.Data;
using System.Threading.Tasks;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;

namespace DenialDatabaseProcessorWorker.Services;

public sealed class DenialTaskBoardRepository
{
	private readonly string _connectionString;

	public DenialTaskBoardRepository(IConfiguration configuration)
	{
		_connectionString = configuration.GetConnectionString("DenialDatabase")
							?? throw new InvalidOperationException("Connection string 'DenialDatabase' not found.");
	}

	// Use this constructor when reading/writing lab-level tables.
	// Example: NorthWest must read dbo.DenialTaskBoard from NWL_Lab / NWL_LRN, not LRNMaster.
	public DenialTaskBoardRepository(string connectionString)
	{
		if (string.IsNullOrWhiteSpace(connectionString))
			throw new ArgumentException("Lab database connection string is required.", nameof(connectionString));

		_connectionString = connectionString;
	}

	public sealed class ExistingTaskInfo
	{
		public string TaskId { get; set; } = "";
		public DateTime? DateOpened { get; set; }
		public Dictionary<string, string> Row { get; set; } = new(StringComparer.OrdinalIgnoreCase);
	}

	// Key: UniqueTrackId (ClaimUID|CPTCode|DenialCode)
	public async Task<Dictionary<string, ExistingTaskInfo>> GetExistingTasksAsync(int labId)
	{
		const string sql = @"
SELECT TaskID, ClaimID, PatientId, CPTCode, DenialCode,
       DenialDescription, DenialClassification, ActionCode, RecommendedAction,
       Task, ActionCategory, Priority, SLADays, Status,
       InsuranceBalance, IsCurrentDenial, AssignedTo,
       DateOpened, DueDate, DateCompleted, DaysRemaining, SLAStatus,
       LabId, LabName, RunId, CreatedOn, UniqueTrackId,
       ClaimUID,
       ICDCodes, CoverageStatus, ICDComplianceStatus, DenialValidity,
       WorkFlowStatus, ClaimFrom
FROM dbo.DenialTaskBoard
WHERE LabId = @LabId";

		var result = new Dictionary<string, ExistingTaskInfo>(StringComparer.OrdinalIgnoreCase);

		await using var conn = new SqlConnection(_connectionString);
		await using var cmd = new SqlCommand(sql, conn);
		cmd.Parameters.AddWithValue("@LabId", labId);
		await conn.OpenAsync().ConfigureAwait(false);

		await using var reader = await cmd.ExecuteReaderAsync().ConfigureAwait(false);
		while (await reader.ReadAsync().ConfigureAwait(false))
		{
			var storedUniqueTrackId = reader["UniqueTrackId"] as string ?? "";
			var claimUid = reader["ClaimUID"]?.ToString() ?? "";
			var cptCode = reader["CPTCode"]?.ToString() ?? "";
			var denialCode = reader["DenialCode"]?.ToString() ?? "";
			var uniqueTrackId = BuildTaskKey(claimUid, cptCode, denialCode);

			if (string.IsNullOrWhiteSpace(uniqueTrackId))
				uniqueTrackId = storedUniqueTrackId;

			if (string.IsNullOrWhiteSpace(uniqueTrackId))
				continue;

			var info = new ExistingTaskInfo
			{
				TaskId = reader["TaskID"] as string ?? "",
				DateOpened = reader["DateOpened"] is DateTime dt ? dt : (DateTime?)null,
				Row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
				{
					["Task ID"] = reader["TaskID"]?.ToString() ?? "",
					["Claim ID"] = reader["ClaimID"]?.ToString() ?? "",
					["ClaimUID"] = claimUid,
					["Patient / Acct #"] = reader["PatientId"]?.ToString() ?? "",
					["CPT Code"] = cptCode,
					["Denial Code"] = denialCode,
					["Denial Description"] = reader["DenialDescription"]?.ToString() ?? "",
					["Denial Classification"] = reader["DenialClassification"]?.ToString() ?? "",
					["Action Code"] = reader["ActionCode"]?.ToString() ?? "",
					["Recommended Action"] = reader["RecommendedAction"]?.ToString() ?? "",
					["Task"] = reader["Task"]?.ToString() ?? "",
					["Action Category"] = reader["ActionCategory"]?.ToString() ?? "",
					["Priority"] = reader["Priority"]?.ToString() ?? "",
					["SLA (Days)"] = reader["SLADays"]?.ToString() ?? "",
					["Status"] = reader["Status"]?.ToString() ?? "",
					["Insurance Balance"] = reader["InsuranceBalance"]?.ToString() ?? "",
					["IsCurrentDenial"] = reader["IsCurrentDenial"]?.ToString() ?? "",
					["Assigned To"] = reader["AssignedTo"]?.ToString() ?? "",
					["Date Opened"] = reader["DateOpened"] is DateTime doDt ? doDt.ToString("yyyy-MM-dd") : "",
					["Due Date"] = reader["DueDate"] is DateTime ddDt ? ddDt.ToString("yyyy-MM-dd") : "",
					["Date Completed"] = reader["DateCompleted"] is DateTime dcDt ? dcDt.ToString("yyyy-MM-dd") : "",
					["Days Remaining"] = reader["DaysRemaining"]?.ToString() ?? "",
					["SLA Status"] = reader["SLAStatus"]?.ToString() ?? "",
					["LabId"] = reader["LabId"]?.ToString() ?? "",
					["LabName"] = reader["LabName"]?.ToString() ?? "",
					["RunId"] = reader["RunId"]?.ToString() ?? "",
					["CreatedOn"] = reader["CreatedOn"] is DateTime coDt ? coDt.ToString("O") : "",
					["UniqueTrackId"] = uniqueTrackId,
					["ICDCodes"] = reader["ICDCodes"]?.ToString() ?? "",
					["CoverageStatus"] = reader["CoverageStatus"]?.ToString() ?? "",
					["ICDComplianceStatus"] = reader["ICDComplianceStatus"]?.ToString() ?? "",
					["DenialValidity"] = reader["DenialValidity"]?.ToString() ?? "",
					["WorkFlowStatus"] = reader["WorkFlowStatus"]?.ToString() ?? "",
					["ClaimFrom"] = reader["ClaimFrom"]?.ToString() ?? ""
				}
			};

			result[uniqueTrackId] = info;
		}

		return result;
	}

	private static string BuildTaskKey(string? claimUid, string? cptCode, string? denialCode)
	{
		var claim = claimUid?.Trim() ?? "";
		var cpt = cptCode?.Trim() ?? "";
		var denial = denialCode?.Trim() ?? "";

		if (string.IsNullOrWhiteSpace(claim) ||
			string.IsNullOrWhiteSpace(cpt) ||
			string.IsNullOrWhiteSpace(denial))
		{
			return "";
		}

		return $"{claim}|{cpt}|{denial}";
	}

	public async Task ReconcileBeforeWriteAsync(
		int labId,
		string labName,
		string runId,
		DataTable lineItemTable,
		List<Dictionary<string, string>> taskRows,
		CancellationToken cancellationToken)
	{
		var currentTasks = BuildCurrentTaskTable(taskRows);
		var currentClaims = BuildCurrentClaimTable(lineItemTable, taskRows);

		await using var conn = new SqlConnection(_connectionString);
		await conn.OpenAsync(cancellationToken).ConfigureAwait(false);

		await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

		try
		{
			await CreateTempTablesAsync(conn, tx, cancellationToken).ConfigureAwait(false);
			await BulkCopyTempTableAsync(conn, tx, currentTasks, "#CurrentTaskKeys", cancellationToken).ConfigureAwait(false);
			await BulkCopyTempTableAsync(conn, tx, currentClaims, "#CurrentClaimUIDs", cancellationToken).ConfigureAwait(false);
			await CreateTempIndexesAsync(conn, tx, cancellationToken).ConfigureAwait(false);

			await using var cmd = new SqlCommand(ReconcileSql, conn, tx)
			{
				CommandTimeout = 0
			};
			cmd.Parameters.AddWithValue("@LabId", labId);
			cmd.Parameters.AddWithValue("@LabName", labName ?? string.Empty);
			cmd.Parameters.AddWithValue("@RunId", runId ?? string.Empty);
			cmd.Parameters.AddWithValue("@NowUtc", DateTime.UtcNow);
			await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);

			await tx.CommitAsync(cancellationToken).ConfigureAwait(false);
		}
		catch
		{
			try
			{
				await tx.RollbackAsync(CancellationToken.None).ConfigureAwait(false);
			}
			catch (InvalidOperationException)
			{
				// SQL Server can complete/abort the transaction before control reaches
				// this catch block. Preserve the original reconcile exception.
			}

			throw;
		}
	}

	private static DataTable BuildCurrentTaskTable(List<Dictionary<string, string>> taskRows)
	{
		var table = new DataTable();
		table.Columns.Add("UniqueTrackId", typeof(string));
		table.Columns.Add("ClaimUID", typeof(string));

		foreach (var row in taskRows)
		{
			var uniqueTrackId = GetValueByAnyKey(row, "UniqueTrackId");
			if (string.IsNullOrWhiteSpace(uniqueTrackId))
				continue;

			var dr = table.NewRow();
			dr["UniqueTrackId"] = uniqueTrackId.Trim();
			dr["ClaimUID"] = GetValueByAnyKey(row, "ClaimUID").Trim();
			table.Rows.Add(dr);
		}

		return table;
	}

	private static DataTable BuildCurrentClaimTable(DataTable lineItemTable, List<Dictionary<string, string>> taskRows)
	{
		var table = new DataTable();
		table.Columns.Add("ClaimUID", typeof(string));

		var claimUids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

		if (lineItemTable.Columns.Contains("ClaimUID"))
		{
			foreach (DataRow row in lineItemTable.Rows)
			{
				var claimUid = row["ClaimUID"]?.ToString();
				if (!string.IsNullOrWhiteSpace(claimUid))
					claimUids.Add(claimUid.Trim());
			}
		}

		foreach (var row in taskRows)
		{
			var claimUid = GetValueByAnyKey(row, "ClaimUID");
			if (!string.IsNullOrWhiteSpace(claimUid))
				claimUids.Add(claimUid.Trim());
		}

		foreach (var claimUid in claimUids)
		{
			var dr = table.NewRow();
			dr["ClaimUID"] = claimUid;
			table.Rows.Add(dr);
		}

		return table;
	}

	private static async Task CreateTempTablesAsync(SqlConnection conn, SqlTransaction tx, CancellationToken cancellationToken)
	{
		const string sql = @"
CREATE TABLE #CurrentTaskKeys
(
	UniqueTrackId NVARCHAR(450) NOT NULL,
	ClaimUID NVARCHAR(600) NULL
);

CREATE TABLE #CurrentClaimUIDs
(
	ClaimUID NVARCHAR(600) NOT NULL
);

CREATE TABLE #DeletedUnassignedClaimUIDs
(
	ClaimUID NVARCHAR(600) NOT NULL
);";

		await using var cmd = new SqlCommand(sql, conn, tx);
		await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
	}

	private static async Task BulkCopyTempTableAsync(
		SqlConnection conn,
		SqlTransaction tx,
		DataTable table,
		string destinationTable,
		CancellationToken cancellationToken)
	{
		if (table.Rows.Count == 0)
			return;

		using var bulk = new SqlBulkCopy(conn, SqlBulkCopyOptions.Default, tx)
		{
			DestinationTableName = destinationTable,
			BatchSize = 10000,
			BulkCopyTimeout = 0
		};

		foreach (DataColumn column in table.Columns)
			bulk.ColumnMappings.Add(column.ColumnName, column.ColumnName);

		await bulk.WriteToServerAsync(table, cancellationToken).ConfigureAwait(false);
	}

	private static async Task CreateTempIndexesAsync(SqlConnection conn, SqlTransaction tx, CancellationToken cancellationToken)
	{
		const string sql = @"
CREATE NONCLUSTERED INDEX IX_CurrentTaskKeys_UniqueTrackId ON #CurrentTaskKeys (UniqueTrackId);
CREATE NONCLUSTERED INDEX IX_CurrentClaimUIDs_ClaimUID ON #CurrentClaimUIDs (ClaimUID);
CREATE NONCLUSTERED INDEX IX_DeletedUnassignedClaimUIDs_ClaimUID ON #DeletedUnassignedClaimUIDs (ClaimUID);";

		await using var cmd = new SqlCommand(sql, conn, tx)
		{
			CommandTimeout = 0
		};

		await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
	}

	private const string ReconcileSql = @"
INSERT INTO #DeletedUnassignedClaimUIDs (ClaimUID)
SELECT DISTINCT NULLIF(LTRIM(RTRIM(ClaimUID)), '')
FROM dbo.DenialTaskBoard
WHERE LabId = @LabId
  AND NULLIF(LTRIM(RTRIM(ISNULL(AssignedTo, ''))), '') IS NULL
  AND NULLIF(LTRIM(RTRIM(ClaimUID)), '') IS NOT NULL;

DELETE li
FROM dbo.DenialLineItem li
WHERE li.LabId = @LabId
  AND EXISTS
  (
	  SELECT 1
	  FROM dbo.DenialTaskBoard tb
	  WHERE tb.LabId = li.LabId
	    AND tb.ClaimUID = li.ClaimUID
	    AND UPPER(LTRIM(RTRIM(ISNULL(tb.Status, '')))) = 'CLOSED'
  );

DELETE tb
FROM dbo.DenialTaskBoard tb
WHERE tb.LabId = @LabId
  AND UPPER(LTRIM(RTRIM(ISNULL(tb.Status, '')))) = 'CLOSED';

IF OBJECT_ID('dbo.DenialVerification', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerification', 'ClaimUID') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerification', 'TaskID') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerification', 'ClaimID') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerification', 'UniqueTrackId') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerification', 'LabId') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerification', 'LabName') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerification', 'RunId') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerification', 'AssignedTo') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerification', 'Status') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerification', 'VerificationStatus') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerification', 'CreatedOn') IS NOT NULL
BEGIN
	INSERT INTO dbo.DenialVerification
	(
		ClaimUID, TaskID, ClaimID, UniqueTrackId, LabId, LabName, RunId,
		AssignedTo, Status, VerificationStatus, CreatedOn
	)
	SELECT DISTINCT
		tb.ClaimUID,
		tb.TaskID,
		tb.ClaimID,
		tb.UniqueTrackId,
		tb.LabId,
		tb.LabName,
		@RunId,
		tb.AssignedTo,
		tb.Status,
		'Verification Pending',
		@NowUtc
	FROM dbo.DenialTaskBoard tb
	WHERE tb.LabId = @LabId
	  AND NULLIF(LTRIM(RTRIM(ISNULL(tb.AssignedTo, ''))), '') IS NOT NULL
	  AND NULLIF(LTRIM(RTRIM(ISNULL(tb.ClaimUID, ''))), '') IS NOT NULL
	  AND UPPER(LTRIM(RTRIM(ISNULL(tb.Status, '')))) <> 'CLOSED'
	  AND NOT EXISTS
	  (
		  SELECT 1
		  FROM #CurrentTaskKeys c
		  WHERE c.UniqueTrackId = tb.UniqueTrackId
		     OR c.UniqueTrackId =
				CONCAT(
					LTRIM(RTRIM(ISNULL(tb.ClaimUID, ''))),
					'|',
					LTRIM(RTRIM(ISNULL(tb.CPTCode, ''))),
					'|',
					LTRIM(RTRIM(ISNULL(tb.DenialCode, '')))
				)
	  )
	  AND NOT EXISTS
	  (
		  SELECT 1
		  FROM dbo.DenialVerification dv
		  WHERE dv.ClaimUID = tb.ClaimUID
		    AND dv.UniqueTrackId = tb.UniqueTrackId
		    AND dv.RunId = @RunId
	  );
END;

UPDATE tb
SET WorkFlowStatus = 'Verification Pending',
	ClaimFrom = 'Old Run',
	IsCurrentDenial = 0,
	RunId = @RunId
FROM dbo.DenialTaskBoard tb
WHERE tb.LabId = @LabId
  AND NULLIF(LTRIM(RTRIM(ISNULL(tb.AssignedTo, ''))), '') IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(ISNULL(tb.ClaimUID, ''))), '') IS NOT NULL
  AND UPPER(LTRIM(RTRIM(ISNULL(tb.Status, '')))) <> 'CLOSED'
  AND NOT EXISTS
  (
	  SELECT 1
	  FROM #CurrentTaskKeys c
	  WHERE c.UniqueTrackId = tb.UniqueTrackId
	     OR c.UniqueTrackId =
			CONCAT(
				LTRIM(RTRIM(ISNULL(tb.ClaimUID, ''))),
				'|',
				LTRIM(RTRIM(ISNULL(tb.CPTCode, ''))),
				'|',
				LTRIM(RTRIM(ISNULL(tb.DenialCode, '')))
			)
  );

UPDATE li
SET ClaimFrom = 'Old Run',
	WorkFlowStatus = 'Verification Pending'
FROM dbo.DenialLineItem li
WHERE li.LabId = @LabId
  AND EXISTS
  (
	  SELECT 1
	  FROM dbo.DenialTaskBoard tb
	  WHERE tb.LabId = li.LabId
	    AND tb.ClaimUID = li.ClaimUID
	    AND NULLIF(LTRIM(RTRIM(ISNULL(tb.AssignedTo, ''))), '') IS NOT NULL
	    AND UPPER(LTRIM(RTRIM(ISNULL(tb.Status, '')))) <> 'CLOSED'
	    AND NOT EXISTS
	    (
		    SELECT 1
		    FROM #CurrentTaskKeys c
		    WHERE c.UniqueTrackId = tb.UniqueTrackId
		       OR c.UniqueTrackId =
			      CONCAT(
				      LTRIM(RTRIM(ISNULL(tb.ClaimUID, ''))),
				      '|',
				      LTRIM(RTRIM(ISNULL(tb.CPTCode, ''))),
				      '|',
				      LTRIM(RTRIM(ISNULL(tb.DenialCode, '')))
			      )
	    )
  );

DELETE li
FROM dbo.DenialLineItem li
WHERE li.LabId = @LabId
  AND
  (
	  EXISTS
	  (
		  SELECT 1
		  FROM #CurrentClaimUIDs c
		  WHERE c.ClaimUID = li.ClaimUID
	  )
	  AND UPPER(LTRIM(RTRIM(ISNULL(li.ClaimFrom, '')))) <> 'OLD RUN'
	  OR EXISTS
	  (
		  SELECT 1
		  FROM #DeletedUnassignedClaimUIDs d
		  WHERE d.ClaimUID = li.ClaimUID
	  )
  );

DELETE tb
FROM dbo.DenialTaskBoard tb
WHERE tb.LabId = @LabId
  AND
  (
	  NULLIF(LTRIM(RTRIM(ISNULL(tb.AssignedTo, ''))), '') IS NULL
	  OR UPPER(LTRIM(RTRIM(ISNULL(tb.Status, '')))) = 'CLOSED'
	  OR EXISTS
	  (
		  SELECT 1
		  FROM #CurrentTaskKeys c
		  WHERE c.UniqueTrackId = tb.UniqueTrackId
		     OR c.UniqueTrackId =
				CONCAT(
					LTRIM(RTRIM(ISNULL(tb.ClaimUID, ''))),
					'|',
					LTRIM(RTRIM(ISNULL(tb.CPTCode, ''))),
					'|',
					LTRIM(RTRIM(ISNULL(tb.DenialCode, '')))
				)
	  )
  );";

	private static string GetValueByAnyKey(Dictionary<string, string> row, params string[] keys)
	{
		foreach (var key in keys)
		{
			if (row.TryGetValue(key, out var value))
				return value ?? string.Empty;

			var actualKey = row.Keys.FirstOrDefault(k => string.Equals(k, key, StringComparison.OrdinalIgnoreCase));
			if (actualKey != null && row.TryGetValue(actualKey, out value))
				return value ?? string.Empty;
		}

		return string.Empty;
	}
}
