using System;
using System.Text.RegularExpressions;

namespace LRN.ProductionReports.Services;

/// <summary>
/// Appends the two differential formats the pivot header regions need — mint
/// for the blank corner and metric captions, white for the field-button row —
/// and reports the indexes the pivot parts must reference.
/// </summary>
internal sealed class PivotHeaderDxfs
{
    /// <summary>Accent 6 Lighter 80%, the mint already used for month headers.</summary>
    private const string Mint = "FFE2EFDA";
    private const string White = "FFFFFFFF";
    private const string Text = "FF385624";

    private readonly string _prefix;
    private readonly int _existingCount;

    private PivotHeaderDxfs(string prefix, int existingCount)
    {
        _prefix = prefix;
        _existingCount = existingCount;
    }

    public int MintId => _existingCount;

    public int WhiteId => _existingCount + 1;

    /// <summary>
    /// Returns null when styles.xml has no dxfs element, in which case the
    /// pivot parts are left alone rather than pointed at a missing style.
    /// </summary>
    public static PivotHeaderDxfs? Plan(string stylesXml)
    {
        var match = Regex.Match(stylesXml, @"<(\w+:)?dxfs\s+count=""(\d+)""\s*(/?)>", RegexOptions.IgnoreCase);
        if (!match.Success)
            return null;

        return new PivotHeaderDxfs(match.Groups[1].Value, int.Parse(match.Groups[2].Value));
    }

    public string Append(string stylesXml)
    {
        var match = Regex.Match(stylesXml, @"<(?:\w+:)?dxfs\s+count=""(\d+)""\s*(/?)>", RegexOptions.IgnoreCase);
        if (!match.Success)
            return stylesXml;

        var block = Dxf(Mint) + Dxf(White);
        var open = $"<{_prefix}dxfs count=\"{_existingCount + 2}\">";

        if (match.Groups[2].Value == "/")
        {
            // <dxfs count="0"/> — expand into a container holding both.
            return stylesXml.Remove(match.Index, match.Length)
                            .Insert(match.Index, open + block + $"</{_prefix}dxfs>");
        }

        var close = stylesXml.IndexOf($"</{_prefix}dxfs>", StringComparison.OrdinalIgnoreCase);
        if (close < 0)
            return stylesXml;

        // Insert at the closing tag first so the opening tag index stays valid.
        return stylesXml.Insert(close, block)
                        .Remove(match.Index, match.Length)
                        .Insert(match.Index, open);
    }

    /// <summary>
    /// A solid pattern paints from fgColor, so set it explicitly. Leaving it
    /// as auto is what rendered these headers black.
    /// </summary>
    private string Dxf(string fill)
    {
        return $"<{_prefix}dxf>"
             + $"<{_prefix}font><{_prefix}b /><{_prefix}sz val=\"10\" /><{_prefix}color rgb=\"{Text}\" /></{_prefix}font>"
             + $"<{_prefix}fill><{_prefix}patternFill patternType=\"solid\">"
             + $"<{_prefix}fgColor rgb=\"{fill}\" /><{_prefix}bgColor rgb=\"{fill}\" />"
             + $"</{_prefix}patternFill></{_prefix}fill>"
             + $"</{_prefix}dxf>";
    }
}
