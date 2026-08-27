using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.VisualBasic.FileIO;
using System.Data;
using System.Text.RegularExpressions;

/// <summary>
/// Keeps dbo.LabInsuranceMaster (LRNMaster) seeded with every distinct PayerName_Raw that appears
/// in a lab's generated LineLevel CSV.
/// <para>
/// A row is considered to already exist when (PayerNameRaw, LabName) match -- the same key as the
/// table's unique index UX_LabInsuranceMaster_PayerNameRaw_LabName, deliberately ignoring LabId so a
/// pre-existing row with a different LabId never causes a duplicate-key insert. LabName here is the
/// value LabInsuranceMaster already uses for the lab (see <see cref="ResolveInsuranceMasterLabName"/>),
/// which is NOT the same as the ClaimUID/LineLevelUID short code. Inserts write only those three
/// columns plus the CreatedBy/CreatedOn audit pair; the enrichment columns (PayerCode, GlobalPayerID,
/// ...) are filled in later by other processes.
/// </para>
/// </summary>
public sealed class LabInsuranceMasterRepository
{
	private const string TableName = "dbo.LabInsuranceMaster";
	private const string CreatedBy = "MasterWorker";
	private const int PayerNameRawMaxLength = 250;
	private const int LabNameMaxLength = 50;
	private const int CreatedByMaxLength = 100;

	private readonly string _connStr;

	public LabInsuranceMasterRepository(IConfiguration config)
	{
		_connStr = config.GetConnectionString("DefaultConnection")
				  ?? throw new InvalidOperationException("Missing DefaultConnection connection string.");
	}

	// The LabName values already present in dbo.LabInsuranceMaster, keyed by the normalized lab name
	// (lowercased, non-alphanumerics stripped). The table's naming is not uniform -- most labs use a
	// full-ish name ("Beech Tree", "InHealth-DTR", "PCR AL", "Augustus") while NorthWest is stored as
	// the short code "NWL" -- so these strings are transcribed from the table rather than derived.
	//
	// Both the configured LabName and the stored LabName are registered as keys so a lab resolves
	// whether config says "Augustus Labs" or "Augustus".
	private static readonly Dictionary<string, string> InsuranceMasterLabNames = BuildInsuranceMasterLabNames();

	private static Dictionary<string, string> BuildInsuranceMasterLabNames()
	{
		// (configured LabName, LabName as stored in LabInsuranceMaster)
		var pairs = new (string Configured, string Stored)[]
		{
			("Beech_Tree",          "Beech Tree"),
			("Inhealth_DTR",        "InHealth-DTR"),
			("Cove",                "Cove"),
			("PCR_Dx_AL",           "PCR AL"),
			("PCR_Dx_CO",           "PCR CO"),
			("Certus",              "Certus"),
			("Elixir",              "Elixir"),
			("Phi Life",            "Phi Life"),
			("Rising Tides",        "Rising Tides"),
			("Augustus Labs",       "Augustus"),
			("PCR Labs of America", "PCR Labs of America"),
			("NorthWest",           "NWL"),
			("Prism",               "Prism"),
		};

		var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

		foreach (var (configured, stored) in pairs)
		{
			map[NormKey(configured)] = stored;
			map[NormKey(stored)] = stored;
		}

		return map;
	}

	/// <summary>
	/// Maps a configured lab name to the LabName that dbo.LabInsuranceMaster stores for that lab
	/// (e.g. "NorthWest" -> "NWL", "Augustus Labs" -> "Augustus"). Returns "" when the lab is unknown.
	/// </summary>
	public static string ResolveInsuranceMasterLabName(string? labName)
	{
		var key = NormKey(labName ?? "");
		if (string.IsNullOrWhiteSpace(key))
			return "";

		return InsuranceMasterLabNames.TryGetValue(key, out var stored) ? stored : "";
	}

	private static string NormKey(string s)
	{
		if (string.IsNullOrWhiteSpace(s)) return "";
		return Regex.Replace(s.Trim().ToLowerInvariant(), "[^a-z0-9]+", "");
	}

	public sealed record SyncResult(int DistinctPayers, int Inserted, int AlreadyExisting)
	{
		public string Summary => $"Distinct={DistinctPayers}, Inserted={Inserted}, Existing={AlreadyExisting}";
	}

