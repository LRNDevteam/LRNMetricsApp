using ClosedXML.Excel;
using LRN.MasterFileProcessorWorker.ExcelValidation;
using Microsoft.VisualBasic.FileIO;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

public static class StandardCsvExporter
{

	public sealed record InsuranceMasterEntry(string GlobalPayerId, string PayerNameNormalized, string payercode, string payercommoncode, string payerGroupCode, string LabName = "");

	/// <summary>
	/// Loads the Consolidated Lab Insurance Master CSV into a lookup keyed by normalized Payer_Name_Raw.
	/// Expected columns include: Payer_Name_Raw, Payer_Name_Normalized, Global_Payer_ID (others ignored).
	/// </summary>
	public static Dictionary<string, InsuranceMasterEntry> LoadInsuranceMaster(string csvPath)
	{
		if (string.IsNullOrWhiteSpace(csvPath))
			throw new ArgumentException("Insurance master CSV path is required.", nameof(csvPath));

		if (!File.Exists(csvPath))
			throw new FileNotFoundException("Insurance master CSV not found.", csvPath);

		using var parser = new TextFieldParser(csvPath);
		parser.TextFieldType = FieldType.Delimited;

		// Detect delimiter: comma vs tab
		var firstLine = File.ReadLines(csvPath).FirstOrDefault() ?? "";
		var delim = firstLine.Contains('	') && !firstLine.Contains(",") ? "	" : ",";
		parser.SetDelimiters(delim);
		parser.HasFieldsEnclosedInQuotes = true;

		if (parser.EndOfData) return new Dictionary<string, InsuranceMasterEntry>(StringComparer.OrdinalIgnoreCase);

		var headers = parser.ReadFields() ?? Array.Empty<string>();
		var idxByNorm = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
		for (int i = 0; i < headers.Length; i++)
		{
			var hn = NormKey(headers[i] ?? "");
			if (!string.IsNullOrWhiteSpace(hn) && !idxByNorm.ContainsKey(hn))
				idxByNorm[hn] = i;
		}

		int idxRaw = idxByNorm.TryGetValue(NormKey("Payer_Name_Raw"), out var iRaw) ? iRaw : -1;
		int idxNorm = idxByNorm.TryGetValue(NormKey("Payer_Name_Normalized"), out var iNorm) ? iNorm : -1;
		int idxLabName = idxByNorm.TryGetValue(NormKey("Lab Name"), out var iLabName) ? iLabName : -1;
		int idxGpid = idxByNorm.TryGetValue(NormKey("Global_Payer_ID"), out var iG) ? iG : -1;
		int idxPc = idxByNorm.TryGetValue(NormKey("Payer_Code"), out var PC) ? PC : -1;
		int idxPCC = idxByNorm.TryGetValue(NormKey("Payer_Common_Code"), out var PCC) ? PCC : -1;
		int idPyGrCd = idxByNorm.TryGetValue(NormKey("Payer_Group_Code"), out var PyGrCode) ? PyGrCode : -1;

		if (idxRaw < 0)
			throw new InvalidOperationException("Insurance master CSV missing required column: Payer_Name_Raw");

		var map = new Dictionary<string, InsuranceMasterEntry>(StringComparer.OrdinalIgnoreCase);

		while (!parser.EndOfData)
		{
			var row = parser.ReadFields();
			if (row == null || row.All(x => string.IsNullOrWhiteSpace(x))) continue;

			var raw = idxRaw >= 0 && idxRaw < row.Length ? (row[idxRaw] ?? "").Trim() : "";
			if (string.IsNullOrWhiteSpace(raw)) continue;

			var normalized = idxNorm >= 0 && idxNorm < row.Length ? (row[idxNorm] ?? "").Trim() : "";
			var labNameFromMaster = idxLabName >= 0 && idxLabName < row.Length ? (row[idxLabName] ?? "").Trim() : "";

			var key = BuildInsuranceLookupKey(labNameFromMaster, raw);
			if (string.IsNullOrWhiteSpace(key)) continue;
			var gpid = idxGpid >= 0 && idxGpid < row.Length ? (row[idxGpid] ?? "").Trim() : "";
			var payCode = idxPc >= 0 && idxPc < row.Length ? (row[idxPc] ?? "").Trim() : "";
			var paycmcode = idxPCC >= 0 && idxPCC < row.Length ? (row[idxPCC] ?? "").Trim() : "";
			var pygrCode = idPyGrCd >= 0 && idPyGrCd < row.Length ? (row[idPyGrCd] ?? "").Trim() : "";

			// First win
			if (!map.ContainsKey(key))
				map[key] = new InsuranceMasterEntry(gpid, normalized, payCode, paycmcode, pygrCode, labNameFromMaster);

			var payerOnlyKey = BuildInsuranceLookupKey("", raw);
			if (string.IsNullOrWhiteSpace(labNameFromMaster) && !map.ContainsKey(payerOnlyKey))
				map[payerOnlyKey] = new InsuranceMasterEntry(gpid, normalized, payCode, paycmcode, pygrCode, labNameFromMaster);
		}

		return map;
	}


