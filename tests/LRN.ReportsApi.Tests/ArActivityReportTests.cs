using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArReports;
using Microsoft.SqlServer.TransactSql.ScriptDom;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// RPT-01 — AR Follow-up Activity Detail.
///
/// The report's SQL is assembled in C# from per-lab column probes, so a schema variant that is not
/// present on any developer machine can still produce a batch that only fails in production. These
/// tests parse the generated batch with the real T-SQL parser for every combination that matters,
/// and pin the filter/window rules the spec is explicit about.
///
/// No database is touched: parsing proves the batch is well-formed T-SQL, not that the data is
/// right. Column/type correctness still needs the run against a real lab described in the AR
/// reports readiness doc.
/// </summary>
public class ArActivityReportTests
{
    // ============================================================================
    // Generated SQL must parse — across every schema-drift combination
    // ============================================================================

    /// <summary>Every column the report probes for, present. The fully migrated lab.</summary>
    private static SqlArActivityReportRepository.ArReportSchema FullSchema() => new(
        Task: Set("ClaimID", "ClaimIDNormalized", "CPTCode", "ClaimUID", "PayerName", "DenialCode",
                  "DenialDescription", "DenialClassification", "ActionCategory", "Task", "Status",
                  "WorkFlowStatus", "AssignedTo", "AssignedOn", "ReviewerUpdatedBy", "Priority",
                  "DateOfService", "InsuranceBalance", "ActionCompleted", "DateCompleted", "RunId",
                  "TaskID", "LabId", "CreatedOn"),
        Line: Set("LabId", "ClaimUID", "AccessionNo", "BilledAmount", "CPTCode"),
        Note: Set("NoteId", "LabId", "ClaimId", "ClaimIdNormalized", "TaskId", "CptCode", "NoteText",
                  "Status", "NextFollowUpDate", "FollowUpReason", "CreatedBy", "CreatedOn", "IsDeleted",
                  "UpdateSource", "UploadBatchId", "ContactMethod", "FollowUpCategory", "BalanceSnapshot",
                  "IsInternalOnly"),
        History: Set("HistoryId", "TaskID", "UniqueTrackId", "LabId", "RunId", "ActionType", "OldStatus",
                     "NewStatus", "OldAssignedTo", "NewAssignedTo", "Comments", "ActionBy", "ActionDate",
                     "UpdateSource", "UploadBatchId", "ContactMethod", "BalanceSnapshot"),
        Escalation: Set("EscalationId", "LabId", "ClaimId", "ClaimIdNormalized", "TaskId", "CptCode",
                        "EscalationLevel", "EscalationReason", "Comments", "Status", "EscalatedTo",
                        "EscalatedToRole", "NextFollowUpDate", "CreatedBy", "CreatedOn", "IsDeleted",
                        "UpdateSource", "UploadBatchId", "BalanceSnapshot"));

    /// <summary>
    /// The oldest lab in the estate: no AR-report columns, no persisted normalized claim keys, no
    /// ClaimUID to reach the line item, no Task column. Every fallback path fires at once.
    /// </summary>
    private static SqlArActivityReportRepository.ArReportSchema MinimalSchema() => new(
        Task: Set("ClaimID", "CPTCode", "PayerName", "DenialCode", "DenialDescription",
                  "DenialClassification", "ActionCategory", "Status", "AssignedTo", "InsuranceBalance",
                  "TaskID", "LabId"),
        Line: Set("LabId"),
        Note: Set("NoteId", "LabId", "ClaimId", "TaskId", "CptCode", "NoteText", "Status",
                  "NextFollowUpDate", "CreatedBy", "CreatedOn", "IsDeleted"),
        History: Set("HistoryId", "TaskID", "LabId", "RunId", "ActionType", "OldStatus", "NewStatus",
                     "Comments", "ActionBy", "ActionDate"),
        Escalation: Set("EscalationId", "LabId", "ClaimId", "TaskId", "CptCode", "EscalationReason",
                        "Comments", "Status", "CreatedBy", "CreatedOn", "IsDeleted"));

    private static HashSet<string> Set(params string[] names) => new(names, StringComparer.OrdinalIgnoreCase);

    private static ArActivityReportFilter BaseFilter() => new()
    {
        LabId = 19,
        FromDate = new DateTime(2026, 8, 28),
        ToDate = new DateTime(2026, 9, 4),
        AsOf = new DateTime(2026, 9, 3, 8, 42, 0)
    };

