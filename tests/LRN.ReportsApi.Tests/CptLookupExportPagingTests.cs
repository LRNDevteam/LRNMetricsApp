using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// Guards the CPT / Panel export row count.
///
/// The export used to route through the public GetCptAsync, which normalises against
/// MaxPageSize (1,000). It set PageSize to the 100,000-row export cap first, but the clamp
/// pulled it straight back down, so every export — filtered or not — silently stopped at
/// 1,000 rows and looked like a complete file.
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
        Assert.Equal(100_000, SqlCptLookupRepository.MaxExportRows);
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
