using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchQaRulesTests
{
    private static readonly string[] ErrorTypes = ["Incomplete Documentation", "Other"];

    [Fact]
    public void Approve_needs_nothing_else()
    {
        var (d, error) = ArWorkbenchQaRules.Validate(new ArWorkbenchQaDecisionRequest { Decision = "Approve" }, ErrorTypes);
        Assert.Null(error);
        Assert.True(d!.Approve);
        Assert.Null(d.ErrorType);
    }

    [Fact]
    public void Reject_needs_error_type_from_the_list()
    {
        Assert.NotNull(ArWorkbenchQaRules.Validate(new() { Decision = "reject", Note = "fix it" }, ErrorTypes).Error);
        Assert.NotNull(ArWorkbenchQaRules.Validate(new() { Decision = "reject", ErrorType = "Made Up", Note = "fix it" }, ErrorTypes).Error);
    }

    [Fact]
    public void Reject_needs_a_note()
        => Assert.NotNull(ArWorkbenchQaRules.Validate(new() { Decision = "reject", ErrorType = "Other", Note = "  " }, ErrorTypes).Error);

    [Fact]
    public void Reject_uses_the_lists_spelling()
    {
        var (d, error) = ArWorkbenchQaRules.Validate(new() { Decision = "reject", ErrorType = "incomplete documentation", Note = "Missing EOB" }, ErrorTypes);
        Assert.Null(error);
        Assert.False(d!.Approve);
        Assert.Equal("Incomplete Documentation", d.ErrorType);
        Assert.Equal("Missing EOB", d.Note);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("maybe")]
    public void Unknown_decision_is_rejected(string? decision)
        => Assert.NotNull(ArWorkbenchQaRules.Validate(new() { Decision = decision }, ErrorTypes).Error);

    [Fact]
    public void Too_long_note_is_rejected()
        => Assert.NotNull(ArWorkbenchQaRules.Validate(new() { Decision = "approve", Note = new string('x', 2001) }, ErrorTypes).Error);
}
