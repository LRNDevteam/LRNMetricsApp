using System.Text.RegularExpressions;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>
/// Columns this pipeline must never copy into an <c>AdditionalFields</c> JSON blob, for any lab and
/// at any level.
/// <para>
/// AdditionalFields exists so a column a lab adds to its file is not silently lost. That is exactly
/// what makes it a privacy hazard: it captures whatever arrives, including fields nobody reviewed.
/// This is the deny-list that keeps the catch-all from catching things policy says we do not hold.
/// </para>
/// <para>
/// <b>Policy: the Social Security Number is not captured.</b> A lab that sends it gets it dropped at
/// read time - it is never written to a row, so it cannot reach the database and later need purging.
/// </para>
/// <para>
/// This governs the catch-all ONLY. A column deliberately mapped to a real SQL column in a lab's
/// schema JSON or *FieldMappings.json is an explicit, reviewed decision and is not affected - no
/// such mapping exists today, and adding one would be the moment to revisit this.
/// </para>
/// </summary>
public static class SensitiveColumns
{
    /// <summary>
    /// Normalized names that are blocked outright.
    /// <para>
    /// Matched whole, not as a substring: "ssn" inside "ClassNumber" ("cla-ssn-umber") would
    /// otherwise drop a legitimate column.
    /// </para>
    /// </summary>
    private static readonly HashSet<string> BlockedExact = new(StringComparer.Ordinal)
    {
        "ssn",
        "ssns",
        "ssnno",
        "ssnnum",
        "ssnnumber",
        "ssnumber",
        "patientssn",
        "memberssn",
        "insuredssn",
        "subscriberssn",
        "guarantorssn",
        "policyholderssn"
    };

    /// <summary>
    /// Normalized fragments that block a name wherever they appear, so spacing, punctuation and
    /// prefixes cannot slip a field past: "SocialSecurityNumber", "Social Security No",
    /// "Patient Social Security #" and "social_security" all normalize to contain "socialsecurity".
    /// </summary>
    private static readonly string[] BlockedFragments =
    {
        "socialsecurity"
    };

    /// <summary>True when this column must not be captured. Null/blank names are not blocked.</summary>
    public static bool IsBlocked(string? columnName)
    {
        var normalized = Normalize(columnName);

        if (normalized.Length == 0)
            return false;

        foreach (var fragment in BlockedFragments)
        {
            if (normalized.Contains(fragment, StringComparison.Ordinal))
                return true;
        }

        return BlockedExact.Contains(normalized);
    }

    /// <summary>Case, spacing and punctuation are noise: "Social Security #" == "social_security".</summary>
    private static string Normalize(string? value) =>
        string.IsNullOrWhiteSpace(value)
            ? string.Empty
            : Regex.Replace(value.Trim(), "[^A-Za-z0-9]", "").ToLowerInvariant();
}
