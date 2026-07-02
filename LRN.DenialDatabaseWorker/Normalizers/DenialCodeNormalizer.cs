using System.Text.RegularExpressions;

namespace DenialDatabaseProcessorWorker.Normalizers;

public sealed class DenialCodeNormalizer
{
    // remove these anywhere they appear (even if alone)
    private static readonly HashSet<string> Excluded = new(StringComparer.OrdinalIgnoreCase)
    {
        "PR1","CO1","PI1",
        "PR2","CO2","PI2",
        "PR3","CO3","PI3",
        "PR45","CO45","PI45",
        "PR253","CO253","PI253"
    };

	private static readonly Regex Splitter = new(@"\s*[;,]\s*", RegexOptions.Compiled);
	private static readonly Regex Cleanup = new(@"[\s-]+", RegexOptions.Compiled);

    public string NormalizeDenialCodeField(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
            return "";

        var parts = SplitToCodes(raw);
        return string.Join(",", parts);
    }

    public List<string> SplitToCodes(string raw)
    {
        var tokens = Splitter.Split(raw)
            .Select(t => Cleanup.Replace(t ?? "", "").Trim())
            .Where(t => !string.IsNullOrWhiteSpace(t))
            .Select(t => t.ToUpperInvariant())
            .ToList();

        // remove excluded codes
        tokens = tokens.Where(t => !Excluded.Contains(t)).ToList();

        // distinct preserve order
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var final = new List<string>();
        foreach (var t in tokens)
        {
            if (seen.Add(t))
                final.Add(t);
        }

        return final;
    }
}
