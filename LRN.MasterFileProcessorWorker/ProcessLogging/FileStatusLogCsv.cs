// Updated to match client-required SINGLE daily filestatus CSV format.
// Key fixes (Feb 2026):
//  1) Can write BOTH "Claim Level" and "Line Level" rows into the same daily CSV even if caller logs only once.
//     - If caller does NOT specify fileType, we infer it and (optionally) also write the other scope.
//  2) For ERROR/FAIL statuses, Output location is forced to EMPTY (client only wants Source file path).
//  3) Adds optional Source File Location parameter so caller can pass SharePoint path (recommended).
//
// File path (local):
//   {folder}\{Month}\fileStatus.{ddMMyyyy}.csv
//
// SharePoint target folder (helper):
//   Data Analysis/ImportLogs/{Month}

using System;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

public static class FileStatusLogCsv
{
	// Matches the sample header exactly (including spaces/typos).
	// DO NOT "fix" the typos/spaces - client expects this exact shape.
	private const string Header =
		"Lab Id ,labname ,importede date,imported time,FileType,Source File Name,Source File Location,Status ,Output location,Log";

	// SharePoint root folder required by client (relative to drive root)
	public const string SharePointImportLogsRoot = "Data Analysis/ImportLogs";

	public static string GetMonthFolderName(DateTime importedLocal)
		=> importedLocal.ToString("MMMM", CultureInfo.InvariantCulture);

	public static string GetDailyFileName(DateTime importedLocal)
		=> $"fileStatus.{importedLocal:ddMMyyyy}.csv";

	/// <summary>
	/// Returns: "Data Analysis/ImportLogs/{Month}"
	/// </summary>
	public static string GetSharePointFolderPath(DateTime importedLocal)
		=> $"{SharePointImportLogsRoot}/{GetMonthFolderName(importedLocal)}";

	/// <summary>
	/// Append ONE row to the daily fileStatus CSV.
	/// Creates the file + header if missing.
	///
	/// IMPORTANT:
	/// - If fileType is not provided, we infer it from outputLocation/fileName/sourceFileLocation.
	/// - If fileType is not provided AND writeBothScopesWhenUnknown is true:
	///     - When we detect a ClaimLevel output, we ALSO write a LineLevel row (inferred path)
	///     - When we detect a LineLevel output, we ALSO write a ClaimLevel row (inferred path)
	///
	/// OUTPUT LOCATION RULE (client request):
	/// - For Error/Fail statuses, outputLocation is ALWAYS blank.
	///
	/// SOURCE FILE LOCATION:
	/// - Pass selected.SharePointPath here if possible (recommended).
	///   If not provided, it stays blank (same as your current CSV).
	/// </summary>
	public static string Write(
		string folder,
		int labId,
		string labName,
		DateTime importedLocal,
		string fileName,
		string status,
		string outputLocation,
		string logMessage,
		string? sourceFileLocation = null,
		string? fileType = null,
		bool writeBothScopesWhenUnknown = true)
	{
		if (string.IsNullOrWhiteSpace(folder))
			throw new ArgumentException("Folder is required.", nameof(folder));

		// Put under {folder}\{Month}\fileStatus.ddMMyyyy.csv
		var monthFolder = GetMonthFolderName(importedLocal);
		var monthPath = Path.Combine(folder, monthFolder);
		Directory.CreateDirectory(monthPath);

		var csvPath = Path.Combine(monthPath, GetDailyFileName(importedLocal));

		// Normalize statuses to what the client expects ("Completed" / "Error" / "Skipped" / "Warning")
		var normalizedStatus = NormalizeStatus(status);

		// If error/fail => output path must be EMPTY
		var finalOutputLocation = ShouldBlankOutputLocation(normalizedStatus) ? "" : (outputLocation ?? "");

		// Determine file type
		var inferredType = string.IsNullOrWhiteSpace(fileType)
			? InferFileType(fileName, outputLocation, sourceFileLocation)
			: fileType!.Trim();

		// Write primary row
		AppendRow(
			csvPath: csvPath,
			labId: labId,
			labName: labName,
			importedLocal: importedLocal,
			fileType: inferredType,
			sourceFileName: fileName,
			sourceFileLocation: sourceFileLocation ?? "",
			status: normalizedStatus,
			outputLocation: finalOutputLocation,
			logMessage: logMessage);

		// Optionally also write the other scope when caller didn't specify fileType.
		if (writeBothScopesWhenUnknown && string.IsNullOrWhiteSpace(fileType))
		{
			var otherType = GetOtherType(inferredType);
			if (!string.IsNullOrEmpty(otherType))
			{
				// Infer the other scope output path from the provided outputLocation (if it looks like a generated CSV path)
				var otherOut = InferOtherScopeOutputPath(outputLocation, inferredType, otherType);

				// If primary status is Completed but the other output isn't present, mark other as Skipped (so we don't lie).
				var otherStatus = normalizedStatus;
				var otherLog = logMessage;
				var otherFinalOutput = ShouldBlankOutputLocation(otherStatus) ? "" : (otherOut ?? "");

				if (string.Equals(normalizedStatus, "Completed", StringComparison.OrdinalIgnoreCase))
				{
					if (string.IsNullOrWhiteSpace(otherOut) || !File.Exists(otherOut))
					{
						otherStatus = "Skipped";
						otherFinalOutput = "";
						otherLog = "not generated";
					}
				}

				// If error => log both scopes as Error (output location blank)
				if (ShouldBlankOutputLocation(normalizedStatus))
				{
					otherStatus = normalizedStatus;
					otherFinalOutput = "";
					otherLog = logMessage;
				}

				AppendRow(
					csvPath: csvPath,
					labId: labId,
					labName: labName,
					importedLocal: importedLocal,
					fileType: otherType,
					sourceFileName: fileName,
					sourceFileLocation: sourceFileLocation ?? "",
					status: otherStatus,
					outputLocation: otherFinalOutput,
					logMessage: otherLog);
			}
		}

		return csvPath;
	}

