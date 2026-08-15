using System;
using System.Collections.Generic;
using System.Linq;
using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace LabMetricsDashboard.Tests;

public class ReportStatusParsingTests
{
    [Theory]
    [InlineData("Success")]
    [InlineData("success")]
    [InlineData("  SUCCESS  ")]
    public void Success_in_any_casing_parses_as_success(string raw)
        => Assert.Equal(ReportRunStatus.Success, ReportBoardController.ParseStatus(raw));

    [Theory]
    [InlineData("Failed")]
    [InlineData("FAILED")]
    public void Failed_parses_as_failed(string raw)
        => Assert.Equal(ReportRunStatus.Failed, ReportBoardController.ParseStatus(raw));

    [Theory]
    [InlineData("Pending")]
    [InlineData("In Progress")]
    [InlineData("InProgress")]
    public void In_flight_values_parse_as_pending(string raw)
        => Assert.Equal(ReportRunStatus.Pending, ReportBoardController.ParseStatus(raw));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("Skipped")]
    [InlineData("something the tracker has never emitted")]
    public void Null_empty_and_unknown_values_parse_as_not_configured(string? raw)
        => Assert.Equal(ReportRunStatus.NotConfigured, ReportBoardController.ParseStatus(raw));
}

public class ReportCatalogTests
{
    // Mapped tracker columns (excludes "Error Log", which is a run artifact hidden from the board).
    private static readonly string[] SpColumnOrder =
    [
        "Line Level Master", "Claim Level Master", "LIS Summary", "Production Summary", "Collection Summary",
        "Denial Report", "Executive Summary", "Clinic Summary", "Sales Rep Summary", "Coding Validation",
        "Payer Policy Validation", "Forecasting", "Prediction Analysis"
    ];

    // "LIMS Master" is an always-on nav tile, present even when the SP does not return it.
    private const int AlwaysOnCount = 1;

    [Fact]
    public void Every_current_tracker_column_is_in_the_catalog()
    {
        foreach (var column in SpColumnOrder)
            Assert.NotNull(ReportCatalog.Find(column));
    }

    [Fact]
    public void Order_returns_catalog_order_not_sp_order()
    {
        var ordered = ReportCatalog.Order(SpColumnOrder);

        // The mapped SP columns plus the always-on LIMS Master nav tile.
        Assert.Equal(SpColumnOrder.Length + AlwaysOnCount, ordered.Count);
        Assert.Contains(ordered, c => c.TrackerColumn == "LIMS Master");
        // The SP emits Denial Report before Executive Summary; the board groups it with the
        // summary reports at the end of that band instead.
        var denial = ordered.FindIndex(c => c.TrackerColumn == "Denial Report");
        var exec = ordered.FindIndex(c => c.TrackerColumn == "Executive Summary");
        Assert.True(exec < denial);
    }

    // Report types that stay in dbo.ReportTypeMaster and keep running — the board just never
    // renders a column for them.
    [Theory]
    [InlineData("Error Log")]
    [InlineData("CPT Averages")]
    [InlineData("Panel Averages")]
    public void Hidden_report_types_are_never_shown_on_the_board(string hidden)
    {
        var ordered = ReportCatalog.Order(["LIS Summary", hidden]);

        Assert.DoesNotContain(ordered, c => c.TrackerColumn.Equals(hidden, StringComparison.OrdinalIgnoreCase));
        Assert.Contains(ordered, c => c.TrackerColumn == "LIS Summary");
    }

