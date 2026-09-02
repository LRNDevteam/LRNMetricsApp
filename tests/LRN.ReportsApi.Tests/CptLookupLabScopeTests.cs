using LRN.ReportsApi.Services;
using Microsoft.Data.SqlClient;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// Lab scoping on CPT &amp; Panel Lookup. CPTAverage/PanelAverage are LRNMaster-wide, so this
/// clause is the only thing stopping a signed-in user from reading every lab's negotiated
/// rates by clearing the lab filter or hand-editing ?labId=. Each case below is a way that
/// could go wrong, so the boundary stays pinned.
/// </summary>
public class CptLookupLabScopeTests
{
    private static (List<string> Parts, List<SqlParameter> Parameters) Scope(int? requestedLabId, IReadOnlyList<int>? allowedLabIds)
    {
        var parts = new List<string>();
        var parameters = new List<SqlParameter>();
        SqlCptLookupRepository.AddLabScope(parts, parameters, "a.LabID", requestedLabId, allowedLabIds);
        return (parts, parameters);
    }

    [Fact]
    public void Null_scope_adds_no_clause_so_admins_still_see_every_lab()
    {
        var (parts, parameters) = Scope(requestedLabId: null, allowedLabIds: null);
        Assert.Empty(parts);
        Assert.Empty(parameters);
    }

    // The dangerous case: "no labs assigned" must mean no rows, never every row.
    [Fact]
    public void Empty_scope_blocks_everything()
    {
        var (parts, _) = Scope(requestedLabId: null, allowedLabIds: Array.Empty<int>());
        Assert.Contains("1=0", parts);
    }

    [Fact]
    public void Empty_scope_blocks_everything_even_when_a_lab_was_picked()
    {
        var (parts, _) = Scope(requestedLabId: 7, allowedLabIds: Array.Empty<int>());
        Assert.Contains("1=0", parts);
    }

    [Fact]
    public void No_lab_picked_restricts_to_the_users_labs()
    {
        var (parts, parameters) = Scope(requestedLabId: null, allowedLabIds: new[] { 3, 9 });

        Assert.Contains("a.LabID IN (@ScopeLab0,@ScopeLab1)", parts);
        Assert.Equal(new[] { 3, 9 }, parameters.Select(x => (int)x.Value!));
    }

    // A lab the user does own is already constrained by the caller's own LabID = @LabId clause,
    // so this must not pile on a second, contradictory filter.
    [Fact]
    public void Picking_an_allowed_lab_adds_nothing_further()
    {
        var (parts, parameters) = Scope(requestedLabId: 3, allowedLabIds: new[] { 3, 9 });
        Assert.Empty(parts);
        Assert.Empty(parameters);
    }

    // Hand-edited ?labId= must return nothing, not fall back to the whole allowed set.
    [Fact]
    public void Picking_a_lab_outside_the_scope_returns_nothing()
    {
        var (parts, _) = Scope(requestedLabId: 42, allowedLabIds: new[] { 3, 9 });
        Assert.Contains("1=0", parts);
        Assert.DoesNotContain(parts, x => x.Contains("IN (", StringComparison.Ordinal));
    }

    [Fact]
    public void Single_lab_user_is_restricted_to_that_lab()
    {
        var (parts, parameters) = Scope(requestedLabId: null, allowedLabIds: new[] { 5 });

        Assert.Contains("a.LabID IN (@ScopeLab0)", parts);
        Assert.Equal(5, (int)Assert.Single(parameters).Value!);
    }
}
