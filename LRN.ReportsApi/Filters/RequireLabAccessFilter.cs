using System.Collections;
using System.Reflection;
using LRN.ReportsApi.Security;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace LRN.ReportsApi.Filters;

/// <summary>
/// Exempts an action or controller from <see cref="RequireLabAccessFilter"/>.
/// </summary>
/// <remarks>
/// For an endpoint where a lab id is not a scope for reading that lab's data - the import worker
/// writing across labs, or an endpoint that lists which labs the caller has. Only ever safe where
/// something else already restricts the caller.
/// </remarks>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, AllowMultiple = false)]
public sealed class SkipLabAccessCheckAttribute : Attribute
{
}

/// <summary>
/// Refuses any request carrying a lab id the caller is not entitled to.
///
/// <para>
/// HIPAA finding F4. The check existed on one controller. Every other workflow endpoint took a
/// labId and used it - notes, claim history, document download, document upload and delete, bulk
/// import, export jobs - so a token issued for lab 1 read lab 2 by changing a number in the query
/// string. Registered globally for the workflow and master-values routes so a new endpoint is
/// covered on the day it is written rather than when somebody notices.
/// </para>
/// <para>
/// Bound body models are searched as well as the route and query string, because most of the POST
/// endpoints here take the lab inside a JSON object rather than on the URL.
/// </para>
/// </summary>
public sealed class RequireLabAccessFilter : IAsyncActionFilter
{
    /// <summary>Route prefixes this filter applies to. Everything else passes through untouched.</summary>
    private static readonly string[] GuardedPathPrefixes =
    {
        "/api/denialworkflow",
        "/api/denial-workflow",
        "/api/master-values",
    };

    private static readonly string[] LabIdKeys = { "labId", "labid", "LabId", "LabID", "lab_id" };

    // Reflecting over a model on every request would be wasteful; the shape of a type never
    // changes, so the answer is cached per type for the process lifetime.
    private static readonly Dictionary<Type, PropertyInfo[]> LabPropertyCache = new();
    private static readonly object CacheGate = new();

    private readonly ILabAccess _labAccess;
    private readonly ILogger<RequireLabAccessFilter> _logger;

    public RequireLabAccessFilter(ILabAccess labAccess, ILogger<RequireLabAccessFilter> logger)
    {
        _labAccess = labAccess;
        _logger = logger;
    }

    public async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        var http = context.HttpContext;
        var path = http.Request.Path.Value ?? string.Empty;

        var guarded = GuardedPathPrefixes.Any(p => path.StartsWith(p, StringComparison.OrdinalIgnoreCase));
        if (!guarded || Skipped(context))
        {
            await next();
            return;
        }

        // Anonymous requests are the authentication layer's problem, not this filter's. Refusing
        // here would turn a 401 into a 403 and hide the real reason.
        if (http.User?.Identity?.IsAuthenticated != true)
        {
            await next();
            return;
        }

        foreach (var labId in CollectLabIds(context).Distinct())
        {
            if (await _labAccess.CanAccessAsync(http.User, labId, http.RequestAborted)) continue;

            _logger.LogWarning(
                "Lab access denied. User={User} LabId={LabId} Method={Method} Path={Path}",
                LabAccess.UserName(http.User) ?? "(unknown)", labId, http.Request.Method, path);

            context.Result = new ObjectResult(new { message = LabAccess.DeniedMessage })
            {
                StatusCode = StatusCodes.Status403Forbidden
            };
            return;
        }

        await next();
    }

    private static bool Skipped(ActionExecutingContext context) =>
        context.ActionDescriptor.EndpointMetadata.OfType<SkipLabAccessCheckAttribute>().Any();

    private static IEnumerable<int> CollectLabIds(ActionExecutingContext context)
    {
        // Bound arguments first: they cover the JSON body, which is where most of these endpoints
        // carry the lab, and they are already parsed.
        foreach (var (name, value) in context.ActionArguments)
        {
            if (value is null) continue;

            if (value is int id && Matches(name))
            {
                if (id > 0) yield return id;
                continue;
            }

            if (value is string s && Matches(name) && int.TryParse(s, out var parsed))
            {
                if (parsed > 0) yield return parsed;
                continue;
            }

            // A complex model: any property called LabId counts, however nested the model is not -
            // one level is enough for every request shape in this API, and recursing risks walking
            // an entity graph on every call.
            if (value is not string && value.GetType().IsClass)
            {
                foreach (var found in FromModel(value)) yield return found;
            }
        }

        var request = context.HttpContext.Request;

        foreach (var key in LabIdKeys)
        {
            if (context.RouteData.Values.TryGetValue(key, out var routeValue)
                && int.TryParse(routeValue?.ToString(), out var routeId) && routeId > 0)
            {
                yield return routeId;
            }

            if (request.Query.TryGetValue(key, out var queryValues))
            {
                foreach (var v in queryValues)
                    if (int.TryParse(v, out var queryId) && queryId > 0) yield return queryId;
            }
        }
    }

    private static IEnumerable<int> FromModel(object model)
    {
        // A list of models (bulk operations) is searched element by element.
        if (model is IEnumerable enumerable and not string)
        {
            foreach (var item in enumerable)
            {
                if (item is null || !item.GetType().IsClass || item is string) continue;
                foreach (var found in ReadLabProperties(item)) yield return found;
            }
            yield break;
        }

        foreach (var found in ReadLabProperties(model)) yield return found;
    }

    private static IEnumerable<int> ReadLabProperties(object model)
    {
        foreach (var property in LabProperties(model.GetType()))
        {
            var raw = property.GetValue(model);

            var id = raw switch
            {
                int i => i,
                long l when l is > 0 and <= int.MaxValue => (int)l,
                string s when int.TryParse(s, out var parsed) => parsed,
                _ => 0
            };

            if (id > 0) yield return id;
        }
    }

    private static PropertyInfo[] LabProperties(Type type)
    {
        lock (CacheGate)
        {
            if (LabPropertyCache.TryGetValue(type, out var cached)) return cached;

            var properties = type
                .GetProperties(BindingFlags.Public | BindingFlags.Instance)
                .Where(p => p.CanRead && p.GetIndexParameters().Length == 0)
                .Where(p => Matches(p.Name))
                .ToArray();

            LabPropertyCache[type] = properties;
            return properties;
        }
    }

    private static bool Matches(string name) =>
        LabIdKeys.Any(k => string.Equals(k, name, StringComparison.OrdinalIgnoreCase));
}
