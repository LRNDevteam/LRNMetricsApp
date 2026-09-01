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

	/// <summary>
	/// What the orphan-disposition checks are allowed to read, and what counts as a resolution.
	/// Passed per call rather than injected so the repository keeps working for the lab-scoped
	/// constructor the worker builds on the fly.
	/// </summary>
	public sealed record OrphanDispositionSettings(
		bool EnableUpstreamResolution,
		bool EnableResubmission,
		string PayerValidationReportTable,
		string LineLevelTable,
		IReadOnlyList<string> WriteOffStatusValues,
		IReadOnlyList<string> AdjustedStatusValues);

	/// <summary>
	/// Counts per reconciliation bucket, written to the info log so an unexpected mass deletion or
	/// a mis-mapped status value is visible without a database query (NF-15).
	/// </summary>
	public sealed record ReconcileCensus(
		int Orphans,
		int ResolvedUpstream,
		int ReSubmitted,
		int RaisedForVerification,
		int DeletedOrphanUnassigned,
		int ArchivedClosed,
		bool UpstreamCheckRan,
		bool ResubmissionCheckRan,
		IReadOnlyList<string> UnmatchedOrphanStatuses);

	public async Task<ReconcileCensus> ReconcileBeforeWriteAsync(
		int labId,
		string labName,
		string runId,
		DataTable lineItemTable,
		List<Dictionary<string, string>> taskRows,
		OrphanDispositionSettings settings,
		CancellationToken cancellationToken)
	{
		var currentTasks = BuildCurrentTaskTable(taskRows);
		var currentClaims = BuildCurrentClaimTable(lineItemTable, taskRows);

		await using var conn = new SqlConnection(_connectionString);
		await conn.OpenAsync(cancellationToken).ConfigureAwait(false);

		// Which optional columns this lab actually has. The workflow app adds several of them, so a
		// lab where it was never set up is missing them; substituting a typed NULL keeps one
		// statement working everywhere instead of failing the lab on a column name.
		var boardColumns = await GetColumnSetAsync(conn, null, "dbo.DenialTaskBoard", cancellationToken).ConfigureAwait(false);
		var probe = await ProbeSourcesAsync(conn, null, settings, cancellationToken).ConfigureAwait(false);

		await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

		try
		{
			await CreateTempTablesAsync(conn, tx, cancellationToken).ConfigureAwait(false);
			await BulkCopyTempTableAsync(conn, tx, currentTasks, "#CurrentTaskKeys", cancellationToken).ConfigureAwait(false);
			await BulkCopyTempTableAsync(conn, tx, currentClaims, "#CurrentClaimUIDs", cancellationToken).ConfigureAwait(false);
			await CreateTempIndexesAsync(conn, tx, cancellationToken).ConfigureAwait(false);

			// Classify every existing task before anything is written (RC-06).
			await ExecuteAsync(conn, tx, BuildOrphansSql(boardColumns), cancellationToken, labId, labName, runId).ConfigureAwait(false);

			// §6.1 first, then §6.2 (OD-02): the source data STATES the outcome, while resubmission
			// INFERS it from a date comparison. Where both apply, the stated outcome wins.
			var upstreamRan = false;
			var resubmissionRan = false;

			if (settings.EnableUpstreamResolution && probe.HasPayerValidationReport)
			{
				await SeedResolutionStatusMapAsync(conn, tx, settings, cancellationToken).ConfigureAwait(false);
				await ExecuteAsync(conn, tx, BuildUpstreamResolutionSql(settings, probe), cancellationToken, labId, labName, runId).ConfigureAwait(false);
				upstreamRan = true;
			}

			if (settings.EnableResubmission && probe.HasLineLevelTable)
			{
				await ExecuteAsync(conn, tx, BuildResubmissionSql(settings, boardColumns), cancellationToken, labId, labName, runId).ConfigureAwait(false);
				resubmissionRan = true;
			}

			await ExecuteAsync(conn, tx, BuildReconcileSql(boardColumns), cancellationToken, labId, labName, runId).ConfigureAwait(false);

			var census = await ReadCensusAsync(conn, tx, upstreamRan, resubmissionRan, cancellationToken).ConfigureAwait(false);

			await tx.CommitAsync(cancellationToken).ConfigureAwait(false);
			return census;
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

	private static async Task ExecuteAsync(
		SqlConnection conn, SqlTransaction? tx, string sql, CancellationToken ct,
		int labId, string labName, string runId)
	{
		await using var cmd = new SqlCommand(sql, conn, tx) { CommandTimeout = 0 };
		cmd.Parameters.AddWithValue("@LabId", labId);
		cmd.Parameters.AddWithValue("@LabName", labName ?? string.Empty);
		cmd.Parameters.AddWithValue("@RunId", runId ?? string.Empty);
		cmd.Parameters.AddWithValue("@NowUtc", DateTime.UtcNow);
		await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
	}

	private sealed record SourceProbe(bool HasPayerValidationReport, bool HasClaimStatus, bool HasLineLevelTable);

	/// <summary>
	/// Both orphan checks are advisory (OD-03): an unavailable source skips the check with a
	/// warning and the orphan falls through to the ordinary rules. Neither may fail the lab, so
	/// availability is probed rather than assumed.
	/// </summary>
	private static async Task<SourceProbe> ProbeSourcesAsync(
		SqlConnection conn, SqlTransaction? tx, OrphanDispositionSettings settings, CancellationToken ct)
	{
		var pvr = QualifyTableName(settings.PayerValidationReportTable, "dbo.PayerValidationReport");
		var lineLevel = QualifyTableName(settings.LineLevelTable, "dbo.LineLevelData");

		var sql = $@"
SELECT
    CASE WHEN OBJECT_ID('{pvr}', 'U') IS NOT NULL THEN 1 ELSE 0 END,
    CASE WHEN COL_LENGTH('{pvr}', 'ClaimStatus') IS NOT NULL THEN 1 ELSE 0 END,
    CASE WHEN OBJECT_ID('{lineLevel}', 'U') IS NOT NULL
          AND COL_LENGTH('{lineLevel}', 'VisitNumber')    IS NOT NULL
          AND COL_LENGTH('{lineLevel}', 'CPTCode')        IS NOT NULL
          AND COL_LENGTH('{lineLevel}', 'DateOfService')  IS NOT NULL
          AND COL_LENGTH('{lineLevel}', 'FirstBilledDate') IS NOT NULL
         THEN 1 ELSE 0 END;";

		await using var cmd = new SqlCommand(sql, conn, tx) { CommandTimeout = 60 };
		await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

		if (!await reader.ReadAsync(ct).ConfigureAwait(false))
			return new SourceProbe(false, false, false);

		return new SourceProbe(reader.GetInt32(0) == 1, reader.GetInt32(1) == 1, reader.GetInt32(2) == 1);
	}

	private static async Task<HashSet<string>> GetColumnSetAsync(
		SqlConnection conn, SqlTransaction? tx, string table, CancellationToken ct)
	{
		var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
		var qualified = QualifyTableName(table, "dbo.DenialTaskBoard");

		var sql = $@"
SELECT c.name
FROM   sys.columns c
WHERE  c.object_id = OBJECT_ID('{qualified}', 'U');";

		await using var cmd = new SqlCommand(sql, conn, tx) { CommandTimeout = 60 };
		await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

		while (await reader.ReadAsync(ct).ConfigureAwait(false))
			columns.Add(reader.GetString(0));

		return columns;
	}

	/// <summary>Bracket-quotes a configured schema.table, falling back when it is malformed.</summary>
	private static string QualifyTableName(string? configured, string fallback)
	{
		var value = (configured ?? "").Trim();
		if (value.Length == 0) value = fallback;

		var match = System.Text.RegularExpressions.Regex.Match(
			value, @"^\[?(?<schema>[A-Za-z0-9_]+)\]?\.\[?(?<table>[A-Za-z0-9_]+)\]?$");

		if (!match.Success)
			throw new InvalidOperationException($"Table name must be 'schema.table'. Value was '{configured}'.");

		return $"[{match.Groups["schema"].Value}].[{match.Groups["table"].Value}]";
	}

	/// <summary>A task-board column reference, or a typed NULL where the lab does not have it.</summary>
	private static string Col(HashSet<string> columns, string name, string nullAs)
		=> columns.Contains(name) ? $"tb.[{name}]" : $"CAST(NULL AS {nullAs})";

	/// <summary>Loads the configured write-off / adjustment vocabulary in its normalized form.</summary>
	private static async Task SeedResolutionStatusMapAsync(
		SqlConnection conn, SqlTransaction tx, OrphanDispositionSettings settings, CancellationToken ct)
	{
		var map = new DataTable();
		map.Columns.Add("NormalizedValue", typeof(string));
		map.Columns.Add("ClosureReason", typeof(string));

		void Add(IReadOnlyList<string> values, string reason)
		{
			foreach (var value in values ?? Array.Empty<string>())
			{
				var normalized = NormalizeStatus(value);
				if (normalized.Length == 0) continue;

				var row = map.NewRow();
				row["NormalizedValue"] = normalized;
				row["ClosureReason"] = reason;
				map.Rows.Add(row);
			}
		}

		Add(settings.WriteOffStatusValues, "Write Off");
		Add(settings.AdjustedStatusValues, "Adjusted");

		await BulkCopyTempTableAsync(conn, tx, map, "#ResolutionStatusMap", ct).ConfigureAwait(false);
	}

	/// <summary>
	/// UR-03: case-insensitive, whitespace-trimmed, and blind to spaces and hyphens, so
	/// "Write Off", "Write-Off", "WriteOff" and "write off" all collapse to one token.
	/// </summary>
	private static string NormalizeStatus(string? value)
		=> (value ?? "").Trim().Replace(" ", "").Replace("-", "").ToLowerInvariant();

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
);

-- Every existing non-closed task whose denial did NOT recur in this run (spec §6 definition).
-- Materialized once so both orphan checks and the bucket rules read the same set.
CREATE TABLE #Orphans
(
	UniqueTrackId   NVARCHAR(450) NOT NULL,
	ClaimUID        NVARCHAR(600) NULL,
	ClaimID         NVARCHAR(150) NULL,
	CPTCode         NVARCHAR(50)  NULL,
	DateOfService   DATE          NULL,
	FirstBilledDate DATE          NULL,
	IsAssigned      BIT           NOT NULL
);

-- The verdict for an orphan the upstream data explains. One row per orphan at most: the PK is
-- what gives §6.1 precedence over §6.2 (OD-02), because the second insert cannot displace the first.
CREATE TABLE #OrphanDisposition
(
	UniqueTrackId   NVARCHAR(450) NOT NULL CONSTRAINT PK_OrphanDisposition PRIMARY KEY,
	ClosureReason   VARCHAR(40)   NOT NULL,
	SourcePayStatus VARCHAR(60)   NULL
);

-- The configured write-off / adjustment vocabulary, already normalized (UR-03).
CREATE TABLE #ResolutionStatusMap
(
	NormalizedValue NVARCHAR(120) NOT NULL,
	ClosureReason   VARCHAR(40)   NOT NULL
);

-- One row per run of PayerValidationReport, keyed the way the task board is, so the §6.1 join is
-- a single set-based pass rather than a query per orphan (UR-09).
CREATE TABLE #PvrClaim
(
	ClaimUID        NVARCHAR(600) NULL,
	CPTCode         NVARCHAR(50)  NULL,
	PayStatusRaw    NVARCHAR(120) NULL,
	PayStatusNorm   NVARCHAR(120) NULL,
	ClaimStatusRaw  NVARCHAR(120) NULL,
	ClaimStatusNorm NVARCHAR(120) NULL
);

-- Orphan statuses that matched neither list, surfaced so a missing spelling is caught on the run
-- that introduces it rather than a month later (NF-16).
CREATE TABLE #UnmatchedOrphanStatus
(
	SourceStatus NVARCHAR(120) NULL
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
CREATE NONCLUSTERED INDEX IX_DeletedUnassignedClaimUIDs_ClaimUID ON #DeletedUnassignedClaimUIDs (ClaimUID);
CREATE NONCLUSTERED INDEX IX_Orphans_ClaimUID_CPT ON #Orphans (ClaimUID, CPTCode);
CREATE NONCLUSTERED INDEX IX_Orphans_Claim_CPT_Dos ON #Orphans (ClaimID, CPTCode, DateOfService);
CREATE NONCLUSTERED INDEX IX_PvrClaim_ClaimUID_CPT ON #PvrClaim (ClaimUID, CPTCode);
CREATE NONCLUSTERED INDEX IX_ResolutionStatusMap_Value ON #ResolutionStatusMap (NormalizedValue);";

		await using var cmd = new SqlCommand(sql, conn, tx)
		{
			CommandTimeout = 0
		};

		await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
	}

	/// <summary>
	/// The identity of a task board row, tolerating rows written before UniqueTrackId existed
	/// by rebuilding it from its three parts (RC-05).
	/// </summary>
	private const string BoardKeySql = @"
		ISNULL(
			NULLIF(LTRIM(RTRIM(ISNULL(tb.UniqueTrackId, ''))), ''),
			CONCAT(
				LTRIM(RTRIM(ISNULL(tb.ClaimUID, ''))), '|',
				LTRIM(RTRIM(ISNULL(tb.CPTCode, ''))), '|',
				LTRIM(RTRIM(ISNULL(tb.DenialCode, '')))))";

	/// <summary>True when the row's denial recurred in the run being processed.</summary>
	private const string InCurrentRunSql = @"
		EXISTS (SELECT 1 FROM #CurrentTaskKeys c WHERE c.UniqueTrackId = " + BoardKeySql + ")";

	/// <summary>
	/// Classifies every existing task before anything is written (RC-06). An orphan is an
	/// existing, non-closed task whose denial is absent from the current run set.
	/// </summary>
	private static string BuildOrphansSql(HashSet<string> cols)
	{
		var claimUid = Col(cols, "ClaimUID", "NVARCHAR(600)");
		var claimId = Col(cols, "ClaimID", "NVARCHAR(150)");
		var dos = Col(cols, "DateOfService", "NVARCHAR(50)");
		var firstBilled = Col(cols, "FirstBilledDate", "NVARCHAR(50)");

		return $@"
INSERT INTO #Orphans (UniqueTrackId, ClaimUID, ClaimID, CPTCode, DateOfService, FirstBilledDate, IsAssigned)
SELECT
	{BoardKeySql},
	LTRIM(RTRIM(ISNULL({claimUid}, ''))),
	LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(150), {claimId}), ''))),
	LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50), tb.CPTCode), ''))),
	TRY_CONVERT(DATE, {dos}),
	TRY_CONVERT(DATE, {firstBilled}),
	CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(tb.AssignedTo, ''))), '') IS NOT NULL THEN 1 ELSE 0 END
