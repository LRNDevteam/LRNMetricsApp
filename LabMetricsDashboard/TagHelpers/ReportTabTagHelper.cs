using LabMetricsDashboard.Models.ReportVisibility;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc.Rendering;
using Microsoft.AspNetCore.Mvc.ViewFeatures;
using Microsoft.AspNetCore.Razor.TagHelpers;

namespace LabMetricsDashboard.TagHelpers;

/// <summary>
/// <c>&lt;li lmd-report-tab="mcv"&gt;</c> - drops the element from the HTML when the user's role has
/// that Standard Reports tab hidden (Admin &gt; Report Visibility). Put it on both the tab button's
/// container and the tab pane so a hidden tab's data is never sent.
/// </summary>
/// <remarks>
/// The page comes from <c>lmd-report-page</c>, or from <c>ViewData[ReportVisibilityCatalog.ViewDataKey]</c>
/// which each report view sets once. With neither, or with no <see cref="IReportAccessService"/>
/// registered (view render tests), the element renders unchanged.
/// When something is dropped the layout adds a small script that activates the first remaining tab,
/// in case the default (active) tab was the hidden one.
/// </remarks>
[HtmlTargetElement(Attributes = TabAttribute)]
public sealed class ReportTabTagHelper : TagHelper
{
    private const string TabAttribute = "lmd-report-tab";
    public const string HiddenTabsItemKey = "lmd:report-tabs-hidden";

    [HtmlAttributeName(TabAttribute)]
    public string? TabKey { get; set; }

    [HtmlAttributeName("lmd-report-page")]
    public string? PageKey { get; set; }

    [ViewContext]
    [HtmlAttributeNotBound]
    public ViewContext ViewContext { get; set; } = default!;

    public override async Task ProcessAsync(TagHelperContext context, TagHelperOutput output)
    {
        var page = PageKey ?? ViewContext.ViewData[ReportVisibilityCatalog.ViewDataKey] as string;
        if (string.IsNullOrWhiteSpace(page) || string.IsNullOrWhiteSpace(TabKey)) return;

        var http = ViewContext.HttpContext;
        if (http.RequestServices.GetService(typeof(IReportAccessService)) is not IReportAccessService service) return;

        var access = await service.GetAsync(page, http.RequestAborted);
        if (access.IsTabVisible(TabKey)) return;

        output.SuppressOutput();
        http.Items[HiddenTabsItemKey] = true;
    }
}
