using LabMetricsDashboard.Services.Security;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace LabMetricsDashboard.Filters;

/// <summary>
/// Exempts an action or controller from <see cref="RequireLabAccessFilter"/>.
///
/// <para>
/// For endpoints where a lab id is the SUBJECT of administration rather than a scope for reading
/// data. AdminController.AssignUserLabAjax takes a labId in order to grant somebody access to it;
/// running the read rule over that would stop an admin assigning a demo lab, because an admin is
/// deliberately not given demo labs by <c>VisibleLabs</c>. Refusing there would break lab
/// administration to enforce a rule about reading lab data.
/// </para>
/// <para>
/// Only ever safe on an endpoint that is itself restricted by role. Every current use is on a
/// controller carrying [Authorize(Roles = "Admin")].
/// </para>
/// </summary>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, AllowMultiple = false)]
public sealed class SkipLabAccessCheckAttribute : Attribute
{
}

/// <summary>
/// Refuses any request that names a lab the caller is not entitled to, wherever the name appears.
///
/// <para>
/// HIPAA finding F3. Registered globally rather than applied per action, and that is the point:
/// the failure this guards against is an endpoint that takes a lab and whose author did not think
/// about access. A per-action attribute only protects the actions somebody remembered to decorate,
/// which is the situation that produced the finding. Export and download actions were the ones
/// most often missed, and they are the ones that hand over a whole file.
/// </para>
/// <para>
/// Route values, query string and form fields are all checked, because the same parameter is
/// spelled differently depending on the endpoint - <c>lab</c> on the page actions, <c>labId</c> on
/// the API-style ones, and both appear in forms on the export posts.
/// </para>
/// </summary>
public sealed class RequireLabAccessFilter : IAsyncActionFilter
{
    // Every spelling a lab arrives under in this application.
    private static readonly string[] NameKeys = { "lab", "labName", "labname", "selectedLab" };
    private static readonly string[] IdKeys = { "labId", "labid", "LabId", "LabID" };

    private readonly ILabAccessService _labAccess;
    private readonly ILogger<RequireLabAccessFilter> _logger;

    public RequireLabAccessFilter(ILabAccessService labAccess, ILogger<RequireLabAccessFilter> logger)
    {
        _labAccess = labAccess;
        _logger = logger;
    }

    public async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        var http = context.HttpContext;

        // Anonymous endpoints (the login page, the health check) name no lab and must stay
        // reachable. [Authorize] decides who gets in; this filter decides which lab they may name.
        if (http.User?.Identity?.IsAuthenticated != true)
        {
            await next();
            return;
        }

        if (HasSkipAttribute(context))
        {
            await next();
            return;
        }

        foreach (var (key, value) in CollectLabValues(context))
        {
            if (string.IsNullOrWhiteSpace(value)) continue;

            var allowed = int.TryParse(value, out var labId)
                ? _labAccess.CanAccess(http.User, labId)
                : _labAccess.CanAccess(http.User, value);

            if (allowed) continue;

            // Logged at Warning with the user and the lab they asked for. This is the line an
            // audit reads to answer "did anyone try", and a 403 with no log answers nothing.
            _logger.LogWarning(
                "Lab access denied. User={User} Lab={Lab} Parameter={Parameter} Path={Path}",
                http.User.Identity?.Name ?? "(unknown)", value, key, http.Request.Path);

            context.Result = new ForbidResult();
            return;
        }

        await next();
    }

    /// <summary>
    /// Every lab-shaped value on this request. Bound action arguments come first because they are
    /// already typed and already include anything bound from a JSON body.
    /// </summary>
    private static IEnumerable<(string Key, string? Value)> CollectLabValues(ActionExecutingContext context)
    {
        foreach (var (name, value) in context.ActionArguments)
        {
            if (value is null) continue;

            if (Matches(name, NameKeys) && value is string s)
                yield return (name, s);
            else if (Matches(name, IdKeys) && value is int id)
                yield return (name, id.ToString());
        }

        var request = context.HttpContext.Request;

        foreach (var key in NameKeys.Concat(IdKeys))
        {
            if (context.RouteData.Values.TryGetValue(key, out var routeValue))
                yield return (key, routeValue?.ToString());

            if (request.Query.TryGetValue(key, out var queryValue))
                foreach (var v in queryValue)
                    yield return (key, v);

            // HasFormContentType guards this: reading Form on a JSON or file-stream request throws.
            if (request.HasFormContentType && request.Form.TryGetValue(key, out var formValue))
                foreach (var v in formValue)
                    yield return (key, v);
        }
    }

    private static bool HasSkipAttribute(ActionExecutingContext context) =>
        context.ActionDescriptor.EndpointMetadata.OfType<SkipLabAccessCheckAttribute>().Any();

    private static bool Matches(string name, string[] keys) =>
        keys.Any(k => string.Equals(k, name, StringComparison.OrdinalIgnoreCase));
}

/// <summary>
/// Turns <see cref="LabAccessDeniedException"/> into a 403 instead of a 500.
/// </summary>
/// <remarks>
/// <see cref="LabSelectionHelper"/> throws from deep inside a controller action, where returning a
/// result is not an option. Without this the refusal would surface as an unhandled exception: the
/// user sees an error page, the operator sees a stack trace, and a deliberate security decision
/// reads as a bug in our code.
/// </remarks>
public sealed class LabAccessDeniedExceptionFilter : IExceptionFilter
{
    private readonly ILogger<LabAccessDeniedExceptionFilter> _logger;

    public LabAccessDeniedExceptionFilter(ILogger<LabAccessDeniedExceptionFilter> logger)
        => _logger = logger;

    public void OnException(ExceptionContext context)
    {
        if (context.Exception is not LabAccessDeniedException denied) return;

        _logger.LogWarning(
            "Lab access denied. User={User} Lab={Lab} Path={Path}",
            context.HttpContext.User?.Identity?.Name ?? "(unknown)",
            denied.LabName,
            context.HttpContext.Request.Path);

        context.Result = new ForbidResult();
        context.ExceptionHandled = true;
    }
}