FROM dbo.DenialTaskBoard tb
WHERE tb.LabId = @LabId
  AND UPPER(LTRIM(RTRIM(ISNULL(tb.Status, '')))) <> 'CLOSED'
  AND NOT {InCurrentRunSql};";
	}

	/// <summary>
	/// Spec Â§6.1. Reads the ENTIRE PayerValidationReport for the run â€” deliberately not filtered to
	/// the denied rows â€” and asks what the claim line became. A line the source says was written off
	/// or adjusted is resolved, not missing, so it must not reach a reviewer as an unexplained
	/// disappearance (RC-16).
	///
	/// Matching is on ClaimUID + CPTCode, without the denial code (UR-02): a non-denied row carries
	/// no denial code, and the disposition applies to the claim line as a whole, so every task on
	/// that line is dispositioned together.
	/// </summary>
	private static string BuildUpstreamResolutionSql(OrphanDispositionSettings settings, SourceProbe probe)
	{
		var pvr = QualifyTableName(settings.PayerValidationReportTable, "dbo.PayerValidationReport");

		// UR-06 places PayStatus above ClaimStatus. That precedence is free here: the second insert
		// carries a NOT EXISTS against the PK, so it can only fill orphans PayStatus did not answer.
		var claimStatusRaw = probe.HasClaimStatus
			? "CONVERT(NVARCHAR(120), p.ClaimStatus)"
			: "CAST(NULL AS NVARCHAR(120))";
		var claimStatusNorm = probe.HasClaimStatus
			? "LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(120), p.ClaimStatus), ''))), ' ', ''), '-', ''))"
			: "CAST(NULL AS NVARCHAR(120))";

		var claimStatusPass = probe.HasClaimStatus
			? @"
INSERT INTO #OrphanDisposition (UniqueTrackId, ClosureReason, SourcePayStatus)
SELECT UniqueTrackId, ClosureReason, SourcePayStatus
FROM (
	SELECT
		o.UniqueTrackId,
		m.ClosureReason,
		CONVERT(VARCHAR(60), p.ClaimStatusRaw) AS SourcePayStatus,
		ROW_NUMBER() OVER (PARTITION BY o.UniqueTrackId ORDER BY m.ClosureReason) AS rn
	FROM #Orphans o
	JOIN #PvrClaim p ON p.ClaimUID = o.ClaimUID AND p.CPTCode = o.CPTCode
	JOIN #ResolutionStatusMap m ON m.NormalizedValue = p.ClaimStatusNorm
) x
WHERE x.rn = 1
  AND NOT EXISTS (SELECT 1 FROM #OrphanDisposition d WHERE d.UniqueTrackId = x.UniqueTrackId);"
			: "";

		return $@"
-- Key the run's rows the way the task board is keyed. The ClaimUID expression mirrors
-- BuildClaimUid in the worker, including the trailing .00 that visit and accession numbers pick up
-- from being carried as floats.
INSERT INTO #PvrClaim (ClaimUID, CPTCode, PayStatusRaw, PayStatusNorm, ClaimStatusRaw, ClaimStatusNorm)
SELECT
	CONCAT(v.Visit, '_', v.Accession, '_',
	       ISNULL(CONVERT(VARCHAR(8), TRY_CONVERT(DATE, p.DateOfService), 112), '')),
	LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50), p.CPTCode), ''))),
	CONVERT(NVARCHAR(120), p.PayStatus),
	LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(120), p.PayStatus), ''))), ' ', ''), '-', '')),
	{claimStatusRaw},
	{claimStatusNorm}