    public static TheoryData<string, bool, string, string[]?> SqlVariants() => new()
    {
        // grain, latestOnly, groupBy, analyst scope
        { "Claim", false, "none",         null },
        { "Claim", true,  "none",         null },
        { "Line",  false, "none",         null },
        { "Line",  true,  "analyst",      null },
        { "Claim", false, "classification", null },
        { "Claim", false, "action",       null },
        { "Claim", false, "payer",        null },
        { "Claim", false, "activityType", null },
        { "Claim", false, "none",         new[] { "anita.rao", "daniel.kim" } }
    };

    [Theory]
    [MemberData(nameof(SqlVariants))]
    public void GeneratedSql_Parses_OnAFullyMigratedLab(string grain, bool latestOnly, string groupBy, string[]? scope)
        => AssertParses(FullSchema(), grain, latestOnly, groupBy, scope);

    [Theory]
    [MemberData(nameof(SqlVariants))]
    public void GeneratedSql_Parses_WhenEveryOptionalColumnIsMissing(string grain, bool latestOnly, string groupBy, string[]? scope)
        => AssertParses(MinimalSchema(), grain, latestOnly, groupBy, scope);

    private static void AssertParses(SqlArActivityReportRepository.ArReportSchema schema, string grain, bool latestOnly, string groupBy, string[]? scope)
    {
        var filter = BaseFilter();
        filter.Grain = grain;
        filter.LatestOnly = latestOnly;
        filter.GroupBy = groupBy;
        SqlArActivityReportRepository.Normalize(filter);

        var sql = SqlArActivityReportRepository.BuildActivitySql(filter, schema, scope);
        AssertNoParseErrors(sql, $"grain={grain} latestOnly={latestOnly} groupBy={groupBy} scope={(scope is null ? "none" : "set")}");
    }

    [Fact]
    public void RuntimeSchemaBatches_Parse()
    {
        AssertNoParseErrors(SqlArActivityReportRepository.SchemaBatchColumnsAndTables, "schema batch 1");
        AssertNoParseErrors(SqlArActivityReportRepository.SchemaBatchCatalogSeed, "schema batch 2 (catalog seed)");
    }

