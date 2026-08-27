using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// Guards the CPT / Panel export row count.
///
/// The export used to route through the public GetCptAsync, which normalises against
/// MaxPageSize (1,000). It set PageSize to the export cap first, but the clamp pulled it
/// straight back down, so every export — filtered or not — silently stopped at 1,000 rows
/// and looked like a complete file.
///
/// The cap itself was the second half of the same bug: at 100,000 it cut a ~300k-row
/// whole-table extract to a third, again without any sign in the workbook. It is now Excel's
/// own sheet limit, so the only thing that shortens an export is a filter.
/// </summary>
public class CptLookupExportPagingTests
{
    [Fact]
    public void Ui_page_requests_are_clamped_to_the_page_limit()
    {
        var q = new LookupQuery { Page = 1, PageSize = 100_000 };
        SqlCptLookupRepository.Normalise(q, SqlCptLookupRepository.MaxPageSize);
        Assert.Equal(SqlCptLookupRepository.MaxPageSize, q.PageSize);
    }

    [Fact]
    public void Export_requests_keep_the_full_export_cap()
    {
        // This is the regression: normalising against the export cap rather than the page
        // limit is what lets an export return more than 1,000 rows.
        var q = new LookupQuery { Page = 1, PageSize = SqlCptLookupRepository.MaxExportRows };
        SqlCptLookupRepository.Normalise(q, SqlCptLookupRepository.MaxExportRows);
        Assert.Equal(SqlCptLookupRepository.MaxExportRows, q.PageSize);
    }

    [Fact]
    public void The_export_cap_is_far_above_the_ui_page_limit()
    {
        // If these ever converge, exports are truncated again and the tests above still pass.
        Assert.True(SqlCptLookupRepository.MaxExportRows > SqlCptLookupRepository.MaxPageSize,
            "Export cap must exceed the UI page limit, or exports truncate at one page.");
    }

    [Fact]
    public void The_export_cap_is_excels_sheet_limit_not_a_policy_number()
    {
        // 1,048,576 rows per sheet, one of them the header. Above this the workbook cannot be
        // written; below it the cap starts silently dropping rows off the end of a full extract
        // (CPTAverage / PanelAverage are ~300k rows, which the old 100,000 cap cut to a third).
        Assert.Equal(1_048_575, SqlCptLookupRepository.MaxExportRows);
    }

    [Fact]
    public void The_export_cap_clears_a_full_table_extract()
    {
        // The tables the export reads are in the hundreds of thousands of rows; a cap at or below
        // that truncates every unfiltered export into a file that still looks complete.
        Assert.True(SqlCptLookupRepository.MaxExportRows > 300_000,
            "Export cap must clear a whole-table extract, or unfiltered exports truncate silently.");
    }

    [Theory]
    [InlineData(0, 50)]       // unset falls back to the default page
    [InlineData(-5, 50)]
    [InlineData(3, 10)]       // below the floor
    [InlineData(250, 250)]    // untouched inside the range
    public void Page_size_normalisation_handles_the_edges(int requested, int expected)
    {
        var q = new LookupQuery { Page = 1, PageSize = requested };
        SqlCptLookupRepository.Normalise(q, SqlCptLookupRepository.MaxPageSize);
        Assert.Equal(expected, q.PageSize);
    }

    [Fact]
    public void Page_number_is_never_below_one()
    {
        var q = new LookupQuery { Page = 0, PageSize = 50 };
        SqlCptLookupRepository.Normalise(q, SqlCptLookupRepository.MaxPageSize);
        Assert.Equal(1, q.Page);
    }
}
