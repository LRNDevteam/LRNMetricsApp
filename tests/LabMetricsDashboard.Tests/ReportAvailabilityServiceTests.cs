using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;
using Xunit;

namespace LabMetricsDashboard.Tests;

public class ReportAvailabilityServiceTests
{
    // Two real catalog shapes: Coding Validation has a feature flag and no built-in lab list;
    // Sales Rep Summary carries a built-in list, which configuration is allowed to replace.
    private static readonly ReportCatalogEntry Coding =
        new("Coding Validation", "Coding Validation", "Coding", "bi-pencil-square", "Analytics & validation",
            "Coding", "Summary", "EnableCoding");

    private static readonly ReportCatalogEntry SalesRep =
        new("Sales Rep Summary", "Sales Rep Summary", "Sales", "bi-people-fill", "Summary reports",
            "Dashboard", "SalesRepSummary", "EnableSalesRepsummary", null, null, ["Cove", "Elixir"]);

    private static ReportAvailabilityService Service(ReportAvailabilitySettings settings)
        => new(new StaticMonitor<ReportAvailabilitySettings>(settings));

    private static ReportAvailabilitySettings WithRule(string report, ReportAvailabilityRule rule)
        => new() { Reports = new(StringComparer.OrdinalIgnoreCase) { [report] = rule } };

    // ── The lab list drives the padlock ──────────────────────────────────────

    [Theory]
    [InlineData("Cove")]
    [InlineData("Certus")]
    [InlineData("PCRLabsofAmerica")]
    public void Listed_lab_is_available(string lab)
    {
        var svc = Service(WithRule("Coding Validation",
            new ReportAvailabilityRule { Labs = ["Cove", "Certus", "PCRLabsofAmerica"] }));

        Assert.True(svc.Evaluate(Coding, lab, lab, featureEnabled: true).IsAvailable);
    }

    [Theory]
    [InlineData("Elixir")]
    [InlineData("Inhealth_DTR")]
    [InlineData("NorthWest")]
    public void Unlisted_lab_is_locked_with_a_reason(string lab)
    {
        var svc = Service(WithRule("Coding Validation",
            new ReportAvailabilityRule { Labs = ["Cove", "Certus", "PCRLabsofAmerica"] }));

        var result = svc.Evaluate(Coding, lab, lab, featureEnabled: true);

        Assert.False(result.IsAvailable);
        Assert.False(string.IsNullOrWhiteSpace(result.LockReason));
    }

    [Fact]
    public void Empty_lab_list_means_every_lab()
    {
        var svc = Service(WithRule("Coding Validation", new ReportAvailabilityRule()));

        Assert.True(svc.Evaluate(Coding, "Rising_Tides", "Rising_Tides", featureEnabled: true).IsAvailable);
    }

    [Fact]
    public void Disabled_report_is_locked_for_every_lab()
    {
        var svc = Service(WithRule("Coding Validation",
            new ReportAvailabilityRule { Enabled = false, Labs = ["Cove"] }));

        Assert.False(svc.Evaluate(Coding, "Cove", "Cove", featureEnabled: true).IsAvailable);
    }

    [Fact]
    public void ExcludeLabs_wins_over_the_lab_list()
    {
        var svc = Service(WithRule("Coding Validation",
            new ReportAvailabilityRule { Labs = ["Cove", "Certus"], ExcludeLabs = ["Certus"] }));

        Assert.True(svc.Evaluate(Coding, "Cove", "Cove", featureEnabled: true).IsAvailable);
        Assert.False(svc.Evaluate(Coding, "Certus", "Certus", featureEnabled: true).IsAvailable);
    }

    [Fact]
    public void Note_replaces_the_generated_lock_reason()
    {
        var svc = Service(WithRule("Coding Validation",
            new ReportAvailabilityRule { Labs = ["Cove"], Note = "Coding starts here in Q3." }));

        Assert.Equal("Coding starts here in Q3.",
            svc.Evaluate(Coding, "Elixir", "Elixir", featureEnabled: true).LockReason);
    }

    // ── Loose matching, so a rule survives the spelling the tracker happens to use ──

    [Theory]
    [InlineData("Coding Validation")]
    [InlineData("CodingValidation")]
    [InlineData("coding validation")]
    [InlineData("Coding")]
    public void Rule_key_matches_tracker_column_display_name_or_short_name(string key)
    {
        var svc = Service(WithRule(key, new ReportAvailabilityRule { Labs = ["Cove"] }));

        Assert.False(svc.Evaluate(Coding, "Elixir", "Elixir", featureEnabled: true).IsAvailable);
    }

