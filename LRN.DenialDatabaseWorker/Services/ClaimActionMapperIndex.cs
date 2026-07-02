namespace DenialDatabaseProcessorWorker.Services;

public sealed class ClaimActionMapperIndex
{
	public sealed record MapperRow(
		string DenialCode,
		string DenialDescription,
		string DenialClassification,
		string CoverageStatus,
		string IcdComplianceStatus,
		string DenialValidity,
		string ActionCode,
		string RecommendedAction,
		string ActionCategory,
		string Task,
		string ShortCategory,
		string Priority,
		string SlaDays,
		string NotesComments
	);

	// _map[DenialCode][ICD] = List<MapperRow>
	private readonly Dictionary<string, Dictionary<string, List<MapperRow>>> _map;

	public ClaimActionMapperIndex(List<Dictionary<string, string>> rows)
	{
		_map = BuildFastIndex(rows);
	}

	public IReadOnlyList<MapperRow> FindByCode(string denialCode)
	{
		denialCode = (denialCode ?? "").Trim().ToUpperInvariant();
		if (_map.TryGetValue(denialCode, out var icdMap))
		{
			return icdMap.Values.SelectMany(x => x).ToList();
		}

		return Array.Empty<MapperRow>();
	}

	public IReadOnlyList<MapperRow> FindByCodeAndICD(string denialCode, string icd)
	{
		denialCode = (denialCode ?? "").Trim().ToUpperInvariant();
		icd = (icd ?? "").Trim().ToUpperInvariant();

		if (_map.TryGetValue(denialCode, out var icdMap))
		{
			if (icdMap.TryGetValue(icd, out var exact))
				return exact;

			if (icdMap.TryGetValue("N/A", out var fallback))
				return fallback;
		}

		return Array.Empty<MapperRow>();
	}

	private static Dictionary<string, Dictionary<string, List<MapperRow>>> BuildFastIndex(
		List<Dictionary<string, string>> rows)
	{
		var map = new Dictionary<string, Dictionary<string, List<MapperRow>>>(StringComparer.OrdinalIgnoreCase);

		foreach (var r in rows)
		{
			string Get(params string[] names)
			{
				foreach (var n in names)
				{
					var nn = Normalize(n);

					var key = r.Keys.FirstOrDefault(k =>
					{
						var nk = Normalize(k);
						// FIX: allow header cells that *contain* the token, not just equal/starts-with
						return nk == nn || nk.StartsWith(nn) || nk.Contains(nn);
					});

					if (key != null && r.TryGetValue(key, out var v))
						return v?.Trim() ?? "";
				}
				return "";
			}

			var denialCode = Get("Denial Code", "DenialCode", "Denial Code_Prefix").ToUpperInvariant();
			if (string.IsNullOrWhiteSpace(denialCode))
				continue;

			var icd = Get("ICD Compliance Status", "Icd Compliance Status").ToUpperInvariant();
			if (string.IsNullOrWhiteSpace(icd))
				icd = "N/A";

			var row = new MapperRow(
				DenialCode: denialCode,
				DenialDescription: Get("Denial Description"),
				DenialClassification: Get("Denial Classification"),
				CoverageStatus: Get("Coverage Status"),
				IcdComplianceStatus: icd,
				DenialValidity: Get("Denial Validity"),
				ActionCode: Get("Action Code", "Status Action Code"),
				RecommendedAction: Get("Recommended Action"),
				ActionCategory: Get("Action Category"),
				Task: Get("Task", "Task Guidance"),
				ShortCategory: Get("Short Category"),
				Priority: Get("Priority"),
				SlaDays: Get("SLA (Days)", "SLA Days"),
				NotesComments: Get("Notes / Comments", "Notes Comments")
			);

			if (!map.TryGetValue(denialCode, out var icdMap))
			{
				icdMap = new Dictionary<string, List<MapperRow>>(StringComparer.OrdinalIgnoreCase);
				map[denialCode] = icdMap;
			}

			if (!icdMap.TryGetValue(icd, out var list))
			{
				list = new List<MapperRow>();
				icdMap[icd] = list;
			}

			list.Add(row);
		}

		return map;
	}

	private static string Normalize(string s)
	{
		if (string.IsNullOrWhiteSpace(s)) return "";
		return new string(s.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());
	}
}