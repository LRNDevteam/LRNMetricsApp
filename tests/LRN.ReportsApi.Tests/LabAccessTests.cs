using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Claims;
using System.Threading;
using System.Threading.Tasks;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Security;
using LRN.ReportsApi.Services;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>
/// HIPAA finding F4. The lab check existed, but only inside DenialActionVerificationController and
/// only that controller called it. Every other workflow endpoint took a labId and used it: notes,
/// claim history, document download, document upload and delete, bulk import and the export jobs.
/// A token issued for lab 1 read lab 2 by changing one number in the query string.
///
/// <para>
/// Finding F10 is covered here too, because the fix shares a code path: the admin check used to
/// normalise the FIRST role claim and ask whether it CONTAINED "ADMIN".
/// </para>
/// </summary>
public sealed class LabAccessTests
{
    private static ClaimsPrincipal Token(string[]? roles = null, int[]? labIds = null, string? name = "analyst@lab")
    {
        var claims = new List<Claim>();
        foreach (var role in roles ?? Array.Empty<string>()) claims.Add(new Claim("role", role));
        foreach (var id in labIds ?? Array.Empty<int>()) claims.Add(new Claim("lab_id", id.ToString()));
        if (name is not null) claims.Add(new Claim(ClaimTypes.Name, name));

        return new ClaimsPrincipal(new ClaimsIdentity(claims, "TestJwt"));
    }

    private static LabAccess Build(params int[] fallbackLabIds) =>
        new(new StubWorkflowService(fallbackLabIds));

    // ── the finding itself ──────────────────────────────────────────────────────────────────

    [Fact]
    public async Task A_token_for_one_lab_cannot_reach_another()
    {
        var access = Build();

        Assert.True(await access.CanAccessAsync(Token(labIds: new[] { 1 }), 1, CancellationToken.None));
        Assert.False(await access.CanAccessAsync(Token(labIds: new[] { 1 }), 2, CancellationToken.None));
    }

    [Fact]
    public async Task A_token_carrying_several_labs_reaches_all_of_them()
    {
        var access = Build();
        var token = Token(labIds: new[] { 1, 4, 7 });

        Assert.True(await access.CanAccessAsync(token, 4, CancellationToken.None));
        Assert.True(await access.CanAccessAsync(token, 7, CancellationToken.None));
        Assert.False(await access.CanAccessAsync(token, 8, CancellationToken.None));
    }

    [Fact]
    public async Task An_admin_reaches_every_lab()
    {
        Assert.True(await Build().CanAccessAsync(Token(new[] { "Admin" }), 99, CancellationToken.None));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public async Task A_non_positive_lab_id_is_refused(int labId)
    {
        // Refused rather than ignored. Treating 0 as "no lab named, nothing to check" is how an
        // unset value becomes a way past the filter.
        Assert.False(await Build().CanAccessAsync(Token(labIds: new[] { 1 }), labId, CancellationToken.None));
    }

    [Fact]
    public async Task The_database_fallback_is_used_only_when_the_token_carries_no_labs()
    {
        // Tokens issued before lab claims existed still have to work.
        Assert.True(await Build(5).CanAccessAsync(Token(), 5, CancellationToken.None));
        Assert.False(await Build(5).CanAccessAsync(Token(), 6, CancellationToken.None));

        // A token that DOES carry labs is authoritative: the fallback must not widen it.
        Assert.False(await Build(6).CanAccessAsync(Token(labIds: new[] { 5 }), 6, CancellationToken.None));
    }

    [Fact]
    public async Task An_unnamed_caller_with_no_lab_claims_gets_nothing()
    {
        Assert.False(await Build(5).CanAccessAsync(Token(name: null), 5, CancellationToken.None));
    }

    // ── F10: exact role matching ────────────────────────────────────────────────────────────

    [Theory]
    [InlineData("Admin")]
    [InlineData("LRN Admin")]
    [InlineData("LRNAdmin")]
    [InlineData("lrn-admin")]   // normalisation still collapses spacing and case
    public void Real_admin_role_names_are_recognised(string role)
    {
        Assert.True(Build().IsAdmin(Token(new[] { role })));
    }

    [Theory]
    [InlineData("Non Admin")]
    [InlineData("Admin Assistant")]
    [InlineData("Administrative Reviewer")]
    [InlineData("NotAnAdministrator")]
    public void A_role_that_merely_contains_the_word_admin_is_not_admin(string role)
    {
        // The old check asked whether the normalised role CONTAINED "ADMIN", so every one of these
        // was granted administrator rights across every lab.
        Assert.False(Build().IsAdmin(Token(new[] { role })));
    }

    [Fact]
    public void Admin_is_found_even_when_it_is_not_the_first_role_claim()
    {
        // The old check read only the first role claim, so an admin whose token happened to list
        // another role first silently lost their rights.
        Assert.True(Build().IsAdmin(Token(new[] { "AR Reviewer", "Admin" })));
    }

    [Fact]
    public void Roles_packed_into_one_comma_separated_claim_are_all_read()
    {
        var packed = new ClaimsPrincipal(new ClaimsIdentity(
            new[] { new Claim("roles", "AR Reviewer,Admin") }, "TestJwt"));

        Assert.True(Build().IsAdmin(packed));
    }

    [Fact]
    public void HasRole_matches_exactly_rather_than_by_substring()
    {
        Assert.True(LabAccess.HasRole(Token(new[] { "AR Manager" }), "ARManager"));
        Assert.False(LabAccess.HasRole(Token(new[] { "AR Manager Assistant" }), "ARManager"));
    }

    // ── token parsing ───────────────────────────────────────────────────────────────────────

    [Fact]
    public void Lab_ids_are_read_from_either_claim_spelling()
    {
        var token = new ClaimsPrincipal(new ClaimsIdentity(
            new[] { new Claim("lab_id", "1"), new Claim("labs", "4,7") }, "TestJwt"));

        Assert.Equal(new[] { 1, 4, 7 }, LabAccess.LabIdsFromToken(token).OrderBy(x => x));
    }

    [Fact]
    public void Unparseable_and_non_positive_lab_claims_are_discarded()
    {
        var token = new ClaimsPrincipal(new ClaimsIdentity(
            new[] { new Claim("lab_id", "abc"), new Claim("lab_id", "0"), new Claim("lab_id", "3") }, "TestJwt"));

        Assert.Equal(new[] { 3 }, LabAccess.LabIdsFromToken(token));
    }

    /// <summary>The database fallback, standing in for the real lookup.</summary>
    private sealed class StubWorkflowService : IUserLabLookup
    {
        private readonly int[] _labIds;
        public StubWorkflowService(int[] labIds) => _labIds = labIds;

        public Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsForUserAsync(string userName, CancellationToken ct)
            => Task.FromResult<IReadOnlyList<DenialWorkflowLabOption>>(
                _labIds.Select(id => new DenialWorkflowLabOption { LabId = id, LabName = $"Lab{id}" }).ToList());
    }
}
