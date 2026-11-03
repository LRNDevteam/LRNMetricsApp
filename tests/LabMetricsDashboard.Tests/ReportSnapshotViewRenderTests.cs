using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Claims;
using System.Threading;
using System.Threading.Tasks;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models.Menu;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.Services.ReportSnapshots;
using LabMetricsDashboard.ViewModels;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Mvc.ModelBinding;
using Microsoft.AspNetCore.Mvc.Razor;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.AspNetCore.Mvc.ViewEngines;
using Microsoft.AspNetCore.Mvc.ViewFeatures;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;
using Codes = LabMetricsDashboard.Services.ReportSnapshots.ReportSnapshotViewContext.ReportCodes;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// The report pages' real Razor views, rendered the way ReportSnapshotViewerController renders a snapshot:
/// they must render in snapshot mode, point their lazy tabs at the viewer, and leave out the live-only parts.
/// </summary>
public sealed class ReportSnapshotViewRenderTests
{
    private const string Lab = "TexasDiagnostic";

    [Fact]
    public async Task Executive_summary_renders_as_a_snapshot_with_its_highlight_frames_on_the_snapshot()
    {
        var vm = Populated<PhiExecutiveSummaryViewModel>();
        vm.SelectedLab = Lab;
        vm.YearMonthColumns = [(2026, 9), (2026, 10), (0, 0)];
        vm.Rows = [new ExecSummaryRow { RowCode = "A", Category = "LIS", Description = "Samples", ValuesByYearMonth = new() { [(2026, 9)] = 5m, [(2026, 10)] = 10m, [(0, 0)] = 15m } }];

        var html = await RenderAsync("~/Views/ExecutiveSummary/Index.cshtml", vm, Context(Codes.ExecutiveSummary,
            new Dictionary<string, string> { [Codes.ProductionSummary] = "/ReportSnapshotViewer/Report/11?embed=1&embedTabs=monthly-pane" }));

        AssertSnapshotPage(html);
        Assert.Contains("Samples", html);
        Assert.Contains("data-src=\"/ReportSnapshotViewer/Report/11?embed=1&amp;embedTabs=monthly-pane\"", html);
        Assert.Contains("was not captured in this snapshot", html);   // Collection / LIMS / Denial not in this run
        Assert.DoesNotContain("notes-insights.js", html);
        Assert.DoesNotContain("es-cell-rows.js", html);
    }

    [Fact]
    public async Task Lis_summary_renders_its_result_inline()
    {
        var result = Populated<LisSummaryResult>();
        var html = await RenderAsync("~/Views/LisSummary/Index.cshtml", new LisSummaryPageViewModel
        {
            CurrentLabName = Lab,
            ConfiguredLabKey = Lab,
            Result = result,
            FilterOptions = new([], [], [], [], [])
        }, Context(Codes.LisSummary));

        AssertSnapshotPage(html);
        Assert.DoesNotContain("id=\"lisResultSpinner\"", html);
        Assert.Contains("lis-kpi-grid", html);
    }

    [Fact]
    public async Task Production_summary_loads_its_tabs_from_the_snapshot()
    {
        var vm = Populated<LRN.ProductionReports.Models.ProductionReportViewModel>();

        var html = await RenderAsync("~/Views/Dashboard/ProductionSummaryReport.cshtml", vm, Context(Codes.ProductionSummary),
            viewData => viewData["PrCacheKey"] = "42");

        AssertSnapshotPage(html);
        Assert.Contains("data-pr-key=\"42\"", html);
        Assert.Contains("data-pr-tab-url=\"/ReportSnapshotViewer/ProductionPane\"", html);
        Assert.Contains("data-pr-meta-url=\"/ReportSnapshotViewer/ProductionMeta\"", html);
    }

    [Theory]
    [InlineData("weekly-pane")]
    [InlineData("payer-breakdown-pane")]
    [InlineData("cpt-breakdown-pane")]
    public async Task Production_tabs_render_as_panes(string pane)
    {
        var vm = Populated<LRN.ProductionReports.Models.ProductionReportViewModel>();

        var html = await RenderAsync("~/Views/Dashboard/ProductionReport.cshtml", vm, Context(Codes.ProductionSummary),
            viewData => viewData["PrPaneOnly"] = pane, mainPage: false);

        // A pane is the tab's inner HTML (the page's loader takes it either way), never the page around it.
        Assert.True(html.Trim().Length > 200, html);
        Assert.DoesNotContain("<html", html);
        Assert.DoesNotContain("class=\"lmd-snap-banner\"", html);
    }

