using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchSavedViewRulesTests
{
    private static ArWorkbenchSavedViewRequest Request(string? key = "followup", string? name = "My overdue", string? filters = "{\"quick\":\"overdue\"}", string? hidden = null)
        => new() { ViewKey = key, ViewName = name, FiltersJson = filters, HiddenColumnsJson = hidden };

    [Fact]
    public void Valid_request_is_normalized()
    {
        var (view, error) = ArWorkbenchSavedViewRules.Validate(Request(key: " MyWork ", name: "  High   priority  "));
        Assert.Null(error);
        Assert.Equal("mywork", view!.ViewKey);
        Assert.Equal("High priority", view.ViewName);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("dashboard")]
    public void Unknown_screen_is_rejected(string? key)
    {
        var (view, error) = ArWorkbenchSavedViewRules.Validate(Request(key: key));
        Assert.Null(view);
        Assert.NotNull(error);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("   ")]
    public void Blank_name_is_rejected(string? name)
    {
        Assert.Null(ArWorkbenchSavedViewRules.Validate(Request(name: name)).View);
    }

    [Fact]
    public void Too_long_name_is_rejected()
    {
        Assert.Null(ArWorkbenchSavedViewRules.Validate(Request(name: new string('x', ArWorkbenchSavedViewRules.MaxNameLength + 1))).View);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[1,2]")]
    [InlineData("\"text\"")]
    public void Filters_must_be_a_json_object(string? filters)
    {
        Assert.Null(ArWorkbenchSavedViewRules.Validate(Request(filters: filters)).View);
    }

    [Fact]
    public void Oversized_filters_are_rejected()
    {
        var big = "{\"q\":\"" + new string('a', ArWorkbenchSavedViewRules.MaxJsonLength) + "\"}";
        Assert.Null(ArWorkbenchSavedViewRules.Validate(Request(filters: big)).View);
    }

    [Theory]
    [InlineData(null, true)]
    [InlineData("[\"agingBucket\"]", true)]
    [InlineData("{\"a\":1}", false)]
    [InlineData("oops", false)]
    public void Hidden_columns_are_optional_but_must_be_an_array(string? hidden, bool ok)
    {
        Assert.Equal(ok, ArWorkbenchSavedViewRules.Validate(Request(hidden: hidden)).View is not null);
    }
}