	/// <summary>
	/// Reads the distinct PayerName_Raw values from <paramref name="lineLevelCsvPath"/> and inserts the
	/// ones not already present for this LabName. <paramref name="insuranceMasterLabName"/>
	/// must be the LabName as stored in LabInsuranceMaster -- see <see cref="ResolveInsuranceMasterLabName"/>.
	/// </summary>
	public async Task<SyncResult> SyncPayersFromLineLevelCsvAsync(
		string lineLevelCsvPath,
		string insuranceMasterLabName,
		int labId,
		CancellationToken ct)
	{
		if (string.IsNullOrWhiteSpace(insuranceMasterLabName))
			throw new ArgumentException("Insurance master lab name is required.", nameof(insuranceMasterLabName));

		var payers = ReadDistinctPayerNamesRaw(lineLevelCsvPath);
		if (payers.Count == 0)
			return new SyncResult(0, 0, 0);

		using var conn = new SqlConnection(_connStr);
		await conn.OpenAsync(ct);

		var existing = await LoadExistingPayerNamesAsync(conn, insuranceMasterLabName, ct);

		var toInsert = payers.Where(p => !existing.Contains(p)).ToList();
		if (toInsert.Count == 0)
			return new SyncResult(payers.Count, 0, payers.Count);

		using var tx = conn.BeginTransaction();

		// Guarded insert keyed the same way as UX_LabInsuranceMaster_PayerNameRaw_LabName, so a row
		// added after the snapshot above (or one the snapshot missed) is skipped instead of throwing
		// a duplicate-key error.
		const string insertSql = $@"
INSERT INTO {TableName} (PayerNameRaw, LabName, LabId, CreatedBy, CreatedOn)
SELECT @PayerNameRaw, @LabName, @LabId, @CreatedBy, @CreatedOn
WHERE NOT EXISTS (
	SELECT 1 FROM {TableName} WITH (UPDLOCK, HOLDLOCK)
	WHERE PayerNameRaw = @PayerNameRaw AND LabName = @LabName
);";

		// One timestamp for the whole batch so every payer added by this run shares a CreatedOn.
		// UTC to match the table's sysutcdatetime() default.
		var createdOn = DateTime.UtcNow;

		// Not prepared: SqlCommand.Prepare demands an explicit non-zero Size on every variable-length
		// parameter, which datetime2 counts as. The command text is constant, so SQL Server reuses the
		// cached plan across these executions anyway.
		using var cmd = new SqlCommand(insertSql, conn, tx);
		var payerParam = cmd.Parameters.Add("@PayerNameRaw", SqlDbType.NVarChar, PayerNameRawMaxLength);
		cmd.Parameters.Add("@LabName", SqlDbType.NVarChar, LabNameMaxLength).Value = Truncate(insuranceMasterLabName, LabNameMaxLength);
		cmd.Parameters.Add("@LabId", SqlDbType.Int).Value = labId;
		cmd.Parameters.Add("@CreatedBy", SqlDbType.NVarChar, CreatedByMaxLength).Value = CreatedBy;
		cmd.Parameters.Add("@CreatedOn", SqlDbType.DateTime2).Value = createdOn;

		var inserted = 0;

		foreach (var payer in toInsert)
		{
			ct.ThrowIfCancellationRequested();
			payerParam.Value = payer;
			inserted += await cmd.ExecuteNonQueryAsync(ct);
		}

		tx.Commit();

		return new SyncResult(payers.Count, inserted, payers.Count - inserted);
	}

	private static async Task<HashSet<string>> LoadExistingPayerNamesAsync(
		SqlConnection conn,
		string insuranceMasterLabName,
		CancellationToken ct)
	{
		// Filtered by LabName only, to mirror the unique index (PayerNameRaw, LabName). Rows written
		// for this lab under a different LabId must still count as existing, otherwise re-inserting
		// them violates UX_LabInsuranceMaster_PayerNameRaw_LabName.
		const string sql = $@"
SELECT PayerNameRaw
FROM {TableName}
WHERE LabName = @LabName;";

		var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

		using var cmd = new SqlCommand(sql, conn);
		cmd.Parameters.Add("@LabName", SqlDbType.NVarChar, LabNameMaxLength).Value = Truncate(insuranceMasterLabName, LabNameMaxLength);

		using var reader = await cmd.ExecuteReaderAsync(ct);
		while (await reader.ReadAsync(ct))
		{
			if (reader.IsDBNull(0)) continue;
			var value = reader.GetString(0).Trim();
			if (!string.IsNullOrWhiteSpace(value))
				existing.Add(value);
		}

		return existing;
	}

	/// <summary>
	/// Distinct, trimmed, non-blank PayerName_Raw values from the generated LineLevel CSV,
	/// in first-appearance order. Comparison is case-insensitive to mirror SQL Server collation.
	/// </summary>
	private static List<string> ReadDistinctPayerNamesRaw(string lineLevelCsvPath)
	{
		if (string.IsNullOrWhiteSpace(lineLevelCsvPath) || !File.Exists(lineLevelCsvPath))
			throw new FileNotFoundException("LineLevel CSV not found.", lineLevelCsvPath);

		using var parser = new TextFieldParser(lineLevelCsvPath)
		{
			TextFieldType = FieldType.Delimited,
			HasFieldsEnclosedInQuotes = true,
			TrimWhiteSpace = false
		};
		parser.SetDelimiters(",");

		if (parser.EndOfData)
			return new List<string>();

		var headers = parser.ReadFields() ?? Array.Empty<string>();
		var payerIndex = Array.FindIndex(
			headers,
			h => (h ?? string.Empty).Trim().Equals("PayerName_Raw", StringComparison.OrdinalIgnoreCase));

		if (payerIndex < 0)
			return new List<string>();

		var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
		var distinct = new List<string>();

		while (!parser.EndOfData)
		{
			var row = parser.ReadFields();
			if (row == null || payerIndex >= row.Length)
				continue;

			var payer = (row[payerIndex] ?? string.Empty).Trim();
			if (string.IsNullOrWhiteSpace(payer))
				continue;

			payer = Truncate(payer, PayerNameRawMaxLength);
			if (seen.Add(payer))
				distinct.Add(payer);
		}

		return distinct;
	}

	private static string Truncate(string value, int maxLength)
	{
		var trimmed = (value ?? string.Empty).Trim();
		return trimmed.Length <= maxLength ? trimmed : trimmed.Substring(0, maxLength);
	}
}
