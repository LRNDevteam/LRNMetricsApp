using Microsoft.Data.SqlClient;

namespace DenialDatabaseProcessorWorker.Services;

/// <summary>
/// Reads a lab's dbo.DenialCodeMaster - the table AR Managers edit on the Denial Code Master page in
/// LRN.ReportsApi - as claim action mapper rows.
///
/// Before this, the worker only read the "Denial Action Classifier" workbook. The API rewrites that
/// workbook on every edit, but into one global folder that no lab's ClaimActionMapper points at, so
/// every lab kept mapping from a shared file and no edit ever reached the task board. Reading the
/// table removes the file hand-off entirely.
///
/// Rows are keyed by the workbook's own header text so <see cref="ClaimActionMapperIndex"/> treats
/// both sources identically.
/// </summary>
public sealed class DenialCodeMasterRepository
{
	public const string TableName = "dbo.DenialCodeMaster";

	/// <summary>
	/// Same order and spelling as the API's export (DenialCodeMasterExcelService.TemplateHeaders) and
	/// the classifier workbooks already on disk.
	/// </summary>
	public static readonly IReadOnlyList<(string Header, string Column)> Columns =
	[
		("Denial Code", "DenialCode"),
		("Denial Description", "DenialDescription"),
		("Denial Classification", "DenialClassification"),
		("Coverage Status", "CoverageStatus"),
		("ICD Compliance Status", "ICDComplianceStatus"),
		("Denial Validity", "DenialValidity"),
		("Action Code", "ActionCode"),
		("Recommended Action", "RecommendedAction"),
		("Action Category", "ActionCategory"),
		("Task", "Task"),
		("Short Category", "ShortCategory"),
		("Priority", "Priority"),
		("SLA (Days)", "SLADays"),
		("Notes / Comments", "NotesComments")
	];

	private readonly string _connectionString;
	private readonly int _commandTimeoutSeconds;

	public DenialCodeMasterRepository(string connectionString, int commandTimeoutSeconds)
	{
		if (string.IsNullOrWhiteSpace(connectionString))
			throw new ArgumentException("Lab database connection string is required.", nameof(connectionString));

		_connectionString = connectionString;
		_commandTimeoutSeconds = commandTimeoutSeconds;
	}

	/// <summary>
	/// Returns the master's rows, or an empty list when the table does not exist in this lab's
	/// database. <see cref="MapperRows.SourceLabel"/> names the database actually read, so the step
	/// log shows which one the worker resolved.
	/// </summary>
	public async Task<MapperRows> ReadAsync(CancellationToken ct)
	{
		var columnList = string.Join(", ", Columns.Select(c => c.Column));
		var sql = $@"
IF OBJECT_ID('{TableName}', 'U') IS NOT NULL
    SELECT {columnList}
    FROM {TableName}
    ORDER BY DenialCode, CoverageStatus, ICDComplianceStatus;";

		await using var conn = new SqlConnection(_connectionString);
		await conn.OpenAsync(ct);

		// Database name only: the server of a managed instance carries ",port", and this label lands
		// in the CSV step log.
		var label = $"SQL {conn.Database}.{TableName}";
		var rows = new List<Dictionary<string, string>>();

		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = _commandTimeoutSeconds };
		await using var reader = await cmd.ExecuteReaderAsync(ct);

		// No result set at all means the IF was false: the table is missing.
		if (reader.FieldCount == 0)
			return new MapperRows(rows, label, TableExists: false);

		while (await reader.ReadAsync(ct))
		{
			var row = new Dictionary<string, string>(Columns.Count, StringComparer.OrdinalIgnoreCase);
			for (var i = 0; i < Columns.Count; i++)
				row[Columns[i].Header] = reader.IsDBNull(i) ? "" : Convert.ToString(reader.GetValue(i)) ?? "";

			rows.Add(row);
		}

		return new MapperRows(rows, label, TableExists: true);
	}

	public sealed record MapperRows(List<Dictionary<string, string>> Rows, string SourceLabel, bool TableExists);
}
