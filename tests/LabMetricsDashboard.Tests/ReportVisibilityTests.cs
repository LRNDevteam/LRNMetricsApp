using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Claims;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using LabMetricsDashboard.Models.Menu;
using LabMetricsDashboard.Models.ReportVisibility;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>Admin &gt; Report Visibility: per-role tab and Key Insights access on the Standard Reports pages.</summary>
public sealed class ReportVisibilityTests
{
    // ── ReportPageAccess ──────────────────────────────────────────────────────

    [Fact]
    public void Unrestricted_shows_every_tab_and_keeps_the_pages_own_edit_rule()
    {
        var access = ReportPageAccess.Unrestricted(ReportVisibilityCatalog.Production);

        Assert.True(access.IsTabVisible("weekly"));
        Assert.True(access.IsTabVisible(ReportVisibilityCatalog.KeyInsightsTab));
        Assert.True(access.CanKeyInsights(KeyInsightAction.Import, fallback: true));
        Assert.False(access.CanKeyInsights(KeyInsightAction.Import, fallback: false));
    }

    [Theory]
    [InlineData(true, null, true, true)]     // Default -> page rule
    [InlineData(true, null, false, false)]
    [InlineData(true, true, false, true)]    // Allow wins over a page rule that says no
    [InlineData(true, false, true, false)]   // Deny
    [InlineData(false, null, true, false)]   // Hidden Key Insights: no action at all
    [InlineData(false, true, true, false)]
    public void Key_insight_action_resolution(bool visible, bool? setting, bool fallback, bool expected)
    {
        var actions = setting is null ? null : new Dictionary<KeyInsightAction, bool> { [KeyInsightAction.Add] = setting.Value };
        var access = new ReportPageAccess(ReportVisibilityCatalog.LisSummary, [], visible, actions);
        Assert.Equal(expected, access.CanKeyInsights(KeyInsightAction.Add, fallback));
    }

    [Fact]
    public void Each_action_is_decided_on_its_own()
    {
        // "View + add": add allowed, import and template denied, edit left on Default.
        var access = new ReportPageAccess(ReportVisibilityCatalog.Production, [], true, new Dictionary<KeyInsightAction, bool>
        {
            [KeyInsightAction.Add] = true,
            [KeyInsightAction.Import] = false,
            [KeyInsightAction.Template] = false,
        });

        Assert.True(access.CanKeyInsights(KeyInsightAction.Add, fallback: false));
        Assert.False(access.CanKeyInsights(KeyInsightAction.Import, fallback: true));
        Assert.False(access.CanKeyInsights(KeyInsightAction.Template, fallback: true));
        Assert.True(access.CanKeyInsights(KeyInsightAction.Edit, fallback: true));
        Assert.Null(access.KeyInsightActionOverride(KeyInsightAction.Edit));
    }

    [Fact]
    public void The_key_insights_pseudo_tab_follows_key_insights_visibility()
    {
        var hidden = new ReportPageAccess(ReportVisibilityCatalog.DenialSummary, [], keyInsightsVisible: false);
        Assert.False(hidden.IsTabVisible(ReportVisibilityCatalog.KeyInsightsTab));
        Assert.True(hidden.IsTabVisible("monthly"));
    }

    [Fact]
    public void First_visible_tab_skips_hidden_ones_and_is_null_when_all_are_hidden()
    {
        var access = new ReportPageAccess(ReportVisibilityCatalog.LisSummary, ["summary"], true);
        Assert.Equal("line", access.FirstVisibleTab("summary", ["summary", "line"]));
        Assert.Equal("line", access.FirstVisibleTab("line", ["summary", "line"]));

        var none = new ReportPageAccess(ReportVisibilityCatalog.LisSummary, ["summary", "LINE"], true);
        Assert.Null(none.FirstVisibleTab("summary", ["summary", "line"]));
    }

    // ── ReportAccessService ───────────────────────────────────────────────────

