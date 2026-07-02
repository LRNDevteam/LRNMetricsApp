namespace DenialDatabaseProcessorWorker.Normalizers;

public static class CoverageIcdNormalizer
{
	public static string NormalizeCoverage(string? v)
	{
		if (string.IsNullOrWhiteSpace(v))
			return "";

		// Replace all punctuation and symbols with space
		var cleaned = new string(
			v.Select(ch => char.IsLetterOrDigit(ch) ? ch : ' ')
			 .ToArray()
		);

		// Collapse multiple spaces → single space
		cleaned = string.Join(" ", cleaned.Split(' ', StringSplitOptions.RemoveEmptyEntries));

		// Remove spaces entirely for matching
		cleaned = new string(cleaned.Where(char.IsLetterOrDigit).ToArray());

		return cleaned.ToLowerInvariant();
	}

	public static string NormalizeICD(string? v)
	{
		if (string.IsNullOrWhiteSpace(v))
			return "";

		var cleaned = new string(
			v.Select(ch => char.IsLetterOrDigit(ch) ? ch : ' ')
			 .ToArray()
		);

		cleaned = string.Join(" ", cleaned.Split(' ', StringSplitOptions.RemoveEmptyEntries));
		cleaned = new string(cleaned.Where(char.IsLetterOrDigit).ToArray());

		return cleaned.ToLowerInvariant();
	}

	public static string NormalizeGeneral(string? v)
	{
		if (string.IsNullOrWhiteSpace(v))
			return "";

		return new string(
			v.Where(char.IsLetterOrDigit)
			 .Select(char.ToLowerInvariant)
			 .ToArray()
		);
	}

	public static bool IsNA(string? v)
	{
		if (string.IsNullOrWhiteSpace(v)) return true;

		v = v.Trim().ToUpperInvariant();
		return v == "N/A" || v == "NA" || v == "BLANK";
	}
}

public static class TaskGuidanceNormalizer
{
	public static string Normalize(string? raw, string denialCode)
	{
		if (string.IsNullOrWhiteSpace(raw))
			return "";

		raw = raw.Trim();

		// Remove prefixes like "CO50:" or "RB:" or "APP:"
		var idx = raw.IndexOf(':');
		if (idx > 0)
			raw = raw[(idx + 1)..].Trim();

		// If task accidentally equals denial code → invalid
		if (raw.Equals(denialCode, StringComparison.OrdinalIgnoreCase))
			return "";

		return raw;
	}
}