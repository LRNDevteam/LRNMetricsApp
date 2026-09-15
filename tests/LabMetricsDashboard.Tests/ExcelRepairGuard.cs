using System;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Validation;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// Guards against the "We found a problem with some content" prompt. Excel
/// repairs a workbook whenever a part fails schema validation, so validate the
/// saved bytes the same way Excel does before shipping a report change.
/// </summary>
internal static class ExcelRepairGuard
{
    public static void AssertOpensWithoutRepair(byte[] workbookBytes)
    {
        using var stream = new MemoryStream(workbookBytes, writable: false);
        using var doc = SpreadsheetDocument.Open(stream, false);

        var validator = new OpenXmlValidator(FileFormatVersions.Office2019);
        var errors = validator.Validate(doc)
            .Select(e => $"[{e.ErrorType}] {e.Description} (part={e.Part?.Uri}, path={e.Path?.XPath})")
            .Take(10)
            .ToList();

        Assert.True(errors.Count == 0, "Excel would repair this workbook:" + Environment.NewLine
            + string.Join(Environment.NewLine, errors));
    }

    /// <summary>
    /// A solid pattern paints with fgColor. ClosedXML leaves fgColor auto="1"
    /// and puts the header color in bgColor, which Excel renders black.
    /// </summary>
    public static void AssertDifferentialFillsAreNotAuto(string stylesXml, string expectedHeaderRgb)
    {
        var dxfs = Regex.Match(stylesXml, @"<(?:\w+:)?dxfs\b[\s\S]*?</(?:\w+:)?dxfs>");
        if (!dxfs.Success)
            return;

        Assert.DoesNotContain("auto=\"1\"", dxfs.Value, StringComparison.Ordinal);
        Assert.Contains($"fgColor rgb=\"FF{expectedHeaderRgb}\"", dxfs.Value, StringComparison.OrdinalIgnoreCase);
    }
}