    private sealed class SettingsMenu(Dictionary<string, bool> settings) : IMenuService
    {
        public Task<List<MenuItemVm>> GetMenuForUserAsync(ClaimsPrincipal user, CancellationToken ct) => Task.FromResult(new List<MenuItemVm>());
        public Task<bool> CanAccessAsync(ClaimsPrincipal user, string? area, string? controller, string? action, CancellationToken ct) => Task.FromResult(true);
        public Task<bool> IsFeatureEnabledAsync(ClaimsPrincipal user, string featureKey, bool fallback, CancellationToken ct)
            => Task.FromResult(settings.TryGetValue(featureKey, out var v) ? v : fallback);
        public Task<bool?> GetFeatureSettingAsync(ClaimsPrincipal user, string featureKey, CancellationToken ct)
            => Task.FromResult(settings.TryGetValue(featureKey, out var v) ? v : (bool?)null);
        public void InvalidateCache() { }
    }

    private static ReportAccessService Service(Dictionary<string, bool> settings, params string[] roles)
    {
        var identity = new ClaimsIdentity(roles.Select(r => new Claim(ClaimTypes.Role, r)), authenticationType: "test");
        var http = new DefaultHttpContext { User = new ClaimsPrincipal(identity) };
        return new ReportAccessService(new HttpContextAccessor { HttpContext = http }, new SettingsMenu(settings),
            NullLogger<ReportAccessService>.Instance);
    }

    [Fact]
    public async Task Saved_rows_hide_tabs_and_set_key_insight_actions()
    {
        var page = ReportVisibilityCatalog.CollectionSummary;
        var service = Service(new()
        {
            [ReportVisibilityCatalog.TabViewKey(page, "aging")] = false,
            [ReportVisibilityCatalog.TabViewKey(page, "mcv")] = true,
            [ReportVisibilityCatalog.KeyInsightsViewKey(page)] = true,
            [ReportVisibilityCatalog.KeyInsightsKey(page, KeyInsightAction.Add)] = true,
            [ReportVisibilityCatalog.KeyInsightsKey(page, KeyInsightAction.Import)] = false,
        }, "Account Manager");

        var access = await service.GetAsync(page);

        Assert.False(access.IsTabVisible("aging"));
        Assert.True(access.IsTabVisible("mcv"));
        Assert.True(access.IsTabVisible("wcv"));          // Default
        Assert.True(access.KeyInsightsVisible);
        Assert.True(access.CanKeyInsights(KeyInsightAction.Add, fallback: false));
        Assert.False(access.CanKeyInsights(KeyInsightAction.Import, fallback: true));
        Assert.Null(access.KeyInsightActionOverride(KeyInsightAction.Delete));
    }

    [Fact]
    public async Task An_action_the_page_does_not_have_is_never_read()
    {
        // Denial Summary has no Add (its rows come from import), so a stray Add row is ignored.
        var page = ReportVisibilityCatalog.DenialSummary;
        var access = await Service(new()
        {
            [ReportVisibilityCatalog.KeyInsightsKey(page, KeyInsightAction.Add)] = false,
            [ReportVisibilityCatalog.KeyInsightsKey(page, KeyInsightAction.Import)] = false,
        }, "AR Manager").GetAsync(page);

        Assert.Null(access.KeyInsightActionOverride(KeyInsightAction.Add));
        Assert.False(access.CanKeyInsights(KeyInsightAction.Import, fallback: true));
    }

    [Fact]
    public async Task Nothing_saved_leaves_the_page_as_it_was()
    {
        var access = await Service(new(), "Lab Admin").GetAsync(ReportVisibilityCatalog.Production);

        Assert.False(access.HasHiddenTabs);
        Assert.True(access.KeyInsightsVisible);
        Assert.All(Enum.GetValues<KeyInsightAction>(), a => Assert.Null(access.KeyInsightActionOverride(a)));
    }

