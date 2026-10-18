using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using LabMetricsDashboard.Services;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>Master Values > Fees Schedule Import: reading the CMS fee schedule and its variants.</summary>
public class FeeScheduleWorkbookTests
{
    /// <summary>The file the business supplied (docs/ClinicalLaboratoryFeeSchedule_2026_Q1V1.xls), a legacy .xls.</summary>
    [Fact]
    public void The_CMS_2026_Q1_fee_schedule_xls_is_read_as_published()
    {
        var path = FindDocsFile("ClinicalLaboratoryFeeSchedule_2026_Q1V1.xls");
        if (path is null) return;   // docs not present on this machine

        using var stream = File.OpenRead(path);
        var import = FeeScheduleWorkbook.Read(stream, Path.GetFileName(path));

        Assert.Null(import.Error);
        Assert.Equal(2038, import.Rows.Count);          // 2,162 rows, 124 of them the same code again with modifier QW
        Assert.Equal(124, import.DuplicateRows);
        Assert.Empty(import.ConflictingRates);          // QW rows carry the code's own rate
        Assert.Empty(import.InvalidRates);

        var cmp = Assert.Single(import.Rows, r => r.Hcpcs == "80053");   // numeric HCPCS cell, no ".0"
        Assert.Equal(10.56m, cmp.Rate);
        Assert.Null(cmp.Modifier);                      // the base row wins over the QW row
        Assert.Equal(new DateTime(2026, 1, 1), cmp.EffectiveDate);
        Assert.Equal(2026, cmp.FeeYear);

        Assert.Equal(720m, Assert.Single(import.Rows, r => r.Hcpcs == "0001U").Rate);
        Assert.Equal(114.43m, Assert.Single(import.Rows, r => r.Hcpcs == "G0480").Rate);
    }

    [Fact]
    public void Header_row_is_found_below_a_title_and_matched_by_name()
    {
        var rows = new List<object?[]>
        {
            new object?[] { "Clinical Laboratory Fee Schedule - 2026 Q1", null, null },
            new object?[] { null, null, null },
            new object?[] { "Short Desc", "Rate", "hcpcs", "Mod" },
            new object?[] { "Comprehensive metabolic", 10.56d, 80053d, null },
            new object?[] { "Drug test", "$62.14", "80307", null },
        };

        var import = FeeScheduleWorkbook.ReadSheet(rows, "Sheet1");

        Assert.NotNull(import);
        Assert.Null(import!.Error);
        Assert.Equal(new[] { "80053", "80307" }, import.Rows.Select(r => r.Hcpcs));
        Assert.Equal(62.14m, import.Rows[1].Rate);
        Assert.Equal("Comprehensive metabolic", import.Rows[0].ShortDescription);
    }

    [Fact]
    public void A_sheet_without_HCPCS_and_RATE_is_not_a_fee_schedule()
    {
        var rows = new List<object?[]> { new object?[] { "CPT", "Description" }, new object?[] { "80053", "x" } };
        // "CPT" alone is a code column, but there is no rate column.
        Assert.Null(FeeScheduleWorkbook.ReadSheet(rows, "Sheet1"));
    }

    [Fact]
    public void Repeated_code_keeps_the_row_without_a_modifier_and_reports_different_rates()
    {
        var rows = new List<object?[]>
        {
            new object?[] { "HCPCS", "MOD", "RATE" },
            new object?[] { "87635", "QW", 40d },     // modifier row first
            new object?[] { "87635", null, 51.31d },  // base row: wins
            new object?[] { "87635", "QW", 51.31d },
        };

        var import = FeeScheduleWorkbook.ReadSheet(rows, null)!;

        var row = Assert.Single(import.Rows);
        Assert.Equal(51.31m, row.Rate);
        Assert.Null(row.Modifier);
        Assert.Equal(2, import.DuplicateRows);
        Assert.Equal(new[] { "87635" }, import.ConflictingRates);
    }

    [Fact]
    public void Rows_with_no_or_a_bad_rate_are_skipped_and_reported_but_zero_is_a_rate()
    {
        var rows = new List<object?[]>
        {
            new object?[] { "HCPCS", "RATE" },
            new object?[] { "81479", 0d },        // CLFS "L" (locally priced) codes are 0: kept
            new object?[] { "80000", null },
            new object?[] { "80001", "n/a" },
            new object?[] { "80002", -5d },
            new object?[] { null, 12d },          // a rate with no code
            new object?[] { null, null },         // a fully empty row is not reported
        };

        var import = FeeScheduleWorkbook.ReadSheet(rows, null)!;

        Assert.Equal(new[] { "81479" }, import.Rows.Select(r => r.Hcpcs));
        Assert.Equal(0m, import.Rows[0].Rate);
        Assert.Equal(3, import.InvalidRates.Count);
        Assert.Equal(1, import.BlankHcpcsRows);
    }

    [Fact]
    public void Nothing_usable_is_an_error_so_the_schedule_is_not_wiped()
    {
        var rows = new List<object?[]> { new object?[] { "HCPCS", "RATE" }, new object?[] { "80053", "abc" } };
        Assert.NotNull(FeeScheduleWorkbook.ReadSheet(rows, null)!.Error);
    }

    [Fact]
    public void A_csv_with_the_same_columns_imports()
    {
        var csv = "YEAR,HCPCS,MOD,EFF_DATE,INDICATOR,RATE,SHORTDESC\n2026,80053,,20260101,N,10.56,Comprehen metabolic panel\n2026,80053,QW,20260101,N,10.56,Comprehen metabolic panel\n";
        using var stream = new MemoryStream(Encoding.UTF8.GetBytes(csv));

        var import = FeeScheduleWorkbook.Read(stream, "schedule.csv");

        Assert.Null(import.Error);
        var row = Assert.Single(import.Rows);
        Assert.Equal("80053", row.Hcpcs);
        Assert.Equal(10.56m, row.Rate);
        Assert.Equal(new DateTime(2026, 1, 1), row.EffectiveDate);
        Assert.Equal(1, import.DuplicateRows);
    }

    private static string? FindDocsFile(string name)
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "docs", name);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}