	/// <summary>
	/// Generates a standardized CSV from a raw CSV (exported from Excel sheet) using a COMMON schema JSON:
	/// - Uses Aliases to map source headers to each common column.
	/// - Normalizes all date/datetime columns to MM/dd/yyyy.
	/// - Fills metadata columns: LabID, LabName, SourceFileID (SharePoint file name), IngestedOn, RowHash.
	/// - Supports Calculation: "A + B" (A/B are COMMON schema column names).
	/// - Computes DaystoDOS/RollingDays/DaystoBill/DaystoPost using Today() and DateofService/FirstBilledDate/CheckDate.
	/// </summary>
	public static void Generate(
		string sourceCsvPath,
		int headerRow,
		string outputCsvPath,
		ColumnSchema commonSchema,
		int labId,
		string labName,
		string sourceFileName,
		DateTime ingestedOnLocal,
		ColumnSchema? labSchema = null,
		Dictionary<string, InsuranceMasterEntry>? insuranceMaster = null,
		bool appendUnmappedSourceColumns = true,
		ExportAugmentationContext? augmentation = null,
		bool enableDynamicColumnMatching = true,
		Action<string>? log = null)
	{
		if (!File.Exists(sourceCsvPath))
			throw new FileNotFoundException("Source CSV not found", sourceCsvPath);

		Directory.CreateDirectory(Path.GetDirectoryName(outputCsvPath)!);

		using var parser = new TextFieldParser(sourceCsvPath)
		{
			TextFieldType = FieldType.Delimited,
			HasFieldsEnclosedInQuotes = true,
			TrimWhiteSpace = false
		};
		parser.SetDelimiters(",");

		// Skip to header row (1-based)
		string[]? header = null;
		for (int i = 1; i <= headerRow; i++)
		{
			if (parser.EndOfData) break;
			header = parser.ReadFields();
		}
		if (header == null)
			throw new InvalidOperationException($"Header row {headerRow} not found in CSV: {sourceCsvPath}");

		// Build header lookups (exact + normalized)
		var headerExact = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
		var headerNorm = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

		for (int i = 0; i < header.Length; i++)
		{
			var h = (header[i] ?? "").Trim();
			if (string.IsNullOrWhiteSpace(h)) continue;

			if (!headerExact.ContainsKey(h))
				headerExact[h] = i;

			var hn = NormKey(h);
			if (!string.IsNullOrWhiteSpace(hn) && !headerNorm.ContainsKey(hn))
				headerNorm[hn] = i;
		}

		// Lab-level overrides: prefer lab schema headers when multiple aliases exist,
		// and support composite expressions like "[Last], [First] {Referral Name}".
		var labOv = BuildLabOverrides(labSchema);

		// Last-resort binding for headers the lab renamed since the schema was written.
		// Must run before the extra-column scan so a bound header is not ALSO appended as unmapped.
		if (enableDynamicColumnMatching)
			ResolveDynamicColumnBindings(header, commonSchema, headerExact, headerNorm, labOv, log);

		// For calculations: resolve by COMMON column name
		var schemaByName = commonSchema.Columns
			.Where(c => !string.IsNullOrWhiteSpace(c.Name))
			.ToDictionary(c => c.Name, c => c, StringComparer.OrdinalIgnoreCase);

		var extraSourceColumnIndexes = appendUnmappedSourceColumns
			? FindExtraSourceColumnIndexes(header, commonSchema, headerExact, headerNorm, labOv)
			: new List<ExtraSourceColumn>();

		var finalOutputHeaders = commonSchema.Columns.Select(c => c.Name).ToList();

		if (augmentation?.IsAugustus == true)
		{
			if (augmentation.IncludeEncounterPlusPaymentPostedDate)
				finalOutputHeaders.Add("Encounter + PaymentPostedDate");

			finalOutputHeaders.Add("PanelNew");

			// PanelNew comes from the source file now, so a missing column means the whole output
			// column is blank. Say so once, here, rather than leaving it to be noticed downstream.
			var hasPanelCategory = AugustusPanelNewSourceColumns.Any(c =>
				headerExact.ContainsKey(c) || headerNorm.ContainsKey(NormKey(c)));

			if (!hasPanelCategory)
				log?.Invoke($"WARNING: Augustus source '{sourceFileName}' has no 'Panel Category' column; PanelNew will be empty.");
		}

		if (augmentation?.IsNorthWest == true)
		{
			finalOutputHeaders.Add("LRN Panel Type");
		}

		finalOutputHeaders.AddRange(extraSourceColumnIndexes.Select(e => e.OutputName));

		using var sw = new StreamWriter(outputCsvPath, false, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
		sw.WriteLine(string.Join(",", finalOutputHeaders.Select(Escape)));

		int rowNumber = 0;

		while (!parser.EndOfData)
		{
			var row = parser.ReadFields();
			if (row == null) continue;
			if (row.All(x => string.IsNullOrWhiteSpace(x))) continue;

			rowNumber++;

			// Cache extracted values for referenced columns (commonName -> raw string)
			var extracted = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

			foreach (var col in commonSchema.Columns)
			{
				if (IsMetadata(col.Name) || IsDays(col.Name))
					continue;

				if (!string.IsNullOrWhiteSpace(col.Calculation))
					continue;

				extracted[col.Name] = ReadValueForCommonColumn(col, row, headerExact, headerNorm, labOv);
			}

			// Dates for day calculations
			var dos = ParseDateMaybe(extracted.TryGetValue("DateofService", out var dosRaw) ? dosRaw : "");
			var firstBill = ParseDateMaybe(extracted.TryGetValue("FirstBilledDate", out var billRaw) ? billRaw : "");
			var check = ParseDateMaybe(extracted.TryGetValue("CheckDate", out var chkRaw) ? chkRaw : "");

			int? daysToDos = dos.HasValue ? (int?)(DateTime.Today - dos.Value.Date).TotalDays : null;
			int? daysToBill = firstBill.HasValue ? (int?)(DateTime.Today - firstBill.Value.Date).TotalDays : null;
			int? daysToPost = check.HasValue ? (int?)(DateTime.Today - check.Value.Date).TotalDays : null;

			// --- Insurance Master mapping: Global_Payer_ID + normalized PayerName ---
			if (insuranceMaster != null && insuranceMaster.Count > 0)
			{
				var payerRaw = GetFirstNonEmpty(extracted,
					"PayerName_Raw", "Payer Name", "PayerName", "Payer");

				if (!string.IsNullOrWhiteSpace(payerRaw))
				{
					var ins = FindInsuranceMasterEntry(insuranceMaster, labName, payerRaw);

					if (ins != null)
					{
						// Fill normalized payer name & global payer id if those columns exist in the COMMON schema
						extracted["PayerName"] = ins.PayerNameNormalized ?? "";
						extracted["Payer_Code"] = ins.payercode ?? "";
						extracted["Payer_Common_Code"] = ins.payercommoncode ?? "";
						extracted["Payer_Group_Code"] = ins.payerGroupCode ?? "";
						extracted["Global_Payer_ID"] = ins.GlobalPayerId ?? "";

					}
				}
			}

			if (commonSchema.Columns.Any(c => c.Name.Equals("ICDCode", StringComparison.OrdinalIgnoreCase)))
			{
				if (extracted["ICDCode"] != null)
				{
					extracted["ICDCode"] = ExtractIcdCodes(extracted["ICDCode"].ToString());
				}
			}

			// --- Per-unit columns (LineLevel) ---
			var unitsRaw = extracted.TryGetValue("Units", out var uRaw) ? uRaw : "";
			var unitsVal = ParseDecimal(unitsRaw);

			if (unitsVal > 0m)
			{
				extracted["ChargeAmountPerUnit"] = DividePerUnit(extracted, "ChargeAmount", unitsVal);
				extracted["AllowedAmountPerUnit"] = DividePerUnit(extracted, "AllowedAmount", unitsVal);
				extracted["InsurancePaymentPerUnit"] = DividePerUnit(extracted, "InsurancePayment", unitsVal);
				extracted["PatientBalancePerUnit"] = DividePerUnit(extracted, "PatientBalance", unitsVal);
				extracted["PatientPaymentPerUnit"] = DividePerUnit(extracted, "PatientPayment", unitsVal);
			}
			else
			{
				extracted["ChargeAmountPerUnit"] = "";
				extracted["AllowedAmountPerUnit"] = "";
				extracted["InsurancePaymentPerUnit"] = "";
				extracted["PatientBalancePerUnit"] = "";
				extracted["PatientPaymentPerUnit"] = "";
			}

			// --- Pay Status (derived) ---
			if (commonSchema.Columns.Any(c => c.Name.Equals("Pay Status", StringComparison.OrdinalIgnoreCase)))
			{
				decimal carrierPay = ParseDecimal(extracted.TryGetValue("InsurancePayment", out var ip) ? ip : "");
				decimal patientPay = ParseDecimal(extracted.TryGetValue("PatientPayment", out var pp) ? pp : "");
				decimal totalPayment = carrierPay + patientPay;

				decimal carrierBal = ParseDecimal(extracted.TryGetValue("InsuranceBalance", out var cb) ? cb : "");

				decimal patAdj = ParseDecimal(extracted.TryGetValue("PatientAdjustments", out var pa) ? pa : "");
				decimal insAdj = ParseDecimal(extracted.TryGetValue("InsuranceAdjustments", out var ia) ? ia : "");
				decimal totalAdj = patAdj + insAdj;

				decimal chargeAmt = ParseDecimal(extracted.TryGetValue("ChargeAmount", out var ca) ? ca : "");
				decimal patientBal = ParseDecimal(extracted.TryGetValue("PatientBalance", out var pb) ? pb : "");
				decimal totalbalance = ParseDecimal(extracted.TryGetValue("Total Balance", out var tb) ? tb : "");
				if (totalbalance == 0)
				{
					totalbalance = carrierBal + patientBal;
				}

				string status = ComputePayStatus(extracted);

				if (status == "Adjusted")
				{
					if (totalAdj == chargeAmt)
					{
						extracted["AllowedAmount"] = "0";
						extracted["AllowedAmountPerUnit"] = "0";
					}
				}
				else if (status == "Denied")
				{
					if (chargeAmt == totalbalance)
					{
						extracted["AllowedAmount"] = "0";
						extracted["AllowedAmountPerUnit"] = "0";
					}
				}
				else if (status == "Partially Adjusted")
				{
					if (chargeAmt == totalbalance + totalAdj)
					{
						extracted["AllowedAmount"] = "0";
						extracted["AllowedAmountPerUnit"] = "0";
					}
				}
				extracted["Pay Status"] = status;
			}


			string rolling = "";
			if (daysToDos.HasValue)
			{
				if (daysToDos.Value <= 90) rolling = "Rolling90";
				else if (daysToDos.Value >= 91 && daysToDos.Value <= 180) rolling = "Rolling180";
				else if (daysToDos.Value >= 181) rolling = "YTD";
			}

			extracted["ClaimUID"] = BuildClaimUID(extracted, dos, labName);
			extracted["LineLevelUID"] = BuildLineLevelUID(extracted, dos, labName);

			var outFields = new List<string>(commonSchema.Columns.Count + extraSourceColumnIndexes.Count);

			foreach (var col in commonSchema.Columns)
			{
				string val;

				// Metadata columns
				if (col.Name.Equals("LabID", StringComparison.OrdinalIgnoreCase))
					val = labId.ToString(CultureInfo.InvariantCulture);
				else if (col.Name.Equals("LabName", StringComparison.OrdinalIgnoreCase))
					val = labName ?? "";
				else if (col.Name.Equals("SourceFileID", StringComparison.OrdinalIgnoreCase))
					val = sourceFileName ?? "";
				else if (col.Name.Equals("IngestedOn", StringComparison.OrdinalIgnoreCase))
					val = ingestedOnLocal.ToString("MM/dd/yyyy", CultureInfo.InvariantCulture);
				else if (col.Name.Equals("RowHash", StringComparison.OrdinalIgnoreCase))
					// RowHash should be Excel-like row number: headerRow + rowNumber
					val = (headerRow + rowNumber).ToString(CultureInfo.InvariantCulture);

				// Day-based computed columns
				else if (col.Name.Equals("DaystoDOS", StringComparison.OrdinalIgnoreCase))
					val = daysToDos?.ToString(CultureInfo.InvariantCulture) ?? "";
				else if (col.Name.Equals("RollingDays", StringComparison.OrdinalIgnoreCase))
					val = rolling;
				else if (col.Name.Equals("DaystoBill", StringComparison.OrdinalIgnoreCase))
					val = daysToBill?.ToString(CultureInfo.InvariantCulture) ?? "";
				else if (col.Name.Equals("DaystoPost", StringComparison.OrdinalIgnoreCase))
					val = daysToPost?.ToString(CultureInfo.InvariantCulture) ?? "";

				// Calculation columns
				else if (!string.IsNullOrWhiteSpace(col.Calculation))
				{
					// Requirement:
					// If this calculated column already exists in the LAB-level schema (meaning the lab file provides it),
					// then DO NOT calculate — take the lab value as-is.
					if (LabProvidesTargetColumn(col, labOv) &&
						TryReadValueIfHeaderExists(col, row, headerExact, headerNorm, labOv, out var directVal))
					{
						val = directVal;
						extracted[col.Name] = directVal;
					}
					else
					{
						val = EvaluateCalculation(col.Calculation!, extracted, schemaByName, row, headerExact, headerNorm, labOv);
						extracted[col.Name] = val;
					}
				}

				// Standard extracted columns
				else
					val = extracted.TryGetValue(col.Name, out var raw) ? raw : ReadValueForCommonColumn(col, row, headerExact, headerNorm, labOv);

				// Normalize date fields based on schema datatype
				if (IsDateType(col.DataType))
					val = NormalizeDate(val);

				outFields.Add(Escape(val));
			}

			if (augmentation?.IsAugustus == true)
			{
				if (augmentation.IncludeEncounterPlusPaymentPostedDate)
				{
					outFields.Add(Escape(BuildEncounterPlusPaymentPostedDate(row, headerExact, headerNorm)));
				}

				outFields.Add(Escape(ResolvePanelNew(row, headerExact, headerNorm, augmentation)));
			}
			if (augmentation?.IsNorthWest == true)
			{
				outFields.Add(Escape(ResolvePanelType(row, headerExact, headerNorm, augmentation)));
			}

			foreach (var extra in extraSourceColumnIndexes)
			{
				var extraValue = "";

				foreach (var extraIndex in extra.SourceIndexes)
				{
					extraValue = Get(row, extraIndex);
					if (!string.IsNullOrWhiteSpace(extraValue))
						break;
				}

				outFields.Add(Escape(extraValue));
			}

			sw.WriteLine(string.Join(",", outFields));
		}
	}
	/// <summary>
	/// Copies ClaimStatus from the generated claim-level CSV into the generated line-level CSV.
	/// Used only by selected labs from MasterFileProcessorWorker.
	/// Match priority: ClaimID, VisitNumber, Encounter ID, AccessionNumber, Accession.
	/// </summary>
	public static void CopyClaimStatusFromClaimLevelToLineLevel(
		string claimCsvPath,
		string lineCsvPath,
		string targetColumnName = "ClaimStatus")
	{
		if (string.IsNullOrWhiteSpace(claimCsvPath) || !File.Exists(claimCsvPath))
			throw new FileNotFoundException("ClaimLevel CSV not found.", claimCsvPath);

		if (string.IsNullOrWhiteSpace(lineCsvPath) || !File.Exists(lineCsvPath))
			throw new FileNotFoundException("LineLevel CSV not found.", lineCsvPath);

		var claimStatusByKey = LoadClaimStatusLookup(claimCsvPath);
		if (claimStatusByKey.Count == 0)
			return;

		var tempPath = lineCsvPath + ".claimstatus.tmp";

		using var parser = OpenCsvParser(lineCsvPath);

		if (parser.EndOfData)
			return;

		var headers = parser.ReadFields() ?? Array.Empty<string>();
		var outputHeaders = headers.ToList();

		// Try to find existing column (both formats)
		var targetIndex = FindHeaderIndex(outputHeaders, "Claim Status", "ClaimStatus");

		string finalColumnName;

		// If column exists, preserve original name
		if (targetIndex >= 0)
		{
			finalColumnName = outputHeaders[targetIndex];
		}
		else
		{
			// Default naming (recommended standard)
			finalColumnName = "Claim Status";
			targetIndex = outputHeaders.Count;
			outputHeaders.Add(finalColumnName);
		}

		using var sw = new StreamWriter(tempPath, false, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
		sw.WriteLine(string.Join(",", outputHeaders.Select(Escape)));

		while (!parser.EndOfData)
		{
			var row = (parser.ReadFields() ?? Array.Empty<string>()).ToList();
			if (row.Count == 0)
				continue;

			while (row.Count < outputHeaders.Count)
				row.Add(string.Empty);

			var existing = targetIndex < row.Count ? row[targetIndex] : string.Empty;
			if (string.IsNullOrWhiteSpace(existing))
			{
				foreach (var key in BuildClaimStatusMatchKeys(headers, row))
				{
					if (claimStatusByKey.TryGetValue(key, out var status) && !string.IsNullOrWhiteSpace(status))
					{
						row[targetIndex] = status;
						break;
					}
				}
			}

			sw.WriteLine(string.Join(",", row.Take(outputHeaders.Count).Select(Escape)));
		}

		sw.Dispose();
		parser.Dispose();

		File.Copy(tempPath, lineCsvPath, overwrite: true);
		File.Delete(tempPath);
	}

	// Opens a CSV for reading with a tolerant share mode (FileShare.ReadWrite | Delete) and a
	// short retry. This rides out transient locks (antivirus/search-indexer/another reader) that
	// would otherwise abort the whole run with an IOException even when nothing is truly holding
	// the file. The returned parser owns the underlying stream and closes it on Dispose.
	private static TextFieldParser OpenCsvParser(string path)
	{
		const int maxAttempts = 6;
		IOException? last = null;

		for (int attempt = 1; attempt <= maxAttempts; attempt++)
		{
			try
			{
				var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
				var parser = new TextFieldParser(fs)
				{
					TextFieldType = FieldType.Delimited,
					HasFieldsEnclosedInQuotes = true,
					TrimWhiteSpace = false
				};
				parser.SetDelimiters(",");
				return parser;
			}
			catch (IOException ex)
			{
				last = ex;
				if (attempt < maxAttempts)
					Thread.Sleep(Math.Min(3000, attempt * attempt * 200));
			}
		}

		throw last ?? new IOException($"Unable to open CSV for reading: {path}");
	}

	private static Dictionary<string, string> LoadClaimStatusLookup(string claimCsvPath)
	{
		var lookup = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

		using var parser = OpenCsvParser(claimCsvPath);

		if (parser.EndOfData)
			return lookup;

		var headers = parser.ReadFields() ?? Array.Empty<string>();
		var statusIndex = FindHeaderIndex(headers, "ClaimStatus", "Claim Status");
		if (statusIndex < 0)
			return lookup;

		while (!parser.EndOfData)
		{
			var row = parser.ReadFields() ?? Array.Empty<string>();
			var status = Get(row, statusIndex).Trim();
			if (string.IsNullOrWhiteSpace(status))
				continue;

			foreach (var key in BuildClaimStatusMatchKeys(headers, row))
			{
				if (!lookup.ContainsKey(key))
					lookup[key] = status;
			}
		}

		return lookup;
	}

	private static IEnumerable<string> BuildClaimStatusMatchKeys(IReadOnlyList<string> headers, IReadOnlyList<string> row)
	{
		var keyGroups = new (string GroupName, string[] ColumnNames)[]
		{
			("claim", new[] { "ClaimID", "VisitNumber", "Visit No", "VisitNum", "Encounter ID", "Enc" }),
			("accession", new[] { "AccessionNumber", "Accession", "Accession No", "Accession# Without Letters", "Specimen ID" })
		};

		foreach (var group in keyGroups)
		{
			foreach (var columnName in group.ColumnNames)
			{
				var idx = FindHeaderIndex(headers, columnName);
				if (idx < 0) continue;

				var value = idx < row.Count ? (row[idx] ?? string.Empty).Trim() : string.Empty;
				if (string.IsNullOrWhiteSpace(value)) continue;

				var normalizedValue = NormKey(value);
				if (!string.IsNullOrWhiteSpace(normalizedValue))
					yield return group.GroupName + ":" + normalizedValue;
			}
		}
	}

	private static int FindHeaderIndex(IReadOnlyList<string> headers, params string[] names)
	{
		if (headers == null || names == null || names.Length == 0)
			return -1;

		for (int i = 0; i < headers.Count; i++)
		{
			var header = headers[i] ?? string.Empty;
			foreach (var name in names)
			{
				if (header.Equals(name, StringComparison.OrdinalIgnoreCase) ||
					NormKey(header).Equals(NormKey(name), StringComparison.OrdinalIgnoreCase))
				{
					return i;
				}
			}
		}

		return -1;
	}

	public static string ExtractIcdCodes(string input)
	{
		if (string.IsNullOrWhiteSpace(input))
			return "";

		// ICD-10-CM examples:
		// D89.40, C85.90, C43.9, D72.829, Z3A.13
		var matches = Regex.Matches(
			input.ToUpperInvariant(),
			@"\b[A-Z][0-9][A-Z0-9](?:\.[A-Z0-9]{1,4})?\b",
			RegexOptions.CultureInvariant);

		var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
		var codes = new List<string>();

		foreach (Match match in matches)
		{
			var code = match.Value.Trim();
			if (seen.Add(code))
				codes.Add(code);
		}

		return string.Join(",", codes);
	}
	// ---------------- Lab schema overrides ----------------
	// Lab schema is used to:
	// 1) Prefer certain source headers when multiple COMMON aliases exist (e.g., CPT vs Procedure).
	// 2) Support simple composite expressions in lab schema Name, like:
	//    "[Last Name], [First Name] {Referral Name}"
	//    -> Output COMMON column "Referral Name" = "Last Name, First Name"

	private sealed class LabOverrides
	{
		public HashSet<string> PreferredExact { get; } = new(StringComparer.OrdinalIgnoreCase);
		public HashSet<string> PreferredNorm { get; } = new(StringComparer.OrdinalIgnoreCase);
		public Dictionary<string, CompositeTemplate> CompositeByName { get; } = new(StringComparer.OrdinalIgnoreCase);
		public Dictionary<string, CompositeTemplate> CompositeByNorm { get; } = new(StringComparer.OrdinalIgnoreCase);

		/// <summary>
		/// Interchangeable source spellings declared by one LAB schema column, reachable from any
		/// member. { "Name": "Enc", "Aliases": [ "Proc-Encounter #" ] } registers the group
		/// [Enc, Proc-Encounter #] under both keys.
		/// <para>
		/// This exists because a lab can ship the SAME logical column under different headers in
		/// one file. NorthWest sends line level twice - a Webpm sheet ("Enc", "Acc", "DOS") and a
		/// Daq sheet ("Proc-Encounter #", "Proc-Superbill", "Proc-Date of Service") - and the two
		/// sheets are combined into one CSV whose header is the UNION of both. Every group column
		/// therefore exists in the file, but each row only fills the one from its own sheet.
		/// </para>
		/// </summary>
		public Dictionary<string, List<string>> AliasGroupByNorm { get; } = new(StringComparer.OrdinalIgnoreCase);

		/// <summary>
		/// COMMON column (normalized) -&gt; source header bound at runtime by the near-miss matcher.
		/// Only populated for columns that nothing declared could resolve, so a renamed header keeps
		/// flowing without a schema edit. See <see cref="ResolveDynamicColumnBindings"/>.
		/// </summary>
		public Dictionary<string, string> DynamicSourceByCommonNorm { get; } = new(StringComparer.OrdinalIgnoreCase);
	}

	private readonly record struct CompositeSegment(bool IsColumn, string Text);

	private sealed class CompositeTemplate
	{
		public string TargetName { get; init; } = "";
		public List<CompositeSegment> Segments { get; init; } = new();
	}

	private static LabOverrides BuildLabOverrides(ColumnSchema? labSchema)
	{
		var ov = new LabOverrides();

		if (labSchema?.Columns == null)
			return ov;

		foreach (var c in labSchema.Columns)
		{
			if (c == null) continue;

			var rawName = (c.Name ?? "").Trim();
			if (string.IsNullOrWhiteSpace(rawName)) continue;

			// Composite mapping: "[A], [B] {Target}"
			if (TryParseComposite(rawName, out var tpl))
			{
				if (!string.IsNullOrWhiteSpace(tpl.TargetName))
				{
					ov.CompositeByName[tpl.TargetName] = tpl;

					var tn = NormKey(tpl.TargetName);
					if (!string.IsNullOrWhiteSpace(tn))
						ov.CompositeByNorm[tn] = tpl;
				}

				// Treat referenced headers as preferred too
				foreach (var seg in tpl.Segments.Where(s => s.IsColumn))
				{
					var h = (seg.Text ?? "").Trim();
					if (string.IsNullOrWhiteSpace(h)) continue;

					ov.PreferredExact.Add(h);

					var hn = NormKey(h);
					if (!string.IsNullOrWhiteSpace(hn))
						ov.PreferredNorm.Add(hn);
				}

				continue;
			}

			// Simple preferred header
			ov.PreferredExact.Add(rawName);
			var norm = NormKey(rawName);
			if (!string.IsNullOrWhiteSpace(norm))
				ov.PreferredNorm.Add(norm);

			// Every spelling this lab column declares is one interchangeable group.
			var group = new List<string> { rawName };

			// Some lab schemas may also include Aliases on their column specs
			if (c.Aliases != null)
			{
				foreach (var a in c.Aliases)
				{
					var aa = (a ?? "").Trim();
					if (string.IsNullOrWhiteSpace(aa)) continue;

					ov.PreferredExact.Add(aa);

					var an = NormKey(aa);
					if (!string.IsNullOrWhiteSpace(an))
						ov.PreferredNorm.Add(an);

					if (!group.Contains(aa, StringComparer.OrdinalIgnoreCase))
						group.Add(aa);
				}
			}

			RegisterAliasGroup(ov, group);
		}

		return ov;
	}

	/// <summary>
	/// Makes every member of <paramref name="group"/> resolve to the whole group. Groups that share
	/// a member are merged so a spelling declared twice does not split into rival groups.
	/// </summary>
	private static void RegisterAliasGroup(LabOverrides ov, List<string> group)
	{
		var members = group
			.Select(g => (g ?? "").Trim())
			.Where(g => !string.IsNullOrWhiteSpace(g))
			.ToList();

		if (members.Count == 0)
			return;

		// Merge with anything already registered under any of these keys.
		foreach (var key in members.Select(NormKey).Where(k => !string.IsNullOrWhiteSpace(k)).Distinct())
		{
			if (!ov.AliasGroupByNorm.TryGetValue(key, out var existing))
				continue;

			foreach (var e in existing)
				if (!members.Contains(e, StringComparer.OrdinalIgnoreCase))
					members.Add(e);
		}

		foreach (var key in members.Select(NormKey).Where(k => !string.IsNullOrWhiteSpace(k)).Distinct())
			ov.AliasGroupByNorm[key] = members;
	}

	private static bool TryParseComposite(string raw, out CompositeTemplate template)
	{
		template = new CompositeTemplate();

		// Expect trailing "{Target}" (but allow whitespace after)
		var m = Regex.Match(raw, @"\{([^{}]+)\}\s*$");
		if (!m.Success)
			return false;

		var target = (m.Groups[1].Value ?? "").Trim();
		if (string.IsNullOrWhiteSpace(target))
			return false;

		var expr = raw.Substring(0, m.Index).TrimEnd();
		if (string.IsNullOrWhiteSpace(expr))
			return false;

		var segs = new List<CompositeSegment>();
		int pos = 0;

		foreach (Match bm in Regex.Matches(expr, @"\[(?<col>[^\]]+)\]"))
		{
			if (bm.Index > pos)
			{
				segs.Add(new CompositeSegment(false, expr.Substring(pos, bm.Index - pos)));
			}

			var col = (bm.Groups["col"].Value ?? "").Trim();
			segs.Add(new CompositeSegment(true, col));

			pos = bm.Index + bm.Length;
		}

		if (pos < expr.Length)
			segs.Add(new CompositeSegment(false, expr.Substring(pos)));

		// Must contain at least one [col]
		if (!segs.Any(s => s.IsColumn))
			return false;

		template = new CompositeTemplate
		{
			TargetName = target,
			Segments = segs
		};

		return true;
	}


	private static bool TryGetCompositeTemplate(ColumnSpec col, LabOverrides labOv, out CompositeTemplate tpl)
	{
		// 1) by common column name
		if (labOv.CompositeByName.TryGetValue(col.Name, out tpl))
			return true;

		var nn = NormKey(col.Name);
		if (!string.IsNullOrWhiteSpace(nn) && labOv.CompositeByNorm.TryGetValue(nn, out tpl))
			return true;

		// 2) by any alias (this is what makes "{Referral Name}" target work for BillingProvider, etc.)
		if (col.Aliases != null)
		{
			foreach (var a in col.Aliases.Where(x => !string.IsNullOrWhiteSpace(x)))
			{
				var key = (a ?? "").Trim();
				if (labOv.CompositeByName.TryGetValue(key, out tpl))
					return true;

				var an = NormKey(key);
				if (!string.IsNullOrWhiteSpace(an) && labOv.CompositeByNorm.TryGetValue(an, out tpl))
					return true;
			}
		}

		tpl = null!;
		return false;
	}

	private static string ReadValueForCommonColumn(
			ColumnSpec col,
			string[] row,
			Dictionary<string, int> headerExact,
			Dictionary<string, int> headerNorm,
			LabOverrides labOv)
	{
		// Composite overrides by column name OR by any alias (exact or normalized)
		if (TryGetCompositeTemplate(col, labOv, out var tpl))
			return EvaluateComposite(tpl, row, headerExact, headerNorm);

		if (col.Name.Equals("CPTCode", StringComparison.OrdinalIgnoreCase))
			return ReadCptCodeValue(col, row, headerExact, headerNorm, labOv);

		return ReadByAliases(col, row, headerExact, headerNorm, labOv);
	}

	private static string EvaluateComposite(
		CompositeTemplate tpl,
		string[] row,
		Dictionary<string, int> headerExact,
		Dictionary<string, int> headerNorm)
	{
		// Pre-evaluate all column segments
		var segVals = new List<(CompositeSegment Seg, string Val)>(tpl.Segments.Count);
		foreach (var seg in tpl.Segments)
		{
			if (!seg.IsColumn)
			{
				segVals.Add((seg, seg.Text ?? ""));
				continue;
			}

			var v = ReadHeaderValue(seg.Text, row, headerExact, headerNorm);
			segVals.Add((seg, v));
		}

		var nonEmptyRefIdx = segVals
			.Select((x, i) => (x, i))
			.Where(t => t.x.Seg.IsColumn && !string.IsNullOrWhiteSpace(t.x.Val))
			.Select(t => t.i)
			.ToList();

		if (nonEmptyRefIdx.Count == 0)
			return "";

		int first = nonEmptyRefIdx.First();
		int last = nonEmptyRefIdx.Last();

		var sb = new StringBuilder();
		bool hasAny = false;

		for (int i = 0; i < segVals.Count; i++)
		{
			var (seg, val) = segVals[i];

			if (seg.IsColumn)
			{
				if (string.IsNullOrWhiteSpace(val))
					continue;

				sb.Append(val);
				hasAny = true;
				continue;
			}

			// literal segment
			var lit = val ?? "";
			if (string.IsNullOrEmpty(lit))
				continue;

			// Keep prefix/suffix literals only if they contain letters/digits (e.g., "Dr ")
			bool hasAlphaNum = lit.Any(ch => char.IsLetterOrDigit(ch));

			if (i < first)
			{
				if (hasAlphaNum)
					sb.Append(lit);
				continue;
			}

			if (i > last)
			{
				if (hasAlphaNum)
					sb.Append(lit);
				continue;
			}

			// Between two non-empty values -> keep separators exactly
			if (hasAny)
				sb.Append(lit);
		}

		return sb.ToString().Trim();
	}

	private static string ReadHeaderValue(
		string headerName,
		string[] row,
		Dictionary<string, int> headerExact,
		Dictionary<string, int> headerNorm)
	{
		var key = (headerName ?? "").Trim();
		if (string.IsNullOrWhiteSpace(key)) return "";

		if (headerExact.TryGetValue(key, out int idx))
			return Get(row, idx);

		var kn = NormKey(key);
		if (!string.IsNullOrWhiteSpace(kn) && headerNorm.TryGetValue(kn, out idx))
			return Get(row, idx);

		return "";
	}

	private static string ReadCptCodeValue(
		ColumnSpec col,
		string[] row,
		Dictionary<string, int> headerExact,
		Dictionary<string, int> headerNorm,
		LabOverrides labOv)
	{
		// When the LAB schema declares a source for this column (e.g. Cove maps CPTCode from
		// "Procedure"), that mapping must win even if the input file also contains a literal
		// CPT/CPTCode column. ReadByAliases orders lab-declared headers first, so it resolves
		// to the mapped column and ignores the other alias matches.
		if (LabProvidesTargetColumn(col, labOv))
			return ReadByAliases(col, row, headerExact, headerNorm, labOv);

		var preferredHeaders = new[]
		{
			"CPT",
			"CPTCode",
			"CPT Code",
			"CPTs",
			"Claim Level CPT"
		};

		foreach (var header in preferredHeaders)
		{
			var value = ReadHeaderValue(header, row, headerExact, headerNorm);
			if (!string.IsNullOrWhiteSpace(value))
				return value;
		}

		return ReadByAliases(col, row, headerExact, headerNorm, labOv);
	}

	/// <summary>
	/// Every source header the COMMON schema knows for this column: declared aliases, built-ins and
	/// the column name itself. Order is preserved; lab-declared spellings are hoisted to the front
	/// so they win when the file happens to contain several of them.
	/// </summary>
	private static List<string> BuildCommonCandidates(ColumnSpec col, LabOverrides labOv)
	{
		var candidates = (col.Aliases ?? new List<string>())
			.Where(a => !string.IsNullOrWhiteSpace(a))
			.Concat(GetBuiltInSourceAliases(col.Name))
			.Concat(new[] { col.Name })
			.Select(a => (a ?? "").Trim())
			.Where(a => !string.IsNullOrWhiteSpace(a))
			.ToList();

		var ordered = new List<string>(candidates.Count);
		var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

		// Preferred first (stable order), then the rest.
		foreach (var c in candidates)
			if (IsLabPreferred(c, labOv) && seen.Add(c))
				ordered.Add(c);

		foreach (var c in candidates)
			if (!IsLabPreferred(c, labOv) && seen.Add(c))
				ordered.Add(c);

		return ordered;
	}

	private static bool IsLabPreferred(string header, LabOverrides labOv)
	{
		var h = (header ?? "").Trim();
		if (string.IsNullOrWhiteSpace(h))
			return false;

		if (labOv.PreferredExact.Contains(h))
			return true;

		var hn = NormKey(h);
		return !string.IsNullOrWhiteSpace(hn) && labOv.PreferredNorm.Contains(hn);
	}

	/// <summary>
	/// The interchangeable spellings this LAB declares for a COMMON column, plus any header the
	/// near-miss matcher bound at runtime. Empty when the lab schema says nothing about the column.
	/// </summary>
	private static List<string> BuildLabDeclaredGroup(ColumnSpec col, IReadOnlyList<string> commonCandidates, LabOverrides labOv)
	{
		var group = new List<string>();
		var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

		foreach (var cand in commonCandidates)
		{
			var cn = NormKey(cand);
			if (string.IsNullOrWhiteSpace(cn) || !labOv.AliasGroupByNorm.TryGetValue(cn, out var members))
				continue;

			foreach (var m in members)
				if (!string.IsNullOrWhiteSpace(m) && seen.Add(m.Trim()))
					group.Add(m.Trim());
		}

		var target = NormKey(col.Name);
		if (!string.IsNullOrWhiteSpace(target) &&
			labOv.DynamicSourceByCommonNorm.TryGetValue(target, out var dynamicHeader) &&
			!string.IsNullOrWhiteSpace(dynamicHeader) &&
			seen.Add(dynamicHeader))
		{
			group.Add(dynamicHeader);
		}

		return group;
	}

	private static string ReadByAliases(ColumnSpec col, string[] row, Dictionary<string, int> headerExact, Dictionary<string, int> headerNorm,
			LabOverrides labOv)
	{
		var candidates = BuildCommonCandidates(col, labOv);
		var labGroup = BuildLabDeclaredGroup(col, candidates, labOv);

		// TIER 1 - the lab's own interchangeable spellings.
		// Scan for the first NON-EMPTY value instead of the first column that merely exists.
		// When two source systems are merged into one CSV the union header carries both spellings
		// on every row, and the row's own system fills exactly one of them; stopping at the first
		// existing column would return the other system's blank cell for every row.
		bool anyLabColumnPresent = false;

		foreach (var cand in labGroup)
		{
			if (!TryResolveHeaderIndex(cand, headerExact, headerNorm, out var labIdx))
				continue;

			anyLabColumnPresent = true;

			var value = Get(row, labIdx);
			if (!string.IsNullOrWhiteSpace(value))
				return value;
		}

		// The lab declared this column and it is genuinely blank on this row. Do NOT fall through to
		// unrelated COMMON aliases - that is how a blank line-level CPT used to pick up the
		// claim-level roll-up instead of staying empty.
		if (anyLabColumnPresent)
			return "";

		// TIER 2 - nothing the lab declared exists in the file: first matching COMMON alias wins.
		foreach (var cand in candidates)
		{
			if (TryResolveHeaderIndex(cand, headerExact, headerNorm, out var idx))
				return Get(row, idx);
		}

		return "";
	}


	/// <summary>
	/// One appended output column. <see cref="SourceIndexes"/> holds more than one index when the lab
	/// schema declares several interchangeable spellings for a column that has no COMMON target
	/// (e.g. Webpm "Subscriber Id" and Daq "Primary Carrier Policy Number"); the row takes the first
	/// non-empty of them so the merged file gets one populated column instead of two half-empty ones.
	/// </summary>
	private sealed record ExtraSourceColumn(string OutputName, List<int> SourceIndexes);

	private static List<ExtraSourceColumn> FindExtraSourceColumnIndexes(
		string[] header,
		ColumnSchema commonSchema,
		Dictionary<string, int> headerExact,
		Dictionary<string, int> headerNorm,
		LabOverrides labOv)
	{
		var usedIndexes = new HashSet<int>();

		foreach (var col in commonSchema.Columns)
		{
			if (col == null)
				continue;

			// metadata / computed columns are not source-backed
			if (IsMetadata(col.Name) || IsDays(col.Name) || !string.IsNullOrWhiteSpace(col.Calculation))
				continue;

			MarkReferencedSourceIndexes(col, headerExact, headerNorm, labOv, usedIndexes);
		}

		var commonTargetNorms = new HashSet<string>(
			commonSchema.Columns
				.Where(c => c != null && !string.IsNullOrWhiteSpace(c.Name))
				.Select(c => NormKey(c.Name))
				.Where(x => !string.IsNullOrWhiteSpace(x)),
			StringComparer.OrdinalIgnoreCase);

		var extras = new List<ExtraSourceColumn>();
		var emittedGroups = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

		for (int i = 0; i < header.Length; i++)
		{
			var sourceHeader = (header[i] ?? string.Empty).Trim();
			if (string.IsNullOrWhiteSpace(sourceHeader))
				continue;

			// Consumed by a COMMON column already (directly, via alias, or via a composite).
			if (usedIndexes.Contains(i))
				continue;

			var normalizedSourceHeader = NormKey(sourceHeader);

			// If source header itself is already a standard/common output column, do not append it again.
			if (!string.IsNullOrWhiteSpace(normalizedSourceHeader) && commonTargetNorms.Contains(normalizedSourceHeader))
				continue;

			// A header the LAB schema declares but no COMMON column consumed: it has no standard
			// target, so it still has to be appended or the data is lost. Emit the whole alias group
			// once, under its primary spelling, merging the sheet-specific variants into one column.
			// (Certus "Billed Amounts" does not reach here - it maps to ChargeAmount and is already
			// in usedIndexes, so it is still not duplicated.)
			if (!string.IsNullOrWhiteSpace(normalizedSourceHeader) &&
				labOv.AliasGroupByNorm.TryGetValue(normalizedSourceHeader, out var group) &&
				group.Count > 0)
			{
				if (!emittedGroups.Add(NormKey(group[0])))
					continue;

				var groupIndexes = group
					.Select(g => TryResolveHeaderIndex(g, headerExact, headerNorm, out var gi) ? gi : -1)
					.Where(gi => gi >= 0 && !usedIndexes.Contains(gi))
					.Distinct()
					.ToList();

				if (groupIndexes.Count > 0)
					extras.Add(new ExtraSourceColumn(group[0], groupIndexes));

				continue;
			}

			// Lab-declared single spelling with no group and no common target: keep it as-is.
			extras.Add(new ExtraSourceColumn(sourceHeader, new List<int> { i }));
		}

		return extras;
	}

	private static void MarkReferencedSourceIndexes(
		ColumnSpec col,
		Dictionary<string, int> headerExact,
		Dictionary<string, int> headerNorm,
		LabOverrides labOv,
		HashSet<int> usedIndexes)
	{
		if (TryGetCompositeTemplate(col, labOv, out var tpl))
		{
			foreach (var seg in tpl.Segments.Where(s => s.IsColumn))
			{
				if (TryResolveHeaderIndex(seg.Text, headerExact, headerNorm, out var compositeIndex))
					usedIndexes.Add(compositeIndex);
			}
			return;
		}

		var candidates = BuildCommonCandidates(col, labOv);

		// Alias-group members and runtime bindings are real sources for this column too, so they
		// must not be appended a second time as "unmapped extra" output columns.
		foreach (var cand in candidates.Concat(BuildLabDeclaredGroup(col, candidates, labOv)))
		{
			if (TryResolveHeaderIndex(cand, headerExact, headerNorm, out var idx))
				usedIndexes.Add(idx);
		}
	}

	// ---------------- Dynamic (near-miss) column binding ----------------
	// NormKey already absorbs the common kinds of header drift for free, because it strips case,
	// spaces and punctuation: "Proc-Charge Amount $" / "Proc Charge Amount" / "proc_charge_amount"
	// all resolve to the same key. What it cannot absorb is a header that gained, lost or misspelt a
	// WORD ("Proc-Modifier 1" -> "Proc-Modifier", "Pat Payments" -> "Pat Paymentss").
	//
	// This pass runs once per file, AFTER everything declared has been resolved, and only for
	// COMMON columns that found no source at all. It considers only source headers that no other
	// column claimed, and it binds one only when the best score clears MinScore AND beats the
	// runner-up by MinMargin - an ambiguous header is left unbound rather than guessed. Every
	// decision (bound and rejected) is logged so a real rename can be promoted into the lab schema.

	// Deliberately strict. A wrong binding writes plausible-looking numbers into the wrong column,
	// which is far worse than a blank, so only a near-identical header is taken automatically.
	// Anything merely similar is logged instead, to be promoted into the lab schema by hand.
	private const double DynamicMinScore = 0.90;
	private const double DynamicMinMargin = 0.08;
	private const double DynamicReportScore = 0.75;

	private static void ResolveDynamicColumnBindings(
		string[] header,
		ColumnSchema commonSchema,
		Dictionary<string, int> headerExact,
		Dictionary<string, int> headerNorm,
		LabOverrides labOv,
		Action<string>? log)
	{
		// 1. Which source headers are already spoken for.
		// Note every source-backed column stays in the running, not just the ones that resolved to
		// nothing: in a merged two-system file a column is "resolved" as soon as ONE system's
		// spelling is present, while the other system's renamed spelling is still orphaned and
		// would leave that system's rows blank.
		var claimed = new HashSet<int>();
		var targets = new List<ColumnSpec>();

		foreach (var col in commonSchema.Columns)
		{
			if (col == null || IsMetadata(col.Name) || IsDays(col.Name) || !string.IsNullOrWhiteSpace(col.Calculation))
				continue;

			MarkReferencedSourceIndexes(col, headerExact, headerNorm, labOv, claimed);

			if (!TryGetCompositeTemplate(col, labOv, out _))
				targets.Add(col);
		}

		if (targets.Count == 0)
			return;

		var freeHeaders = new List<(int Index, string Name)>();
		for (int i = 0; i < header.Length; i++)
		{
			var name = (header[i] ?? "").Trim();
			if (!string.IsNullOrWhiteSpace(name) && !claimed.Contains(i))
				freeHeaders.Add((i, name));
		}

		if (freeHeaders.Count == 0)
			return;

		// 2. Score every (unresolved column, free header) pair, then take them greedily by score so
		//    one header cannot be handed to two columns.
		var scored = new List<(ColumnSpec Col, string Header, double Score, double Runner)>();

		foreach (var col in targets)
		{
			var candidates = BuildCommonCandidates(col, labOv)
				.Concat(BuildLabDeclaredGroup(col, BuildCommonCandidates(col, labOv), labOv))
				.Distinct(StringComparer.OrdinalIgnoreCase)
				.ToList();

			var ranked = freeHeaders
				.Select(h => (h.Name, Score: candidates.Max(c => HeaderSimilarity(c, h.Name))))
				.OrderByDescending(x => x.Score)
				.ToList();

			if (ranked.Count == 0)
				continue;

			var best = ranked[0];
			var runner = ranked.Count > 1 ? ranked[1].Score : 0d;

			if (best.Score < DynamicMinScore)
			{
				if (best.Score >= DynamicReportScore)
					log?.Invoke($"Possible renamed column: source header '{best.Name}' resembles '{col.Name}' (score {best.Score:0.00}) but is below the auto-bind threshold {DynamicMinScore:0.00}. It was NOT used - add it to the lab schema Aliases if it is the same column.");

				continue;
			}

			if (best.Score - runner < DynamicMinMargin)
			{
				log?.Invoke($"Dynamic column match skipped for '{col.Name}': '{best.Name}' ({best.Score:0.00}) is too close to the next candidate ({runner:0.00}).");
				continue;
			}

			scored.Add((col, best.Name, best.Score, runner));
		}

		var takenHeaders = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

		foreach (var match in scored.OrderByDescending(s => s.Score))
		{
			if (!takenHeaders.Add(match.Header))
			{
				log?.Invoke($"Dynamic column match skipped for '{match.Col.Name}': source header '{match.Header}' was already bound to a closer column.");
				continue;
			}

			var key = NormKey(match.Col.Name);
			if (string.IsNullOrWhiteSpace(key))
				continue;

			labOv.DynamicSourceByCommonNorm[key] = match.Header;
			log?.Invoke($"Dynamic column match: '{match.Header}' -> '{match.Col.Name}' (score {match.Score:0.00}). Add it to the lab schema Aliases to make this permanent.");
		}
	}

	/// <summary>
	/// 0..1 similarity between two header names: the better of a whole-string edit-distance ratio
	/// and a word-overlap (Jaccard) ratio, both computed on normalized text.
	/// </summary>
	private static double HeaderSimilarity(string a, string b)
	{
		var na = NormKey(a);
		var nb = NormKey(b);

		if (string.IsNullOrWhiteSpace(na) || string.IsNullOrWhiteSpace(nb))
			return 0d;

		if (na.Equals(nb, StringComparison.Ordinal))
			return 1d;

		double edit = 1d - ((double)LevenshteinDistance(na, nb) / Math.Max(na.Length, nb.Length));

		var ta = TokenizeHeader(a);
		var tb = TokenizeHeader(b);

		double jaccard = 0d;
		if (ta.Count > 0 && tb.Count > 0)
		{
			double intersect = ta.Count(t => tb.Contains(t));
			double union = ta.Union(tb, StringComparer.OrdinalIgnoreCase).Count();
			if (union > 0) jaccard = intersect / union;
		}

		return Math.Max(edit, jaccard);
	}

	private static HashSet<string> TokenizeHeader(string s)
	{
		var parts = Regex.Split(s ?? "", @"(?<=[a-z0-9])(?=[A-Z])|[^A-Za-z0-9]+")
			.Select(p => p.Trim().ToLowerInvariant())
			.Where(p => p.Length > 0);

		return new HashSet<string>(parts, StringComparer.OrdinalIgnoreCase);
	}

	private static int LevenshteinDistance(string a, string b)
	{
		if (a.Length == 0) return b.Length;
		if (b.Length == 0) return a.Length;

		var prev = new int[b.Length + 1];
		var curr = new int[b.Length + 1];

		for (int j = 0; j <= b.Length; j++) prev[j] = j;

		for (int i = 1; i <= a.Length; i++)
		{
			curr[0] = i;

			for (int j = 1; j <= b.Length; j++)
			{
				int cost = a[i - 1] == b[j - 1] ? 0 : 1;
				curr[j] = Math.Min(Math.Min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
			}

			(prev, curr) = (curr, prev);
		}

		return prev[b.Length];
	}

	private static bool TryResolveHeaderIndex(
		string headerName,
		Dictionary<string, int> headerExact,
		Dictionary<string, int> headerNorm,
		out int idx)
	{
		idx = -1;
		var key = (headerName ?? string.Empty).Trim();
		if (string.IsNullOrWhiteSpace(key))
			return false;

		if (headerExact.TryGetValue(key, out idx))
			return true;

		var normalized = NormKey(key);
		if (!string.IsNullOrWhiteSpace(normalized) && headerNorm.TryGetValue(normalized, out idx))
			return true;

		return false;
	}



	private static IEnumerable<string> GetBuiltInSourceAliases(string? commonColumnName)
	{
		var name = (commonColumnName ?? string.Empty).Trim();

		if (name.Equals("ChargeAmount", StringComparison.OrdinalIgnoreCase))
		{
			yield return "Billed Amounts";
			yield return "Biilled Amounts";
			yield return "Billed Amount";
			yield return "Claim Amount";
			yield return "Charge Amount";
			yield return "Total Charge";
			yield return "Total Charges";
			yield return "TotalCharge";
			yield break;
		}

		if (name.Equals("InsurancePayment", StringComparison.OrdinalIgnoreCase))
		{
			yield return "Insurance Payments";
			yield return "Insurance Payment";
			yield return "CarrierPayment";
			yield return "Carrier Payment";
			yield return "Ins. Payment";
			yield break;
		}

		if (name.Equals("PatientPayment", StringComparison.OrdinalIgnoreCase))
		{
			yield return "Patient Payments";
			yield return "Patient Payment";
			yield return "PatientPayment";
			yield return "Pat Payments";
			yield return "Pat. Payments";
			yield break;
		}

		if (name.Equals("InsuranceAdjustments", StringComparison.OrdinalIgnoreCase))
		{
			yield return "Adjustments";
			yield return "Adjustment";
			yield return "Insurance Adjustment";
			yield return "InsuranceAdjustment";
			yield return "CarrierWO";
			yield break;
		}

		if (name.Equals("InsuranceBalance", StringComparison.OrdinalIgnoreCase))
		{
			yield return "Insurance Balance";
			yield return "InsuranceBalance";
			yield return "Ins Balance";
			yield return "CarrierBalance";
			yield return "Carrier Balance";
			yield break;
		}

		if (name.Equals("PatientBalance", StringComparison.OrdinalIgnoreCase))
		{
			yield return "Patient Balance";
			yield return "PatientBalance";
			yield return "Pat Balance";
			yield break;
		}
	}

	private static bool LabProvidesTargetColumn(ColumnSpec col, LabOverrides labOv)
	{
		// Composite lab mapping counts as "provided"
		if (TryGetCompositeTemplate(col, labOv, out _))
			return true;

		// Direct name match
		if (labOv.PreferredExact.Contains(col.Name))
			return true;

		var nn = NormKey(col.Name);
		if (!string.IsNullOrWhiteSpace(nn) && labOv.PreferredNorm.Contains(nn))
			return true;

		// Any alias match
		if (col.Aliases != null)
		{
			foreach (var a in col.Aliases)
			{
				var aa = (a ?? "").Trim();
				if (string.IsNullOrWhiteSpace(aa)) continue;

				if (labOv.PreferredExact.Contains(aa))
					return true;

				var an = NormKey(aa);
				if (!string.IsNullOrWhiteSpace(an) && labOv.PreferredNorm.Contains(an))
					return true;
			}
		}

		return false;
	}

	/// <summary>
	/// Tries to read the value for a common column ONLY IF a matching header exists in the source CSV.
	/// Returns true if a header match was found (even if the cell value is blank).
	/// </summary>
	private static bool TryReadValueIfHeaderExists(
		ColumnSpec col,
		string[] row,
		Dictionary<string, int> headerExact,
		Dictionary<string, int> headerNorm,
		LabOverrides labOv,
		out string value)
	{
		// Composite overrides by column name OR by any alias (exact or normalized)
		if (TryGetCompositeTemplate(col, labOv, out var tpl))
		{
			value = EvaluateComposite(tpl, row, headerExact, headerNorm);
			return true;
		}

		var candidates = (col.Aliases ?? new List<string>())
			.Where(a => !string.IsNullOrWhiteSpace(a))
			.Concat(GetBuiltInSourceAliases(col.Name))
			.Concat(new[] { col.Name })
			.Select(a => (a ?? "").Trim())
			.Where(a => !string.IsNullOrWhiteSpace(a))
			.ToList();

		// Prefer headers explicitly present in the LAB schema when multiple COMMON aliases exist.
		var ordered = new List<string>(candidates.Count);
		var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

		foreach (var c in candidates)
		{
			var cn = NormKey(c);
			var isPref = labOv.PreferredExact.Contains(c) || (!string.IsNullOrWhiteSpace(cn) && labOv.PreferredNorm.Contains(cn));
			if (!isPref) continue;

			if (seen.Add(c))
				ordered.Add(c);
		}

		foreach (var c in candidates)
		{
			var cn = NormKey(c);
			var isPref = labOv.PreferredExact.Contains(c) || (!string.IsNullOrWhiteSpace(cn) && labOv.PreferredNorm.Contains(cn));
			if (isPref) continue;

			if (seen.Add(c))
				ordered.Add(c);
		}

		foreach (var cand in ordered)
		{
			var c = (cand ?? "").Trim();
			if (string.IsNullOrWhiteSpace(c)) continue;

			if (headerExact.TryGetValue(c, out int idx))
			{
				value = Get(row, idx);
				return true;
			}

			var cn = NormKey(c);
			if (!string.IsNullOrWhiteSpace(cn) && headerNorm.TryGetValue(cn, out idx))
			{
				value = Get(row, idx);
				return true;
			}
		}

		value = "";
		return false;
	}

	private static string EvaluateCalculation(
		string expr,
		Dictionary<string, string> extracted,
		Dictionary<string, ColumnSpec> schemaByName,
		string[] row,
		Dictionary<string, int> headerExact,
		Dictionary<string, int> headerNorm,
		LabOverrides labOv)
	{
		decimal sum = 0m;
		bool hadAny = false;

		foreach (var token in expr.Split('+', StringSplitOptions.RemoveEmptyEntries))
		{
			var key = token.Trim();
			if (string.IsNullOrWhiteSpace(key)) continue;

			string raw = "";

			if (schemaByName.TryGetValue(key, out var refCol))
			{
				if (!extracted.TryGetValue(refCol.Name, out raw))
					raw = ReadValueForCommonColumn(refCol, row, headerExact, headerNorm, labOv);
			}
			else
			{
				if (headerExact.TryGetValue(key, out int idx))
					raw = Get(row, idx);
				else
				{
					var kn = NormKey(key);
					if (!string.IsNullOrWhiteSpace(kn) && headerNorm.TryGetValue(kn, out idx))
						raw = Get(row, idx);
				}
			}

			if (!string.IsNullOrWhiteSpace(raw))
				hadAny = true;

			sum += ParseDecimal(raw);
		}

		return hadAny ? sum.ToString(CultureInfo.InvariantCulture) : "";
	}

	private static bool IsDateType(string? dt)
		=> (dt ?? "").Trim().Equals("date", StringComparison.OrdinalIgnoreCase)
		|| (dt ?? "").Trim().Equals("datetime", StringComparison.OrdinalIgnoreCase);

	private static bool IsMetadata(string name)
		=> name.Equals("LabID", StringComparison.OrdinalIgnoreCase)
		|| name.Equals("LabName", StringComparison.OrdinalIgnoreCase)
		|| name.Equals("SourceFileID", StringComparison.OrdinalIgnoreCase)
		|| name.Equals("IngestedOn", StringComparison.OrdinalIgnoreCase)
		|| name.Equals("RowHash", StringComparison.OrdinalIgnoreCase);

	private static bool IsDays(string name)
		=> name.Equals("DaystoDOS", StringComparison.OrdinalIgnoreCase)
		|| name.Equals("RollingDays", StringComparison.OrdinalIgnoreCase)
		|| name.Equals("DaystoBill", StringComparison.OrdinalIgnoreCase)
		|| name.Equals("DaystoPost", StringComparison.OrdinalIgnoreCase);

	private static string NormalizeDate(string raw)
	{
		var dt = ParseDateMaybe(raw);
		return dt.HasValue ? dt.Value.ToString("MM/dd/yyyy", CultureInfo.InvariantCulture) : "";
	}


	private static string GetFirstNonEmpty(Dictionary<string, string> extracted, params string[] keys)
	{
		foreach (var k in keys)
		{
			if (extracted.TryGetValue(k, out var v) && !string.IsNullOrWhiteSpace(v))
				return v;
		}
		return "";
	}

	private static string DividePerUnit(Dictionary<string, string> extracted, string amountKey, decimal unitsVal)
	{
		if (!extracted.TryGetValue(amountKey, out var raw) || string.IsNullOrWhiteSpace(raw))
			return "";

		var amt = ParseDecimal(raw);
		var per = amt / unitsVal;
		return per.ToString("0.00");
	}

	private static string ComputePayStatus(Dictionary<string, string> extracted)
	{
		decimal carrierPay = ParseDecimal(extracted.TryGetValue("InsurancePayment", out var ip) ? ip : "");
		decimal patientPay = ParseDecimal(extracted.TryGetValue("PatientPayment", out var pp) ? pp : "");
		decimal totalPayment = carrierPay + patientPay;

		decimal carrierBal = ParseDecimal(extracted.TryGetValue("InsuranceBalance", out var cb) ? cb : "");

		decimal patAdj = ParseDecimal(extracted.TryGetValue("PatientAdjustments", out var pa) ? pa : "");
		decimal insAdj = ParseDecimal(extracted.TryGetValue("InsuranceAdjustments", out var ia) ? ia : "");
		decimal totalAdj = patAdj + insAdj;

		decimal chargeAmt = ParseDecimal(extracted.TryGetValue("ChargeAmount", out var ca) ? ca : "");
		decimal patientBal = ParseDecimal(extracted.TryGetValue("PatientBalance", out var pb) ? pb : "");

		var denial = (extracted.TryGetValue("DenialCode", out var dc) ? dc : "") ?? "";
		denial = denial.Trim();
		bool hasDenial = !string.IsNullOrWhiteSpace(denial);   // "Code"
		bool denialBlank = !hasDenial;                         // "Blank"

		// Use a tiny epsilon for safe comparisons
		const decimal EPS = 0.00001m;

		static bool IsZero(decimal v, decimal eps) => Math.Abs(v) <= eps;
		static bool Eq(decimal a, decimal b, decimal eps) => Math.Abs(a - b) <= eps;

		// Rule 1: Paid
		if (totalPayment > EPS)
			return "Paid";

		// Rule 9: Negative Payment
		if (totalPayment < -EPS)
			return "Negative Payment";

		// Rule 12: Zero Billed Amount
		// NOTE: put this BEFORE rule 2, otherwise ChargeAmount=0 would incorrectly become "Adjusted".
		if (IsZero(chargeAmt, EPS))
			return "Zero Billed Amount";

		// Rule 2: Adjusted
		// Total Payment = 0 AND Carrier Balance <= 0 AND Total Adjustment >= Charge Amount AND Denial Code = Code or Blank
		if (IsZero(totalPayment, EPS) && carrierBal <= EPS && (totalAdj + EPS) >= chargeAmt)
			return "Adjusted";

		// Rule 3: Partially Adjusted
		// Total Payment = 0 AND Carrier Balance > 0 AND Total Adjustment > 0 AND Denial Code = Blank
		if (IsZero(totalPayment, EPS) && carrierBal > EPS && totalAdj > EPS && denialBlank)
			return "Partially Adjusted";

		// Rule 4: No Response
		// Charge Amount = Carrier Balance AND Denial Code = Blank
		if (Eq(chargeAmt, carrierBal, EPS) && denialBlank)
			return "No Response";

		// Rule 5: No Response
		// Total Payment = 0 AND Total Adjustments = 0 AND Carrier Balance > 0 AND Denial Code = Blank
		if (IsZero(totalPayment, EPS) && IsZero(totalAdj, EPS) && carrierBal > EPS && denialBlank)
			return "No Response";

		// Rule 6: Denied
		// Total Payment = 0 AND Carrier Balance > 0 AND Denial Code = Code
		if (IsZero(totalPayment, EPS) && carrierBal > EPS && hasDenial)
			return "Denied";

		// Rule 7: Denied
		// Total Payment = 0 AND Total Adjustments = 0 AND Carrier Balance = 0 AND Denial Code = Code
		if (IsZero(totalPayment, EPS) && IsZero(totalAdj, EPS) && IsZero(carrierBal, EPS) && hasDenial)
			return "Denied";

		// Rule 8: Patient Responsibility
		// Carrier Payment = 0 AND Patient Balance > 0
		if (IsZero(carrierPay, EPS) && patientBal > EPS)
			return "Patient Responsibility";

		// Rule 10: Partially Adjusted
		// Total Payment = 0 AND Carrier Balance = 0 AND Total Adjustment > 0 AND Denial Code = Blank
		if (IsZero(totalPayment, EPS) && IsZero(carrierBal, EPS) && totalAdj > EPS && IsZero(patientBal, EPS) && denialBlank)
			return "Partially Adjusted";

		// Rule 11: Partially Adjusted
		// Total Payment = 0 AND Carrier Balance = 0 AND Total Adjustment > 0 AND Denial Code = Code
		if (IsZero(totalPayment, EPS) && IsZero(carrierBal, EPS) && totalAdj > EPS && hasDenial)
			return "Partially Adjusted";

		return "";
	}
	// ClaimLevel UID: LabShortCode + ClaimID(VisitNumber) + AccessionNo + DOS(MMDDYYYY).
	// Plain concatenation with no delimiters.
	private static string BuildClaimUID(Dictionary<string, string> extracted, DateTime? dos, string? labName)
	{
		var prefix = ResolveLabShortCode(labName);
		var claimId = extracted.TryGetValue("ClaimID", out var c) ? c.Trim() : "";
		var accession = extracted.TryGetValue("AccessionNumber", out var a) ? a.Trim() : "";
		var dosStr = dos.HasValue ? dos.Value.ToString("MMddyyyy", CultureInfo.InvariantCulture) : "";
		return $"{prefix}{claimId}{accession}{dosStr}";
	}

	// LineLevel UID: LabShortCode + ClaimID(VisitNumber) + AccessionNo + DOS(MMDDYYYY) + CPTCode + Units.
	// Plain concatenation with no delimiters.
	private static string BuildLineLevelUID(Dictionary<string, string> extracted, DateTime? dos, string? labName)
	{
		var prefix = ResolveLabShortCode(labName);
		var claimId = extracted.TryGetValue("ClaimID", out var c) ? c.Trim() : "";
		var accession = extracted.TryGetValue("AccessionNumber", out var a) ? a.Trim() : "";
		var dosStr = dos.HasValue ? dos.Value.ToString("MMddyyyy", CultureInfo.InvariantCulture) : "";
		var cptCode = extracted.TryGetValue("CPTCode", out var cpt) ? cpt.Trim() : "";
		var units = extracted.TryGetValue("Units", out var u) ? u.Trim() : "";
		return $"{prefix}{claimId}{accession}{dosStr}{cptCode}{units}";
	}

	// Maps a lab name to its short code used as a prefix on ClaimUID / LineLevelUID.
	// Matching is done on the normalized name (lowercased, non-alphanumeric stripped) so
	// variants like "Beech_Tree" / "Beech Tree" or "NorthWest" / "North West" all resolve.
	private static readonly Dictionary<string, string> LabShortCodesByNormName = new(StringComparer.OrdinalIgnoreCase)
	{
		[NormKey("Beech_Tree")] = "BCT",
		[NormKey("Inhealth_DTR")] = "IHR",
		[NormKey("Cove")] = "COV",
		[NormKey("PCR_Dx_AL")] = "PAL",
		[NormKey("PCR_Dx_CO")] = "PCO",
		[NormKey("Certus")] = "CTS",
		[NormKey("Elixir")] = "EXR",
		[NormKey("Phi Life")] = "PLF",
		[NormKey("Rising Tides")] = "RTS",
		[NormKey("Augustus Labs")] = "AUG",
		[NormKey("PCR Labs of America")] = "PLA",
		[NormKey("NorthWest")] = "NWL",
	};

	/// <summary>
	/// Resolves a lab's short code (e.g. "NorthWest" -> "NWL"). Returns "" when the lab is unknown.
	/// Used both as the ClaimUID/LineLevelUID prefix and as the LabName value in LabInsuranceMaster.
	/// </summary>
	public static string ResolveLabShortCode(string? labName)
	{
		var key = NormKey(labName ?? "");
		if (string.IsNullOrWhiteSpace(key))
			return "";

		return LabShortCodesByNormName.TryGetValue(key, out var code) ? code : "";
	}

	private static DateTime? ParseDateMaybe(string raw)
	{
		raw = (raw ?? "").Trim();
		if (string.IsNullOrWhiteSpace(raw)) return null;

		// Excel serial number
		if (double.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out var oa))
		{
			if (oa > 20000 && oa < 60000)
			{
				try { return DateTime.FromOADate(oa); } catch { }
			}
		}

		var formats = new[]
		{
			"MM/dd/yyyy","M/d/yyyy",
			"dd/MM/yyyy","d/M/yyyy",
			"yyyy-MM-dd","yyyy/M/d","yyyy/MM/dd",
			"yyyy-MM-dd HH:mm:ss","yyyy/MM/dd HH:mm:ss","MM/dd/yyyy HH:mm:ss","M/d/yyyy H:mm:ss",
			"MM/dd/yyyy h:mm:ss tt","M/d/yyyy h:mm:ss tt",
			"dd-MMM-yyyy","d-MMM-yyyy","dd-MMM-yy","d-MMM-yy"
		};

		if (DateTime.TryParseExact(raw, formats, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var dtExact))
			return dtExact;

		if (DateTime.TryParse(raw, new CultureInfo("en-SG"), DateTimeStyles.AllowWhiteSpaces, out var dtSg))
			return dtSg;

		if (DateTime.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var dtAny))
			return dtAny;

		return null;
	}

	private static decimal ParseDecimal(string raw)
	{
		raw = (raw ?? "").Trim();
		if (string.IsNullOrWhiteSpace(raw)) return 0m;

		raw = raw.Replace("$", "").Replace(",", "");

		bool neg = raw.StartsWith("(") && raw.EndsWith(")");
		if (neg) raw = raw.Trim('(', ')');

		if (decimal.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out var d))
			return neg ? -d : d;

		if (decimal.TryParse(raw, NumberStyles.Any, new CultureInfo("en-US"), out d))
			return neg ? -d : d;

		if (decimal.TryParse(raw, NumberStyles.Any, new CultureInfo("en-SG"), out d))
			return neg ? -d : d;

		return 0m;
	}

