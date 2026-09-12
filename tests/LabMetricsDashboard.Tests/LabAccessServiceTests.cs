using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Claims;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.Services.Security;
using Microsoft.AspNetCore.Http;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// HIPAA finding F3. Every controller used to build its lab list from
/// <c>LabSettings.Labs.Keys</c> - every configured lab, for every user - and hand that to
/// <see cref="LabSelectionHelper"/> as "availableLabs". Because the list held every lab, any
/// <c>?lab=</c> was accepted, so an authenticated user could read any lab's data by editing the
/// query string. The navbar showed the correct narrower list, so the UI and the server disagreed
/// and only the UI was right.
/// </summary>
public sealed class LabAccessServiceTests
{
    private const string Cove = "Cove";
    private const string Certus = "Certus";
    private const string Demo = "LRNLabDemo";

    private static LabAccessService Build()
    {
        var settings = new LabSettings
        {
            Labs = new Dictionary<string, LabCsvConfig>(StringComparer.OrdinalIgnoreCase)
            {
                [Cove] = new(),
                [Certus] = new(),
                [Demo] = new(),
            }
        };

        var config = new LabConfigOptions
        {
            LabsID = { new LabIdInfo { Id = 4, Name = Cove }, new LabIdInfo { Id = 7, Name = Certus } },
            DemoLabs = { Demo },
        };

        return new LabAccessService(settings, config);
    }

    private static ClaimsPrincipal User(string? role = null, params string[] labs)
    {
        var claims = labs.Select(l => new Claim("LabName", l)).ToList();
        if (role is not null) claims.Add(new Claim(ClaimTypes.Role, role));

        // The authentication type is what makes IsAuthenticated true; without one, every principal
        // reads as anonymous and the tests would pass for the wrong reason.
        return new ClaimsPrincipal(new ClaimsIdentity(claims, "TestAuth"));
    }

    [Fact]
    public void A_user_sees_only_the_labs_they_are_assigned()
    {
        var allowed = Build().GetAllowedLabNames(User(labs: Cove));

        Assert.Equal(new[] { Cove }, allowed);
    }

    [Fact]
    public void A_user_cannot_reach_another_labs_data()
    {
        // The whole finding in one assertion: this is what ?lab=Certus used to do.
        Assert.False(Build().CanAccess(User(labs: Cove), Certus));
    }

    [Fact]
    public void An_anonymous_principal_gets_nothing()
    {
        var anonymous = new ClaimsPrincipal(new ClaimsIdentity());

        Assert.Empty(Build().GetAllowedLabNames(anonymous));
        Assert.False(Build().CanAccess(anonymous, Cove));
    }

    [Fact]
    public void An_admin_sees_every_lab_except_an_unassigned_demo_lab()
    {
        var allowed = Build().GetAllowedLabNames(User("Admin"));

        Assert.Contains(Cove, allowed);
        Assert.Contains(Certus, allowed);

        // A demo lab holds deliberately frozen data. On an admin's screen it reads as a stalled
        // pipeline, so it appears only for someone explicitly assigned it.
        Assert.DoesNotContain(Demo, allowed);
    }

    [Fact]
    public void An_admin_assigned_the_demo_lab_does_see_it()
    {
        Assert.Contains(Demo, Build().GetAllowedLabNames(User("Admin", Demo)));
    }

    [Theory]
    [InlineData(4, true)]    // Cove, which this user has
    [InlineData(7, false)]   // Certus, which they do not
    [InlineData(999, false)] // maps to no lab at all
    public void Access_by_lab_id_follows_the_same_rule(int labId, bool expected)
    {
        Assert.Equal(expected, Build().CanAccess(User(labs: Cove), labId));
    }

    [Fact]
    public void Lab_names_are_matched_case_insensitively()
    {
        // Lab names come from claims, query strings and cookies, and the casing is not consistent
        // between them. A case-sensitive comparison would lock a user out of their own lab.
        Assert.True(Build().CanAccess(User(labs: Cove), "cove"));
        Assert.True(Build().CanAccess(User(labs: "COVE"), "Cove"));
    }

    [Fact]
    public void RequireAccess_returns_the_configured_spelling_not_the_callers()
    {
        // Several downstream dictionaries are keyed by lab name and not all compare
        // case-insensitively, so the caller's casing must not propagate.
        Assert.Equal(Cove, Build().RequireAccess(User(labs: Cove), "cOvE"));
    }

    [Fact]
    public void RequireAccess_throws_for_a_lab_the_user_does_not_have()
    {
        var ex = Assert.Throws<LabAccessDeniedException>(
            () => Build().RequireAccess(User(labs: Cove), Certus));

        Assert.Equal(Certus, ex.LabName);
    }

    [Fact]
    public void RequireAccess_with_no_lab_falls_back_to_the_users_own_first_lab()
    {
        // Never to the first CONFIGURED lab, which is how a user with no assignment used to land
        // on somebody else's data.
        Assert.Equal(Certus, Build().RequireAccess(User(labs: Certus), null));
        Assert.Equal(string.Empty, Build().RequireAccess(User(), null));
    }
}

/// <summary>
/// The query-string half of F3: <see cref="LabSelectionHelper.Resolve"/> took an explicit
/// <c>?lab=</c> at face value. The cookie path was already checked against the available list, so
/// the query string - the one an attacker controls - was the only unchecked route in.
/// </summary>
public sealed class LabSelectionHelperTests
{
    private static HttpContext Context() => new DefaultHttpContext();

    [Fact]
    public void An_explicit_lab_outside_the_allowed_list_is_refused()
    {
        var ex = Assert.Throws<LabAccessDeniedException>(
            () => LabSelectionHelper.Resolve(Context(), "Certus", new List<string> { "Cove" }));

        Assert.Equal("Certus", ex.LabName);
    }

    [Fact]
    public void An_explicit_allowed_lab_is_returned()
    {
        Assert.Equal("Cove", LabSelectionHelper.Resolve(Context(), "Cove", new List<string> { "Cove" }));
    }

    [Fact]
    public void An_allowed_lab_comes_back_in_its_configured_spelling()
    {
        Assert.Equal("Cove", LabSelectionHelper.Resolve(Context(), "cove", new List<string> { "Cove" }));
    }

    [Fact]
    public void No_lab_named_falls_back_to_the_first_allowed_lab()
    {
        Assert.Equal("Cove", LabSelectionHelper.Resolve(Context(), null, new List<string> { "Cove", "Certus" }));
    }

    [Fact]
    public void A_cookie_naming_a_lab_the_user_lost_access_to_is_ignored()
    {
        // Lab assignments change. A stale cookie must not outlive the assignment that justified it.
        var context = Context();
        context.Request.Headers.Cookie = "lmd_selected_lab=Certus";

        Assert.Equal("Cove", LabSelectionHelper.Resolve(context, null, new List<string> { "Cove" }));
    }

    [Fact]
    public void A_user_with_no_labs_gets_an_empty_selection_rather_than_someone_elses()
    {
        Assert.Equal(string.Empty, LabSelectionHelper.Resolve(Context(), null, new List<string>()));
    }
}
