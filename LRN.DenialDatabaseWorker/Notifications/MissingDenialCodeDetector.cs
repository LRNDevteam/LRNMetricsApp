using DenialDatabaseProcessorWorker.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace DenialDatabaseProcessorWorker.Notifications;

/// <summary>
/// Detects denial codes that show up in a lab's own denied rows but are absent from LRNMaster's
/// active dbo.DenialMapperSuperMaster, records one row per lab+code in
/// dbo.MissingDenialCodeNotification (so AR Managers see it on login in the React workflow app), and
/// queues one AR-Manager email per newly created notification into dbo.DenialCodeMailQueue.
///
/// The mail queue is deliberately write-only from here: nothing in this worker sends the queued rows.
/// Graph API is not configured yet - a separate dispatcher will poll Status='Queued' once it is.
///
/// Best-effort throughout: a failure anywhere in here is logged and swallowed. Missing-code detection
/// must never turn a successful denial run into a failed one.
/// </summary>
public sealed class MissingDenialCodeDetector
{
	private readonly string _connectionString;
	private readonly ILogger<MissingDenialCodeDetector> _logger;

	public MissingDenialCodeDetector(IConfiguration configuration, ILogger<MissingDenialCodeDetector> logger)
	{
		_connectionString = configuration.GetConnectionString("DenialDatabase")
			?? throw new InvalidOperationException("Connection string 'DenialDatabase' not found.");
		_logger = logger;
	}

	public async Task DetectAndNotifyAsync(LabConfig lab, string runId, IEnumerable<string> denialCodes, CancellationToken ct)
	{
		try
		{
			var codes = denialCodes
				.Where(c => !string.IsNullOrWhiteSpace(c))
				.Select(c => c.Trim())
				.Distinct(StringComparer.OrdinalIgnoreCase)
				.ToList();

			if (codes.Count == 0) return;

			await using var conn = new SqlConnection(_connectionString);
			await conn.OpenAsync(ct);

			await EnsureSchemaAsync(conn, ct);

			var known = await LoadKnownSuperMasterCodesAsync(conn, ct);
			if (known is null)
			{
				// dbo.DenialMapperSuperMaster does not exist in this environment. Flagging every code
				// as "missing" in that state would be noise, not signal - skip quietly.
				_logger.LogWarning(
					"Lab {LabName}: dbo.DenialMapperSuperMaster does not exist. Skipping missing denial code detection.",
					lab.LabName);
				return;
			}

			var missing = codes.Where(c => !known.Contains(c)).ToList();
			if (missing.Count == 0) return;

			foreach (var code in missing)
			{
				var isNew = await UpsertNotificationAsync(conn, lab, runId, code, ct);
				if (isNew)
					await QueueMailAsync(conn, lab, code, ct);
			}

			_logger.LogInformation(
				"Lab {LabName}: {Count} denial code(s) not found in dbo.DenialMapperSuperMaster: {Codes}.",
				lab.LabName, missing.Count, string.Join(", ", missing));
		}
		catch (Exception ex)
		{
			_logger.LogWarning(ex, "Lab {LabName}: missing denial code detection failed; continuing without it.", lab.LabName);
		}
	}

	private static async Task<HashSet<string>?> LoadKnownSuperMasterCodesAsync(SqlConnection conn, CancellationToken ct)
	{
		const string sql = @"
IF OBJECT_ID('dbo.DenialMapperSuperMaster', 'U') IS NOT NULL
    SELECT DISTINCT DenialCode FROM dbo.DenialMapperSuperMaster WHERE IsActive = 1;";

		await using var cmd = new SqlCommand(sql, conn);
		await using var reader = await cmd.ExecuteReaderAsync(ct);

		if (reader.FieldCount == 0) return null;

		var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
		while (await reader.ReadAsync(ct))
			set.Add(reader.GetString(0));

		return set;
	}

	private static async Task<bool> UpsertNotificationAsync(SqlConnection conn, LabConfig lab, string runId, string denialCode, CancellationToken ct)
	{
		const string sql = @"
UPDATE dbo.MissingDenialCodeNotification
SET LastSeenOn = SYSUTCDATETIME(), OccurrenceCount = OccurrenceCount + 1, RunId = @RunId, LabName = @LabName
WHERE LabId = @LabId AND DenialCode = @DenialCode AND IsAcknowledged = 0;

IF @@ROWCOUNT = 0
BEGIN
    INSERT INTO dbo.MissingDenialCodeNotification (LabId, LabName, DenialCode, RunId)
    VALUES (@LabId, @LabName, @DenialCode, @RunId);
    SELECT CAST(1 AS BIT);
END
ELSE
    SELECT CAST(0 AS BIT);";

		await using var cmd = new SqlCommand(sql, conn);
		cmd.Parameters.AddWithValue("@LabId", lab.LabId);
		cmd.Parameters.AddWithValue("@LabName", (object?)lab.LabName ?? DBNull.Value);
		cmd.Parameters.AddWithValue("@DenialCode", denialCode);
		cmd.Parameters.AddWithValue("@RunId", (object?)runId ?? DBNull.Value);

		var result = await cmd.ExecuteScalarAsync(ct);
		return result is bool b && b;
	}