	/// <summary>
	/// Convenience: explicitly write Claim Level row.
	/// (No "auto other scope" behaviour.)
	/// </summary>
	public static string WriteClaimLevel(
		string folder,
		int labId,
		string labName,
		DateTime importedLocal,
		string fileName,
		string sourceFileLocation,
		string status,
		string outputLocation,
		string logMessage)
		=> Write(folder, labId, labName, importedLocal, fileName, status, outputLocation, logMessage,
			sourceFileLocation: sourceFileLocation,
			fileType: "Claim Level",
			writeBothScopesWhenUnknown: false);

	/// <summary>
	/// Convenience: explicitly write Line Level row.
	/// (No "auto other scope" behaviour.)
	/// </summary>
	public static string WriteLineLevel(
		string folder,
		int labId,
		string labName,
		DateTime importedLocal,
		string fileName,
		string sourceFileLocation,
		string status,
		string outputLocation,
		string logMessage)
		=> Write(folder, labId, labName, importedLocal, fileName, status, outputLocation, logMessage,
			sourceFileLocation: sourceFileLocation,
			fileType: "Line Level",
			writeBothScopesWhenUnknown: false);

	private static void AppendRow(
		string csvPath,
		int labId,
		string labName,
		DateTime importedLocal,
		string fileType,
		string sourceFileName,
		string sourceFileLocation,
		string status,
		string outputLocation,
		string logMessage)
	{
		var importedDate = importedLocal.ToString("MM/dd/yyyy", CultureInfo.InvariantCulture);
		var importedTime = importedLocal.ToString("HH:mm", CultureInfo.InvariantCulture);

		var row = string.Join(",",
			labId.ToString(CultureInfo.InvariantCulture),
			Escape(labName),
			Escape(importedDate),
			Escape(importedTime),
			Escape(NormalizeTypeLabel(fileType)),
			Escape(sourceFileName),
			Escape(sourceFileLocation),
			Escape(status),
			Escape(outputLocation),
			Escape(logMessage));

		AppendLine(csvPath, row);
	}

	private static string NormalizeTypeLabel(string fileType)
	{
		var t = fileType.Trim();

		// Standardize to exactly "Claim Level" / "Line Level" (space included)
		if (t.Equals("ClaimLevel", StringComparison.OrdinalIgnoreCase) ||
			t.Equals("Claim Level", StringComparison.OrdinalIgnoreCase))
			return "Claim Level";

		if (t.Equals("LineLevel", StringComparison.OrdinalIgnoreCase) ||
			t.Equals("Line Level", StringComparison.OrdinalIgnoreCase))
			return "Line Level";

		return t; // keep as-is for unexpected values
	}

	private static string NormalizeStatus(string status)
	{
		var s = (status ?? "").Trim();

		if (s.Equals("PROCESSED", StringComparison.OrdinalIgnoreCase) ||
			s.Equals("DONE", StringComparison.OrdinalIgnoreCase) ||
			s.Equals("SUCCESS", StringComparison.OrdinalIgnoreCase))
			return "Completed";

		if (s.Equals("FAILED", StringComparison.OrdinalIgnoreCase) ||
			s.Equals("FAIL", StringComparison.OrdinalIgnoreCase) ||
			s.Equals("ERROR", StringComparison.OrdinalIgnoreCase))
			return "Error";

		if (s.Equals("SKIPPED", StringComparison.OrdinalIgnoreCase))
			return "Skipped";

		if (s.Equals("WARNING", StringComparison.OrdinalIgnoreCase) ||
			s.Equals("WARN", StringComparison.OrdinalIgnoreCase))
			return "Warning";

		// If caller already passes "Completed"/"Error"/etc just return it
		return string.IsNullOrWhiteSpace(s) ? "Completed" : s;
	}

