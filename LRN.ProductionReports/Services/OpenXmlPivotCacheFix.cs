using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace LRN.ProductionReports.Services;

/// <summary>
/// ClosedXML 0.104 writes pivot caches at the package root (<c>/pivotCache/</c>)
/// instead of <c>/xl/pivotCache/</c>. Excel then cannot load the cache, so native
/// PivotTables open with headers and no values. Also strips invalid style
/// references (field 4294967294 = Values axis), sets Office 2013 Accent 6, and
/// repairs solid differential fills so pivot headers paint forest green rather
/// than black. Never adds new style parts — injecting a custom pivot table
/// style is what made Excel drop styles.xml and demand a repair.
/// </summary>
public static class OpenXmlPivotCacheFix
{
    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    public static void Apply(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        var bytes = File.ReadAllBytes(filePath);
        var fixedBytes = Apply(bytes);
        File.WriteAllBytes(filePath, fixedBytes);
    }

    public static void Apply(Stream stream)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (!stream.CanSeek)
            throw new ArgumentException("Stream must be seekable.", nameof(stream));

        stream.Position = 0;
        using var copy = new MemoryStream();
        stream.CopyTo(copy);
        var fixedBytes = Apply(copy.ToArray());
        stream.Position = 0;
        stream.SetLength(0);
        stream.Write(fixedBytes, 0, fixedBytes.Length);
        stream.Position = 0;
    }

    public static byte[] Apply(byte[] zipBytes)
    {
        ArgumentNullException.ThrowIfNull(zipBytes);
        using var input = new ZipArchive(new MemoryStream(zipBytes, writable: false), ZipArchiveMode.Read);

        var names = input.Entries.Select(e => e.FullName.Replace('\\', '/')).ToList();
        var hasRootCache = names.Any(n =>
            n.StartsWith("pivotCache/", StringComparison.OrdinalIgnoreCase));
        var hasTableXml = names.Any(n =>
            n.StartsWith("xl/pivotTables/pivotTable", StringComparison.OrdinalIgnoreCase)
            && n.EndsWith(".xml", StringComparison.OrdinalIgnoreCase));
        if (!hasRootCache && !hasTableXml)
            return zipBytes;

        // The corner, Values caption and metric captions have no dxf of their
        // own, so append two and note where they land before any part is
        // written. Pivot XML must reference indexes that styles.xml will hold.
        var stylesEntry = input.Entries.FirstOrDefault(e =>
            e.FullName.Replace('\\', '/').Equals("xl/styles.xml", StringComparison.OrdinalIgnoreCase));
        var headerDxfs = stylesEntry is null
            ? null
            : PivotHeaderDxfs.Plan(FromUtf8(ReadEntry(stylesEntry)));

        using var output = new MemoryStream();
        using (var outZip = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var entry in input.Entries)
            {
                var name = RelocateCachePath(entry.FullName);
                var data = ReadEntry(entry);
                if (name.Equals("[Content_Types].xml", StringComparison.OrdinalIgnoreCase)
                    || name.EndsWith(".rels", StringComparison.OrdinalIgnoreCase))
                {
                    var xml = FromUtf8(data);
                    if (xml.Contains("pivotCache", StringComparison.OrdinalIgnoreCase))
                        data = ToUtf8(RewriteRootCacheTargets(xml));
                }
                else if (IsPivotTableXml(name))
                    data = ToUtf8(RewritePivotTable(FromUtf8(data), headerDxfs));
                else if (name.Equals("xl/theme/theme1.xml", StringComparison.OrdinalIgnoreCase))
                    data = ToUtf8(RewriteOffice2013Theme(FromUtf8(data)));
                else if (name.Equals("xl/styles.xml", StringComparison.OrdinalIgnoreCase))
                {
                    var xml = RepairSolidDifferentialFills(FromUtf8(data));
                    data = ToUtf8(headerDxfs is null ? xml : headerDxfs.Append(xml));
                }

                WriteEntry(outZip, name, data);
            }
        }

        return output.ToArray();
    }

    private static bool IsPivotTableXml(string name)
    {
        return name.StartsWith("xl/pivotTables/pivotTable", StringComparison.OrdinalIgnoreCase)
            && name.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)
            && !name.Contains("/_rels/", StringComparison.Ordinal);
    }

    private static string RelocateCachePath(string fullName)
    {
        var normalized = fullName.Replace('\\', '/');
        if (normalized.StartsWith("pivotCache/", StringComparison.OrdinalIgnoreCase))
            return "xl/" + normalized;
        return normalized;
    }

    private static string RewriteRootCacheTargets(string xml)
    {
        return Regex.Replace(xml, @"(?<!/xl)/pivotCache/", "/xl/pivotCache/");
    }

    private static string RewritePivotTable(string xml, PivotHeaderDxfs? headerDxfs)
    {
        xml = RecolorValuesAxis(xml, headerDxfs);
        xml = AddHeaderAreas(xml, headerDxfs);

        var colCount = 0;
        var colMatch = Regex.Match(xml, @"<colFields\s+count=""(\d+)""", RegexOptions.IgnoreCase);
        if (colMatch.Success)
            int.TryParse(colMatch.Groups[1].Value, out colCount);
        var firstDataRow = colCount <= 0 ? 2 : Math.Max(2, colCount);

        xml = Regex.Replace(
            xml,
            @"firstHeaderRow=""0""\s+firstDataRow=""0""\s+firstDataCol=""0""",
            $"firstHeaderRow=\"1\" firstDataRow=\"{firstDataRow}\" firstDataCol=\"1\"",
            RegexOptions.IgnoreCase);

        if (!Regex.IsMatch(xml, @"\buseAutoFormatting=", RegexOptions.IgnoreCase))
        {
            xml = Regex.Replace(
                xml,
                @"<pivotTableDefinition\b",
                "<pivotTableDefinition useAutoFormatting=\"1\"",
                RegexOptions.IgnoreCase);
        }

        return xml;
    }

    /// <summary>
    /// ClosedXML writes the Values axis as field="-2" everywhere, but the two
    /// elements disagree on type: pivotArea/@field is an Int32 and accepts -2,
    /// while reference/@field is a UInt32 and does not. Excel writes 4294967294
    /// there. Fixing only the reference is what clears the repair prompt; then
    /// point the "Values" button at white and the metric captions at mint.
    /// </summary>
    private static string RecolorValuesAxis(string xml, PivotHeaderDxfs? dxfs)
    {
        xml = Regex.Replace(xml, @"(<reference\b[^>]*\bfield=)""-2""", @"$1""4294967294""",
            RegexOptions.IgnoreCase);

        if (dxfs is null)
            return xml;

        return Regex.Replace(
            xml,
            @"<format\s+dxfId=""\d+""\s*>(?<body>[\s\S]*?)</format>",
            m =>
            {
                var body = m.Groups["body"].Value;
                if (!body.Contains("field=\"-2\"", StringComparison.Ordinal)
                    && !body.Contains("field=\"4294967294\"", StringComparison.Ordinal))
                    return m.Value;

                var id = body.Contains("type=\"button\"", StringComparison.OrdinalIgnoreCase)
                    ? dxfs.WhiteId
                    : dxfs.MintId;
                return $"<format dxfId=\"{id}\">{body}</format>";
            },
            RegexOptions.IgnoreCase);
    }

    /// <summary>
    /// Colours the blank top-left corner, which no ClosedXML format covers.
    /// </summary>
    private static string AddHeaderAreas(string xml, PivotHeaderDxfs? dxfs)
    {
        if (dxfs is null)
            return xml;

        var added = new StringBuilder();
        if (!xml.Contains("type=\"origin\"", StringComparison.OrdinalIgnoreCase))
        {
            added.Append($"<format dxfId=\"{dxfs.MintId}\">")
                 .Append("<pivotArea type=\"origin\" dataOnly=\"0\" outline=\"0\" />")
                 .Append("</format>");
        }

        // The stretch of the field-button row past the last button.
        if (!xml.Contains("type=\"topRight\"", StringComparison.OrdinalIgnoreCase))
        {
            added.Append($"<format dxfId=\"{dxfs.WhiteId}\">")
                 .Append("<pivotArea type=\"topRight\" dataOnly=\"0\" outline=\"0\" />")
                 .Append("</format>");
        }

        if (added.Length == 0)
            return xml;

        var formats = Regex.Match(xml, @"<formats\s+count=""(\d+)""\s*>", RegexOptions.IgnoreCase);
        if (formats.Success)
        {
            var count = int.Parse(formats.Groups[1].Value) + CountFormats(added);
            xml = xml.Remove(formats.Index, formats.Length)
                     .Insert(formats.Index, $"<formats count=\"{count}\">");
            var close = xml.IndexOf("</formats>", StringComparison.OrdinalIgnoreCase);
            return close < 0 ? xml : xml.Insert(close, added.ToString());
        }

        // No formats element yet. It must sit after dataFields and before
        // pivotTableStyleInfo, or the part fails schema validation.
        var anchor = xml.IndexOf("<pivotTableStyleInfo", StringComparison.OrdinalIgnoreCase);
        if (anchor < 0)
            return xml;
        var block = $"<formats count=\"{CountFormats(added)}\">{added}</formats>";
        return xml.Insert(anchor, block);
    }

    private static int CountFormats(StringBuilder sb)
    {
        return Regex.Matches(sb.ToString(), "<format ", RegexOptions.IgnoreCase).Count;
    }

    /// <summary>
    /// ClosedXML writes differential fills as patternType="solid" with
    /// fgColor auto="1" and the real color in bgColor. A solid pattern paints
    /// with fgColor, so Excel renders those pivot headers black. Copy the color
    /// onto fgColor. Only fills that are already painting "auto" are touched.
    /// </summary>
    private static string RepairSolidDifferentialFills(string xml)
    {
        return Regex.Replace(
            xml,
            @"(<(?:\w+:)?patternFill\b[^>]*patternType=""solid""[^>]*>\s*<(?:\w+:)?fgColor\b)\s+auto=""1""(\s*/>\s*<(?:\w+:)?bgColor\b[^>]*\brgb=""([0-9A-Fa-f]{6,8})"")",
            m => $"{m.Groups[1].Value} rgb=\"{m.Groups[3].Value}\"{m.Groups[2].Value}",
            RegexOptions.IgnoreCase);
    }

    private static string RewriteOffice2013Theme(string xml)
    {
        xml = ReplaceThemeRgb(xml, "dk2", "44546A");
        xml = ReplaceThemeRgb(xml, "lt2", "E7E6E6");
        xml = ReplaceThemeRgb(xml, "accent1", "4472C4");
        xml = ReplaceThemeRgb(xml, "accent2", "ED7D31");
        xml = ReplaceThemeRgb(xml, "accent3", "A5A5A5");
        xml = ReplaceThemeRgb(xml, "accent4", "FFC000");
        xml = ReplaceThemeRgb(xml, "accent5", "5B9BD5");
        xml = ReplaceThemeRgb(xml, "accent6", "70AD47");
        return xml;
    }

    private static string ReplaceThemeRgb(string xml, string part, string hex)
    {
        return Regex.Replace(
            xml,
            $@"(<a:{part}>\s*<a:srgbClr val="")[0-9A-Fa-f]+("")",
            $"${{1}}{hex}${{2}}",
            RegexOptions.IgnoreCase);
    }

    private static byte[] ReadEntry(ZipArchiveEntry entry)
    {
        using var src = entry.Open();
        using var ms = new MemoryStream();
        src.CopyTo(ms);
        return ms.ToArray();
    }

    private static void WriteEntry(ZipArchive zip, string name, byte[] data)
    {
        var dest = zip.CreateEntry(name, CompressionLevel.Optimal);
        using var stream = dest.Open();
        stream.Write(data, 0, data.Length);
    }

    private static string FromUtf8(byte[] data)
    {
        var xml = Utf8NoBom.GetString(data);
        if (xml.Length > 0 && xml[0] == '\uFEFF')
            xml = xml[1..];
        return xml;
    }

    private static byte[] ToUtf8(string xml)
    {
        if (xml.Length > 0 && xml[0] == '\uFEFF')
            xml = xml[1..];
        return Utf8NoBom.GetBytes(xml);
    }
}
