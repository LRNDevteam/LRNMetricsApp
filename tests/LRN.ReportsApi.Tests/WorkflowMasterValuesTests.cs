using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Microsoft.SqlServer.TransactSql.ScriptDom;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class WorkflowMasterValueRulesTests
{
    private static WorkflowMasterType Type(string key) => WorkflowMasterValueRules.Find(key)!;

    private static WorkflowMasterValidation Validate(string key, string? value, string? actionCode = null, int? sortOrder = null) =>
        WorkflowMasterValueRules.Validate(Type(key), new WorkflowMasterValueSaveRequest { Value = value, ActionCode = actionCode, SortOrder = sortOrder });

    [Fact]
    public void Catalogue_is_exactly_the_seven_lists_under_their_stored_keys()
    {
        // The keys are rows in dbo.DenialMapperLookupMaster and what the Denial Mapper reads —
        // renaming one here would orphan every value stored under the old key.
        Assert.Equal(
            ["DenialClassification", "CoverageStatus", "ICDComplianceStatus", "DenialValidity", "ActionCategory", "SLADays", "Priority"],
            WorkflowMasterValueRules.Types.Select(t => t.Key));
        Assert.Equal(
            ["Classification", "Coverage Status", "ICD Compliance", "Denial Validity", "Action Category", "SLA", "Priority"],
            WorkflowMasterValueRules.Types.Select(t => t.Label));
        Assert.Single(WorkflowMasterValueRules.Types, t => t.IsActionCategory);
    }

    [Theory]
    [InlineData("coveragestatus", "CoverageStatus")]
    [InlineData(" SLADays ", "SLADays")]
    public void Find_ignores_case_and_padding(string input, string expected) =>
        Assert.Equal(expected, WorkflowMasterValueRules.Find(input)?.Key);

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("LabName")]
    public void Find_returns_null_for_anything_else(string? input) =>
        Assert.Null(WorkflowMasterValueRules.Find(input));

    [Theory]
    [InlineData("Non Covered", "Non-Covered")]
    [InlineData("non-covered", "NON COVERED")]
    [InlineData("  Conditional - Note  ", "Conditional-Note")]
    [InlineData("Client Info Pending / Write Off", "ClientInfoPendingWriteOff")]
    public void Normalize_treats_spacing_hyphen_and_slash_variants_as_one_value(string a, string b) =>
        Assert.Equal(WorkflowMasterValueRules.Normalize(a), WorkflowMasterValueRules.Normalize(b));

    [Fact]
    public void Normalize_still_tells_genuinely_different_values_apart() =>
        Assert.NotEqual(WorkflowMasterValueRules.Normalize("Conditional - Note"), WorkflowMasterValueRules.Normalize("Conditional - Note & Dx"));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void Value_is_required(string? value) =>
        Assert.NotNull(Validate("Priority", value).Error);

    [Fact]
    public void Value_is_trimmed() =>
        Assert.Equal("Urgent", Validate("Priority", "  Urgent ").Result!.Value);

    [Fact]
    public void Line_breaks_are_rejected() =>
        Assert.NotNull(Validate("DenialValidity", "Valid\r\nper policy").Error);

    [Theory]
    [InlineData("7", "7 days")]
    [InlineData("7 days", "7 days")]
    [InlineData("7days", "7 days")]
    [InlineData("7 Day", "7 days")]
    [InlineData("1", "1 day")]
    [InlineData("1 days", "1 day")]
    [InlineData("0 days", "0 days")]
    public void Sla_is_stored_as_a_day_count(string input, string expected) =>
        Assert.Equal(expected, Validate("SLADays", input).Result!.Value);

    [Theory]
    [InlineData("one week")]
    [InlineData("7 business days")]
    [InlineData("-5 days")]
    [InlineData("1000 days")]
    [InlineData("2 weeks")]
    public void Sla_that_is_not_a_day_count_is_rejected(string input) =>
        Assert.NotNull(Validate("SLADays", input).Error);

    [Fact]
    public void Value_length_is_capped_at_the_super_master_column_width()
    {
        // DenialMapperSuperMaster: DenialClassification nvarchar(100), Priority nvarchar(50).
        // A longer master value could be picked in the mapper and then fail to save there.
        Assert.Null(Validate("DenialClassification", new string('x', 100)).Error);
        Assert.NotNull(Validate("DenialClassification", new string('x', 101)).Error);
        Assert.Null(Validate("Priority", new string('x', 50)).Error);
        Assert.NotNull(Validate("Priority", new string('x', 51)).Error);
    }

    [Fact]
    public void Action_category_requires_an_action_code()
    {
        Assert.NotNull(Validate("ActionCategory", "Appeal", actionCode: null).Error);
        Assert.NotNull(Validate("ActionCategory", "Appeal", actionCode: "  ").Error);
        Assert.Equal("APP", Validate("ActionCategory", "Appeal", actionCode: " APP ").Result!.ActionCode);
    }

    [Fact]
    public void Action_code_is_ignored_for_every_other_list() =>
        Assert.Null(Validate("Priority", "High", actionCode: "APP").Result!.ActionCode);

    [Theory]
    [InlineData(-1)]
    [InlineData(WorkflowMasterValueRules.MaxSortOrder + 1)]
    public void Sort_order_out_of_range_is_rejected(int sortOrder) =>
        Assert.NotNull(Validate("Priority", "High", sortOrder: sortOrder).Error);

    [Fact]
    public void Omitted_sort_order_is_left_for_the_repository_to_assign() =>
        Assert.Null(Validate("Priority", "High").Result!.SortOrder);
}

