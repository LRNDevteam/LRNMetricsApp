using System.Globalization;
using System.Net;
using System.Text.RegularExpressions;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Read-side rules for the team's uploaded Key Observations (dbo.DenialClaimLevelInsight, written by
/// LRN Metrics' Denial Claim Report). Kept free of SQL so they can be unit-tested.
/// </summary>
public static partial class ArWorkbenchUploadedInsightRules
{
    [GeneratedRegex(@"<\s*(br|/p|/div|/li|/ul|/ol)\b[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex LineBreakTags();

    [GeneratedRegex(@"<\s*li\b[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex ListItemTag();

    [GeneratedRegex(@"<[^>]*>")]
    private static partial Regex AnyTag();

    [GeneratedRegex(@"[ \t ]+")]
    private static partial Regex Spaces();

    /// <summary>
    /// The stored rich text (bold, bullets) as plain text: each list item a "• " line, paragraphs and
    /// line breaks kept as new lines, every other tag dropped and entities decoded. The workbench shows
    /// it as text, so nothing from the upload is ever rendered as HTML.
    /// </summary>
    public static string? ToPlainText(string? html)
    {
        if (string.IsNullOrWhiteSpace(html)) return null;
        var text = ListItemTag().Replace(html, "\n• ");
        text = LineBreakTags().Replace(text, "\n");
        text = WebUtility.HtmlDecode(AnyTag().Replace(text, string.Empty));
        var lines = text.Replace("\r", string.Empty).Split('\n')
            .Select(l => Spaces().Replace(l, " ").Trim())
            .Where(l => l.Length > 0 && l != "•");
        var result = string.Join("\n", lines);
        return result.Length == 0 ? null : result;
    }

    /// <summary>
    /// "$ Impact (%)" to show: the uploaded text, unless it is a number outside 0-100% - impossible,
    /// since the payer's insurance balance is part of the code's total - in which case it is
    /// Insurance Balance / Total Balance. Same rule as LRN Metrics' DenialInsightPercent.DisplayText.
    /// </summary>
    public static string? ImpactText(string? text, decimal insuranceBalance, decimal totalBalance)
    {
        var shown = (text ?? string.Empty).Trim();
        if (shown.Length == 0) return totalBalance > 0 && insuranceBalance >= 0 && insuranceBalance <= totalBalance ? Percent(insuranceBalance, totalBalance) : null;
        var raw = shown.Replace("%", string.Empty).Replace(",", string.Empty).Trim();
        if (!decimal.TryParse(raw, NumberStyles.Number, CultureInfo.InvariantCulture, out var value)) return shown;
        if (value is >= 0m and <= 100m) return shown;
        if (totalBalance <= 0m || insuranceBalance < 0m || insuranceBalance > totalBalance) return shown;
        return Percent(insuranceBalance, totalBalance);
    }

    private static string Percent(decimal part, decimal whole) =>
        decimal.Round(part / whole * 100m, 2).ToString("0.##", CultureInfo.InvariantCulture) + "%";
}