	private static string Get(string[] row, int idx)
		=> idx >= 0 && idx < row.Length ? (row[idx] ?? "") : "";

	private static InsuranceMasterEntry? FindInsuranceMasterEntry(
		Dictionary<string, InsuranceMasterEntry> insuranceMaster,
		string? labName,
		string? payerRaw)
	{
		var payerKey = NormKey(payerRaw ?? "");
		if (string.IsNullOrWhiteSpace(payerKey))
			return null;

		var labKey = NormKey(labName ?? "");

		// 1) Prefer exact lab + payer match when available.
		var exactKey = BuildInsuranceLookupKey(labName, payerRaw);
		if (!string.IsNullOrWhiteSpace(exactKey) && insuranceMaster.TryGetValue(exactKey, out var exactMatch))
			return exactMatch;

		// 2) If lab names are not exactly the same, match by payer and lab contains either way.
		// Example: source lab "NorthWest" can match master lab "Northwest Labs".
		if (!string.IsNullOrWhiteSpace(labKey))
		{
			foreach (var item in insuranceMaster)
			{
				if (!InsuranceKeyHasPayer(item.Key, payerKey))
					continue;

				var masterLabKey = NormKey(item.Value.LabName ?? "");
				if (string.IsNullOrWhiteSpace(masterLabKey))
					continue;

				if (masterLabKey.Contains(labKey, StringComparison.OrdinalIgnoreCase)
					|| labKey.Contains(masterLabKey, StringComparison.OrdinalIgnoreCase))
				{
					return item.Value;
				}
			}
		}

		// 3) Fallback only to payer-only records where insurance master has no Lab Name.
		var payerOnlyKey = BuildInsuranceLookupKey("", payerRaw);
		return insuranceMaster.TryGetValue(payerOnlyKey, out var payerOnlyMatch) ? payerOnlyMatch : null;
	}

