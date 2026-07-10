using System.Text.RegularExpressions;

namespace LRN.PayerPolicyMapper.Core.Steps;

/// <summary>
/// Step 1A - cosmetic canonicalization: uppercase, non-alphanumerics to spaces,
/// collapse whitespace, trim. Removes NO words.
/// "Aetna - Choice (POS II)" -> "AETNA CHOICE POS II".
/// </summary>
public static class Step1ACanonicalize
{
    private static readonly Regex NonAlphaNumeric = new("[^A-Z0-9 ]", RegexOptions.Compiled);
    private static readonly Regex MultiSpace = new(" {2,}", RegexOptions.Compiled);

    public static string Run(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return string.Empty;
        var text = raw.ToUpperInvariant();
        text = NonAlphaNumeric.Replace(text, " ");
        text = MultiSpace.Replace(text, " ");
        return text.Trim();
    }

    public static void Run(MatchContext context) => context.CosmeticName = Run(context.PayerNameRaw);
}
