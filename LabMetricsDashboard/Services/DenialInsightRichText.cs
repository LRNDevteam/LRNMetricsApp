using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using ClosedXML.Excel;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Turns an Excel cell's formatting into HTML the Denial Summary page can render, and keeps that
/// HTML safe to render.
///
/// The requirement is that what the analyst typed in Observation and Action - bold, bullet points,
/// line breaks - survives the import and shows the same way on screen. Excel stores that as rich
/// text runs on the cell, so the runs are read and re-emitted as tags rather than flattened to
/// plain text.
///
/// Sanitizing is an allowlist rebuild: every tag is re-emitted from its name alone with no
/// attributes, so no attribute (onerror, style, href="javascript:") can survive a round trip
/// through a workbook a user supplied.
/// </summary>
public static class DenialInsightRichText
{
    public const int MaxLength = 20_000;

    private static readonly HashSet<string> AllowedTags = new(StringComparer.OrdinalIgnoreCase)
    {
        "b", "strong", "i", "em", "u", "s", "ul", "ol", "li", "p", "br"
    };

    private static readonly HashSet<string> DropWithContent = new(StringComparer.OrdinalIgnoreCase)
    {
        "script", "style", "iframe", "object", "embed", "noscript", "template", "textarea", "head", "svg", "math"
    };

    private static readonly Regex TagPattern = new(@"^(/?)([a-zA-Z][a-zA-Z0-9]*)(?=[\s/]|$)",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    /// <summary>
    /// Reads a cell as HTML, preserving its rich-text runs. Falls back to the plain string (with
    /// line breaks and bullet lines turned into markup) when the cell carries no run formatting.
    /// </summary>
    public static string FromCell(IXLCell? cell)
    {
        if (cell is null || cell.IsEmpty()) return string.Empty;

        string html;
        try
        {
            // HasRichText throws on some cell types rather than returning false; treat any failure
            // as "plain cell" and fall back, which is always renderable.
            html = cell.HasRichText ? FromRuns(cell.GetRichText()) : FromPlainText(cell.GetString());
        }
        catch
        {
            html = FromPlainText(cell.GetString());
        }

        var sanitized = Sanitize(html);
        return sanitized.Length > MaxLength ? sanitized[..MaxLength] : sanitized;
    }

    private static string FromRuns(IXLRichText richText)
    {
        var sb = new StringBuilder();

        foreach (var run in richText)
        {
            var text = run.Text;
            if (string.IsNullOrEmpty(text)) continue;

            var open = new StringBuilder();
            var close = new StringBuilder();

            if (run.Bold) { open.Append("<b>"); close.Insert(0, "</b>"); }
            if (run.Italic) { open.Append("<i>"); close.Insert(0, "</i>"); }
            if (run.Underline != XLFontUnderlineValues.None) { open.Append("<u>"); close.Insert(0, "</u>"); }
            if (run.Strikethrough) { open.Append("<s>"); close.Insert(0, "</s>"); }

            sb.Append(open).Append(EncodeWithBreaks(text)).Append(close);
        }

        return BulletLinesToList(sb.ToString());
    }

    private static string FromPlainText(string? text) =>
        string.IsNullOrWhiteSpace(text) ? string.Empty : BulletLinesToList(EncodeWithBreaks(text));

    private static string EncodeWithBreaks(string text) =>
        WebUtility.HtmlEncode(text).Replace("\r\n", "\n").Replace("\r", "\n").Replace("\n", "<br>");

    /// <summary>
    /// Lines that start with a bullet glyph or a dash become a real &lt;ul&gt;, so the list reads as
    /// a list on the page instead of as a run of text with stray characters in it.
    /// </summary>
    private static string BulletLinesToList(string html)
    {
        if (html.Length == 0) return html;

        var lines = html.Split("<br>", StringSplitOptions.None);
        if (!lines.Any(IsBulletLine)) return html;

        var sb = new StringBuilder();
        var inList = false;

        foreach (var line in lines)
        {
            if (IsBulletLine(line))
            {
                if (!inList) { sb.Append("<ul>"); inList = true; }
                sb.Append("<li>").Append(StripBullet(line)).Append("</li>");
                continue;
            }

            if (inList) { sb.Append("</ul>"); inList = false; }
            if (line.Trim().Length > 0) sb.Append(line).Append("<br>");
        }

        if (inList) sb.Append("</ul>");
        return sb.ToString();
    }

    private static bool IsBulletLine(string line)
    {
        var trimmed = StripLeadingTags(line).TrimStart();
        return trimmed.StartsWith('•') || trimmed.StartsWith("- ", StringComparison.Ordinal) || trimmed.StartsWith('●');
    }

    private static string StripBullet(string line)
    {
        var index = line.IndexOfAny(['•', '●', '-']);
        if (index < 0) return line;
        return line[..index] + line[(index + 1)..].TrimStart();
    }

    private static string StripLeadingTags(string line)
    {
        var i = 0;
        while (i < line.Length && line[i] == '<')
        {
            var close = line.IndexOf('>', i);
            if (close < 0) break;
            i = close + 1;
        }
        return line[i..];
    }

    /// <summary>Allowlist rebuild - formatting tags only, never attributes.</summary>
    public static string Sanitize(string? html)
    {
        if (string.IsNullOrWhiteSpace(html)) return string.Empty;

        var sb = new StringBuilder(html.Length);
        var i = 0;

        while (i < html.Length)
        {
            var c = html[i];

            if (c != '<') { sb.Append(c); i++; continue; }

            var gt = html.IndexOf('>', i + 1);
            if (gt < 0) { sb.Append("&lt;"); i++; continue; }

            var inner = html[(i + 1)..gt];
            var match = TagPattern.Match(inner);
            if (!match.Success) { sb.Append("&lt;"); i++; continue; }

            i = gt + 1;
            var closing = match.Groups[1].Value == "/";
            var name = match.Groups[2].Value.ToLowerInvariant();

            if (AllowedTags.Contains(name))
            {
                if (name == "br") { if (!closing) sb.Append("<br>"); }
                else sb.Append(closing ? "</" : "<").Append(name).Append('>');
            }
            else if (!closing && DropWithContent.Contains(name))
            {
                var close = html.IndexOf("</" + name, i, StringComparison.OrdinalIgnoreCase);
                if (close < 0) { i = html.Length; continue; }
                var closeGt = html.IndexOf('>', close);
                i = closeGt < 0 ? html.Length : closeGt + 1;
            }

            // Anything else: tag dropped, its text kept.
        }

        return sb.ToString().Trim();
    }

    /// <summary>Readable text for an Excel cell on the way back out.</summary>
    public static string ToPlainText(string? html)
    {
        if (string.IsNullOrWhiteSpace(html)) return string.Empty;

        var text = Regex.Replace(html, @"<\s*br\s*/?\s*>", "\n", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"<\s*li\s*>", "\n• ", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"<\s*/\s*(p|ul|ol)\s*>", "\n", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"<[^>]*>", string.Empty);
        text = WebUtility.HtmlDecode(text);
        text = Regex.Replace(text, @"[ \t]+\n", "\n");
        text = Regex.Replace(text, @"\n{3,}", "\n\n");
        return text.Trim();
    }
}
