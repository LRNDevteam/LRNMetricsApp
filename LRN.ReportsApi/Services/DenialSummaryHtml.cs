using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace LRN.ReportsApi.Services;

/// <summary>
/// Rich text for Denial Summary observations (spec 4b).
///
/// The page renders this HTML directly, so it is sanitized on the way in AND on the way out: a row
/// written straight into SQL must not be able to run script in a manager's browser. The approach is
/// an allowlist rebuild rather than a blocklist: every tag is re-emitted from its name alone with no
/// attributes, so there is no attribute (onerror, href="javascript:", style) left to abuse. Anything
/// not on the list is dropped and its text kept, except script-like elements, whose content goes too.
/// </summary>
internal static class DenialSummaryHtml
{
    public const int MaxSanitizedLength = 20_000;

    private static readonly HashSet<string> AllowedTags = new(StringComparer.OrdinalIgnoreCase)
    {
        "b", "strong", "i", "em", "u", "s", "ul", "ol", "li", "p", "div", "br"
    };

    // Elements whose text is not prose and must disappear with the tag.
    private static readonly HashSet<string> DropWithContent = new(StringComparer.OrdinalIgnoreCase)
    {
        "script", "style", "iframe", "object", "embed", "noscript", "template", "textarea", "title", "head", "svg", "math"
    };

    // A tag name must follow "<" or "</" immediately, as in the HTML tokenizer.
    private static readonly Regex TagPattern = new(@"^(/?)([a-zA-Z][a-zA-Z0-9]*)(?=[\s/]|$)", RegexOptions.CultureInvariant);
    private static readonly Regex EntityPattern = new(@"\G&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});", RegexOptions.CultureInvariant);

    public static string? Sanitize(string? html)
    {
        if (string.IsNullOrWhiteSpace(html)) return null;

        var sb = new StringBuilder(html.Length);
        var i = 0;

        while (i < html.Length)
        {
            var c = html[i];

            if (c == '<')
            {
                if (string.CompareOrdinal(html, i, "<!--", 0, 4) == 0)
                {
                    var endComment = html.IndexOf("-->", i + 4, StringComparison.Ordinal);
                    i = endComment < 0 ? html.Length : endComment + 3;
                    continue;
                }

                var gt = html.IndexOf('>', i + 1);
                var nextLt = html.IndexOf('<', i + 1);
                if (gt < 0 || (nextLt >= 0 && nextLt < gt))
                {
                    sb.Append("&lt;");
                    i++;
                    continue;
                }

                var inner = html.Substring(i + 1, gt - i - 1);
                var match = TagPattern.Match(inner);
                if (!match.Success)
                {
                    // "a < b > c" is text to a browser, not a tag: escape it rather than drop it.
                    sb.Append("&lt;");
                    i++;
                    continue;
                }
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

                continue;
            }

            if (c == '&')
            {
                var entity = EntityPattern.Match(html, i);
                if (entity.Success)
                {
                    sb.Append(entity.Value);
                    i += entity.Length;
                }
                else
                {
                    sb.Append("&amp;");
                    i++;
                }
                continue;
            }

            if (c == '>') sb.Append("&gt;");
            else sb.Append(c);
            i++;
        }

        var result = sb.ToString().Trim();
        return string.IsNullOrWhiteSpace(ToPlainText(result)) ? null : result;
    }

    /// <summary>Readable text for Excel cells: line breaks and bullets kept, markup and entities gone.</summary>
    public static string ToPlainText(string? html)
    {
        if (string.IsNullOrWhiteSpace(html)) return string.Empty;

        var text = Regex.Replace(html, @"<\s*br\s*/?\s*>", "\n", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"<\s*li\s*>", "\n• ", RegexOptions.IgnoreCase);
        // Not </li>: each <li> already starts its own line, and a second break would space the list out.
        text = Regex.Replace(text, @"<\s*/\s*(p|div|ul|ol)\s*>", "\n", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"<[^>]*>", string.Empty);
        text = WebUtility.HtmlDecode(text).Replace(' ', ' ');
        text = Regex.Replace(text, @"[ \t]+\n", "\n");
        text = Regex.Replace(text, @"\n{3,}", "\n\n");
        return text.Trim();
    }
}