FROM {pvr} p
CROSS APPLY (
	SELECT
		Visit = CASE
			WHEN RIGHT(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(150), p.VisitNumber), ''))), 3) = '.00'
			THEN LEFT(LTRIM(RTRIM(CONVERT(NVARCHAR(150), p.VisitNumber))),
			          LEN(LTRIM(RTRIM(CONVERT(NVARCHAR(150), p.VisitNumber)))) - 3)
			ELSE LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(150), p.VisitNumber), ''))) END,
		Accession = CASE
			WHEN RIGHT(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(150), p.AccessionNo), ''))), 3) = '.00'
			THEN LEFT(LTRIM(RTRIM(CONVERT(NVARCHAR(150), p.AccessionNo))),
			          LEN(LTRIM(RTRIM(CONVERT(NVARCHAR(150), p.AccessionNo)))) - 3)
			ELSE LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(150), p.AccessionNo), ''))) END
) v
WHERE p.RunId = @RunId;

-- PayStatus pass.
INSERT INTO #OrphanDisposition (UniqueTrackId, ClosureReason, SourcePayStatus)
SELECT UniqueTrackId, ClosureReason, SourcePayStatus
FROM (
	SELECT
		o.UniqueTrackId,
		m.ClosureReason,
		CONVERT(VARCHAR(60), p.PayStatusRaw) AS SourcePayStatus,
		ROW_NUMBER() OVER (PARTITION BY o.UniqueTrackId ORDER BY m.ClosureReason) AS rn
	FROM #Orphans o
	JOIN #PvrClaim p ON p.ClaimUID = o.ClaimUID AND p.CPTCode = o.CPTCode
	JOIN #ResolutionStatusMap m ON m.NormalizedValue = p.PayStatusNorm
) x
WHERE x.rn = 1
  AND NOT EXISTS (SELECT 1 FROM #OrphanDisposition d WHERE d.UniqueTrackId = x.UniqueTrackId);
{claimStatusPass}

-- NF-16: statuses seen on an orphan that matched neither configured list. A missing spelling is
-- caught on the run that introduces it rather than a month later.
INSERT INTO #UnmatchedOrphanStatus (SourceStatus)
SELECT DISTINCT p.PayStatusRaw
FROM #Orphans o
JOIN #PvrClaim p ON p.ClaimUID = o.ClaimUID AND p.CPTCode = o.CPTCode
WHERE NULLIF(LTRIM(RTRIM(ISNULL(p.PayStatusRaw, ''))), '') IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM #ResolutionStatusMap m WHERE m.NormalizedValue = p.PayStatusNorm);";
	}

	/// <summary>
	/// Spec Â§6.2. Only orphans Â§6.1 did not explain reach this: the source data STATES an outcome
	/// while a moved bill date only INFERS one, so the stated outcome wins (OD-02).
	///
	/// FirstBilledDate is read from the task board rather than DenialLineItem as the spec words it.
	/// Both are populated from the same source row, and the board is the table the orphan set is
	/// already built from, so this avoids a second join for an identical value.
	/// </summary>
	private static string BuildResubmissionSql(OrphanDispositionSettings settings, HashSet<string> cols)
	{
		var lineLevel = QualifyTableName(settings.LineLevelTable, "dbo.LineLevelData");

		return $@"
INSERT INTO #OrphanDisposition (UniqueTrackId, ClosureReason, SourcePayStatus)
SELECT DISTINCT o.UniqueTrackId, 'Re-Submitted', NULL
FROM #Orphans o
WHERE o.FirstBilledDate IS NOT NULL
  AND o.DateOfService IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM #OrphanDisposition d WHERE d.UniqueTrackId = o.UniqueTrackId)
  AND EXISTS (
      SELECT 1
      FROM {lineLevel} ll
      WHERE LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(150), ll.VisitNumber), ''))) = o.ClaimID
        AND LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50), ll.CPTCode), ''))) = o.CPTCode
        AND TRY_CONVERT(DATE, ll.DateOfService) = o.DateOfService
        AND TRY_CONVERT(DATE, ll.FirstBilledDate) > o.FirstBilledDate
  );";
	}

	/// <summary>
	/// The bucket rules (spec Â§5). Evaluation order is B1 -> B2 -> B3 -> B4 -> B5 -> B6 -> B7 and
	/// the first match wins (RC-07): Closed is exempt from everything else, and a denial the source
	/// already resolved is stale regardless of who owns it.
	/// </summary>
	private static string BuildReconcileSql(HashSet<string> cols)
	{
		var claimUid = Col(cols, "ClaimUID", "NVARCHAR(600)");
		var claimId = Col(cols, "ClaimID", "NVARCHAR(150)");
		var dos = Col(cols, "DateOfService", "NVARCHAR(50)");
		var payer = Col(cols, "PayerName", "NVARCHAR(256)");
		var balance = Col(cols, "InsuranceBalance", "DECIMAL(18,2)");
		var workflow = Col(cols, "WorkFlowStatus", "NVARCHAR(100)");
		var comments = Col(cols, "ReviewerComments", "NVARCHAR(MAX)");
		var opened = Col(cols, "DateOpened", "NVARCHAR(50)");
		var completed = Col(cols, "DateCompleted", "NVARCHAR(50)");
		var taskId = Col(cols, "TaskID", "NVARCHAR(100)");

		// A curated snapshot rather than SELECT * : the archive is for reporting, and the row is
		// about to be deleted, so this is the last chance to keep what a person would ask about.
		var snapshot = $@"(SELECT
				{taskId} AS TaskID,
				tb.Status AS [Status],
				{workflow} AS WorkFlowStatus,
				tb.AssignedTo AS AssignedTo,
				{balance} AS InsuranceBalance,
				tb.DenialCode AS DenialCode,
				tb.CPTCode AS CPTCode,
				tb.RunId AS RunId
			FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)";

		return $@"