    // ReportTypeMaster is hand-maintained, so the hide must survive its spelling.
    [Theory]
    [InlineData("CPTAverages")]
    [InlineData("cpt averages")]
    [InlineData("Panel  Averages")]
    [InlineData("Error_Log")]
    public void Hiding_ignores_spacing_and_casing(string spelling)
    {
        Assert.True(ReportCatalog.IsHidden(spelling));
        Assert.DoesNotContain(ReportCatalog.Order(["LIS Summary", spelling]),
            c => c.TrackerColumn.Equals(spelling, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Real_reports_are_not_hidden()
    {
        Assert.False(ReportCatalog.IsHidden("Collection Summary"));
        Assert.False(ReportCatalog.IsHidden("Coding Validation"));
        Assert.False(ReportCatalog.IsHidden(null));
    }

    [Fact]
    public void Lims_Master_is_an_always_on_nav_tile()
    {
        // Not returned by the SP, but still present as a page shortcut.
        var ordered = ReportCatalog.Order(["LIS Summary"]);

        Assert.Contains(ordered, c => c.TrackerColumn == "LIMS Master");
        Assert.True(ReportCatalog.IsNavShortcut("LIMS Master"));
    }

    [Fact]
    public void An_unknown_column_is_kept_as_a_status_only_column_at_the_end()
    {
        var withNewReport = SpColumnOrder.Append("Cash Posting Summary").ToArray();

        var ordered = ReportCatalog.Order(withNewReport);

        Assert.Equal(withNewReport.Length + AlwaysOnCount, ordered.Count);
        var added = ordered[^1];
        Assert.Equal("Cash Posting Summary", added.TrackerColumn);
        Assert.Null(added.Controller);
        Assert.Null(added.Action);
    }

    [Fact]
    public void Column_lookup_is_case_insensitive()
        => Assert.NotNull(ReportCatalog.Find("collection summary"));

    [Fact]
    public void Every_catalog_route_is_either_complete_or_absent()
    {
        foreach (var entry in ReportCatalog.Entries)
            Assert.Equal(entry.Controller is null, entry.Action is null);
    }
}

public class LabNameResolverTests
{
    /// <summary>The 12 configured labs, keyed exactly as LabSettings keys them.</summary>
    private static readonly string[] ConfigKeys =
    [
        "PCRLabsofAmerica", "Cove", "Inhealth_DTR", "Elixir", "Certus", "Beech_Tree",
        "Augustus_Labs", "NorthWest", "PCR_Dx_AL", "PCR_Dx_CO", "Phi_Life", "Rising_Tides"
    ];

    private static LabNameResolver Build(IDictionary<string, LabCsvConfig>? labs = null)
    {
        var settings = new LabSettings
        {
            Labs = labs is null
                ? ConfigKeys.ToDictionary(k => k, _ => new LabCsvConfig(), StringComparer.OrdinalIgnoreCase)
                : new Dictionary<string, LabCsvConfig>(labs, StringComparer.OrdinalIgnoreCase)
        };
        return new LabNameResolver(settings, NullLogger<LabNameResolver>.Instance);
    }

    /// <summary>The tracker's display name for each lab, as returned by usp_ReportsWorkflowTracker_Pivot.</summary>
    [Theory]
    [InlineData("PCR Labs of America", "PCRLabsofAmerica")]
    [InlineData("Cove", "Cove")]
    [InlineData("Inhealth_DTR", "Inhealth_DTR")]
    [InlineData("Elixir", "Elixir")]
    [InlineData("Certus", "Certus")]
    [InlineData("Beech_Tree", "Beech_Tree")]
    [InlineData("Beech Tree", "Beech_Tree")]
    [InlineData("Augustus Labs", "Augustus_Labs")]
    [InlineData("NorthWest", "NorthWest")]
    [InlineData("PCR_Dx_AL", "PCR_Dx_AL")]
    [InlineData("PCR_Dx_CO", "PCR_Dx_CO")]
    [InlineData("Phi Life", "Phi_Life")]
    [InlineData("Rising Tides", "Rising_Tides")]
    public void Every_tracker_lab_name_resolves_to_its_config_key(string trackerName, string expectedKey)
        => Assert.Equal(expectedKey, Build().Resolve(trackerName));

    [Fact]
    public void All_twelve_labs_resolve_from_their_own_key()
    {
        var resolver = Build();
        foreach (var key in ConfigKeys)
            Assert.Equal(key, resolver.Resolve(key));
    }

    [Fact]
    public void Resolution_is_case_insensitive()
        => Assert.Equal("NorthWest", Build().Resolve("northwest"));

    [Fact]
    public void DbLabName_is_used_when_the_key_does_not_match()
    {
        var resolver = Build(new Dictionary<string, LabCsvConfig>
        {
            ["PCR_Dx_CO"] = new() { DbLabName = "PCRCO" }
        });

        Assert.Equal("PCR_Dx_CO", resolver.Resolve("PCRCO"));
    }

    [Theory]
    [InlineData("A Lab We Never Configured")]
    [InlineData("")]
    [InlineData(null)]
    public void An_unmatched_lab_resolves_to_null(string? trackerName)
        => Assert.Null(Build().Resolve(trackerName));

    [Fact]
    public void Squash_strips_the_separators_that_differ_between_the_two_naming_schemes()
        => Assert.Equal(LabNameResolver.Squash("PCR Labs of America"), LabNameResolver.Squash("PCRLabsofAmerica"));
}

public class ReportBoardFeatureGatingTests
{
    [Fact]
    public void A_report_with_no_flag_is_always_enabled()
        => Assert.True(ReportBoardController.IsFeatureEnabled(null, new LabCsvConfig()));

    [Fact]
    public void A_flag_that_is_off_blocks_the_link()
        => Assert.False(ReportBoardController.IsFeatureEnabled("EnablePrediction", new LabCsvConfig { EnablePrediction = false }));

    [Fact]
    public void A_flag_that_is_on_allows_the_link()
        => Assert.True(ReportBoardController.IsFeatureEnabled("EnablePrediction", new LabCsvConfig { EnablePrediction = true }));

    [Fact]
    public void An_unmapped_lab_has_no_config_so_every_flagged_report_is_blocked()
        => Assert.False(ReportBoardController.IsFeatureEnabled("EnableCoding", null));

    [Fact]
    public void A_flag_name_that_no_longer_exists_on_LabCsvConfig_blocks_rather_than_opens()
        => Assert.False(ReportBoardController.IsFeatureEnabled("EnableSomethingRemoved", new LabCsvConfig()));

    /// <summary>Guards against a catalog entry naming a flag that was renamed on LabCsvConfig.</summary>
    [Fact]
    public void Every_catalog_flag_is_a_real_bool_property_on_LabCsvConfig()
    {
        var boolProperties = typeof(LabCsvConfig).GetProperties()
            .Where(p => p.PropertyType == typeof(bool))
            .Select(p => p.Name)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        foreach (var entry in ReportCatalog.Entries.Where(e => e.FeatureFlag is not null))
            Assert.Contains(entry.FeatureFlag!, boolProperties);
    }
}