    [Theory]
    [InlineData("PCRLabsofAmerica", "PCR Labs of America")]
    [InlineData("Cove", "CoveLRN")]
    [InlineData("Inhealth_DTR", "InhealthDTR")]
    public void Lab_names_match_across_spellings(string configured, string trackerSpelling)
    {
        var svc = Service(WithRule("Coding Validation",
            new ReportAvailabilityRule { Labs = [configured] }));

        Assert.True(svc.Evaluate(Coding, null, trackerSpelling, featureEnabled: true).IsAvailable);
    }

    // ── No rule: the board keeps the behaviour it had before this section existed ──

    [Fact]
    public void Without_a_rule_the_built_in_lab_list_still_applies()
    {
        var svc = Service(new ReportAvailabilitySettings());

        Assert.True(svc.Evaluate(SalesRep, "Cove", "Cove", featureEnabled: true).IsAvailable);
        Assert.False(svc.Evaluate(SalesRep, "Certus", "Certus", featureEnabled: true).IsAvailable);
    }

    [Fact]
    public void Without_a_rule_the_labs_feature_flag_still_applies()
    {
        var svc = Service(new ReportAvailabilitySettings());

        Assert.False(svc.Evaluate(Coding, "Elixir", "Elixir", featureEnabled: false).IsAvailable);
        Assert.True(svc.Evaluate(Coding, "Elixir", "Elixir", featureEnabled: true).IsAvailable);
    }

    [Fact]
    public void A_rule_replaces_the_feature_flag_so_adding_a_lab_actually_shows_it()
    {
        var svc = Service(WithRule("Coding Validation",
            new ReportAvailabilityRule { Labs = ["Elixir"] }));

        Assert.True(svc.Evaluate(Coding, "Elixir", "Elixir", featureEnabled: false).IsAvailable);
    }

    [Fact]
    public void A_rule_replaces_the_built_in_lab_list_too()
    {
        var svc = Service(WithRule("Sales Rep Summary",
            new ReportAvailabilityRule { Labs = ["Certus"] }));

        Assert.True(svc.Evaluate(SalesRep, "Certus", "Certus", featureEnabled: true).IsAvailable);
        Assert.False(svc.Evaluate(SalesRep, "Cove", "Cove", featureEnabled: true).IsAvailable);
    }

    // ── The section shape an admin actually edits must bind ───────────────────

    [Fact]
    public void Section_binds_from_appsettings_json_shape()
    {
        const string json = """
        {
          "ReportAvailability": {
            "Reports": {
              "Coding Validation": { "Enabled": true, "Labs": [ "Cove", "Certus", "PCRLabsofAmerica" ] },
              "Sales Rep Summary": { "Enabled": false, "ExcludeLabs": [ "Elixir" ], "Note": "Paused." }
            }
          }
        }
        """;

        var config = new ConfigurationBuilder()
            .AddJsonStream(new MemoryStream(Encoding.UTF8.GetBytes(json)))
            .Build();

        var settings = config.GetSection("ReportAvailability").Get<ReportAvailabilitySettings>();

        Assert.NotNull(settings);
        Assert.Equal(2, settings!.Reports.Count);

        var coding = settings.Reports["Coding Validation"];
        Assert.True(coding.Enabled);
        Assert.Equal(["Cove", "Certus", "PCRLabsofAmerica"], coding.Labs);
        Assert.Empty(coding.ExcludeLabs);

        var sales = settings.Reports["Sales Rep Summary"];
        Assert.False(sales.Enabled);
        Assert.Equal(["Elixir"], sales.ExcludeLabs);
        Assert.Equal("Paused.", sales.Note);

        // And the whole thing still drives the padlock once bound.
        var svc = Service(settings);
        Assert.False(svc.Evaluate(Coding, "Elixir", "Elixir", featureEnabled: true).IsAvailable);
        Assert.True(svc.Evaluate(Coding, "Cove", "Cove", featureEnabled: true).IsAvailable);
    }

    private sealed class StaticMonitor<T>(T value) : IOptionsMonitor<T>
    {
        public T CurrentValue { get; } = value;
        public T Get(string? name) => CurrentValue;
        public IDisposable? OnChange(Action<T, string?> listener) => null;
    }
}
