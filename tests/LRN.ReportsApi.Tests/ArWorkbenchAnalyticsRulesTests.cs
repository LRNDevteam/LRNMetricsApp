using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchAnalyticsRulesTests
{
    private static ArWorkbenchRecoveryRow Row(string label, decimal recovered, decimal outstanding, int count = 1)
        => new() { Label = label, Key = label, Count = count, InitialAR = recovered + outstanding, Recovered = recovered, Outstanding = outstanding };

    [Fact]
    public void Rows_are_ordered_by_recovered_plus_outstanding()
    {
        var result = ArWorkbenchAnalyticsRules.TopWithOther([Row("A", 10, 0), Row("B", 0, 50), Row("C", 20, 20)]);
        Assert.Equal(["B", "C", "A"], result.Select(r => r.Label));
    }

    [Fact]
    public void Short_list_is_returned_whole()
    {
        var rows = Enumerable.Range(1, 15).Select(i => Row($"P{i}", i, 0)).ToList();
        var result = ArWorkbenchAnalyticsRules.TopWithOther(rows, 15);
        Assert.Equal(15, result.Count);
        Assert.All(result, r => Assert.NotNull(r.Key));
    }

    [Fact]
    public void Long_list_rolls_the_tail_into_one_row_that_cannot_drill()
    {
        var rows = Enumerable.Range(1, 20).Select(i => Row($"P{i}", i, 1, count: 2)).ToList();
        var result = ArWorkbenchAnalyticsRules.TopWithOther(rows, 5);

        Assert.Equal(5, result.Count);
        var other = result[^1];
        Assert.Equal("All other (16)", other.Label);
        Assert.Null(other.Key);
        Assert.Equal(32, other.Count);
        // Totals are preserved across the rollup.
        Assert.Equal(rows.Sum(r => r.Recovered), result.Sum(r => r.Recovered));
        Assert.Equal(rows.Sum(r => r.Outstanding), result.Sum(r => r.Outstanding));
        Assert.Equal(rows.Sum(r => r.InitialAR), result.Sum(r => r.InitialAR));
    }

    [Theory]
    [InlineData(25, 100, 0.25)]
    [InlineData(0, 100, 0)]
    [InlineData(10, 0, 0)]
    [InlineData(1, 3, 0.3333)]
    public void Recovery_rate_guards_against_zero_initial_ar(decimal recovered, decimal initial, decimal expected)
    {
        Assert.Equal(expected, ArWorkbenchAnalyticsRules.RecoveryRate(recovered, initial));
    }
}