    /// <summary>
    /// The checked-in DBA script is what a DBA runs in a maintenance window, where a typo is
    /// expensive. Parse it here so it cannot drift out of valid T-SQL unnoticed.
    /// </summary>
    [Fact]
    public void DbaSetupScript_Parses()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Sql", "RPT01_ActivityDetail_Setup.sql");
        Assert.True(File.Exists(path), $"RPT-01 setup script was not copied to the test output: {path}");
        AssertNoParseErrors(File.ReadAllText(path), "Sql/ArReports/RPT01_ActivityDetail_Setup.sql");
    }

    private static void AssertNoParseErrors(string sql, string context)
    {
        var parser = new TSql160Parser(initialQuotedIdentifiers: true);
        using var reader = new StringReader(sql);
        parser.Parse(reader, out var errors);
        Assert.True(
            errors.Count == 0,
            $"Generated T-SQL failed to parse ({context}): " +
            string.Join(" | ", errors.Select(e => $"line {e.Line}: {e.Message}")));
    }

    /// <summary>
    /// The escalation source is authoritative for a raise, so the history rows the same escalation
    /// writes (one per affected task) must never reach the spine — otherwise "escalations raised"
    /// inflates on every multi-line claim.
    /// </summary>
    [Fact]
    public void GeneratedSql_ExcludesEscalationHistoryRowsFromTheSpine()
    {
        var filter = BaseFilter();
        SqlArActivityReportRepository.Normalize(filter);
        var sql = SqlArActivityReportRepository.BuildActivitySql(filter, FullSchema(), null);

        Assert.Contains("LOWER(LTRIM(RTRIM(ISNULL(h.ActionType,'')))) <> 'escalation'", sql);
        Assert.Contains("FROM dbo.DenialClaimEscalations e WITH (NOLOCK)", sql);
    }

    /// <summary>
    /// Balance worked is summed once per claim/analyst/activity date. Summing the per-row balance
    /// would re-add the same claim balance for every note on it — the inflation spec 3.1 forbids.
    /// </summary>
    [Fact]
    public void GeneratedSql_AggregatesBalanceOncePerClaimDay()
    {
        var filter = BaseFilter();
        SqlArActivityReportRepository.Normalize(filter);
        var sql = SqlArActivityReportRepository.BuildActivitySql(filter, FullSchema(), null);

        Assert.Contains("GROUP BY ClaimKey, Author, ActivityDateKey", sql);
        Assert.DoesNotContain("BalanceWorked = SUM(BalanceSnapshot)", sql);
    }

    // ============================================================================
    // Activity window
    // ============================================================================

    [Fact]
    public void Normalize_TurnsAnInclusiveEndDateIntoAnExclusiveUpperBound()
    {
        // The UI sends a calendar day. A plain "<= @ToDate" would drop every activity recorded
        // after midnight on that day — i.e. almost all of the last day's work.
        var filter = BaseFilter();
        filter.ToDate = new DateTime(2026, 9, 4);
        SqlArActivityReportRepository.Normalize(filter);

        Assert.Equal(new DateTime(2026, 9, 5), filter.ToDate);
    }

    [Fact]
    public void Normalize_KeepsAnExplicitTimeOnTheUpperBound()
    {
        var filter = BaseFilter();
        filter.ToDate = new DateTime(2026, 9, 4, 17, 30, 0);
        SqlArActivityReportRepository.Normalize(filter);

        Assert.Equal(new DateTime(2026, 9, 4, 17, 30, 0), filter.ToDate);
    }

    [Fact]
    public void Normalize_DefaultsToTheLastSevenDaysOfActivity()
    {
        var filter = new ArActivityReportFilter { LabId = 19, AsOf = new DateTime(2026, 9, 3, 8, 42, 0) };
        SqlArActivityReportRepository.Normalize(filter);

        Assert.Equal(new DateTime(2026, 8, 28), filter.FromDate);
        Assert.Equal(new DateTime(2026, 9, 4), filter.ToDate);
    }

    [Fact]
    public void Normalize_SwapsAnInvertedRangeRatherThanReturningNothing()
    {
        var filter = BaseFilter();
        filter.FromDate = new DateTime(2026, 9, 4);
        filter.ToDate = new DateTime(2026, 8, 28);
        SqlArActivityReportRepository.Normalize(filter);

        Assert.Equal(new DateTime(2026, 8, 28), filter.FromDate);
        Assert.Equal(new DateTime(2026, 9, 5), filter.ToDate);
    }

    [Fact]
    public void Normalize_RejectsAWindowWiderThanAYear()
    {
        var filter = BaseFilter();
        filter.FromDate = new DateTime(2025, 1, 1);
        filter.ToDate = new DateTime(2026, 9, 4);

        var ex = Assert.Throws<InvalidOperationException>(() => SqlArActivityReportRepository.Normalize(filter));
        Assert.Contains("cannot exceed", ex.Message);
    }

    [Fact]
    public void Normalize_RequiresALab()
    {
        var filter = new ArActivityReportFilter { LabId = 0 };
        Assert.Throws<InvalidOperationException>(() => SqlArActivityReportRepository.Normalize(filter));
    }

    // ============================================================================
    // Paging
    // ============================================================================

    [Theory]
    [InlineData(0, 50)]
    [InlineData(10, 25)]      // below the floor
    [InlineData(5000, 200)]   // above the screen ceiling
    [InlineData(100, 100)]
    public void Normalize_ClampsScreenPageSize(int requested, int expected)
    {
        var filter = BaseFilter();
        filter.PageSize = requested;
        SqlArActivityReportRepository.Normalize(filter);
        Assert.Equal(expected, filter.PageSize);
    }

    [Fact]
    public void Normalize_LetsAnExportTakeEveryFilteredRow()
    {
        // A paged export cannot satisfy FR-002: the workbook's reconciliation sheet recomputes the
        // summary from the rows it actually contains.
        var filter = BaseFilter();
        filter.IsExport = true;
        filter.PageSize = 0;
        SqlArActivityReportRepository.Normalize(filter);

        Assert.Equal(SqlArActivityReportRepository.MaxExportRows, filter.PageSize);
    }

    // ============================================================================
    // Role-based visibility (spec 2.6 / 3.1)
    // ============================================================================

    [Theory]
    [InlineData("AR Manager", true)]
    [InlineData("Admin", true)]
    [InlineData("AR Reviewer", true)]
    [InlineData("AR Analyst", true)]
    [InlineData("Client Manager", false)]
    [InlineData("client-manager", false)]
    [InlineData("Account Manager", false)]
    [InlineData("Lab User", false)]
    [InlineData("labuser", false)]
    public void InternalNotes_AreHiddenFromClientFacingRolesOnly(string role, bool visible)
        => Assert.Equal(visible, SqlArActivityReportRepository.InternalNotesVisible(role));
}