/* â”€â”€ B1 â€” Closed. Archived, then removed. Exempt from every other rule (RC-08). â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */
IF OBJECT_ID('dbo.DenialClosureLog', 'U') IS NOT NULL
BEGIN
	INSERT INTO dbo.DenialClosureLog
	(ClaimUID, LabId, LabName, RunId, OriginRunId, UniqueTrackId, ClaimID, CPTCode,
	 DenialCode, DateOfService, PayerName, InsuranceBalance, ClosureReason, SourcePayStatus,
	 FinalWorkFlowStatus, AssignedTo, ReviewerComments, DateOpened, DateCompleted, ArchivedOn, TaskSnapshot)
	SELECT
		{claimUid}, tb.LabId, tb.LabName, @RunId, tb.RunId,
		{BoardKeySql},
		CONVERT(NVARCHAR(150), {claimId}),
		CONVERT(NVARCHAR(50), tb.CPTCode),
		CONVERT(NVARCHAR(100), tb.DenialCode),
		TRY_CONVERT(DATE, {dos}),
		{payer}, {balance},
		'Closed by Reviewer',
		NULL,
		ISNULL(NULLIF(LTRIM(RTRIM(ISNULL({workflow}, ''))), ''), tb.Status),
		tb.AssignedTo, {comments},
		TRY_CONVERT(DATE, {opened}), TRY_CONVERT(DATE, {completed}),
		@NowUtc, {snapshot}
	FROM dbo.DenialTaskBoard tb
	WHERE tb.LabId = @LabId
	  AND UPPER(LTRIM(RTRIM(ISNULL(tb.Status, '')))) = 'CLOSED';
