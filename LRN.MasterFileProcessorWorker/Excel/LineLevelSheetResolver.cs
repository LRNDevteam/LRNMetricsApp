using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

/// <summary>
/// Recognises line-level sheets by name and picks the ones to combine.
/// <para>
/// A line-level sheet is "[system] Line Level [period]": the system prefix is optional ("Webpm",
/// "Daq", "Master"), "Line Level" may be written "LineLevel" / "Line_Level", and a lab that splits a
/// large line level into several sheets adds a period after it - "Webpm Linelevel 2026",
/// "Webpm Linelevel 2025", "Line Level 2025-2026", "Line Level Q1", "Line Level Part 2", "Line Level (2)".
/// Every sheet of a split is loaded, and its rows keep the system name (not the period) as Source.
/// Anything else after "Line Level" ("Line Level Summary", "Line Level Pivot") is not line-level data.
/// </para>
/// </summary>
public static class LineLevelSheetResolver
{
	private static readonly Regex SheetPattern = new(
		@"^\s*(?<system>.*?)[\s_\-]*line[\s_\-]*level(?<period>(?:[\s_\-().]*(?:part|sheet|q|h|p)?[\s_\-]*\d+[\s_\-().]*)*)\s*$",
		RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

	/// <summary>True for a line-level sheet, with or without a system prefix and a period suffix.</summary>
	public static bool IsLineLevelSheet(string? sheetName)
		=> !string.IsNullOrWhiteSpace(sheetName) && SheetPattern.IsMatch(sheetName);

	/// <summary>True when the sheet is one part of a line level split by period ("Webpm Linelevel 2026").</summary>
	public static bool HasPeriod(string? sheetName)
	{
		if (string.IsNullOrWhiteSpace(sheetName)) return false;
		var m = SheetPattern.Match(sheetName);
		return m.Success && m.Groups["period"].Value.Any(char.IsDigit);
	}

	/// <summary>
	/// The source system a line-level sheet belongs to: "Webpm Linelevel 2026" -> "Webpm",
	/// "Daq Line Level" -> "Daq", plain "Line Level 2025" -> "". A name that is not a line-level sheet
	/// is returned trimmed.
	/// </summary>
	public static string SystemLabel(string? sheetName)
	{
		var trimmed = (sheetName ?? string.Empty).Trim();
		var m = SheetPattern.Match(trimmed);
		if (!m.Success) return trimmed;
		return m.Groups["system"].Value.Trim().Trim('-', '_').Trim();
	}

	/// <summary>
	/// The line-level sheets to combine, in workbook order. When two or more source systems are
	/// present as prefixed sheets, an unprefixed "Line Level" sheet beside them is ambiguous (usually a
	/// rollup) and is left out; <paramref name="ignored"/> lists it. Every period sheet of a system is kept.
	/// </summary>
	public static List<string> Select(IEnumerable<string> workbookSheets, out List<string> ignored)
	{
		var lineSheets = workbookSheets.Where(IsLineLevelSheet).ToList();
		var prefixed = lineSheets.Where(s => SystemLabel(s).Length > 0).ToList();
		var systems = prefixed.Select(SystemLabel).Distinct(StringComparer.OrdinalIgnoreCase).Count();

		var selected = systems >= 2 ? prefixed : lineSheets;
		ignored = lineSheets.Except(selected).ToList();
		return selected;
	}
}
