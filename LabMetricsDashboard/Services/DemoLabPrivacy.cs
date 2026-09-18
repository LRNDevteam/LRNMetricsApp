using System.Text.RegularExpressions;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Withholds identifying columns from the demo labs, at the point the column list is
/// built rather than at the point it is rendered.
///
/// <para><b>Why here and not in the views.</b> Hiding a column in a Razor view leaves it in
/// the SELECT, in the JSON, and - the one that matters - in the Excel export, which is the
/// first thing anyone does with a report. The column list produced here feeds the grids
/// <i>and</i> <c>GetExportSelectList</c>, so a column withheld is never queried, never
/// serialised and never exported.</para>
///
/// <para><b>Two treatments, because the columns are not alike.</b> Patient name, DOB,
/// patient id and subscriber id are pure identifiers - nothing reports on them, so they
/// are dropped outright. Clinic, sales rep and referring provider are <i>business</i>
/// identifiers that reports group by; dropping those from an aggregate report leaves an
/// empty report, so away from detail grids they want a stable pseudonym instead. See
/// <see cref="Pseudonym"/>.</para>
///
/// <para><b>This is not de-identification.</b> The database still holds the real values and
/// any surface that does not consult this class still shows them. It buys a demo that does
/// not display PHI; it does not make the database safe to hand out.</para>
/// </summary>
public sealed class DemoLabPrivacy
{
    private readonly DemoLabPrivacyOptions _options;

    public DemoLabPrivacy(DemoLabPrivacyOptions options) => _options = options ?? new DemoLabPrivacyOptions();

    /// <summary>True when this lab's reports must withhold identifying columns.</summary>
    public bool AppliesTo(string? labName) =>
        !string.IsNullOrWhiteSpace(labName)
        && _options.Enabled
        && _options.LabNames.Contains(labName.Trim(), StringComparer.OrdinalIgnoreCase);

    /// <summary>True when this lab id is a demo lab - for the paths that carry an id, not a name.</summary>
    public bool AppliesTo(int labId) => _options.Enabled && _options.LabIds.Contains(labId);

    /// <summary>
    /// The columns to keep for this lab. A non-demo lab gets the list back untouched, so the
    /// cost on every real lab is one dictionary lookup.
    /// </summary>
    public IReadOnlyList<string> Filter(string? labName, IReadOnlyList<string> columns)
    {
        if (!AppliesTo(labName) || columns.Count == 0) return columns;

        var kept = columns.Where(c => !IsWithheld(c)).ToList();

        // Withholding every column would produce an empty grid, which reads as a broken
        // report rather than a private one. Something has gone wrong with the patterns.
        return kept.Count == 0 ? columns : kept;
    }

    /// <summary>True when a column carries an identity the demo must not show.</summary>
    public bool IsWithheld(string? column)
    {
        if (string.IsNullOrWhiteSpace(column)) return false;

        var name = column.Trim();
        return _options.WithheldPatterns.Any(p =>
            name.Contains(p, StringComparison.OrdinalIgnoreCase))
            && !_options.KeepPatterns.Any(k => name.Equals(k, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// A stable stand-in for a business identifier: the same clinic is always "Clinic 07",
    /// so an aggregate report still groups, sorts and totals the way it always did while the
    /// real name stays off the screen.
    /// </summary>
    /// <remarks>
    /// Derived from the value, not allocated in sequence, so two reports built from separate
    /// queries agree on which clinic is which - and so the label survives a page reload.
    /// </remarks>
    public string Pseudonym(string? value, string prefix)
    {
        if (string.IsNullOrWhiteSpace(value)) return string.Empty;

        // FNV-1a: small, stable across processes, and - unlike string.GetHashCode - not
        // randomised per run, which would relabel every clinic on each app restart.
        unchecked
        {
            const uint offset = 2166136261;
            const uint prime = 16777619;

            var hash = offset;
            foreach (var c in value.Trim().ToUpperInvariant())
            {
                hash ^= c;
                hash *= prime;
            }

            return $"{prefix} {hash % 900 + 100}";
        }
    }
}

/// <summary>
/// Bound from <c>DemoLabPrivacy</c> in appsettings. Config rather than constants so a column
/// that turns up later can be withheld without a deploy.
/// </summary>
public sealed class DemoLabPrivacyOptions
{
    public const string SectionName = "DemoLabPrivacy";

    /// <summary>Master switch. Off means every lab behaves exactly as it did before.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>Lab keys whose reports withhold identifying columns.</summary>
    public List<string> LabNames { get; set; } = new() { "LRNLabDemo", "LRNDemo" };

    /// <summary>The same labs by id, for paths that carry an id rather than a name.</summary>
    public List<int> LabIds { get; set; } = new() { 98, 99 };

    /// <summary>
    /// Matched as case-insensitive substrings of the column name, so a lab spelling a column
    /// its own way ("SalesRepname", "Sales_Rep_Name") is covered without listing every variant.
    /// </summary>
    public List<string> WithheldPatterns { get; set; } = new()
    {
        // Patient identity - dropped outright, nothing reports on these.
        "PatientName", "PatientDOB", "DOB", "PatientID", "PatientAccount",
        "MRN", "SubscriberID", "Subscriber", "MemberID", "PolicyNumber",

        // Business identities the demo must not name.
        "SalesRep", "SalesPerson",
        "Referring", "Referral", "OrderingPhysician", "Physician", "Doctor",
        "Clinic"
    };

    /// <summary>
    /// Exact column names that survive despite matching a pattern above. "ClaimID" does not
    /// match "PatientID" as a substring, but a lab is free to name something awkwardly, and
    /// this is the escape hatch that does not need a code change.
    /// </summary>
    public List<string> KeepPatterns { get; set; } = new();
}