	private static bool InsuranceKeyHasPayer(string lookupKey, string payerKey)
	{
		if (string.IsNullOrWhiteSpace(lookupKey) || string.IsNullOrWhiteSpace(payerKey))
			return false;

		if (lookupKey.Equals(payerKey, StringComparison.OrdinalIgnoreCase))
			return true;

		var splitIndex = lookupKey.LastIndexOf('|');
		if (splitIndex < 0 || splitIndex == lookupKey.Length - 1)
			return false;

		return lookupKey[(splitIndex + 1)..].Equals(payerKey, StringComparison.OrdinalIgnoreCase);
	}

	private static string BuildInsuranceLookupKey(string? labName, string? payerRaw)
	{
		var payerKey = NormKey(payerRaw ?? "");
		if (string.IsNullOrWhiteSpace(payerKey))
			return "";

		var labKey = NormKey(labName ?? "");
		return string.IsNullOrWhiteSpace(labKey) ? payerKey : $"{labKey}|{payerKey}";
	}

	private static string NormKey(string s)
	{
		if (string.IsNullOrWhiteSpace(s)) return "";
		s = s.Trim().ToLowerInvariant();
		return Regex.Replace(s, @"[^a-z0-9]+", "");
	}

	private static string Escape(string? s)
	{
		if (string.IsNullOrEmpty(s))
			return "";

		bool mustQuote = s.Contains(',') || s.Contains('"') || s.Contains('\n') || s.Contains('\r');
		if (!mustQuote)
			return s;

		return $"\"{s.Replace("\"", "\"\"")}\"";
	}
	public static void EnrichClaimLevelWithLineLevelCptSummary(
		string claimCsvPath,
		string lineCsvPath,
		string? targetColumnName = null)
	{
		if (string.IsNullOrWhiteSpace(claimCsvPath))
			throw new ArgumentException("Claim CSV path is required.", nameof(claimCsvPath));

		if (string.IsNullOrWhiteSpace(lineCsvPath))
			throw new ArgumentException("Line CSV path is required.", nameof(lineCsvPath));

		if (!File.Exists(claimCsvPath))
			throw new FileNotFoundException("Claim CSV not found.", claimCsvPath);

		if (!File.Exists(lineCsvPath))
			throw new FileNotFoundException("Line CSV not found.", lineCsvPath);

		var claimToCptSummary = BuildClaimLevelCptSummaryLookup(lineCsvPath);

		var tempPath = Path.Combine(
			Path.GetDirectoryName(claimCsvPath)!,
			$"{Path.GetFileNameWithoutExtension(claimCsvPath)}_tmp{Path.GetExtension(claimCsvPath)}");

		if (File.Exists(tempPath))
			File.Delete(tempPath);

		using (var parser = OpenCsvParser(claimCsvPath))
		using (var sw = new StreamWriter(tempPath, false, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true)))
		{
			if (parser.EndOfData)
				throw new InvalidOperationException($"Claim CSV is empty: {claimCsvPath}");

			var headers = parser.ReadFields() ?? Array.Empty<string>();
			if (headers.Length == 0)
				throw new InvalidOperationException($"Claim CSV header row is empty: {claimCsvPath}");

			var headerList = headers.ToList();

			int claimIdIndex = FindHeaderIndex(headerList, "ClaimID");
			if (claimIdIndex < 0)
				throw new InvalidOperationException("Claim CSV does not contain ClaimID column.");

			var effectiveTargetColumnName = string.IsNullOrWhiteSpace(targetColumnName)
				? "CPT Code X Units X Modifier"
				: targetColumnName.Trim();

			int targetIndex = FindHeaderIndex(headerList, effectiveTargetColumnName);

			if (targetIndex < 0)
			{
				headerList.Add(effectiveTargetColumnName);
				targetIndex = headerList.Count - 1;
			}

			sw.WriteLine(string.Join(",", headerList.Select(Escape)));

			while (!parser.EndOfData)
			{
				var row = parser.ReadFields();
				if (row == null)
					continue;

				var rowList = row.ToList();

				while (rowList.Count < headerList.Count)
					rowList.Add(string.Empty);

				var claimId = claimIdIndex < rowList.Count
					? (rowList[claimIdIndex] ?? "").Trim()
					: "";

				rowList[targetIndex] = claimToCptSummary.TryGetValue(claimId, out var summary)
					? summary
					: string.Empty;

				sw.WriteLine(string.Join(",", rowList.Select(Escape)));
			}
		}

		if (File.Exists(claimCsvPath))
			File.Delete(claimCsvPath);

		File.Move(tempPath, claimCsvPath);
	}

	private static Dictionary<string, string> BuildClaimLevelCptSummaryLookup(string lineCsvPath)
	{
		var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
		var grouped = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);

		using var parser = OpenCsvParser(lineCsvPath);

		if (parser.EndOfData)
			return result;

		var headers = parser.ReadFields() ?? Array.Empty<string>();
		var headerList = headers.ToList();

		int claimIdIndex = FindHeaderIndex(headerList, "ClaimID");
		int cptIndex = FindHeaderIndex(headerList, "CPTCode");
		int unitsIndex = FindHeaderIndex(headerList, "Units");
		int modifierIndex = FindHeaderIndex(headerList, "Modifier");

		if (claimIdIndex < 0)
			throw new InvalidOperationException("Line CSV does not contain ClaimID column.");
		if (cptIndex < 0)
			throw new InvalidOperationException("Line CSV does not contain CPTCode column.");

		while (!parser.EndOfData)
		{
			var row = parser.ReadFields();
			if (row == null || row.All(string.IsNullOrWhiteSpace))
				continue;

			string claimId = GetField(row, claimIdIndex);
			string cptCode = GetField(row, cptIndex);
			string units = unitsIndex >= 0 ? GetField(row, unitsIndex) : "";
			string modifier = modifierIndex >= 0 ? GetField(row, modifierIndex) : "";

			if (string.IsNullOrWhiteSpace(claimId) || string.IsNullOrWhiteSpace(cptCode))
				continue;

			string formatted = FormatCptModifierUnits(cptCode, modifier, units);

			if (string.IsNullOrWhiteSpace(formatted))
				continue;

			if (!grouped.TryGetValue(claimId, out var items))
			{
				items = new List<string>();
				grouped[claimId] = items;
			}

			items.Add(formatted);
		}

		foreach (var kvp in grouped)
		{
			result[kvp.Key] = string.Join(",", kvp.Value);
		}

		return result;
	}

	private static string FormatCptModifierUnits(string cptCode, string modifier, string units)
	{
		cptCode = (cptCode ?? "").Trim();
		modifier = (modifier ?? "").Trim();
		units = (units ?? "").Trim();

		if (string.IsNullOrWhiteSpace(cptCode))
			return string.Empty;

		var modifiers = new List<string>();

		string baseCpt = cptCode;

		if (TryExtractCptCodeAndModifier(cptCode, out var extractedCpt, out var extractedModifier))
		{
			baseCpt = extractedCpt;

			if (!string.IsNullOrWhiteSpace(extractedModifier))
				modifiers.Add(extractedModifier);
		}

		baseCpt = NormalizeCptCode(baseCpt);

		if (!string.IsNullOrWhiteSpace(modifier))
		{
			var splitMods = modifier.Split(new[] { ';', ',' }, StringSplitOptions.RemoveEmptyEntries);

			foreach (var mod in splitMods)
			{
				var clean = NormalizeModifierValue(mod);
				if (!string.IsNullOrWhiteSpace(clean))
					modifiers.Add(clean);
			}
		}

		var finalModifiers = new List<string>();
		var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

		foreach (var mod in modifiers)
		{
			if (seen.Add(mod))
				finalModifiers.Add(mod);
		}

		string finalUnits = NormalizeUnits(units);

		string modPart = finalModifiers.Count > 0
			? $"({string.Join(",", finalModifiers)})"
			: "";

		if (!string.IsNullOrWhiteSpace(finalUnits))
			return $"{baseCpt}*{finalUnits}{modPart}";

		return $"{baseCpt}{modPart}";
	}

	private static bool TryExtractCptCodeAndModifier(string value, out string cptCode, out string modifier)
	{
		cptCode = "";
		modifier = "";

		value = (value ?? "").Trim();

		if (string.IsNullOrWhiteSpace(value))
			return false;

		var match = Regex.Match(
			value.ToUpperInvariant(),
			@"(?<![A-Z0-9])(?<code>(?:[A-Z]\d{4}|\d{5}|\d{4}[A-Z]))(?:\s*-\s*(?<modifier>[A-Z0-9]{1,2}))?(?![A-Z0-9])",
			RegexOptions.CultureInvariant);

		if (match.Success)
		{
			cptCode = match.Groups["code"].Value.Trim();
			modifier = NormalizeModifierValue(match.Groups["modifier"].Value);
			return true;
		}

		var decimalMatch = Regex.Match(
			value,
			@"(?<!\d)(?<code>\d{5})\.0+\b",
			RegexOptions.CultureInvariant);

		if (decimalMatch.Success)
		{
			cptCode = decimalMatch.Groups["code"].Value.Trim();
			return true;
		}

		var leadingTokenMatch = Regex.Match(
			value.ToUpperInvariant(),
			@"^\s*(?<code>[A-Z0-9]{4,})(?:\s*-\s*|\s+)",
			RegexOptions.CultureInvariant);

		if (leadingTokenMatch.Success)
		{
			var token = leadingTokenMatch.Groups["code"].Value.Trim();
			cptCode = token.Length > 5 ? token.Substring(0, 5) : token;
			return true;
		}

		return false;
	}

	private static string NormalizeCptCode(string value)
	{
		value = (value ?? "").Trim();

		if (string.IsNullOrWhiteSpace(value))
			return "";

		// remove decimal only when numeric-like, e.g. 80307.00 -> 80307
		if (decimal.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var d))
		{
			if (d == Math.Truncate(d))
				return Convert.ToInt64(d).ToString(CultureInfo.InvariantCulture);

			return d.ToString("0.##", CultureInfo.InvariantCulture);
		}

		if (TryExtractCptCodeAndModifier(value, out var extractedCpt, out _))
			return extractedCpt;

		return value;
	}

	private static string NormalizeModifierValue(string value)
	{
		value = (value ?? "").Trim();

		if (string.IsNullOrWhiteSpace(value))
			return "";

		value = value.Trim(';', ',', ' ', '\t', '(', ')').Trim();

		if (string.IsNullOrWhiteSpace(value))
			return "";

		if (decimal.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var d))
		{
			if (d == Math.Truncate(d))
			{
				var whole = Convert.ToInt64(d).ToString(CultureInfo.InvariantCulture);
				return whole.Length <= 2 ? whole : "";
			}

			return "";
		}

		foreach (Match match in Regex.Matches(value.ToUpperInvariant(), @"\b[A-Z0-9]{1,2}\b", RegexOptions.CultureInvariant))
		{
			var token = match.Value.Trim();
			if (token.Any(char.IsLetterOrDigit))
				return token;
		}

		return "";
	}

	private static string NormalizeUnits(string value)
	{
		value = (value ?? "").Trim();

		if (string.IsNullOrWhiteSpace(value))
			return "";

		if (decimal.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var d))
		{
			if (d == Math.Truncate(d))
				return Convert.ToInt64(d).ToString(CultureInfo.InvariantCulture);

			return d.ToString("0.##", CultureInfo.InvariantCulture);
		}

		return value;
	}

	private static int FindHeaderIndex(List<string> headers, params string[] names)
	{
		for (int i = 0; i < headers.Count; i++)
		{
			var header = headers[i]?.Trim().Replace(" ", "").ToLower();

			foreach (var name in names)
			{
				var normalized = name.Trim().Replace(" ", "").ToLower();

				if (header == normalized)
					return i;
			}
		}
		return -1;
	}

	private static string GetField(string[] row, int index)
	{
		if (index < 0 || index >= row.Length)
			return string.Empty;

		return (row[index] ?? "").Trim();
	}

	public static ExportAugmentationContext BuildAugmentationContext(
	string labName,
	bool isLineLevel,
	string? panelMasterFilePath)
	{
		var isAugustus = !string.IsNullOrWhiteSpace(labName) &&
						 labName.Contains("Augustus", StringComparison.OrdinalIgnoreCase);

		var isNorthWest = !string.IsNullOrWhiteSpace(labName) &&
						  labName.Contains("NorthWest", StringComparison.OrdinalIgnoreCase);

		var ctx = new ExportAugmentationContext
		{
			IsAugustus = isAugustus,
			IsNorthWest = isNorthWest,
			IncludeEncounterPlusPaymentPostedDate = isAugustus && isLineLevel
		};

		if (!isAugustus && !isNorthWest)
			return ctx;
		if (isNorthWest)
			return ctx;

		if (string.IsNullOrWhiteSpace(panelMasterFilePath) || !File.Exists(panelMasterFilePath))
			return ctx;

		using var wb = new XLWorkbook(panelMasterFilePath);
		var ws = wb.Worksheets.FirstOrDefault();
		if (ws == null)
			return ctx;

		var used = ws.RangeUsed();
		if (used == null)
			return ctx;

		var headerRow = used.FirstRow();
		var headers = headerRow.Cells()
			.Select((c, i) => new { Name = c.GetString()?.Trim() ?? "", Index = i + 1 })
			.ToDictionary(x => x.Name, x => x.Index, StringComparer.OrdinalIgnoreCase);

		if (!headers.TryGetValue("Panel Name", out var panelNameCol))
			return ctx;

		headers.TryGetValue("Panel Type", out var panelTypeCol);

		foreach (var row in used.RowsUsed().Skip(1))
		{
			var panelName = row.Cell(panelNameCol).GetString()?.Trim() ?? "";
			if (string.IsNullOrWhiteSpace(panelName))
				continue;

			// PanelNew is NOT built here any more - Augustus sends it in the source file's
			// "Panel Category" column and ResolvePanelNew reads it from there. The workbook read
			// stays because PanelTypeMapping below is built from the same sheet.

			if (isNorthWest && panelTypeCol > 0)
			{
				var panelType = row.Cell(panelTypeCol).GetString()?.Trim() ?? "";
				AddPanelMapping(ctx.PanelTypeMapping, panelName, panelType);
			}
		}

		return ctx;
	}

	private static string GetSourceValue(
	string[] row,
	Dictionary<string, int> headerExact,
	Dictionary<string, int> headerNorm,
	string sourceColumnName)
	{
		if (headerExact.TryGetValue(sourceColumnName, out var idx))
			return Get(row, idx);

		var norm = NormKey(sourceColumnName);
		if (!string.IsNullOrWhiteSpace(norm) && headerNorm.TryGetValue(norm, out idx))
			return Get(row, idx);

		return string.Empty;
	}

	private static string BuildEncounterPlusPaymentPostedDate(
		string[] row,
		Dictionary<string, int> headerExact,
		Dictionary<string, int> headerNorm)
	{
		var enc = GetSourceValue(row, headerExact, headerNorm, "Enc")?.Trim() ?? "";
		var postedRaw = GetSourceValue(row, headerExact, headerNorm, "Posted Date");

		if (string.IsNullOrWhiteSpace(enc))
			return "";

		if (DateTime.TryParse(postedRaw, out var postedDate))
			return enc + postedDate.ToString("MMddyyyy");

		return enc;
	}

	/// <summary>
	/// Source column names that carry PanelNew for Augustus, in preference order.
	/// </summary>
	private static readonly string[] AugustusPanelNewSourceColumns =
	{
		"Panel Category",
		"PanelCategory",
		"Panel_Category"
	};

	/// <summary>
	/// PanelNew for Augustus, taken straight from the source file's "Panel Category" column.
	/// </summary>
	/// <remarks>
	/// This used to be looked up in the panel master workbook, keyed on the row's panel name. The lab
	/// now sends the value itself, so the file is no longer consulted for PanelNew - a lookup can only
	/// disagree with the data it is describing, and the source column cannot.
	///
	/// Applies to both levels: line and claim level share this exporter, so both pick the value up.
	/// </remarks>
	private static string ResolvePanelNew(
		string[] row,
		Dictionary<string, int> headerExact,
		Dictionary<string, int> headerNorm,
		ExportAugmentationContext? augmentation)
	{
		if (augmentation == null || !augmentation.IsAugustus)
			return "";

		foreach (var candidate in AugustusPanelNewSourceColumns)
		{
			var value = GetSourceValue(row, headerExact, headerNorm, candidate)?.Trim() ?? "";
			if (!string.IsNullOrWhiteSpace(value))
				return value;
		}

		return "";
	}

	private static string ResolvePanelType(
	string[] row,
	Dictionary<string, int> headerExact,
	Dictionary<string, int> headerNorm,
	ExportAugmentationContext? augmentation)
	{
		if (augmentation == null || !augmentation.IsNorthWest || augmentation.PanelTypeMapping.Count == 0)
			return "";

		var panelName = GetPanelNameFromSource(row, headerExact, headerNorm);
		if (string.IsNullOrWhiteSpace(panelName))
			return "";

		return ResolvePanelMapping(augmentation.PanelTypeMapping, panelName);
	}

	private static string GetPanelNameFromSource(
		string[] row,
		Dictionary<string, int> headerExact,
		Dictionary<string, int> headerNorm)
	{
		var candidates = new[]
		{
			"Panel Name",
			"Panelname",
			"PanelName",
			"Panel Group",
			"Panel"
		};

		foreach (var candidate in candidates)
		{
			var value = GetSourceValue(row, headerExact, headerNorm, candidate)?.Trim() ?? "";
			if (!string.IsNullOrWhiteSpace(value))
				return value;
		}

		return "";
	}

	private static void AddPanelMapping(Dictionary<string, string> map, string panelName, string mappedValue)
	{
		if (string.IsNullOrWhiteSpace(panelName))
			return;

		var key = panelName.Trim();
		if (!map.ContainsKey(key))
			map[key] = mappedValue ?? "";

		var normalizedKey = NormKey(key);
		if (!string.IsNullOrWhiteSpace(normalizedKey) && !map.ContainsKey(normalizedKey))
			map[normalizedKey] = mappedValue ?? "";
	}

	private static string ResolvePanelMapping(Dictionary<string, string> map, string panelName)
	{
		if (map.Count == 0 || string.IsNullOrWhiteSpace(panelName))
			return "";

		var key = panelName.Trim();
		if (map.TryGetValue(key, out var exact))
			return exact ?? "";

		var normalizedKey = NormKey(key);
		if (!string.IsNullOrWhiteSpace(normalizedKey) && map.TryGetValue(normalizedKey, out var normalized))
			return normalized ?? "";

		// Last fallback for real-world master file differences like extra words/spaces.
		foreach (var kvp in map)
		{
			var mapKey = NormKey(kvp.Key);
			if (string.IsNullOrWhiteSpace(mapKey))
				continue;

			if (normalizedKey.Contains(mapKey, StringComparison.OrdinalIgnoreCase) ||
				mapKey.Contains(normalizedKey, StringComparison.OrdinalIgnoreCase))
			{
				return kvp.Value ?? "";
			}
		}

		return "";
	}
}

public sealed class ExportAugmentationContext
{
	public bool IsAugustus { get; set; }
	public bool IsNorthWest { get; set; }

	public bool IncludeEncounterPlusPaymentPostedDate { get; set; }

	public Dictionary<string, string> PanelNewMapping { get; set; }
		= new(StringComparer.OrdinalIgnoreCase);

	public Dictionary<string, string> PanelTypeMapping { get; set; }
		= new(StringComparer.OrdinalIgnoreCase);
}
