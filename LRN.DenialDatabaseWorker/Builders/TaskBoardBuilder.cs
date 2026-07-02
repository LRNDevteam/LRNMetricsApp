using DenialDatabaseProcessorWorker.Normalizers;
using static DenialDatabaseProcessorWorker.Services.DenialTaskBoardRepository;

namespace DenialDatabaseProcessorWorker.Builders;

public sealed class TaskBoardBuilder
{
	private readonly int _labId;
	private readonly string _labName;
	private readonly string _runId;
	private readonly Dictionary<string, ExistingTaskInfo> _existingTasks;

	public TaskBoardBuilder(int labId, string labName, string runId, Dictionary<string, ExistingTaskInfo> existingTasks)
	{
		_labId = labId;
		_labName = labName;
		_runId = runId;
		_existingTasks = existingTasks ?? new();
	}

	public List<Dictionary<string, string>> Build(List<Dictionary<string, string>> lineRows)
	{
		var result = new List<Dictionary<string, string>>();
		var today = DateTime.Today;
		int newTaskCounter = 1;

		foreach (var line in lineRows)
		{
			var denialCodeNorm = line.GetValueOrDefault("DenialCode_Normalized") ?? "";
			if (string.IsNullOrWhiteSpace(denialCodeNorm))
				continue;

			var visitNumber = line.GetValueOrDefault("Visit Number") ?? "";
			var accessionNo = GetFirstValue(line, "Accession No", "AccessionNo");
			var dateOfService = GetFirstValue(line, "Date of Service", "DateOfService", "DOS");
			var claimUid = BuildClaimUid(visitNumber, accessionNo, dateOfService);
			var cptCode = line.GetValueOrDefault("CPTCode") ?? "";

			var rawDesc = line.GetValueOrDefault("Denial Description") ?? "";
			var rawClass = line.GetValueOrDefault("Denial Classification") ?? "";
			var rawActionCode = line.GetValueOrDefault("Action Code") ?? "";
			var rawRecAction = line.GetValueOrDefault("Recommended Action") ?? "";
			var rawTask = line.GetValueOrDefault("Task Guidance") ?? "";
			var rawActionCategory = line.GetValueOrDefault("Action Category") ?? "";
			var rawPriority = line.GetValueOrDefault("Priority") ?? "";
			var rawSla = line.GetValueOrDefault("SLA (Days)") ?? "";

			// Insurance Balance
			var rawInsBalance = line.GetValueOrDefault("Insurance Balance");
			decimal insBalanceVal = 0;
			if (!string.IsNullOrWhiteSpace(rawInsBalance))
				decimal.TryParse(rawInsBalance, out insBalanceVal);

			var insuranceBalance = insBalanceVal.ToString("0.##");

			int slaDays = int.TryParse(StripPrefix(rawSla), out var s) ? s : 0;

			var denialCodes = denialCodeNorm
				.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)
				.Select(x => x.Trim())
				.ToList();

			var taskSegments = ParseTaskSegments(rawTask, denialCodes);

			for (int i = 0; i < taskSegments.Count; i++)
			{
				var seg = taskSegments[i];
				var denialCode = seg.DenialCode;

				// Key = ClaimUID + CPT + DenialCode
				var key = BuildTaskKey(claimUid, cptCode, denialCode);
				if (string.IsNullOrWhiteSpace(key))
					continue;

				// Try to get existing task
				_existingTasks.TryGetValue(key, out var existing);

				string taskId;
				DateTime dateOpened;

				if (existing != null)
				{
					taskId = existing.TaskId;
					dateOpened = existing.DateOpened ?? today;
				}
				else
				{
					taskId = $"TSK-{newTaskCounter:D5}";
					newTaskCounter++;
					dateOpened = today;
				}

				var dueDate = slaDays > 0 ? dateOpened.AddDays(slaDays) : (DateTime?)null;

				string desc = GetAlignedValue(rawDesc, i, denialCodes);
				string cls = GetAlignedValue(rawClass, i, denialCodes);
				string actCode = GetAlignedValue(rawActionCode, i, denialCodes);
				string recAct = GetAlignedValue(rawRecAction, i, denialCodes);
				string taskText = GetAlignedValue(seg.TaskText, i, denialCodes);
				string actCategory = GetAlignedValue(rawActionCategory, i, denialCodes);
				string priority = GetAlignedValue(rawPriority, i, denialCodes);
				// ------------------------------
				// New fields from DenialLineItem
				// IMPORTANT: Source column names are from DenialLineItem mapping
				// ------------------------------

				var icdCodes = GetFirstValue(
					line,
					"CoveredICD10CodesBilled",
					"ICDCodes",
					"ICD Codes"
				);

				var coverageStatus = GetFirstValue(
					line,
					"CoverageStatus",
					"Coverage Status"
				);

				var icdComplianceStatus = GetFirstValue(
					line,
					"ICDComplianceStatus",
					"ICD Compliance Status"
				);

				var denialValidity = GetDenialValidityForCode(
					GetFirstValue(line, "DenialValidity", "Denial Validity"),
					denialCode,
					denialCodes,
					i
				);

				var units = GetFirstValue(
									line,
									"Units",
									"Unit",
									"unit",
									"units",
									"NoOfUnits",
									"No Of Units",
									"No. Of Units",
									"Quantity",
									"Qty",
									"BilledUnits",
									"Billed Units"
								);

				var modifier = GetFirstValue(
					line,
					"Modifier",
					"modifier",
					"Modifiers",
					"modifiers",
					"Mod",
					"MOD",
					"CPTModifier",
					"CPT Modifier",
					"CPT Mod",
					"ProcedureModifier",
					"Procedure Modifier"
				);


				// Normalize task text
				taskText = TaskGuidanceNormalizer.Normalize(taskText, denialCode);

				// Fallback: if still empty, use Recommended Action
				if (string.IsNullOrWhiteSpace(taskText) && !string.IsNullOrWhiteSpace(recAct))
					taskText = recAct;

				// ------------------------------
				// STATUS + DATE COMPLETED LOGIC
				// ------------------------------

				string status = "New";
				DateTime? dateCompleted = null;
				string assignedTo = "";
				string workflowStatus = "";

				// 1. Preserve existing Closed/Review tasks
				if (existing != null)
				{
					assignedTo = existing.Row.GetValueOrDefault("Assigned To")?.Trim() ?? "";
					workflowStatus = existing.Row.GetValueOrDefault("WorkFlowStatus")?.Trim() ?? "";

					if (existing.Row.TryGetValue("Status", out var oldStatusRaw))
					{
						var oldStatus = CleanStatus(oldStatusRaw);

						if (!string.IsNullOrWhiteSpace(assignedTo))
						{
							status = oldStatus.Equals("Closed", StringComparison.OrdinalIgnoreCase)
								? oldStatus
								: "Review";
						}
						else if (!string.IsNullOrWhiteSpace(oldStatus) &&
							(oldStatus.Equals("Closed", StringComparison.OrdinalIgnoreCase) ||
							 oldStatus.Equals("Review", StringComparison.OrdinalIgnoreCase)))
						{
							status = oldStatus;
						}

						if (status.Equals("Closed", StringComparison.OrdinalIgnoreCase) &&
							existing.Row.TryGetValue("Date Completed", out var oldCompleted) &&
							DateTime.TryParse(oldCompleted, out var parsed))
						{
							dateCompleted = parsed;
						}
					}
				}

				// ------------------------------
				// SLA STATUS LOGIC
				// ------------------------------

				int daysRemaining = dueDate.HasValue ? (dueDate.Value - today).Days : 0;

				string slaStatus = "";

				if (dateCompleted.HasValue && dueDate.HasValue && dateCompleted.Value <= dueDate.Value)
					slaStatus = "Met";
				else if ((status == "Open" || status == "New") && !dateCompleted.HasValue && dueDate.HasValue && today > dueDate.Value)
					slaStatus = "Overdue";
				else if ((status == "Open" || status == "New") && !dateCompleted.HasValue && dueDate.HasValue && daysRemaining <= 3)
					slaStatus = "Due Soon";
				else if ((status == "Open" || status == "New") && !dateCompleted.HasValue && dueDate.HasValue && daysRemaining > 3)
					slaStatus = "On Track";

				// ------------------------------
				// BUILD ROW
				// ------------------------------

				var row = new Dictionary<string, string>
				{
					["Task ID"] = taskId,
					["Claim ID"] = visitNumber,
					["ClaimUID"] = claimUid,
					["Patient / Acct #"] = line.GetValueOrDefault("PatientID") ?? "",
					["CPT Code"] = cptCode,
					["Denial Code"] = denialCode,
					["Denial Description"] = desc,
					["Denial Classification"] = cls,
					["Action Code"] = actCode,
					["Recommended Action"] = recAct,
					["Task"] = taskText,
					["Action Category"] = actCategory,
					["Priority"] = priority,
					["SLA (Days)"] = slaDays > 0 ? slaDays.ToString() : "",
					["Status"] = status,
					["WorkFlowStatus"] = string.IsNullOrWhiteSpace(workflowStatus) ? status : workflowStatus,
					["ClaimFrom"] = "Current Run",
					["Insurance Balance"] = insuranceBalance,
					["IsCurrentDenial"] = "true",
					["Assigned To"] = assignedTo,
					["Date Opened"] = dateOpened.ToString("yyyy-MM-dd"),
					["Due Date"] = dueDate?.ToString("yyyy-MM-dd") ?? "",
					["Date Completed"] = dateCompleted?.ToString("yyyy-MM-dd") ?? "",
					["Days Remaining"] = dueDate.HasValue ? daysRemaining.ToString() : "",
					["SLA Status"] = slaStatus,
					["LabId"] = _labId.ToString(),
					["LabName"] = _labName,
					["RunId"] = _runId,
					["CreatedOn"] = DateTime.UtcNow.ToString("O"),
					["UniqueTrackId"] = key,

					// Additional fields from Denial Line Item
					["SalesRepname"] = line.GetValueOrDefault("SalesRepname") ?? "",
					["ClinicName"] = line.GetValueOrDefault("ClinicName") ?? "",
					["ReferringProvider"] = line.GetValueOrDefault("ReferringProvider") ?? "",
					["Source"] = GetFirstValue(line, "Source"),
					["Pat name"] = GetFirstValue(line, "Pat name", "PatName", "Patient Name", "PatientName"),
					["Subscriber Id"] = GetFirstValue(line, "Subscriber Id", "SubscriberId", "Subscriber ID", "SubscriberID"),
					["PayerName Normalized"] = line.GetValueOrDefault("PayerName Normalized") ?? "",
					["Payer Name"] = line.GetValueOrDefault("Payer Name") ?? "",
					["Payer Code"] = line.GetValueOrDefault("Payer Code") ?? "",
					["Payer Type"] = line.GetValueOrDefault("Payer Type") ?? "",
					["First Billed Date"] = line.GetValueOrDefault("First Billed Date") ?? "",
					["ChargeEnteredDate"] = line.GetValueOrDefault("ChargeEnteredDate") ?? "",
					["BillingProvider"] = line.GetValueOrDefault("BillingProvider") ?? "",
					["Panel Name"] = line.GetValueOrDefault("Panel Name") ?? "",
					["Date of Service"] = line.GetValueOrDefault("Date of Service") ?? "",
					["ICDCodes"] = icdCodes,
					["CoverageStatus"] = coverageStatus,
					["ICDComplianceStatus"] = icdComplianceStatus,
					["DenialValidity"] = denialValidity,
					["Units"] = NormalizeUnits(units),
					["Modifier"] = modifier
				};

				result.Add(row);
			}
		}

