using System.Security.Claims;
using System.Threading.RateLimiting;
using LRN.AI.Api.Security;
using Microsoft.AspNetCore.Authorization;

namespace LRN.AI.Api.Extensions;

internal static class SecurityServiceCollectionExtensions
{
    /// <summary>
    /// Authentication, authorisation, rate limiting and CORS. Fails at startup rather than running open: no signing
    /// key means no API unless the Development-only bypass is on.
    /// </summary>
    public static IServiceCollection AddLrnAiSecurity(this IServiceCollection services, IConfiguration configuration, IHostEnvironment environment)
    {
        var security = configuration.GetSection(AiSecurityOptions.SectionName).Get<AiSecurityOptions>() ?? new AiSecurityOptions();
        var auth = configuration.GetSection("DenialWorkflowAuth");
        var signingKey = auth["JwtSigningKey"] ?? string.Empty;

        if (security.DevelopmentBypass && !environment.IsDevelopment())
            throw new InvalidOperationException($"{AiSecurityOptions.SectionName}:DevelopmentBypass is only permitted in the Development environment.");
        if (!security.DevelopmentBypass && signingKey.Length < LrnJwtValidator.MinimumKeyLength)
            throw new InvalidOperationException(
                "DenialWorkflowAuth:JwtSigningKey is not configured. Supply the key LabMetricsDashboard signs with (32+ characters) " +
                "through user-secrets, appsettings.Local.json or the DenialWorkflowAuth__JwtSigningKey environment variable.");
        if (security.ModelEvaluationRoles.Count == 0)
            throw new InvalidOperationException($"{AiSecurityOptions.SectionName}:ModelEvaluationRoles must list at least one role.");
        if (security.ComparePermitsPerMinute < 1)
            throw new InvalidOperationException($"{AiSecurityOptions.SectionName}:ComparePermitsPerMinute must be at least 1.");

        services.AddAuthentication(LrnJwtAuthenticationHandler.SchemeName)
            .AddScheme<LrnJwtAuthenticationOptions, LrnJwtAuthenticationHandler>(LrnJwtAuthenticationHandler.SchemeName, o =>
            {
                o.SigningKey = signingKey;
                o.Issuer = auth["Issuer"] ?? LrnJwtValidator.DefaultIssuer;
                o.Audience = auth["Audience"] ?? LrnJwtValidator.DefaultAudience;
                o.DevelopmentBypass = security.DevelopmentBypass;
                o.DevelopmentRoles = security.ModelEvaluationRoles;
            });

        var evaluationRoles = new HashSet<string>(security.ModelEvaluationRoles, StringComparer.OrdinalIgnoreCase);
        services.AddAuthorizationBuilder()
            // Secure by default: any endpoint without an explicit policy still needs a signed-in user.
            .SetFallbackPolicy(new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build())
            .AddPolicy(AuthPolicies.ModelEvaluation, policy => policy
                .RequireAuthenticatedUser()
                .RequireAssertion(context => context.User.FindAll(ClaimTypes.Role).Any(role => evaluationRoles.Contains(role.Value))));

        services.AddRateLimiter(options =>
        {
            options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
            options.AddPolicy(RateLimitPolicies.Compare, context => RateLimitPartition.GetFixedWindowLimiter(
                CallerIdentity.UserId(context.User),
                _ => new FixedWindowRateLimiterOptions
                {
                    PermitLimit = security.ComparePermitsPerMinute,
                    Window = TimeSpan.FromMinutes(1),
                    QueueLimit = 0
                }));
        });

        if (security.AllowedCorsOrigins.Count > 0)
        {
            services.AddCors(options => options.AddDefaultPolicy(policy => policy
                .WithOrigins([.. security.AllowedCorsOrigins])
                .WithMethods("GET", "POST")
                .WithHeaders("Authorization", "Content-Type")));
        }

        return services;
    }
}