END;

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

/* â”€â”€ B2 / B3 â€” the source already explained the disappearance. Archived, then removed. â”€â”€â”€â”€â”€â”€â”€â”€
   No verification item is raised: the data has answered the question a verifier would be asked
   (UR-05 / RS-05). ClosureReason distinguishes Write Off, Adjusted and Re-Submitted. */
IF OBJECT_ID('dbo.DenialClosureLog', 'U') IS NOT NULL
BEGIN
	INSERT INTO dbo.DenialClosureLog
	(ClaimUID, LabId, LabName, RunId, OriginRunId, UniqueTrackId, ClaimID, CPTCode,
	 DenialCode, DateOfService, PayerName, InsuranceBalance, ClosureReason, SourcePayStatus,
	 FinalWorkFlowStatus, AssignedTo, ReviewerComments, DateOpened, DateCompleted, ArchivedOn, TaskSnapshot)
	SELECT
		{claimUid}, tb.LabId, tb.LabName, @RunId, tb.RunId,
		{BoardKeySql},
		CONVERT(NVARCHAR(150), {claimId}),
		CONVERT(NVARCHAR(50), tb.CPTCode),
		CONVERT(NVARCHAR(100), tb.DenialCode),
		TRY_CONVERT(DATE, {dos}),
		{payer}, {balance},
		d.ClosureReason,
		d.SourcePayStatus,
		d.ClosureReason,
		tb.AssignedTo, {comments},
		TRY_CONVERT(DATE, {opened}), TRY_CONVERT(DATE, {completed}),
		@NowUtc, {snapshot}
	FROM dbo.DenialTaskBoard tb
	JOIN #OrphanDisposition d ON d.UniqueTrackId = {BoardKeySql}
	WHERE tb.LabId = @LabId;
