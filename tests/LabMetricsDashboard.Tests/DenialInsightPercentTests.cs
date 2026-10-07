using LabMetricsDashboard.Services;
using Xunit;

namespace LabMetricsDashboard.Tests;

public sealed class DenialInsightPercentTests
{
    [Theory]
    // The Previous Week rows from the client's sheet: Ins. Balance / # of Denials instead of / Total Balance.
    [InlineData("41380.76%", 653816.00, 1044686.89, "62.58%")]
    [InlineData("54849.09%", 150835.00, 350817.00, "43%")]
    [InlineData("74841.21%", 123488.00, 238389.06, "51.8%")]
    public void Impossible_impact_is_recomputed_from_the_balances(string shown, double ins, double total, string expected)
        => Assert.Equal(expected, DenialInsightPercent.DisplayText(shown, (decimal)ins, (decimal)total));

    [Theory]
    [InlineData("57%")]
    [InlineData("58.49")]
    [InlineData("100%")]
    [InlineData("0%")]
    [InlineData("-")]
    [InlineData("N/A")]
    [InlineData("")]
    public void Valid_or_non_numeric_text_is_kept_as_shown(string shown)
        => Assert.Equal(shown, DenialInsightPercent.DisplayText(shown, 500m, 1000m));

    [Fact]
    public void Impossible_impact_without_usable_balances_is_left_alone()
    {
        Assert.Equal("41380.76%", DenialInsightPercent.DisplayText("41380.76%", 653816m, 0m));
        Assert.Equal("150%", DenialInsightPercent.DisplayText("150%", 2000m, 1000m));
    }
}
