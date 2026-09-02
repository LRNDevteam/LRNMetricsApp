using Microsoft.Data.SqlClient;

namespace DenialDatabaseProcessorWorker.Services;

/// <summary>
/// The archive of record for denials that have terminally left the task board (spec §3.3, §7).
///
/// NAMED DenialClosureLog, NOT DenialClosedClaims. A table called dbo.DenialClosedClaims already
/// exists in every lab database, created by LRN.ReportsApi: it is CLAIM-grain, carries
/// UNIQUE(LabId, ClaimId), and backs the reviewer "close claim" feature together with
/// dbo.DenialClosedClaimsHistory. This one is DENIAL-EVENT-grain and append-only — AR-05 requires
/// several rows per UniqueTrackId over its life, which that unique index forbids. The two answer
/// different questions and cannot share a name.
///
/// Append-only: the worker never updates or deletes a row here (DD-06). A denial restored through
/// verification is re-inserted onto the board and its archive row is left standing.
/// </summary>
public sealed class DenialClosureLogRepository
{
	public const string TableName = "dbo.DenialClosureLog";

	/// <summary>
	/// Closure reasons that permanently retire a denial (AR-03). A UniqueTrackId archived under one
	/// of these must not be re-created by a later run, which is what makes "the rules do not apply
	/// to closed denials" true across runs rather than only within one.
	///
	/// Re-Submitted, Write Off and Adjusted are deliberately absent (AR-04): they describe the
	/// state of a claim at a point in time, not a human decision to stop working it. If the payer
	/// denies the resubmitted claim, that is legitimately new work.
	/// </summary>
	public const string SuppressingReasons = "'Closed by Reviewer', 'Verified Invalid'";

	private readonly string _connectionString;
	private readonly int _commandTimeoutSeconds;

	public DenialClosureLogRepository(string connectionString, int commandTimeoutSeconds)
	{
		if (string.IsNullOrWhiteSpace(connectionString))
			throw new ArgumentException("Lab database connection string is required.", nameof(connectionString));

		_connectionString = connectionString;
		_commandTimeoutSeconds = commandTimeoutSeconds;
	}

	/// <summary>
	/// Creates the archive if it is absent. Idempotent, and cheap enough to run per lab per pass:
	/// a lab that has never been migrated still gets a working archive on its first run.
	/// </summary>
	public async Task EnsureTableAsync(CancellationToken ct)
	{
		var sql = $@"
IF OBJECT_ID('{TableName}', 'U') IS NULL
BEGIN
    CREATE TABLE {TableName}
    (
        DenialClosureLogId  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClosureLog PRIMARY KEY,
        LabId               INT            NOT NULL,
        LabName             NVARCHAR(255)  NULL,
        RunId               NVARCHAR(100)  NULL,
        OriginRunId         NVARCHAR(100)  NULL,
        ClaimUID            NVARCHAR(600)  NULL,
        UniqueTrackId       NVARCHAR(450)  NULL,
        ClaimID             NVARCHAR(150)  NULL,
        CPTCode             NVARCHAR(50)   NULL,
        DenialCode          NVARCHAR(100)  NULL,
        DateOfService       DATE           NULL,
        PayerName           NVARCHAR(256)  NULL,
        InsuranceBalance    DECIMAL(18,2)  NULL,
        ClosureReason       VARCHAR(40)    NOT NULL,
        SourcePayStatus     VARCHAR(60)    NULL,
        FinalWorkFlowStatus NVARCHAR(100)  NULL,
        AssignedTo          NVARCHAR(255)  NULL,
        ReviewerComments    NVARCHAR(MAX)  NULL,
        DateOpened          DATE           NULL,
        DateCompleted       DATE           NULL,
        ArchivedOn          DATETIME2(3)   NOT NULL CONSTRAINT DF_DenialClosureLog_ArchivedOn DEFAULT SYSUTCDATETIME(),
        TaskSnapshot        NVARCHAR(MAX)  NULL
    );

    CREATE INDEX IX_DenialClosureLog_Lab_Run_Reason
        ON {TableName} (LabId, RunId, ClosureReason);

    -- Supports the AR-03 suppression probe, which runs once per lab per pass.
    CREATE INDEX IX_DenialClosureLog_Lab_UID_Reason
        ON {TableName} (LabId, UniqueTrackId, ClosureReason);
END;";

		await using var conn = new SqlConnection(_connectionString);
		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = _commandTimeoutSeconds };
		await conn.OpenAsync(ct).ConfigureAwait(false);
		await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
	}

	/// <summary>
	/// UniqueTrackIds this lab has permanently retired (AR-03). The caller drops these from the
	/// built task board before load, so a denial a reviewer closed does not walk back on.
	/// </summary>
	public async Task<HashSet<string>> GetSuppressedTrackIdsAsync(int labId, CancellationToken ct)
	{
		var suppressed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

		var sql = $@"
IF OBJECT_ID('{TableName}', 'U') IS NOT NULL
BEGIN
    SELECT DISTINCT UniqueTrackId
    FROM   {TableName}
    WHERE  LabId = @LabId
      AND  ClosureReason IN ({SuppressingReasons})
      AND  NULLIF(LTRIM(RTRIM(ISNULL(UniqueTrackId, ''))), '') IS NOT NULL;
END;";

		await using var conn = new SqlConnection(_connectionString);
		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = _commandTimeoutSeconds };
		cmd.Parameters.AddWithValue("@LabId", labId);

		await conn.OpenAsync(ct).ConfigureAwait(false);
		await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

		while (await reader.ReadAsync(ct).ConfigureAwait(false))
		{
			if (!reader.IsDBNull(0))
				suppressed.Add(reader.GetString(0).Trim());
		}

		return suppressed;
	}

	/// <summary>
	/// What this run archived, by reason. Written to the info log so an unexpected mass closure or
	/// a mis-mapped status value is visible without a database query (NF-15).
	/// </summary>
	public async Task<Dictionary<string, int>> GetRunCensusAsync(int labId, string runId, CancellationToken ct)
	{
		var census = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

		var sql = $@"
IF OBJECT_ID('{TableName}', 'U') IS NOT NULL
BEGIN
    SELECT ClosureReason, COUNT_BIG(1)
    FROM   {TableName}
    WHERE  LabId = @LabId AND RunId = @RunId
    GROUP BY ClosureReason;
END;";

		await using var conn = new SqlConnection(_connectionString);
		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = _commandTimeoutSeconds };
		cmd.Parameters.AddWithValue("@LabId", labId);
		cmd.Parameters.AddWithValue("@RunId", runId ?? "");

		await conn.OpenAsync(ct).ConfigureAwait(false);
		await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

		while (await reader.ReadAsync(ct).ConfigureAwait(false))
			census[reader.GetString(0)] = Convert.ToInt32(reader.GetInt64(1));

		return census;
	}
}
