using System.Net;
using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace LRN.AI.Api.Security;

internal sealed class LrnJwtAuthenticationOptions : AuthenticationSchemeOptions
{
    public string SigningKey { get; set; } = string.Empty;
    public string Issuer { get; set; } = LrnJwtValidator.DefaultIssuer;
    public string Audience { get; set; } = LrnJwtValidator.DefaultAudience;

    /// <summary>Development only (enforced at startup): loopback callers are signed in as a local developer.</summary>
    public bool DevelopmentBypass { get; set; }
    public IReadOnlyList<string> DevelopmentRoles { get; set; } = [];
}

internal sealed class LrnJwtAuthenticationHandler(
    IOptionsMonitor<LrnJwtAuthenticationOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder) : AuthenticationHandler<LrnJwtAuthenticationOptions>(options, logger, encoder)
{
    public const string SchemeName = "LrnJwt";
    public const string DevelopmentUserId = "local-developer";

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (Options.DevelopmentBypass)
        {
            // Loopback only, so a Development build bound to a network interface still needs real tokens.
            if (!IsLoopback(Context.Connection.RemoteIpAddress))
                return Task.FromResult(AuthenticateResult.Fail("The development sign-in accepts loopback callers only."));

            var claims = new List<Claim> { new(ClaimTypes.NameIdentifier, DevelopmentUserId), new(ClaimTypes.Name, DevelopmentUserId) };
            claims.AddRange(Options.DevelopmentRoles.Select(r => new Claim(ClaimTypes.Role, r)));
            var developer = new ClaimsPrincipal(new ClaimsIdentity(claims, "LrnDevelopmentBypass", ClaimTypes.Name, ClaimTypes.Role));
            return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(developer, SchemeName)));
        }

        var header = Request.Headers.Authorization.ToString();
        if (!header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return Task.FromResult(AuthenticateResult.NoResult());

        var token = header["Bearer ".Length..].Trim();
        return Task.FromResult(
            LrnJwtValidator.TryValidate(token, Options.SigningKey, Options.Issuer, Options.Audience, DateTimeOffset.UtcNow, out var principal, out var failure)
                ? AuthenticateResult.Success(new AuthenticationTicket(principal!, SchemeName))
                : AuthenticateResult.Fail(failure));
    }

    private static bool IsLoopback(IPAddress? address)
    {
        if (address is null) return false;
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        return IPAddress.IsLoopback(address);
    }
}
