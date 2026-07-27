using System.Net;
using System.Text;

namespace LabMetricsDashboard.Helpers;

/// <summary>
/// Lightweight CPT display for Coding Insights tables.
/// One flat chip per code (no nested DOM / overflow JS). Caps count for speed.
/// </summary>
public static class CodingCptPillFormatter
{
    private const int MaxChips = 5;

    /// <summary>
    /// Compact colored chips: billable / billed / missing / additional.
    /// Max <see cref="MaxChips"/> codes, then +N.
    /// </summary>
    public static string FormatLite(string? combo, string variant)
    {
        if (string.IsNullOrWhiteSpace(combo))
            return "<span class=\"cpt-empty\">&#8212;</span>";

        var tokens = combo.Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (tokens.Length == 0)
            return "<span class=\"cpt-empty\">&#8212;</span>";

        var sb = new StringBuilder(Math.Min(tokens.Length, MaxChips) * 64 + 48);
        sb.Append("<span class=\"cpt-chips cpt-chips-").Append(WebUtility.HtmlEncode(variant)).Append("\" title=\"")
          .Append(WebUtility.HtmlEncode(combo.Length > 400 ? combo[..400] + "..." : combo))
          .Append("\">");

        var show = Math.Min(tokens.Length, MaxChips);
        for (var i = 0; i < show; i++)
        {
            var label = ShortLabel(tokens[i]);
            sb.Append("<span class=\"cpt-chip\">").Append(WebUtility.HtmlEncode(label)).Append("</span>");
        }

        if (tokens.Length > MaxChips)
            sb.Append("<span class=\"cpt-chip cpt-chip-more\">+").Append(tokens.Length - MaxChips).Append("</span>");

        sb.Append("</span>");
        return sb.ToString();
    }

    /// <summary>Keep full pill UI for tabs that still need it (detail / export preview).</summary>
    public static string Format(string? combo, string variant) => FormatLite(combo, variant);

    private static string ShortLabel(string token)
    {
        // Prefer CPT code before *units(mod); keep short.
        var t = token.Trim();
        if (t.Length == 0) return t;
        var star = t.IndexOf('*');
        if (star > 0) t = t[..star].Trim();
        return t.Length > 18 ? t[..18] + "…" : t;
    }
}