    [Fact]
    public async Task Collection_summary_loads_its_tabs_from_the_snapshot()
    {
        var vm = Populated<CollectionSummaryViewModel>();
        vm.SelectedLab = Lab;
        vm.LazyLoadTabs = true;

        var html = await RenderAsync("~/Views/CollectionSummary/Index.cshtml", vm, Context(Codes.CollectionSummary));

        AssertSnapshotPage(html);
        Assert.Contains("'/ReportSnapshotViewer/CollectionTab/7'", html);
        Assert.Contains("'/ReportSnapshotViewer/CollectionMeta/7'", html);
        Assert.DoesNotContain("GetTabPartial", html);
    }

    [Theory]
    [InlineData("_CsTabWcv")]
    [InlineData("_CsTabAging")]
    [InlineData("_CsTabAvgPayments")]
    [InlineData("_CsTabStatusSummary")]
    [InlineData("_CsTabProvider")]
    public async Task Collection_tabs_render_from_the_snapshot_model(string partial)
    {
        var vm = Populated<CollectionSummaryViewModel>();
        vm.SelectedLab = Lab;

        var html = await RenderAsync($"~/Views/CollectionSummary/{partial}.cshtml", vm, Context(Codes.CollectionSummary), mainPage: false);
        Assert.False(string.IsNullOrWhiteSpace(html));
    }

    [Fact]
    public async Task Denial_summary_renders_without_the_live_claim_level_tab_and_swaps_insight_weeks_from_the_snapshot()
    {
        var vm = Populated<DenialClaimReportViewModel>();
        vm.CurrentLab = Lab;
        vm.ActiveTab = "insight";
        vm.Insight.CurrentLab = Lab;
        vm.Insight.CanEdit = false;
        vm.Insight.Bucket = DenialInsightBuckets.Current;

        var html = await RenderAsync("~/Views/DenialClaimReport/Index.cshtml", vm, Context(Codes.DenialSummary));

        AssertSnapshotPage(html);
        Assert.DoesNotContain("id=\"dcr-claims\"", html);
        Assert.Contains("data-panel-url=\"/ReportSnapshotViewer/InsightPanel/7?bucket=" + DenialInsightBuckets.Previous, html);
        Assert.DoesNotContain("ExportInsights", html);
    }

    [Fact]
    public async Task The_live_pages_are_unchanged_without_a_snapshot()
    {
        var vm = Populated<DenialClaimReportViewModel>();
        vm.CurrentLab = Lab;

        var html = await RenderAsync("~/Views/DenialClaimReport/Index.cshtml", vm, context: null, controller: "DenialClaimReport");

        Assert.DoesNotContain("class=\"lmd-snap-banner\"", html);
        Assert.DoesNotContain("lmdReportSnapshot", html);
        Assert.Contains("id=\"dcr-claims\"", html);
        // The live Insight week links are the page's own (this harness has no route table to print them).
        Assert.DoesNotContain("/ReportSnapshotViewer/", html);
        Assert.Contains("Export", html);
    }

    // ── harness ───────────────────────────────────────────────────────────────

    private static void AssertSnapshotPage(string html)
    {
        Assert.Contains("class=\"lmd-embed lmd-snapshot\"", html);
        Assert.Contains("class=\"lmd-snap-banner\"", html);
        Assert.Contains("window.lmdReportSnapshot = true", html);
        Assert.Contains("R20261029TXD0391", html);
    }

    private static ReportSnapshotViewContext Context(string reportCode, IReadOnlyDictionary<string, string>? highlights = null) => new()
    {
        FileId = 7,
        SnapshotRunId = 4,
        ReportCode = reportCode,
        LabName = Lab,
        RunId = "R20261029TXD0391",
        WeekFolder = "10.16.2026 - 10.22.2026",
        CapturedOnUtc = new DateTime(2026, 10, 29, 9, 25, 0, DateTimeKind.Utc),
        Trigger = "Executive Summary Success",
        ViewerBasePath = "/ReportSnapshotViewer/",
        ProductionPaneUrl = "/ReportSnapshotViewer/ProductionPane",
        ProductionMetaUrl = "/ReportSnapshotViewer/ProductionMeta",
        CollectionTabUrl = "/ReportSnapshotViewer/CollectionTab/7",
        CollectionMetaUrl = "/ReportSnapshotViewer/CollectionMeta/7",
        InsightPanelUrlTemplate = "/ReportSnapshotViewer/InsightPanel/7?bucket=__bucket__",
        HighlightUrls = highlights ?? new Dictionary<string, string>()
    };

