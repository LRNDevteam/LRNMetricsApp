namespace LabMetricsDashboard.Services;

/// <summary>
/// Colour banding for the Denial Insight <c>Category</c> column, matching the client's own
/// Key Observations &amp; Highlights workbook.
///
/// <para>The colour is information, not decoration: an AR analyst reads the sheet by category
/// colour before they read the words, so the page has to band the same way the workbook does or the
/// two stop being the same document. The hex values are the workbook's own fills.</para>
///
/// <para>Matched on what the category contains rather than on an exact string, because the client
/// writes the same category several ways - "Review / Rebill", "Review &amp; Rebill",
/// "Review/ Rebill" all mean one thing.</para>
/// </summary>
public static class DenialInsightCategory
{
    /// <summary>A CSS class name for the category, or an empty string when it is blank.</summary>
    public static string CssClass(string? category)
    {
        var text = (category ?? string.Empty).Trim().ToLowerInvariant();
        if (text.Length == 0) return string.Empty;

        var hasAppeal = text.Contains("appeal");

        // Appeal / MR is the medical-records route and is banded apart from a plain appeal, because
        // it sends different work to a different team.
        if (hasAppeal && (text.Contains("mr") || text.Contains("medical record")))
            return "cat-appeal-mr";

        if (hasAppeal) return "cat-appeal";

        if (text.Contains("rebill") || text.Contains("reprocess")) return "cat-rebill";

        // Write off sits with Review: in the workbook both are the same peach fill, because both
        // end in someone reviewing the claim before anything irreversible happens.
        if (text.Contains("review") || text.Contains("write off") || text.Contains("write-off"))
            return "cat-review";

        return "cat-other";
    }
}
