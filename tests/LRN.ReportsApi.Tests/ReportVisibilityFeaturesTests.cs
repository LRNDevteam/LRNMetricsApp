using LRN.ReportsApi.Models;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>dbo.RoleFeatureAccess keys saved by the dashboard's Admin &gt; Report Visibility screen.</summary>
public sealed class ReportVisibilityFeaturesTests
{
    [Theory]
    [InlineData("Report.CollectionSummary.Tab.mcv.View")]
    [InlineData("Report.Production.Tab.payer-breakdown.View")]
    [InlineData("Report.DenialSummary.KeyInsights.View")]
    [InlineData("Report.LisSummary.KeyInsights.Edit")]
    [InlineData("Report.Production.KeyInsights.Add")]
    [InlineData("Report.CollectionSummary.KeyInsights.Delete")]
    [InlineData("Report.DenialSummary.KeyInsights.Import")]
    [InlineData("Report.ExecutiveSummary.KeyInsights.Template")]
    [InlineData("Report.DenialSummary.KeyInsights.CopyWeek")]
    public void Report_visibility_keys_are_known(string key)
    {
        Assert.True(ReportVisibilityFeatures.IsValidKey(key));
        Assert.True(MenuFeatureCatalog.IsKnown(key));
        Assert.True(ReportVisibilityFeatures.IsReportKey(key));
    }

    [Theory]
    [InlineData("Report.")]
    [InlineData("Report.Production.Tab.weekly.Edit")]         // tabs have no Edit key
    [InlineData("Report.Production.KeyInsights.Publish")]
    [InlineData("Report.Prod uction.Tab.weekly.View")]
    [InlineData("Report.Production.Tab.week'ly.View")]
    [InlineData("Reports.Production.Tab.weekly.View")]
    [InlineData("")]
    [InlineData(null)]
    public void Malformed_keys_are_refused(string? key)
    {
        Assert.False(ReportVisibilityFeatures.IsValidKey(key));
        Assert.False(MenuFeatureCatalog.IsKnown(key));
    }

    [Fact]
    public void Report_keys_stay_off_the_role_menu_mapping_list()
    {
        Assert.DoesNotContain(MenuFeatureCatalog.All, f => ReportVisibilityFeatures.IsReportKey(f.FeatureKey));
        Assert.False(ReportVisibilityFeatures.IsReportKey(MenuFeatureCatalog.ReimbursementChatHeaderIcon));
        Assert.True(MenuFeatureCatalog.IsKnown(MenuFeatureCatalog.ReimbursementChatHeaderIcon));
    }
}
