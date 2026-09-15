using DenialDatabaseProcessorWorker.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace DenialDatabaseProcessorWorker.Services;

/// <summary>
/// Reads LRNMaster's dbo.DenialMapperSuperMaster - the central, lab-agnostic denial mapping table
/// maintained on the Denial Mapper admin screen - as claim action mapper rows.
///
/// This is the fallback tier between a lab's own dbo.DenialCodeMaster (<see cref="DenialCodeMasterRepository"/>)
/// and the classifier Excel file: a lab whose local table is missing or thin still gets the coverage
/// the central table has, before ever falling through to a file.
///
/// Rows are keyed by the same header text <see cref="DenialCodeMasterRepository"/> uses, so
/// <see cref="ClaimActionMapperIndex"/> treats every source identically. The Super Master has no
/// Short Category / Notes-Comments columns, so those two headers are simply absent from these rows -
/// ClaimActionMapperIndex's header lookup already tolerates a missing column.
/// </summary>
public sealed class DenialMapperSuperMasterRepository
{
	public const string TableName = "dbo.DenialMapperSuperMaster";

	/// <summary>Same header spelling as <see cref="DenialCodeMasterRepository.Columns"/> where the column exists here.</summary>
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
		("Priority", "Priority"),
		("SLA (Days)", "SLA")
	];

	private readonly string _connectionString;
	private readonly int _commandTimeoutSeconds;

	public DenialMapperSuperMasterRepository(IConfiguration configuration, IOptions<ProcessorOptions> options)
	{
		_connectionString = configuration.GetConnectionString("DenialDatabase")
			?? throw new InvalidOperationException("Connection string 'DenialDatabase' not found.");
		_commandTimeoutSeconds = options.Value.SqlCommandTimeoutSeconds;
	}

	/// <summary>
	/// Returns the active Super Master rows. <see cref="DenialCodeMasterRepository.MapperRows.SourceLabel"/>
	/// names the database actually read, so the step log shows which tier resolved the mapping.
	/// </summary>
	public async Task<DenialCodeMasterRepository.MapperRows> ReadAsync(CancellationToken ct)
	{
		var columnList = string.Join(", ", Columns.Select(c => c.Column));
		var sql = $@"
IF OBJECT_ID('{TableName}', 'U') IS NOT NULL
    SELECT {columnList}
    FROM {TableName}
    WHERE IsActive = 1
    ORDER BY DenialCode, CoverageStatus, ICDComplianceStatus;";

		await using var conn = new SqlConnection(_connectionString);
		await conn.OpenAsync(ct);

		var label = $"SQL {conn.Database}.{TableName}";
		var rows = new List<Dictionary<string, string>>();

		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = _commandTimeoutSeconds };
		await using var reader = await cmd.ExecuteReaderAsync(ct);

		// No result set at all means the IF was false: the table is missing.
		if (reader.FieldCount == 0)
			return new DenialCodeMasterRepository.MapperRows(rows, label, TableExists: false);

		while (await reader.ReadAsync(ct))
		{
			var row = new Dictionary<string, string>(Columns.Count, StringComparer.OrdinalIgnoreCase);
			for (var i = 0; i < Columns.Count; i++)
				row[Columns[i].Header] = reader.IsDBNull(i) ? "" : Convert.ToString(reader.GetValue(i)) ?? "";

			rows.Add(row);
		}

		return new DenialCodeMasterRepository.MapperRows(rows, label, TableExists: true);
	}
}
