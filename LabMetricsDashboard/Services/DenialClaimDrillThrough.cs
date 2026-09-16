namespace LabMetricsDashboard.Services;

/// <summary>
/// Builds the route values that open <c>Dashboard/ClaimLevel</c> filtered to one denial insight row.
///
/// <para>The Claim Level page is the application's one claim browser - it already has the column
/// set, the paging, the export and the rest of the filter rail - so a denial drill-through hands off
/// to it rather than keeping a second, thinner claim list of its own.</para>
/// </summary>
public static class DenialClaimDrillThrough
{
    /// <summary>The claim adjustment group prefixes a normalized numeric code can appear under.</summary>
    private static readonly string[] GroupPrefixes = ["CO", "PI", "PR", "OA", "CR"];

    /// <summary>
    /// Route values for <c>Dashboard/ClaimLevel</c>: the lab, the denial code, and optionally the
    /// insurance.
    /// </summary>
    /// <param name="denialCode">
    /// The code as the insight row carries it - usually already normalized, e.g. "45" or "MA130".
    /// </param>
    /// <param name="payerName">The insurance to narrow to, or null for every payer on that denial.</param>
    public static Dictionary<string, string?> RouteValues(string lab, string? denialCode, string? payerName = null)
    {
        var values = new Dictionary<string, string?>(StringComparer.Ordinal)
        {
            ["lab"] = lab,
            // Every row behind a denial metric has a code; without this the page would open on the
            // lab's whole claim table if the code filter failed to bind.
            ["filterDenialCodeExcludeBlank"] = "true"
        };

        var codeFilter = BuildDenialCodeFilter(denialCode);
        if (codeFilter is not null) values["filterDenialCode"] = codeFilter;

        // filterPayerNames is an exact match, unlike the LIKE-based filterPayerName. Exact is the
        // right choice here: a partial match on "UHC" would also pull in "UHC Community Plan" and
        // the claim list would stop tying back to the number that was clicked.
        if (!string.IsNullOrWhiteSpace(payerName)) values["filterPayerNames"] = payerName.Trim();

        return values;
    }

    /// <summary>
    /// The value for the Claim Level page's <c>filterDenialCode</c>, which takes a comma-separated
    /// list and matches each entry with <c>LIKE '%value%'</c> against the raw DenialCode column.
    /// </summary>
    /// <remarks>
    /// <para>A normalized numeric code is expanded to the prefixed spellings the claim data actually
    /// stores - 45 becomes "CO45,PI45,PR45,OA45,CR45,45" - because the raw column holds "CO45", not
    /// "45", and a filter of "45" alone would miss nothing but relies entirely on the substring
    /// match. The bare code stays in the list because some labs do store the code unprefixed.</para>
    /// <para><b>Known imprecision.</b> Because the page matches with LIKE, drilling into 45 can also
    /// return a claim denied under 145 or 450. Tightening that needs an exact filter on the new
    /// DenialCodeNormalized column, which means changing usp_GetClaimLevelDetails.</para>
    /// </remarks>
    public static string? BuildDenialCodeFilter(string? denialCode)
    {
        var code = (denialCode ?? string.Empty).Trim();
        if (code.Length == 0) return null;

        // A code the lab stores with its own prefix already ("MA130", "N130", or a raw "CO45") is
        // passed through as-is - prefixing it again would match nothing.
        if (!IsBareNumeric(code)) return code;

        var variants = GroupPrefixes.Select(p => p + code).ToList();
        variants.Add(code);

        return string.Join(",", variants);
    }

    /// <summary>True for a code that is digits, optionally with one trailing letter: 45, 189, 45A.</summary>
    private static bool IsBareNumeric(string code)
    {
        if (code.Length == 0 || !char.IsDigit(code[0])) return false;

        var digits = char.IsLetter(code[^1]) ? code[..^1] : code;
        return digits.Length > 0 && digits.All(char.IsDigit);
    }
}
