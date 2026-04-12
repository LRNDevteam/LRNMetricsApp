using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc.Filters;

namespace LabMetricsDashboard.Filters;

public sealed class AppUsageAuditFilter : IAsyncActionFilter
{
    private readonly IAppUsageAuditService _auditService;
    private readonly ILogger<AppUsageAuditFilter> _logger;

    public AppUsageAuditFilter(IAppUsageAuditService auditService, ILogger<AppUsageAuditFilter> logger)
    {
        _auditService = auditService;
        _logger = logger;
    }

    public async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        var resultContext = await next();

        try
        {
            var httpContext = context.HttpContext;
            var request = httpContext.Request;
            if (!HttpMethods.IsGet(request.Method))
            {
                return;
            }

            var controller = context.RouteData.Values["controller"]?.ToString() ?? string.Empty;
            var action = context.RouteData.Values["action"]?.ToString() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(controller) || string.IsNullOrWhiteSpace(action))
            {
                return;
            }

            // Skip noise endpoints/static-ish views.
            if (controller.Equals("Usage", StringComparison.OrdinalIgnoreCase) &&
                action.Equals("Heartbeat", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            if (resultContext.Exception is not null)
            {
                return;
            }

            var pageName = $"{controller}/{action}";
            await _auditService.LogPageVisitAsync(httpContext, pageName, httpContext.RequestAborted);
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Usage audit filter skipped due to logging error.");
        }
    }
}
