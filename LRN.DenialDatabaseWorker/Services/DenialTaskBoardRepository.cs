using System;
using System.Collections.Generic;
using System.Data;
using System.Threading.Tasks;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;

namespace DenialDatabaseProcessorWorker.Services;

public sealed class DenialTaskBoardRepository
{
	/// <summary>
	/// Used when no timeout is supplied. The ADO.NET default of 30 seconds is not enough:
	/// GetExistingTasksAsync reads every task row a lab has ever accumulated.
	/// </summary>
	private const int DefaultCommandTimeoutSeconds = 600;

	private readonly string _connectionString;
	private readonly int _commandTimeoutSeconds;

	public DenialTaskBoardRepository(IConfiguration configuration)
	{
		_connectionString = configuration.GetConnectionString("DenialDatabase")
							?? throw new InvalidOperationException("Connection string 'DenialDatabase' not found.");
		_commandTimeoutSeconds = DefaultCommandTimeoutSeconds;
	}

	// Use this constructor when reading/writing lab-level tables.
	// Example: NorthWest must read dbo.DenialTaskBoard from NWL_Lab / NWL_LRN, not LRNMaster.
	public DenialTaskBoardRepository(string connectionString, int commandTimeoutSeconds = DefaultCommandTimeoutSeconds)
	{
		if (string.IsNullOrWhiteSpace(connectionString))
			throw new ArgumentException("Lab database connection string is required.", nameof(connectionString));

		if (commandTimeoutSeconds < 0)
			throw new ArgumentOutOfRangeException(nameof(commandTimeoutSeconds), "Command timeout cannot be negative. Use 0 for no timeout.");

		_connectionString = connectionString;
		_commandTimeoutSeconds = commandTimeoutSeconds;
	}

	/// <summary>
	/// The parts of an existing task that TaskBoardBuilder carries forward onto the new run.
	/// Deliberately narrow: this is read for every task a lab has ever accumulated, so every
	/// extra column is paid once per row. Only add a property here together with its column.
	/// </summary>
	public sealed class ExistingTaskInfo
	{
		public string TaskId { get; init; } = "";
		public DateTime? DateOpened { get; init; }
		public DateTime? DateCompleted { get; init; }
		public string Status { get; init; } = "";
		public string AssignedTo { get; init; } = "";
		public string WorkFlowStatus { get; init; } = "";
	}

	// Key: UniqueTrackId (ClaimUID|CPTCode|DenialCode)
	//
	// Ten columns, not the full row. This used to select all 34 - including ICDCodes and
	// DenialValidity, both NVARCHAR(MAX) - and materialize a 33-entry dictionary per row,
	// when the builder only ever reads TaskId, DateOpened, DateCompleted, Status, AssignedTo
	// and WorkFlowStatus. On a lab with a large board that dragged the LOB data across the
	// wire for every task and timed out. The four key columns are here to rebuild the lookup
	// key; the rest were never used.
	public async Task<Dictionary<string, ExistingTaskInfo>> GetExistingTasksAsync(int labId)
	{
		const string sql = @"
SELECT TaskID, ClaimUID, CPTCode, DenialCode, UniqueTrackId,
       Status, AssignedTo, WorkFlowStatus, DateOpened, DateCompleted
FROM dbo.DenialTaskBoard
WHERE LabId = @LabId";

		var result = new Dictionary<string, ExistingTaskInfo>(StringComparer.OrdinalIgnoreCase);

		await using var conn = new SqlConnection(_connectionString);
		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = _commandTimeoutSeconds };
		cmd.Parameters.AddWithValue("@LabId", labId);
		await conn.OpenAsync().ConfigureAwait(false);

		await using var reader = await cmd.ExecuteReaderAsync().ConfigureAwait(false);

		// Resolve ordinals once rather than hashing the column name on every field of every row.
		int taskIdOrd = reader.GetOrdinal("TaskID");
		int claimUidOrd = reader.GetOrdinal("ClaimUID");
		int cptCodeOrd = reader.GetOrdinal("CPTCode");
		int denialCodeOrd = reader.GetOrdinal("DenialCode");
		int uniqueTrackIdOrd = reader.GetOrdinal("UniqueTrackId");
		int statusOrd = reader.GetOrdinal("Status");
		int assignedToOrd = reader.GetOrdinal("AssignedTo");
		int workFlowStatusOrd = reader.GetOrdinal("WorkFlowStatus");
		int dateOpenedOrd = reader.GetOrdinal("DateOpened");
		int dateCompletedOrd = reader.GetOrdinal("DateCompleted");

		while (await reader.ReadAsync().ConfigureAwait(false))
		{
			var claimUid = GetText(reader, claimUidOrd);
			var cptCode = GetText(reader, cptCodeOrd);
			var denialCode = GetText(reader, denialCodeOrd);

			var uniqueTrackId = BuildTaskKey(claimUid, cptCode, denialCode);

			if (string.IsNullOrWhiteSpace(uniqueTrackId))
				uniqueTrackId = GetText(reader, uniqueTrackIdOrd);

			if (string.IsNullOrWhiteSpace(uniqueTrackId))
				continue;

			result[uniqueTrackId] = new ExistingTaskInfo
			{
				TaskId = GetText(reader, taskIdOrd),
				DateOpened = GetDate(reader, dateOpenedOrd),
				DateCompleted = GetDate(reader, dateCompletedOrd),
				Status = GetText(reader, statusOrd),
				AssignedTo = GetText(reader, assignedToOrd),
				WorkFlowStatus = GetText(reader, workFlowStatusOrd)
			};
		}

		return result;
	}

	private static string GetText(SqlDataReader reader, int ordinal)
		=> reader.IsDBNull(ordinal) ? "" : reader.GetValue(ordinal)?.ToString() ?? "";

	private static DateTime? GetDate(SqlDataReader reader, int ordinal)
		=> reader.IsDBNull(ordinal) ? null : reader.GetValue(ordinal) as DateTime?;

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

		// No timeout, like every other statement in this transaction: the DDL itself is
		// trivial, but it can sit behind tempdb contention while the rest of the batch runs.
		await using var cmd = new SqlCommand(sql, conn, tx) { CommandTimeout = 0 };
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