	private static bool ShouldBlankOutputLocation(string normalizedStatus)
		=> normalizedStatus.Equals("Error", StringComparison.OrdinalIgnoreCase)
		|| normalizedStatus.IndexOf("fail", StringComparison.OrdinalIgnoreCase) >= 0;

	private static string InferFileType(string fileName, string outputLocation, string? sourceFileLocation)
	{
		var hay = $"{fileName} {outputLocation} {sourceFileLocation}".ToLowerInvariant();

		if (hay.Contains("linelevel") || hay.Contains("_linelevel") || hay.Contains("line level") || hay.Contains(@"\linelevel\") || hay.Contains("/linelevel/"))
			return "Line Level";

		if (hay.Contains("claimlevel") || hay.Contains("_claimlevel") || hay.Contains("claim level") || hay.Contains(@"\claimlevel\") || hay.Contains("/claimlevel/"))
			return "Claim Level";

		// Default (legacy)
		return "Claim Level";
	}

	private static string? GetOtherType(string inferredType)
	{
		var t = NormalizeTypeLabel(inferredType);

		if (t.Equals("Claim Level", StringComparison.OrdinalIgnoreCase))
			return "Line Level";

		if (t.Equals("Line Level", StringComparison.OrdinalIgnoreCase))
			return "Claim Level";

		return null;
	}

	private static string? InferOtherScopeOutputPath(string outputLocation, string inferredType, string otherType)
	{
		if (string.IsNullOrWhiteSpace(outputLocation))
			return null;

		// Only try inference when outputLocation looks like a local CSV file path.
		if (!outputLocation.EndsWith(".csv", StringComparison.OrdinalIgnoreCase))
			return null;

		var normInferred = NormalizeTypeLabel(inferredType);
		var normOther = NormalizeTypeLabel(otherType);

		try
		{
			var other = outputLocation;

			if (normInferred.Equals("Claim Level", StringComparison.OrdinalIgnoreCase) &&
				normOther.Equals("Line Level", StringComparison.OrdinalIgnoreCase))
			{
				other = other.Replace(@"\ClaimLevel\", @"\LineLevel\", StringComparison.OrdinalIgnoreCase)
							 .Replace("/ClaimLevel/", "/LineLevel/", StringComparison.OrdinalIgnoreCase)
							 .Replace("_ClaimLevel.csv", "_LineLevel.csv", StringComparison.OrdinalIgnoreCase);
				return other;
			}

			if (normInferred.Equals("Line Level", StringComparison.OrdinalIgnoreCase) &&
				normOther.Equals("Claim Level", StringComparison.OrdinalIgnoreCase))
			{
				other = other.Replace(@"\LineLevel\", @"\ClaimLevel\", StringComparison.OrdinalIgnoreCase)
							 .Replace("/LineLevel/", "/ClaimLevel/", StringComparison.OrdinalIgnoreCase)
							 .Replace("_LineLevel.csv", "_ClaimLevel.csv", StringComparison.OrdinalIgnoreCase);
				return other;
			}
		}
		catch
		{
			// ignore inference failures
		}

		return null;
	}

	private static void AppendLine(string path, string line)
	{
		// Lightweight retry to survive transient "file in use" scenarios.
		for (var attempt = 1; attempt <= 3; attempt++)
		{
			try
			{
				if (!File.Exists(path) || new FileInfo(path).Length == 0)
				{
					// Create new file with BOM + header + row
					using var sw = new StreamWriter(path, append: false, encoding: new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
					sw.WriteLine(Header);
					sw.WriteLine(line);
					return;
				}

				// Append (no BOM). Ensure newline exists.
				using var fs = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read);
				if (fs.Length > 0)
				{
					fs.Seek(-1, SeekOrigin.End);
					var last = fs.ReadByte();
					if (last != '\n')
					{
						fs.Seek(0, SeekOrigin.End);
						var nl = Encoding.UTF8.GetBytes(Environment.NewLine);
						fs.Write(nl, 0, nl.Length);
					}
				}

				fs.Seek(0, SeekOrigin.End);
				using var swAppend = new StreamWriter(fs, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
				swAppend.WriteLine(line);
				swAppend.Flush();
				return;
			}
			catch (IOException) when (attempt < 3)
			{
				Thread.Sleep(150 * attempt);
			}
		}

		// Final fallback (let exception bubble if it fails)
		using var swFinal = new StreamWriter(path, append: true, encoding: new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
		swFinal.WriteLine(line);
	}

	private static string Escape(string? s)
	{
		if (string.IsNullOrEmpty(s)) return "";
		bool mustQuote = s.Contains(',') || s.Contains('"') || s.Contains('\n') || s.Contains('\r');
		if (!mustQuote) return s;
		return $"\"{s.Replace("\"", "\"\"")}\"";
	}
}