END;

IF OBJECT_ID('dbo.DenialTaskHistory', 'U') IS NOT NULL
BEGIN
	INSERT INTO dbo.DenialTaskHistory
	(TaskID, UniqueTrackId, LabId, RunId, ActionType, OldStatus, NewStatus,
	 OldAssignedTo, NewAssignedTo, Comments, ActionBy, ActionDate)
	SELECT
		ISNULL({taskId}, ''),
		{BoardKeySql},
		tb.LabId,
		@RunId,
		CASE WHEN d.ClosureReason = 'Re-Submitted' THEN 'ReSubmitted' ELSE 'ResolvedUpstream' END,
		tb.Status,
		d.ClosureReason,
		tb.AssignedTo,
		tb.AssignedTo,
		CONCAT('Resolved upstream as ', d.ClosureReason, ISNULL(' (source status: ' + d.SourcePayStatus + ')', '')),
		'Denial Database Processor',
		@NowUtc
	FROM dbo.DenialTaskBoard tb
	JOIN #OrphanDisposition d ON d.UniqueTrackId = {BoardKeySql}
	WHERE tb.LabId = @LabId;
END;

DELETE li
FROM dbo.DenialLineItem li
WHERE li.LabId = @LabId
  AND EXISTS
  (
	  SELECT 1
	  FROM dbo.DenialTaskBoard tb
	  JOIN #OrphanDisposition d ON d.UniqueTrackId = {BoardKeySql}
	  WHERE tb.LabId = li.LabId AND tb.ClaimUID = li.ClaimUID
  );

