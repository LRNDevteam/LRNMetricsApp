using Microsoft.Data.SqlClient;

namespace DenialDatabaseProcessorWorker.Services;

/// <summary>
/// Issues TaskIDs from a per-lab sequence that persists between runs (spec DD-04 / MG-06).
///
/// The counter used to restart at 1 on every pass, so a task created in run 2 could be issued
/// TSK-00001 while a task surviving from run 1 already held it. UniqueTrackId is the real identity,
/// so reconciliation was never corrupted by this — but TaskID is what people quote to each other,
/// and two live tasks sharing one made it useless as a reference.
///
/// A block is reserved in one atomic statement per lab per run, rather than a round trip per task:
/// the run knows how many new tasks it is about to create before it creates any of them.
/// </summary>
public sealed class TaskIdSequenceRepository
{
	private const string SequenceTable = "dbo.DenialTaskIdSequence";

	private readonly string _connectionString;
	private readonly int _commandTimeoutSeconds;

	public TaskIdSequenceRepository(string connectionString, int commandTimeoutSeconds)
	{
		if (string.IsNullOrWhiteSpace(connectionString))
			throw new ArgumentException("Lab database connection string is required.", nameof(connectionString));

		_connectionString = connectionString;
		_commandTimeoutSeconds = commandTimeoutSeconds;
	}

	/// <summary>
	/// Reserves <paramref name="count"/> consecutive numbers for the lab and returns the first.
	/// Creates and seeds the sequence on first use, from the highest TSK- number already on the
	/// board, so an existing lab never re-issues an id it has already handed out.
	/// </summary>
	public async Task<long> ReserveAsync(int labId, int count, CancellationToken ct)
	{
		if (count <= 0)
			return 0;

		var sql = $@"
IF OBJECT_ID('{SequenceTable}', 'U') IS NULL
BEGIN
    CREATE TABLE {SequenceTable}
    (
        LabId     INT    NOT NULL CONSTRAINT PK_DenialTaskIdSequence PRIMARY KEY,
        NextValue BIGINT NOT NULL
    );
END;

-- Seed from the board itself. TRY_CONVERT keeps a malformed TaskID from failing the whole run:
-- anything that is not TSK-<digits> simply does not raise the seed.
IF NOT EXISTS (SELECT 1 FROM {SequenceTable} WHERE LabId = @LabId)
BEGIN
    DECLARE @Seed BIGINT = 1;

    IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
    BEGIN
        SELECT @Seed = ISNULL(MAX(TRY_CONVERT(BIGINT, SUBSTRING(TaskID, 5, 50))), 0) + 1
        FROM   dbo.DenialTaskBoard
        WHERE  LabId = @LabId
          AND  TaskID LIKE 'TSK-%'
          AND  TRY_CONVERT(BIGINT, SUBSTRING(TaskID, 5, 50)) IS NOT NULL;
    END;

    INSERT INTO {SequenceTable} (LabId, NextValue) VALUES (@LabId, @Seed);
END;

-- Reserve the block and return its first value in one statement, so two workers running against
-- the same lab cannot be handed overlapping ranges.
UPDATE {SequenceTable}
SET    NextValue = NextValue + @Count
OUTPUT deleted.NextValue
WHERE  LabId = @LabId;";

		await using var conn = new SqlConnection(_connectionString);
		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = _commandTimeoutSeconds };
		cmd.Parameters.AddWithValue("@LabId", labId);
		cmd.Parameters.AddWithValue("@Count", count);

		await conn.OpenAsync(ct).ConfigureAwait(false);
		var first = await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false);

		return first is null or DBNull ? 1 : Convert.ToInt64(first);
	}

	/// <summary>The wire format people quote: TSK-00001. Widens past five digits rather than wrapping.</summary>
	public static string Format(long value) => $"TSK-{value:D5}";
}
