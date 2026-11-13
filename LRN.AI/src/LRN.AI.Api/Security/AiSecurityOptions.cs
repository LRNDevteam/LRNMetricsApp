using System.Security.Claims;

namespace LRN.AI.Api.Security;

internal sealed class AiSecurityOptions
{
    public const string SectionName = "AI:Security";

    public bool DevelopmentBypass { get; set; }

    /// <summary>
    /// Roles allowed to list and compare models. The compare endpoint takes free text, so it is an evaluation tool
    /// for a small group, not an ordinary-user feature. Empty by default so configuration replaces it rather than
    /// appending to it.
    /// </summary>
    public List<string> ModelEvaluationRoles { get; set; } = [];

    public int ComparePermitsPerMinute { get; set; } = 10;
    public long MaxRequestBodyBytes { get; set; } = 128 * 1024;
    public List<string> AllowedCorsOrigins { get; set; } = [];
}

internal static class AuthPolicies
{
    public const string ModelEvaluation = "AI.ModelEvaluation";
}

internal static class RateLimitPolicies
{
    public const string Compare = "AI.Compare";
}

internal static class CallerIdentity
{
    public static string UserId(ClaimsPrincipal user) =>
        user.FindFirst(ClaimTypes.NameIdentifier)?.Value
        ?? user.Identity?.Name
        ?? "anonymous";
}