	private static async Task QueueMailAsync(SqlConnection conn, LabConfig lab, string denialCode, CancellationToken ct)
	{
		var recipients = await ResolveArManagerEmailsAsync(conn, lab.LabId, ct);
		if (recipients.Count == 0) return;

		const string sql = @"
INSERT INTO dbo.DenialCodeMailQueue (LabId, NotificationId, ToAddresses, Subject, Body, IsHtml)
VALUES (@LabId, NULL, @ToAddresses, @Subject, @Body, 1);";

		var subject = $"[{lab.LabName}] New denial code not in Denial Mapper Super Master";
		var body =
			$"<p>Denial code <strong>{System.Net.WebUtility.HtmlEncode(denialCode)}</strong> was found in {System.Net.WebUtility.HtmlEncode(lab.LabName)}'s " +
			"denial database but is not present in the central Denial Mapper Super Master.</p>" +
			"<p>Sign in to the Denial Workflow app to review it under Denial Action Master &gt; Missing Denial Codes.</p>";

		await using var cmd = new SqlCommand(sql, conn);
		cmd.Parameters.AddWithValue("@LabId", lab.LabId);
		cmd.Parameters.AddWithValue("@ToAddresses", string.Join(";", recipients));
		cmd.Parameters.AddWithValue("@Subject", subject);
		cmd.Parameters.AddWithValue("@Body", body);
		await cmd.ExecuteNonQueryAsync(ct);
	}

	private static async Task<List<string>> ResolveArManagerEmailsAsync(SqlConnection conn, int labId, CancellationToken ct)
	{
		const string sql = @"
SELECT DISTINCT lu.Email
FROM dbo.LabUsers lu
JOIN dbo.UserRoles ur ON ur.LabUserID = lu.LabUserID
JOIN dbo.Roles r ON r.RoleID = ur.RoleID
JOIN dbo.UserLabs ul ON ul.LabUserID = lu.LabUserID
WHERE lu.IsActive = 1 AND r.IsActive = 1
  AND REPLACE(r.RoleName, ' ', '') = 'ARManager'
  AND ul.LabId = @LabId
  AND lu.Email IS NOT NULL AND lu.Email <> ''";

		await using var cmd = new SqlCommand(sql, conn);
		cmd.Parameters.AddWithValue("@LabId", labId);
		await using var reader = await cmd.ExecuteReaderAsync(ct);

		var emails = new List<string>();
		while (await reader.ReadAsync(ct))
			emails.Add(reader.GetString(0));

		return emails;
	}

	private static async Task EnsureSchemaAsync(SqlConnection conn, CancellationToken ct)
	{
		const string sql = """
			IF OBJECT_ID('dbo.MissingDenialCodeNotification','U') IS NULL
			BEGIN
			    CREATE TABLE dbo.MissingDenialCodeNotification
			    (
			        NotificationId BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MissingDenialCodeNotification PRIMARY KEY,
			        LabId INT NOT NULL,
			        LabName NVARCHAR(120) NULL,
			        DenialCode NVARCHAR(50) NOT NULL,
			        RunId VARCHAR(30) NULL,
			        FirstSeenOn DATETIME2(3) NOT NULL CONSTRAINT DF_MDCN_FirstSeenOn DEFAULT SYSUTCDATETIME(),
			        LastSeenOn DATETIME2(3) NOT NULL CONSTRAINT DF_MDCN_LastSeenOn DEFAULT SYSUTCDATETIME(),
			        OccurrenceCount INT NOT NULL CONSTRAINT DF_MDCN_OccurrenceCount DEFAULT 1,
			        IsAcknowledged BIT NOT NULL CONSTRAINT DF_MDCN_IsAcknowledged DEFAULT 0,
			        AcknowledgedOn DATETIME2(3) NULL,
			        AcknowledgedByUserName NVARCHAR(200) NULL
			    );
			    CREATE UNIQUE INDEX UX_MDCN_Lab_Code_Active ON dbo.MissingDenialCodeNotification (LabId, DenialCode) WHERE IsAcknowledged = 0;
			    CREATE INDEX IX_MDCN_Lab_CreatedOn ON dbo.MissingDenialCodeNotification (LabId, LastSeenOn DESC);
			END

			IF OBJECT_ID('dbo.DenialCodeMailQueue','U') IS NULL
			BEGIN
			    CREATE TABLE dbo.DenialCodeMailQueue
			    (
			        MailQueueId BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialCodeMailQueue PRIMARY KEY,
			        LabId INT NOT NULL,
			        NotificationId BIGINT NULL,
			        ToAddresses NVARCHAR(1000) NOT NULL,
			        Subject NVARCHAR(300) NOT NULL,
			        Body NVARCHAR(MAX) NOT NULL,
			        IsHtml BIT NOT NULL CONSTRAINT DF_DCMQ_IsHtml DEFAULT 1,
			        Status VARCHAR(20) NOT NULL CONSTRAINT DF_DCMQ_Status DEFAULT 'Queued',
			        CreatedOn DATETIME2(3) NOT NULL CONSTRAINT DF_DCMQ_CreatedOn DEFAULT SYSUTCDATETIME(),
			        SentOn DATETIME2(3) NULL,
			        ErrorMessage NVARCHAR(MAX) NULL
			    );
			    CREATE INDEX IX_DCMQ_Status_CreatedOn ON dbo.DenialCodeMailQueue (Status, CreatedOn);
			END
			""";

		await using var cmd = new SqlCommand(sql, conn);
		await cmd.ExecuteNonQueryAsync(ct);
	}
}