		return result;
	}

	// ------------------------------
	// HELPERS
	// ------------------------------
	private static string NormalizeUnits(string? value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return "";

		var text = value.Trim();

		if (decimal.TryParse(text, out var decimalValue))
			return Convert.ToInt32(decimalValue).ToString();

		if (int.TryParse(text, out var intValue))
			return intValue.ToString();

		return text;
	}
	private static string GetFirstValue(Dictionary<string, string> row, params string[] keys)
	{
		if (row == null || keys == null || keys.Length == 0)
			return "";

		foreach (var key in keys)
		{
			if (string.IsNullOrWhiteSpace(key))
				continue;

			if (row.TryGetValue(key, out var exactValue) && !string.IsNullOrWhiteSpace(exactValue))
				return exactValue.Trim();

			var normalizedKey = NormalizeColumnKey(key);

			foreach (var kvp in row)
			{
				if (NormalizeColumnKey(kvp.Key).Equals(normalizedKey, StringComparison.OrdinalIgnoreCase) &&
					!string.IsNullOrWhiteSpace(kvp.Value))
				{
					return kvp.Value.Trim();
				}
			}
		}

		return "";
	}

	private static string NormalizeColumnKey(string? key)
	{
		if (string.IsNullOrWhiteSpace(key))
			return "";

		return key
			.Replace(" ", "")
			.Replace("_", "")
			.Replace("-", "")
			.Replace("/", "")
			.Replace(".", "")
			.Replace("#", "")
			.Trim();
	}

	private static string GetDenialValidityForCode(
		string? raw,
		string denialCode,
		List<string> denialCodes,
		int index)
	{
		if (string.IsNullOrWhiteSpace(raw) || string.IsNullOrWhiteSpace(denialCode))
			return "";

		var map = ParseDenialValidityMap(raw, denialCodes);

		if (map.TryGetValue(denialCode, out var mapped))
			return StripPrefix(mapped);

		return GetAlignedValue(raw, index, denialCodes);
	}

	private static Dictionary<string, string> ParseDenialValidityMap(string raw, List<string> denialCodes)
	{
		var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

		if (string.IsNullOrWhiteSpace(raw))
			return map;

		var parts = raw.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);

		foreach (var part in parts)
		{
			var item = part.Trim();

			if (string.IsNullOrWhiteSpace(item))
				continue;

			var colonIndex = item.IndexOf(':');

			if (colonIndex > 0)
			{
				var code = item[..colonIndex].Trim();
				var text = item[(colonIndex + 1)..].Trim();

				map[code] = string.IsNullOrWhiteSpace(text) ? "N/A" : StripPrefix(text);
			}
			else
			{
				var code = item.Trim();

				if (IsKnownDenialCode(code, denialCodes))
				{
					map[code] = "N/A";
				}
			}
		}

		return map;
	}

	private static bool IsKnownDenialCode(string value, List<string> denialCodes)
	{
		if (string.IsNullOrWhiteSpace(value))
			return false;

		var clean = value.Trim();

		return denialCodes.Any(x =>
			x.Equals(clean, StringComparison.OrdinalIgnoreCase));
	}

	private static string GetByAnyKey(Dictionary<string, string> row, params string[] keys)
	{
		foreach (var key in keys)
		{
			if (row.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
				return value.Trim();
		}

		foreach (var key in keys)
		{
			var normalizedKey = NormalizeHeader(key);
			var actualKey = row.Keys.FirstOrDefault(k => NormalizeHeader(k) == normalizedKey);
			if (actualKey != null && row.TryGetValue(actualKey, out var value) && !string.IsNullOrWhiteSpace(value))
				return value.Trim();
		}

		return "";
	}

	private static string BuildClaimUid(string? visitNumber, string? accessionNo, string? dateOfService)
	{
		var visit = NormalizeClaimUidPart(visitNumber);
		var accession = NormalizeClaimUidPart(accessionNo);
		var dos = NormalizeDateOfServiceForClaimUid(dateOfService);

		if (string.IsNullOrWhiteSpace(visit) &&
			string.IsNullOrWhiteSpace(accession) &&
			string.IsNullOrWhiteSpace(dos))
		{
			return "";
		}

		return $"{visit}_{accession}_{dos}";
	}

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

	private static string NormalizeClaimUidPart(string? value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return "";

		var text = value.Trim();

		if (text.EndsWith(".00", StringComparison.OrdinalIgnoreCase))
			text = text[..^3];

		return text;
	}

	private static string NormalizeDateOfServiceForClaimUid(string? value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return "";

		var text = value.Trim();

		return DateTime.TryParse(text, out var parsed)
			? parsed.ToString("yyyyMMdd")
			: text;
	}

	private static string CleanStatus(string? value)
	{
		return value?.Trim()
			.Replace("\u00A0", "")
			.Replace("\u200B", "")
			.Replace("\r", "")
			.Replace("\n", "")
			.Trim() ?? "";
	}

	private static string NormalizeHeader(string? value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return "";

		return new string(value.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());
	}

	private static string GetAlignedValue(string raw, int index, List<string> denialCodes)
	{
		if (string.IsNullOrWhiteSpace(raw))
			return "";

		var parts = raw.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
		var stripped = parts.Select(StripPrefix).ToList();

		var nonCodeValues = stripped
			.Where(v => !denialCodes.Contains(v, StringComparer.OrdinalIgnoreCase))
			.ToList();

		if (nonCodeValues.Count == 1 &&
			stripped.All(v =>
				v.Equals(nonCodeValues[0], StringComparison.OrdinalIgnoreCase) ||
				denialCodes.Contains(v, StringComparer.OrdinalIgnoreCase)))
		{
			return nonCodeValues[0];
		}

		var codeToValue = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
		string? commonText = null;

		for (int i = 0; i < parts.Length; i++)
		{
			var original = parts[i];
			var value = StripPrefix(original);

			foreach (var code in denialCodes)
			{
				var prefix = code + ":";
				if (original.TrimStart().StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
					codeToValue[code] = value;
			}

			if (!denialCodes.Contains(value, StringComparer.OrdinalIgnoreCase) &&
				string.IsNullOrWhiteSpace(commonText))
			{
				commonText = value;
			}
		}

		var currentCode = denialCodes[index];
		if (codeToValue.TryGetValue(currentCode, out var mapped))
			return mapped;

		if (!string.IsNullOrWhiteSpace(commonText))
			return commonText;

		if (parts.Length == denialCodes.Count)
			return stripped[index];

		return stripped[0];
	}

	private static string StripPrefix(string? value)
	{
		if (string.IsNullOrWhiteSpace(value)) return "";
		var idx = value.IndexOf(':');
		return idx > 0 ? value[(idx + 1)..].Trim() : value.Trim();
	}

	private static string GetValueForDenialCode(string? raw, string denialCode, List<string> denialCodes, int index)
	{
		if (string.IsNullOrWhiteSpace(raw))
			return "";

		var text = raw.Trim();

		// Best case: DenialValidity is stored like "CO16: Valid, CO197: Invalid".
		// Split by denial-code markers, not only comma, because the validity text itself may contain commas.
		var markers = denialCodes
			.Where(c => !string.IsNullOrWhiteSpace(c))
			.Select(c => new { Code = c, Index = text.IndexOf(c + ":", StringComparison.OrdinalIgnoreCase) })
			.Where(x => x.Index >= 0)
			.OrderBy(x => x.Index)
			.ToList();

		if (markers.Count > 0)
		{
			for (int i = 0; i < markers.Count; i++)
			{
				var current = markers[i];
				var valueStart = current.Index + current.Code.Length + 1;
				var valueEnd = i + 1 < markers.Count ? markers[i + 1].Index : text.Length;
				var value = text[valueStart..valueEnd].Trim().Trim(',', ';', '|').Trim();

				if (current.Code.Equals(denialCode, StringComparison.OrdinalIgnoreCase))
					return value;
			}
		}

		// Fallback for simple comma/semicolon aligned values.
		return GetAlignedValue(text, index, denialCodes);
	}

	private static DateTime? TryParseDate(string? v)
		=> DateTime.TryParse(v, out var dt) ? dt : null;

	private sealed class TaskSegment
	{
		public TaskSegment(string denialCode, string taskText)
		{
			DenialCode = denialCode;
			TaskText = taskText;
		}

		public string DenialCode { get; }
		public string TaskText { get; }
	}

	private static List<TaskSegment> ParseTaskSegments(string taskGuidance, List<string> denialCodes)
	{
		var segments = new List<TaskSegment>();

		if (!string.IsNullOrWhiteSpace(taskGuidance))
		{
			var parts = taskGuidance.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
			if (parts.Length == denialCodes.Count)
			{
				for (int i = 0; i < denialCodes.Count; i++)
					segments.Add(new TaskSegment(denialCodes[i], parts[i]));
				return segments;
			}
		}

		foreach (var code in denialCodes)
			segments.Add(new TaskSegment(code, taskGuidance));

		return segments;
	}
}
