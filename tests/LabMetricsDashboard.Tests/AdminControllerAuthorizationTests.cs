using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using LabMetricsDashboard.Controllers;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// HIPAA finding F2. AdminController creates users, grants roles and grants lab access, and it
/// carried no [Authorize] at all - only the four Menu* actions were protected, so user creation,
/// role assignment and user deletion were reachable by anyone who could reach the site.
///
/// <para>
/// These assert the ATTRIBUTES rather than driving HTTP. That is deliberate. An integration test
/// proves the two endpoints it happens to call are protected; reflecting over the whole controller
/// proves every action is, including one added next month. The regression these guard against is
/// somebody adding an endpoint and forgetting, which a fixed list of URLs cannot catch.
/// </para>
/// </summary>
public sealed class AdminControllerAuthorizationTests
{
    private static readonly Type Controller = typeof(AdminController);

    private static IEnumerable<MethodInfo> PublicActions() =>
        Controller.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
                  .Where(m => !m.IsSpecialName)
                  .Where(m => !m.IsDefined(typeof(NonActionAttribute), inherit: true));

    private static bool Mutating(MethodInfo action) =>
        action.IsDefined(typeof(HttpPostAttribute), true)
        || action.IsDefined(typeof(HttpPutAttribute), true)
        || action.IsDefined(typeof(HttpDeleteAttribute), true)
        || action.IsDefined(typeof(HttpPatchAttribute), true);

    [Fact]
    public void Controller_requires_the_Admin_role()
    {
        var authorize = Controller.GetCustomAttributes<AuthorizeAttribute>(inherit: true).ToList();

        Assert.True(authorize.Count > 0,
            "AdminController has no [Authorize]. Every action on it manages users, roles or lab " +
            "access, so an unauthenticated caller could create an account and grant it any lab.");

        Assert.Contains(authorize, a =>
            !string.IsNullOrWhiteSpace(a.Roles) &&
            a.Roles!.Split(',').Select(r => r.Trim())
             .Contains("Admin", StringComparer.OrdinalIgnoreCase));
    }

    [Fact]
    public void Controller_is_not_opted_out_of_authorization()
    {
        // A class-level [Authorize] means nothing if an action carries [AllowAnonymous]: the
        // anonymous attribute wins.
        var opted = PublicActions()
            .Where(m => m.IsDefined(typeof(AllowAnonymousAttribute), inherit: true))
            .Select(m => m.Name)
            .ToList();

        Assert.True(opted.Count == 0,
            $"[AllowAnonymous] overrides the controller's [Authorize] on: {string.Join(", ", opted)}.");
    }

    [Fact]
    public void Every_mutating_action_validates_the_antiforgery_token()
    {
        var unprotected = PublicActions()
            .Where(Mutating)
            .Where(m => !m.IsDefined(typeof(ValidateAntiForgeryTokenAttribute), inherit: true))
            .Where(m => !m.IsDefined(typeof(IgnoreAntiforgeryTokenAttribute), inherit: true))
            .Select(m => m.Name)
            .OrderBy(n => n)
            .ToList();

        Assert.True(unprotected.Count == 0,
            "These POST/PUT/DELETE actions accept a cross-site request: " +
            string.Join(", ", unprotected));
    }

    [Theory]
    // The seven that were reachable without a token before F2 was fixed. Named individually so a
    // failure says which endpoint regressed rather than only that the count changed.
    [InlineData("CreateUserAjax")]
    [InlineData("CreateRoleAjax")]
    [InlineData("AssignRoleAjax")]
    [InlineData("AssignUserLabAjax")]
    [InlineData("RemoveUserRole")]
    [InlineData("RemoveUserLab")]
    [InlineData("RemoveUser")]
    public void Named_ajax_endpoint_is_protected(string actionName)
    {
        var action = PublicActions().FirstOrDefault(m => m.Name == actionName);

        Assert.True(action is not null, $"AdminController.{actionName} no longer exists.");
        Assert.True(action!.IsDefined(typeof(ValidateAntiForgeryTokenAttribute), inherit: true),
            $"{actionName} does not validate the antiforgery token.");
    }
}
