using System.Text.RegularExpressions;

/// <summary>
/// Bridges the system Lab identity (LabId / LabName) to the value stored in the
/// Insurance Master workbook's "Lab Name" column (the "insurance reference").
///
/// The Insurance Master lookup is keyed by {LabName}|{Payer}. The lab name written
/// into that workbook does NOT always equal the lab name configured in this worker,
/// e.g. system "NorthWest" is stored as "NWL", "PCRDx - AL" as "PCR AL". When the
/// two differ, exact-key matching fails and payer enrichment silently drops.
///
/// This map is the single source of truth for that translation. Entries are matched
/// by LabId first (stable) and fall back to the normalized system lab name, so it
/// keeps working even if a lab is reconfigured with a different id or vice versa.
///
/// Only add a row here when the insurance reference differs from the system LabName;
/// identical names resolve fine without an entry, but they are listed for clarity.
/// </summary>
public static class LabInsuranceReferenceMap
{
	private sealed record Entry(int LabId, string LabName, string InsuranceReference);

	// Authoritative Lab Name -> Insurance Master reference table.
	private static readonly Entry[] Entries =
	{
		new(1,  "Prism Molecular",     "Prism"),
		new(2,  "InHealth",            "InHealth-DTR"),
		new(4,  "Cove",                "Cove"),
		new(5,  "Dylo",                "Dylo"),
		new(6,  "PCRDx - AL",          "PCR AL"),
		new(7,  "PCRDx - CO",          "PCR CO"),
		new(10, "BeechTree",           "Beech Tree"),
		new(13, "PCR Labs of America", "PCR Labs of America"),
		new(18, "Certus",              "Certus"),
		new(23, "Northwest",           "NWL"),
		new(24, "Augustus_Labs",       "Augustus"),
		new(16, "Elixir",              "Elixir"),
		new(12, "Phi Life",            "Phi Life"),
		new(9,  "Rising Tides",        "Rising Tides"),
	};

	private static readonly Dictionary<int, string> ByLabId =
		Entries
			.GroupBy(e => e.LabId)
			.ToDictionary(g => g.Key, g => g.First().InsuranceReference);

	private static readonly Dictionary<string, string> ByLabName =
		Entries
			.GroupBy(e => NormKey(e.LabName))
			.Where(g => !string.IsNullOrEmpty(g.Key))
			.ToDictionary(g => g.Key, g => g.First().InsuranceReference);

	/// <summary>
	/// Returns the Insurance Master "Lab Name" reference for the given lab, or null when
	/// no mapping is known (the caller should then use the original lab name as-is).
	/// LabId wins; the normalized lab name is used as a fallback.
	/// </summary>
	public static string? Resolve(int labId, string? labName)
	{
		if (ByLabId.TryGetValue(labId, out var byId))
			return byId;

		var nameKey = NormKey(labName ?? "");
		if (!string.IsNullOrEmpty(nameKey) && ByLabName.TryGetValue(nameKey, out var byName))
			return byName;

		return null;
	}

	private static string NormKey(string s)
	{
		if (string.IsNullOrWhiteSpace(s)) return "";
		s = s.Trim().ToLowerInvariant();
		return Regex.Replace(s, @"[^a-z0-9]+", "");
	}
}
