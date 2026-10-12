namespace LabMetricsDashboard.Services;

/// <summary>
/// The Denial Insight <c>Status</c> column: its allowed values and their colour bands, from the
/// client's sample (docs/DenialSummary_EditableColumns.xlsx). Shared by the page and the Excel
/// download so a status reads the same colour in both.
/// </summary>
public static class DenialInsightStatus
{
    public const string YetToDiscuss = "Yet to Discuss";
    public const string Closed = "Closed";
    public const string Deferred = "Deferred";

    /// <summary>The edit dropdown, in the order the client uses them.</summary>
    public static readonly IReadOnlyList<string> Options = [YetToDiscuss, Closed, Deferred];

    /// <summary>
    /// Fill and text colours. Fills are the sample's own; the Closed and Deferred text is a darker
    /// shade of the sample's green and amber, which are unreadable on their light fills on screen.
    /// </summary>
    public static (string Fill, string Text)? Colours(string? status) => Key(status) switch
    {
        "yettodiscuss" => ("#FCE4D6", "#833C0C"),
        "closed"       => ("#E2EFDA", "#375623"),
        "deferred"     => ("#FFFFCC", "#7F6000"),
        _              => null
    };

    /// <summary>A CSS class for the status pill, or an empty string when blank or unrecognised.</summary>
    public static string CssClass(string? status) => Key(status) switch
    {
        "yettodiscuss" => "status-yet",
        "closed"       => "status-closed",
        "deferred"     => "status-deferred",
        _              => string.Empty
    };

    // Case, spacing and punctuation never decide a match: "Yet to discuss" and "Yet To Discuss"
    // are one status, the way the import receives them.
    private static string Key(string? status) =>
        new((status ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());
}
