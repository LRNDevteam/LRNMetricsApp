using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchUploadedInsightRulesTests
{
    [Fact]
    public void Rich_text_becomes_plain_lines_with_bullets()
    {
        var html = "<p>Per review <b>majority</b> of denied claims are for UTI panel.</p><ul><li>Submit the Patient&#39;s records</li><li>Call  the payer</li></ul>";
        Assert.Equal("Per review majority of denied claims are for UTI panel.\n• Submit the Patient's records\n• Call the payer",
            ArWorkbenchUploadedInsightRules.ToPlainText(html));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("<p> </p>")]
    public void Empty_rich_text_is_null(string? html) => Assert.Null(ArWorkbenchUploadedInsightRules.ToPlainText(html));

    [Fact]
    public void Script_markup_never_survives_as_tags()
    {
        var text = ArWorkbenchUploadedInsightRules.ToPlainText("<script>alert(1)</script><img src=x onerror=alert(1)>ok");
        Assert.DoesNotContain("<", text);
    }

    [Theory]
    [InlineData("41380.76%", 653816.00, 1044686.89, "62.58%")]
    [InlineData("57%", 500, 1000, "57%")]
    [InlineData("N/A", 500, 1000, "N/A")]
    [InlineData("", 250, 1000, "25%")]
    [InlineData(null, 0, 0, null)]
    public void Impact_keeps_the_upload_unless_impossible(string? shown, double ins, double total, string? expected)
        => Assert.Equal(expected, ArWorkbenchUploadedInsightRules.ImpactText(shown, (decimal)ins, (decimal)total));

    [Theory]
    [InlineData("CO-242", "242")]
    [InlineData("PR 204", "204")]
    [InlineData("M127", "M127")]
    public void Uploaded_codes_normalize_like_the_claim_sync(string raw, string expected)
        => Assert.Equal(expected, ArWorkbenchMasterRules.NormalizeDenialCode(raw));
}