    private static T Populated<T>() where T : class
    {
        // The populated sample of the binding tests, then bound back through the snapshot JSON - exactly
        // what the viewer hands the views.
        var sample = ReportSnapshotViewerTests.Sample.Create(typeof(T), 0)!;
        // A captured page had no error, so the view takes its data path, not its error banner.
        foreach (var p in typeof(T).GetProperties())
            if (p.Name is "ErrorMessage" or "Error" && p.PropertyType == typeof(string) && p.SetMethod is not null)
                p.SetValue(sample, null);
        var json = System.Text.Json.JsonSerializer.Serialize(sample, typeof(T), ReportSnapshotJson.Options);
        return System.Text.Json.JsonSerializer.Deserialize<T>(json, ReportSnapshotJson.Options)!;
    }

    private static readonly Lazy<WebApplication> App = new(() =>
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions
        {
            ApplicationName = typeof(LabMetricsDashboard.Controllers.ReportSnapshotViewerController).Assembly.GetName().Name,
            ContentRootPath = DashboardFolder(),
            EnvironmentName = "Development"
        });
        builder.Configuration.Sources.Clear();
        builder.Services.AddControllersWithViews();
        builder.Services.Configure<RazorViewEngineOptions>(o => o.ViewLocationExpanders.Add(new ReportSnapshotViewLocationExpander()));
        builder.Services.AddSingleton(new LabSettings());
        builder.Services.AddSingleton(new LabConfigOptions());
        builder.Services.AddSingleton<IMenuService, NoMenu>();
        var app = builder.Build();
        app.MapControllerRoute("default", "{controller=ReportBoard}/{action=Index}/{id?}");
        return app;
    });

    private static async Task<string> RenderAsync(string viewPath, object model, ReportSnapshotViewContext? context,
        Action<ViewDataDictionary>? setup = null, bool mainPage = true, string controller = "ReportSnapshotViewer")
    {
        var app = App.Value;
        using var scope = app.Services.CreateScope();
        var services = scope.ServiceProvider;

        var http = new DefaultHttpContext { RequestServices = services, User = new ClaimsPrincipal(new ClaimsIdentity()) };
        http.Items["CspNonce"] = "test-nonce";
        http.Request.Scheme = "https";
        http.Request.Host = new HostString("localhost");
        // Url.Action resolves through endpoint routing, as in the app.
        http.SetEndpoint(new Endpoint(_ => Task.CompletedTask, new EndpointMetadataCollection(), "test"));

        var routeData = new RouteData();
        routeData.Values["controller"] = controller;
        routeData.Values["action"] = "Report";
        var actionContext = new ActionContext(http, routeData, new ActionDescriptor());
        http.Features.Set<IRouteValuesFeature>(new RouteValuesFeature { RouteValues = routeData.Values });

        var engine = services.GetRequiredService<ICompositeViewEngine>();
        var found = engine.GetView(executingFilePath: null, viewPath, isMainPage: mainPage);
        found.EnsureSuccessful(originalLocations: null);

        var viewData = new ViewDataDictionary(services.GetRequiredService<IModelMetadataProvider>(), new ModelStateDictionary()) { Model = model };
        if (context is not null) viewData[ReportSnapshotViewContext.ViewDataKey] = context;
        setup?.Invoke(viewData);

        await using var writer = new StringWriter();
        var viewContext = new ViewContext(actionContext, found.View, viewData,
            new TempDataDictionary(http, services.GetRequiredService<ITempDataProvider>()), writer, new HtmlHelperOptions());
        await found.View.RenderAsync(viewContext);
        return writer.ToString();
    }

    private static string DashboardFolder()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "LabMetricsDashboard", "Views")))
            dir = dir.Parent;
        return Path.Combine(dir?.FullName ?? throw new DirectoryNotFoundException("LabMetricsDashboard not found."), "LabMetricsDashboard");
    }

    private sealed class NoMenu : IMenuService
    {
        public Task<List<MenuItemVm>> GetMenuForUserAsync(ClaimsPrincipal user, CancellationToken ct) => Task.FromResult(new List<MenuItemVm>());
        public Task<bool> CanAccessAsync(ClaimsPrincipal user, string? area, string? controller, string? action, CancellationToken ct) => Task.FromResult(true);
        public Task<bool> IsFeatureEnabledAsync(ClaimsPrincipal user, string featureKey, bool fallback, CancellationToken ct) => Task.FromResult(fallback);
        public void InvalidateCache() { }
    }
}