public class WorkflowMasterValuesSqlTests
{
    [Fact]
    public void Seed_never_overwrites_existing_values()
    {
        // Regression guard. The seed used to MERGE with WHEN MATCHED ... IsActive=1 on every Denial
        // Mapper load, which silently undid every deactivation, re-sort and rename an admin made.
        var seed = SqlDenialMapperRepository.MasterDataSeedSql;
        Assert.DoesNotContain("MERGE", seed, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("UPDATE", seed, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("IF NOT EXISTS (SELECT 1 FROM dbo.DenialMapperLookupMaster)", seed);
        Assert.Contains("IF NOT EXISTS (SELECT 1 FROM dbo.DenialMapperActionCategoryMaster)", seed);
    }

    [Fact]
    public void Schema_batch_adds_columns_but_writes_no_rows()
    {
        // The INSERTs name CreatedBy, which the schema batch adds. SQL Server binds column names per
        // batch, so if the INSERTs moved into this batch they would fail on every existing database.
        var schema = SqlDenialMapperRepository.MasterDataSchemaSql;
        Assert.Contains("ADD CreatedBy", schema);
        Assert.DoesNotContain("INSERT", schema, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Runtime_batches_parse()
    {
        AssertNoParseErrors(SqlDenialMapperRepository.MasterDataSchemaSql, "master data schema batch");
        AssertNoParseErrors(SqlDenialMapperRepository.MasterDataSeedSql, "master data seed batch");
        AssertNoParseErrors(SqlWorkflowMasterValuesRepository.AllUsageSql, "usage aggregate");
    }

    [Fact]
    public void Dba_setup_script_parses_and_seeds_in_a_later_batch_than_the_columns_it_uses()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Sql", "DenialWorkflow_MasterValues_Setup.sql");
        Assert.True(File.Exists(path), $"Master values setup script was not copied to the test output: {path}");
        var sql = File.ReadAllText(path);

        var script = AssertNoParseErrors(sql, "Sql/DenialWorkflow_MasterValues_Setup.sql");
        var batches = script.Batches.Select(b => sql.Substring(b.StartOffset, b.FragmentLength)).ToList();

        var alterBatch = batches.FindIndex(b => b.Contains("ADD CreatedBy", StringComparison.OrdinalIgnoreCase));
        var seedBatch = batches.FindIndex(b => b.Contains("INSERT dbo.DenialMapperLookupMaster", StringComparison.OrdinalIgnoreCase));
        Assert.True(alterBatch >= 0 && seedBatch >= 0, "Expected both the audit-column batch and the seed batch.");
        Assert.True(seedBatch > alterBatch, "The seed must run in a batch after the one that adds CreatedBy.");

        Assert.DoesNotContain("MERGE", sql.Split("*/", 2)[1], StringComparison.OrdinalIgnoreCase);
    }

    private static TSqlScript AssertNoParseErrors(string sql, string context)
    {
        var parser = new TSql160Parser(initialQuotedIdentifiers: true);
        using var reader = new StringReader(sql);
        var fragment = parser.Parse(reader, out var errors);
        Assert.True(
            errors.Count == 0,
            $"T-SQL failed to parse ({context}): " + string.Join(" | ", errors.Select(e => $"line {e.Line}: {e.Message}")));
        return (TSqlScript)fragment;
    }
}
