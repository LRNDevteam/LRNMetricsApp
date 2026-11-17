using System.Text.RegularExpressions;

namespace LRN.AI.Application.Common;

/// <summary>
/// Flags text that looks like it contains direct patient identifiers (HIPAA Safe Harbor categories that have a
/// recognisable shape). It is a guard rail for endpoints that must only receive de-identified text, not a
/// de-identification tool: names, addresses and free-text identifiers are not detected.
/// Only category names are returned, never the matched text, so callers can log and report the result safely.
/// </summary>
public static class LikelyPhiDetector
{
    private static readonly TimeSpan MatchTimeout = TimeSpan.FromMilliseconds(250);

    private static readonly (string Category, Regex Pattern)[] Patterns =
    [
        ("SSN", new Regex(@"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b", RegexOptions.CultureInvariant, MatchTimeout)),
        ("Email", new Regex(@"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", RegexOptions.CultureInvariant, MatchTimeout)),
        // Separators are required so claim numbers, NPIs and other bare 10-digit identifiers are not flagged.
        ("Phone", new Regex(@"(?<!\d)(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}(?!\d)", RegexOptions.CultureInvariant, MatchTimeout)),
        ("DateOfBirth", new Regex(@"\b(?:DOB|D\.O\.B\.?|date\s+of\s+birth|birth\s*date)\b\W{0,3}\d{1,4}[/.-]\d{1,2}[/.-]\d{1,4}", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase, MatchTimeout)),
        ("MedicalRecordNumber", new Regex(@"\b(?:MRN|medical\s+record\s+(?:number|no\.?|#))\W{0,3}[A-Za-z0-9-]{4,}", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase, MatchTimeout)),
        // CMS Medicare Beneficiary Identifier format (11 characters, letters exclude S, L, O, I, B, Z).
        ("MedicareBeneficiaryId", new Regex(@"\b[1-9][AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y0-9]\d[AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y0-9]\d[AC-HJKMNP-RT-Y]{2}\d{2}\b", RegexOptions.CultureInvariant, MatchTimeout)),
    ];

    public static IReadOnlyList<string> Detect(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return [];

        var found = new List<string>();
        foreach (var (category, pattern) in Patterns)
        {
            try
            {
                if (pattern.IsMatch(text)) found.Add(category);
            }
            catch (RegexMatchTimeoutException)
            {
                // Fail closed: text the detector cannot finish scanning is treated as possibly containing identifiers.
                found.Add(category);
            }
        }
        return found;
    }
}
