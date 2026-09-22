using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Claims;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// Tenant isolation on the lab dimension. Every page resolves its lab through
/// <see cref="LabSelectionHelper"/> and then opens THAT lab's database, so these are the tests
/// that say one client cannot read another's data.
///
/// <para>Written after the real defect: the ?lab= query parameter was returned unvalidated, so any
/// authenticated user could read any lab by editing one query string.</para>
/// </summary>
public class LabSelectionSecurityTests
{
    private static readonly List<string> Configured = ["Cove", "VariantX", "NorthWest", "LRNLabDemo"];

    private static HttpContext Context(IEnumerable<string> labClaims, params string[] roles)
    {
        var claims = labClaims.Select(l => new Claim("LabName", l)).ToList();
        claims.AddRange(roles.Select(r => new Claim(ClaimTypes.Role, r)));

        var services = new ServiceCollection();
        services.AddSingleton(new LabConfigOptions { DemoLabs = { "LRNLabDemo" } });

        return new DefaultHttpContext
        {
            User = new ClaimsPrincipal(new ClaimsIdentity(claims, "TestAuth")),
            RequestServices = services.BuildServiceProvider()
        };
    }

    [Fact]
    public void Lab_user_cannot_reach_another_lab_via_the_query_string()
    {
        var context = Context(["VariantX"]);

        var resolved = LabSelectionHelper.Resolve(context, "Cove", Configured);

        Assert.Equal("VariantX", resolved);
    }

    [Fact]
    public void Lab_user_gets_their_own_lab_when_no_lab_is_requested()
        => Assert.Equal("VariantX", LabSelectionHelper.Resolve(Context(["VariantX"]), null, Configured));

    [Fact]
    public void Lab_user_may_reach_a_lab_they_are_assigned()
        => Assert.Equal("Cove", LabSelectionHelper.Resolve(Context(["VariantX", "Cove"]), "Cove", Configured));

    [Fact]
    public void Requested_lab_is_matched_case_insensitively_and_returned_in_configured_spelling()
        => Assert.Equal("VariantX", LabSelectionHelper.Resolve(Context(["VariantX"]), "variantx", Configured));

    [Fact]
    public void A_forged_cookie_cannot_reach_another_lab()
    {
        var context = Context(["VariantX"]);
        context.Request.Headers.Cookie = "lmd_selected_lab=Cove";

        Assert.Equal("VariantX", LabSelectionHelper.Resolve(context, null, Configured));
    }

    [Fact]
    public void User_with_no_labs_resolves_to_nothing_rather_than_someone_elses_lab()
        => Assert.Equal(string.Empty, LabSelectionHelper.Resolve(Context([]), "Cove", Configured));

    [Fact]
    public void Unauthenticated_request_resolves_to_nothing()
    {
        var context = new DefaultHttpContext { User = new ClaimsPrincipal(new ClaimsIdentity()) };

        Assert.Equal(string.Empty, LabSelectionHelper.Resolve(context, "Cove", Configured));
    }

    [Fact]
    public void Super_admin_may_reach_any_configured_lab()
        => Assert.Equal("Cove", LabSelectionHelper.Resolve(Context([], "Super Admin"), "Cove", Configured));

    [Fact]
    public void Legacy_admin_role_still_reaches_any_lab_so_existing_cookies_keep_working()
        => Assert.Equal("Cove", LabSelectionHelper.Resolve(Context([], "Admin"), "Cove", Configured));

    [Fact]
    public void Super_admin_does_not_get_a_demo_lab_they_were_not_assigned()
        => Assert.Equal(string.Empty, LabSelectionHelper.Resolve(Context([], "Super Admin"), "LRNLabDemo", ["LRNLabDemo"]));

    [Fact]
    public void Super_admin_assigned_the_demo_lab_may_reach_it()
        => Assert.Equal("LRNLabDemo",
            LabSelectionHelper.Resolve(Context(["LRNLabDemo"], "Super Admin"), "LRNLabDemo", Configured));

    [Fact]
    public void Lab_admin_is_still_scoped_to_its_own_labs()
        => Assert.Equal("VariantX",
            LabSelectionHelper.Resolve(Context(["VariantX"], "Lab Admin"), "Cove", Configured));
}