DELETE tb
FROM dbo.DenialTaskBoard tb
WHERE tb.LabId = @LabId
  AND EXISTS (SELECT 1 FROM #OrphanDisposition d WHERE d.UniqueTrackId = {BoardKeySql});

/* â”€â”€ Claim UIDs of tasks nobody owns, used by the line-item cleanup below. â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */
INSERT INTO #DeletedUnassignedClaimUIDs (ClaimUID)
SELECT DISTINCT NULLIF(LTRIM(RTRIM(tb.ClaimUID)), '')
FROM dbo.DenialTaskBoard tb
WHERE tb.LabId = @LabId
  AND NULLIF(LTRIM(RTRIM(ISNULL(tb.AssignedTo, ''))), '') IS NULL
  AND NULLIF(LTRIM(RTRIM(tb.ClaimUID)), '') IS NOT NULL;

/* â”€â”€ B6 â€” orphaned and assigned. The source does not explain it and a reviewer owns it, so it
   goes to verification and STAYS on the board, keeping their visible ownership (RC-13). â”€â”€â”€â”€â”€â”€ */
IF OBJECT_ID('dbo.DenialVerificationTask', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerificationTask', 'UniqueTrackId') IS NOT NULL
   AND COL_LENGTH('dbo.DenialVerificationTask', 'MissingDetectedRunId') IS NOT NULL
BEGIN
	INSERT INTO dbo.DenialVerificationTask
	(
		TaskID, UniqueTrackId, ClaimID, PatientId, CPTCode, DenialCode, DenialDescription,
		DenialClassification, ActionCode, RecommendedAction, ActionCategory, Task, Priority,
		InsuranceBalance, Status, AssignedTo, DateOpened, DueDate, ReviewerComments,
		LabId, LabName, OriginalRunId, MissingDetectedRunId, RunId,
		VerificationStatus, VerificationComments, MovedOn
	)
	SELECT DISTINCT
		ISNULL({taskId}, ''),
		{BoardKeySql},
		CONVERT(NVARCHAR(100), {claimId}),
		tb.PatientId, tb.CPTCode, tb.DenialCode, tb.DenialDescription,
		tb.DenialClassification, tb.ActionCode, tb.RecommendedAction, tb.ActionCategory, tb.Task, tb.Priority,
		ISNULL({balance}, 0),
		'Verification Pending',
		tb.AssignedTo,
		TRY_CONVERT(DATE, {opened}),
		tb.DueDate,
		{comments},
		tb.LabId, tb.LabName, tb.RunId, @RunId, @RunId,
		'Verification Pending',
		'Raised by Denial Database Processor: the denial did not recur in this run.',
		@NowUtc
	FROM dbo.DenialTaskBoard tb
	JOIN #Orphans o ON o.UniqueTrackId = {BoardKeySql}
	WHERE tb.LabId = @LabId
	  AND o.IsAssigned = 1
	  AND NOT EXISTS (SELECT 1 FROM #OrphanDisposition d WHERE d.UniqueTrackId = o.UniqueTrackId)
	  AND NOT EXISTS
	  (
		  SELECT 1
		  FROM dbo.DenialVerificationTask dv
		  WHERE dv.UniqueTrackId = o.UniqueTrackId
		    AND dv.MissingDetectedRunId = @RunId
	  );
END;

IF OBJECT_ID('dbo.DenialTaskHistory', 'U') IS NOT NULL
BEGIN
	INSERT INTO dbo.DenialTaskHistory
	(TaskID, UniqueTrackId, LabId, RunId, ActionType, OldStatus, NewStatus,
	 OldAssignedTo, NewAssignedTo, Comments, ActionBy, ActionDate)
	SELECT DISTINCT
		ISNULL({taskId}, ''), o.UniqueTrackId, tb.LabId, @RunId,
		'RaisedForVerification', tb.Status, 'Verification Pending',
		tb.AssignedTo, tb.AssignedTo,
		'Denial did not recur in this run.',
		'Denial Database Processor', @NowUtc
	FROM dbo.DenialTaskBoard tb
	JOIN #Orphans o ON o.UniqueTrackId = {BoardKeySql}
	WHERE tb.LabId = @LabId
	  AND o.IsAssigned = 1
	  AND NOT EXISTS (SELECT 1 FROM #OrphanDisposition d WHERE d.UniqueTrackId = o.UniqueTrackId);
END;

UPDATE tb
SET WorkFlowStatus = 'Verification Pending',
	ClaimFrom = 'Old Run',
	IsCurrentDenial = 0,
	RunId = @RunId
FROM dbo.DenialTaskBoard tb
JOIN #Orphans o ON o.UniqueTrackId = {BoardKeySql}
WHERE tb.LabId = @LabId
  AND o.IsAssigned = 1
  AND NOT EXISTS (SELECT 1 FROM #OrphanDisposition d WHERE d.UniqueTrackId = o.UniqueTrackId);

UPDATE li
SET ClaimFrom = 'Old Run',
	WorkFlowStatus = 'Verification Pending'
FROM dbo.DenialLineItem li
WHERE li.LabId = @LabId
  AND EXISTS
  (
	  SELECT 1
	  FROM dbo.DenialTaskBoard tb
	  JOIN #Orphans o ON o.UniqueTrackId = {BoardKeySql}
	  WHERE tb.LabId = li.LabId
	    AND tb.ClaimUID = li.ClaimUID
	    AND o.IsAssigned = 1
	    AND NOT EXISTS (SELECT 1 FROM #OrphanDisposition d WHERE d.UniqueTrackId = o.UniqueTrackId)
  );

/* â”€â”€ B5 / B7 â€” carried-but-unassigned and orphaned-but-unassigned. No human work to protect, so
   the rows go and the bulk copy re-inserts whatever the current run carries. B6 rows survive
   because they are assigned and absent from the current run. â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ */
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

IF OBJECT_ID('dbo.DenialTaskHistory', 'U') IS NOT NULL
BEGIN
	INSERT INTO dbo.DenialTaskHistory
	(TaskID, UniqueTrackId, LabId, RunId, ActionType, OldStatus, NewStatus,
	 OldAssignedTo, NewAssignedTo, Comments, ActionBy, ActionDate)
	SELECT DISTINCT
		ISNULL({taskId}, ''), o.UniqueTrackId, tb.LabId, @RunId,
		'RemovedUnassigned', tb.Status, NULL, tb.AssignedTo, NULL,
		'Denial did not recur and nobody owned it.',
		'Denial Database Processor', @NowUtc
	FROM dbo.DenialTaskBoard tb
	JOIN #Orphans o ON o.UniqueTrackId = {BoardKeySql}
	WHERE tb.LabId = @LabId AND o.IsAssigned = 0;
END;

DELETE tb
FROM dbo.DenialTaskBoard tb
WHERE tb.LabId = @LabId
  AND
  (
	  NULLIF(LTRIM(RTRIM(ISNULL(tb.AssignedTo, ''))), '') IS NULL
	  OR {InCurrentRunSql}
  );";
	}

	/// <summary>Reads the bucket counts back before the transaction commits (NF-15).</summary>
	private static async Task<ReconcileCensus> ReadCensusAsync(
		SqlConnection conn, SqlTransaction tx, bool upstreamRan, bool resubmissionRan, CancellationToken ct)
	{
		const string sql = @"
SELECT
	Orphans        = (SELECT COUNT(1) FROM #Orphans),
	Resolved       = (SELECT COUNT(1) FROM #OrphanDisposition WHERE ClosureReason IN ('Write Off','Adjusted')),
	ReSubmitted    = (SELECT COUNT(1) FROM #OrphanDisposition WHERE ClosureReason = 'Re-Submitted'),
	ForVerification= (SELECT COUNT(1) FROM #Orphans o WHERE o.IsAssigned = 1
	                  AND NOT EXISTS (SELECT 1 FROM #OrphanDisposition d WHERE d.UniqueTrackId = o.UniqueTrackId)),
	DeletedOrphans = (SELECT COUNT(1) FROM #Orphans o WHERE o.IsAssigned = 0
	                  AND NOT EXISTS (SELECT 1 FROM #OrphanDisposition d WHERE d.UniqueTrackId = o.UniqueTrackId));

SELECT DISTINCT TOP (20) SourceStatus FROM #UnmatchedOrphanStatus WHERE SourceStatus IS NOT NULL;";

		await using var cmd = new SqlCommand(sql, conn, tx) { CommandTimeout = 0 };
		await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

		int orphans = 0, resolved = 0, resubmitted = 0, verification = 0, deleted = 0;

		if (await reader.ReadAsync(ct).ConfigureAwait(false))
		{
			orphans = reader.GetInt32(0);
			resolved = reader.GetInt32(1);
			resubmitted = reader.GetInt32(2);
			verification = reader.GetInt32(3);
			deleted = reader.GetInt32(4);
		}

		var unmatched = new List<string>();
		if (await reader.NextResultAsync(ct).ConfigureAwait(false))
		{
			while (await reader.ReadAsync(ct).ConfigureAwait(false))
			{
				if (!reader.IsDBNull(0))
					unmatched.Add(reader.GetString(0));
			}
		}

		// ArchivedClosed is not counted separately: closed tasks are archived and deleted in the
		// same statement pair, and the archive itself is queried per run for the reported figure.
		return new ReconcileCensus(orphans, resolved, resubmitted, verification, deleted, 0,
			upstreamRan, resubmissionRan, unmatched);
	}

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