    [Theory]
    [InlineData("Admin")]
    [InlineData("Super Admin")]
    [InlineData("LRN Admin")]
    public async Task Full_admins_are_never_restricted(string role)
    {
        var page = ReportVisibilityCatalog.Production;
        var access = await Service(new()
        {
            [ReportVisibilityCatalog.TabViewKey(page, "weekly")] = false,
            [ReportVisibilityCatalog.KeyInsightsViewKey(page)] = false,
        }, role).GetAsync(page);

        Assert.True(access.IsTabVisible("weekly"));
        Assert.True(access.KeyInsightsVisible);
    }

    [Fact]
    public async Task An_unknown_page_is_unrestricted()
    {
        var access = await Service(new(), "Lab User").GetAsync("NotAReport");
        Assert.True(access.IsTabVisible("anything"));
    }

    // ── catalog ───────────────────────────────────────────────────────────────

    /// <summary>The key shape LRN.ReportsApi accepts (ReportVisibilityFeatures). Keep the two in step.</summary>
    private static readonly Regex ApiKeyPattern =
        new(@"^Report\.[A-Za-z0-9]{1,40}\.(Tab\.[A-Za-z0-9-]{1,40}\.View|KeyInsights\.(View|Add|Edit|Delete|Import|Template|CopyWeek))$");

    [Fact]
    public void Every_catalog_key_is_one_the_reports_api_accepts()
    {
        var keys = ReportVisibilityCatalog.Pages.SelectMany(p =>
            p.Tabs.Select(t => ReportVisibilityCatalog.TabViewKey(p.Key, t.Key))
             .Append(ReportVisibilityCatalog.KeyInsightsViewKey(p.Key))
             .Concat(p.KeyInsightActions.Select(a => ReportVisibilityCatalog.KeyInsightsKey(p.Key, a.Action)))).ToList();

        Assert.All(keys, k =>
        {
            Assert.Matches(ApiKeyPattern, k);
            Assert.True(k.Length <= 100, k);   // dbo.RoleFeatureAccess.FeatureKey is NVARCHAR(100)
        });
        Assert.Equal(keys.Count, keys.Distinct(StringComparer.OrdinalIgnoreCase).Count());
    }

    [Theory]
    [InlineData("Executive Summary", ReportVisibilityCatalog.ExecutiveSummary)]
    [InlineData("Production Report", ReportVisibilityCatalog.Production)]
    [InlineData("LIS Report", ReportVisibilityCatalog.LisSummary)]
    [InlineData("collection report", ReportVisibilityCatalog.CollectionSummary)]
    [InlineData("Something Else", null)]
    public void Notes_report_names_map_to_their_page(string reportName, string? page)
        => Assert.Equal(page, ReportVisibilityCatalog.PageForNotesReport(reportName));

    [Fact]
    public void Denial_summary_offers_import_and_copy_week_but_no_add()
    {
        var denial = ReportVisibilityCatalog.FindPage(ReportVisibilityCatalog.DenialSummary)!.KeyInsightActions.Select(a => a.Action).ToList();
        Assert.Contains(KeyInsightAction.Import, denial);
        Assert.Contains(KeyInsightAction.CopyWeek, denial);
        Assert.DoesNotContain(KeyInsightAction.Add, denial);

        var production = ReportVisibilityCatalog.FindPage(ReportVisibilityCatalog.Production)!.KeyInsightActions.Select(a => a.Action).ToList();
        Assert.Contains(KeyInsightAction.Add, production);
        Assert.Contains(KeyInsightAction.Template, production);
        Assert.DoesNotContain(KeyInsightAction.CopyWeek, production);
    }

    [Fact]
    public void Every_notes_report_maps_to_a_page()
    {
        foreach (var report in LabMetricsDashboard.Controllers.NotesController.AllowedReports)
            Assert.NotNull(ReportVisibilityCatalog.PageForNotesReport(report));
    }
}
