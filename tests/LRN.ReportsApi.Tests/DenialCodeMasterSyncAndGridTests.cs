using System.IO;
using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// Denial Code Master grid sorting (server-side whitelist) and Denial-Action Super Master Excel
/// template/export shape, plus the "Sync Now" result model. These cover the pure, DB-free logic
/// added for the Denial Workflow requirements v1.1 pass; the SQL-heavy repository methods
/// (ConfirmPushSelectedAsync, SyncLabActionsAsync) need a real lab database and are exercised
/// manually against a lower environment instead - see the plan doc's Phase 3 verification notes.
/// </summary>
public class DenialCodeMasterGridSortingTests
{
    [Theory]
    [InlineData(null, null)]
    [InlineData("", "asc")]
    [InlineData("bogusColumn; DROP TABLE DenialCodeMaster;--", "asc")]
    [InlineData("notAColumn", "desc")]
    public void BuildOrderBy_falls_back_to_the_default_sort_for_anything_not_whitelisted(string? sortBy, string? sortDir)
    {
        var sql = SqlDenialCodeMasterRepository.BuildOrderBy(sortBy, sortDir);
        Assert.Equal("DenialCode, CoverageStatus, ICDComplianceStatus", sql);
    }

    [Theory]
    [InlineData("denialCode", "asc", "DenialCode ASC")]
    [InlineData("DENIALCODE", "ASC", "DenialCode ASC")]
    [InlineData("actionCategory", "desc", "ActionCategory DESC")]
    [InlineData("actionCode", "DESC", "ActionCode DESC")]
    [InlineData("coverageStatus", "asc", "CoverageStatus ASC")]
    [InlineData("icdComplianceStatus", "asc", "ICDComplianceStatus ASC")]
    [InlineData("denialClassification", "asc", "DenialClassification ASC")]
    [InlineData("priority", "asc", "Priority ASC")]
    [InlineData("updatedOn", "desc", "UpdatedOn DESC")]
    public void BuildOrderBy_maps_whitelisted_columns_case_insensitively(string sortBy, string sortDir, string expectedPrefix)
    {
        var sql = SqlDenialCodeMasterRepository.BuildOrderBy(sortBy, sortDir);
        Assert.StartsWith(expectedPrefix, sql);
        Assert.EndsWith("DenialCode, CoverageStatus, ICDComplianceStatus", sql);
    }

    [Fact]
    public void BuildOrderBy_defaults_direction_to_ascending_for_an_unrecognized_direction()
    {
        var sql = SqlDenialCodeMasterRepository.BuildOrderBy("priority", "sideways");
        Assert.StartsWith("Priority ASC", sql);
    }
}

public class DenialMapperSuperMasterExcelTests
{
    private static readonly string[] ExpectedHeaders =
    [
        "Denial Code", "Denial Description", "Denial Classification", "Coverage Status", "ICD Compliance Status",
        "Denial Validity", "Action Code", "Recommended Action", "Action Category", "Task", "SLA (Days)", "Priority"
    ];

    // BuildImportTemplate() never touches the repository, so a null one is safe here - only
    // ExportAsync (not exercised by these tests) needs a real IDenialMapperRepository.
    private static DenialMapperExcelService Service() => new(null!);

    [Fact]
    public void Template_headers_match_what_ImportSuperMasterAsync_recognizes()
    {
        var bytes = Service().BuildImportTemplate();
        using var workbook = new XLWorkbook(new MemoryStream(bytes));
        var sheet = workbook.Worksheets.First();

        for (var i = 0; i < ExpectedHeaders.Length; i++)
            Assert.Equal(ExpectedHeaders[i], sheet.Cell(2, i + 1).GetString());
    }

    [Fact]
    public void Template_sample_row_has_a_denial_code_and_action_code_so_it_round_trips_through_import()
    {
        var bytes = Service().BuildImportTemplate();
        using var workbook = new XLWorkbook(new MemoryStream(bytes));
        var sheet = workbook.Worksheets.First();

        var denialCodeColumn = Array.IndexOf(ExpectedHeaders, "Denial Code") + 1;
        var actionCodeColumn = Array.IndexOf(ExpectedHeaders, "Action Code") + 1;
        Assert.False(string.IsNullOrWhiteSpace(sheet.Cell(3, denialCodeColumn).GetString()));
        Assert.False(string.IsNullOrWhiteSpace(sheet.Cell(3, actionCodeColumn).GetString()));
    }

    [Fact]
    public void Denial_description_column_is_widened_beyond_the_grid_default()
    {
        var bytes = Service().BuildImportTemplate();
        using var workbook = new XLWorkbook(new MemoryStream(bytes));
        var sheet = workbook.Worksheets.First();

        var descriptionColumn = Array.IndexOf(ExpectedHeaders, "Denial Description") + 1;
        Assert.True(sheet.Column(descriptionColumn).Width >= 45,
            $"Denial Description column should be at least 45 wide, was {sheet.Column(descriptionColumn).Width}.");
    }
}

public class DenialCodeSyncResultTests
{
    [Theory]
    [InlineData(null, false)]
    [InlineData(0L, false)]
    [InlineData(5L, true)]
    public void HasActionChangeWarnings_is_true_only_when_a_verification_batch_was_created(long? batchId, bool expected)
    {
        var result = new DenialCodeSyncResult { BatchId = batchId };
        Assert.Equal(expected, result.HasActionChangeWarnings);
    }
}
