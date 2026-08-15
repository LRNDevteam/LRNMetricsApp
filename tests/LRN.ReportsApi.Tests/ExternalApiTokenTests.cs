using System.Security.Claims;
using LRN.ReportsApi.Controllers;
using LRN.ReportsApi.Security;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ApiSecretHasherTests
{
    [Fact]
    public void Verify_accepts_the_original_secret()
    {
        var hash = ApiSecretHasher.Hash("correct horse battery staple");
        Assert.True(ApiSecretHasher.Verify("correct horse battery staple", hash));
    }

    [Fact]
    public void Verify_rejects_a_wrong_secret()
    {
        var hash = ApiSecretHasher.Hash("correct horse battery staple");
        Assert.False(ApiSecretHasher.Verify("Correct horse battery staple", hash));
        Assert.False(ApiSecretHasher.Verify("", hash));
    }

    [Fact]
    public void Hash_is_salted_so_the_same_secret_yields_different_verifiers()
    {
        Assert.NotEqual(ApiSecretHasher.Hash("same"), ApiSecretHasher.Hash("same"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-a-hash")]
    [InlineData("pbkdf2$100$salt$hash")]          // iterations below the floor
    [InlineData("pbkdf2$210000$!!!$!!!")]          // non-base64
    [InlineData("bcrypt$210000$c2FsdA==$aGFzaA==")] // unknown scheme
    public void Verify_returns_false_for_a_malformed_stored_hash(string stored)
    {
        // A bad config line must read as "wrong secret", never throw into a 500.
        Assert.False(ApiSecretHasher.Verify("anything", stored));
    }
}

public class AuthControllerTests
{
    private const string SigningKey = "0123456789abcdef0123456789abcdef0123456789abcdef";
    private const string Secret = "s3cret-value-for-tests";

    private static AuthController Build(
        out ExternalApiClientOptions options,
        bool enabled = true,
        string? signingKey = SigningKey)
    {
        options = new ExternalApiClientOptions
        {
            TokenMinutes = 60,
            MaxFailedAttempts = 3,
            LockoutMinutes = 15,
            Clients =
            {
                new ExternalApiClient
                {
                    ClientId = "acme",
                    DisplayName = "Acme Analytics",
                    SecretHash = ApiSecretHasher.Hash(Secret),
                    Roles = { "ETL" },
                    Labs = { new ExternalApiClientLab { LabId = 4, LabName = "Cove" } },
                    Enabled = enabled
                }
            }
        };

        var settings = new Dictionary<string, string?>
        {
            ["DenialWorkflowAuth:Issuer"] = "LRNMetrics",
            ["DenialWorkflowAuth:Audience"] = "LRNReportsApi"
        };
        if (signingKey is not null) settings["DenialWorkflowAuth:JwtSigningKey"] = signingKey;

        var config = new ConfigurationBuilder().AddInMemoryCollection(settings).Build();

        return new AuthController(
            Options.Create(options),
            config,
            new MemoryCache(new MemoryCacheOptions()),
            NullLogger<AuthController>.Instance)
        {
            ControllerContext = new ControllerContext { HttpContext = new DefaultHttpContext() }
        };
    }

    private static AuthController.TokenRequest Request(string id, string secret) =>
        new() { ClientId = id, ClientSecret = secret };

    [Fact]
    public void Valid_credentials_return_a_token_the_api_validator_accepts()
    {
        var controller = Build(out _);

        var result = Assert.IsType<OkObjectResult>(controller.Token(Request("acme", Secret)));
        var token = result.Value!.GetType().GetProperty("access_token")!.GetValue(result.Value) as string;
        Assert.False(string.IsNullOrWhiteSpace(token));

        // The whole point: a token minted here must pass the same WorkflowJwt gate that guards
        // /api/analytics and /api/master-values.
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["DenialWorkflowAuth:JwtSigningKey"] = SigningKey,
            ["DenialWorkflowAuth:Issuer"] = "LRNMetrics",
            ["DenialWorkflowAuth:Audience"] = "LRNReportsApi"
        }).Build();

        var request = new DefaultHttpContext().Request;
        request.Headers.Authorization = $"Bearer {token}";

        Assert.True(WorkflowJwt.TryValidate(request, config, out var principal, out var reason), reason);
        Assert.Equal("Acme Analytics", principal.Identity!.Name);
    }

    [Fact]
    public void Issued_token_carries_the_configured_roles_and_labs()
    {
        var controller = Build(out _);
        var result = Assert.IsType<OkObjectResult>(controller.Token(Request("acme", Secret)));
        var token = (string)result.Value!.GetType().GetProperty("access_token")!.GetValue(result.Value)!;

        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["DenialWorkflowAuth:JwtSigningKey"] = SigningKey
        }).Build();
        var request = new DefaultHttpContext().Request;
        request.Headers.Authorization = $"Bearer {token}";
        Assert.True(WorkflowJwt.TryValidate(request, config, out var principal, out _));

        // ETL is the read-only role: it may view both masters but write neither.
        Assert.True(PayerMasterRoles.CanViewPolicy(principal));
        Assert.True(PayerMasterRoles.CanViewLab(principal));
        Assert.False(PayerMasterRoles.CanWritePolicy(principal));
        Assert.False(PayerMasterRoles.CanWriteLab(principal));
        Assert.False(PayerMasterRoles.IsLrnAdmin(principal));

        Assert.Equal("4", principal.FindFirst("lab_id")?.Value);
        Assert.Equal("Cove", principal.FindFirst("lab_name")?.Value);
    }

    [Fact]
    public void Wrong_secret_and_unknown_client_are_indistinguishable()
    {
        var badSecret = Assert.IsType<UnauthorizedObjectResult>(
            Build(out _).Token(Request("acme", "wrong")));
        var unknownClient = Assert.IsType<UnauthorizedObjectResult>(
            Build(out _).Token(Request("nope", Secret)));

        // Same status and same body, so client ids cannot be enumerated through the endpoint.
        Assert.Equal(badSecret.StatusCode, unknownClient.StatusCode);
        Assert.Equal(
            System.Text.Json.JsonSerializer.Serialize(badSecret.Value),
            System.Text.Json.JsonSerializer.Serialize(unknownClient.Value));
    }

    [Fact]
    public void Disabled_client_cannot_get_a_token()
    {
        var controller = Build(out _, enabled: false);
        Assert.IsType<UnauthorizedObjectResult>(controller.Token(Request("acme", Secret)));
    }

    [Fact]
    public void Repeated_failures_lock_the_client_out()
    {
        var controller = Build(out var options);
        for (var i = 0; i < options.MaxFailedAttempts; i++)
            Assert.IsType<UnauthorizedObjectResult>(controller.Token(Request("acme", "wrong")));

        var locked = Assert.IsType<ObjectResult>(controller.Token(Request("acme", "wrong")));
        Assert.Equal(StatusCodes.Status429TooManyRequests, locked.StatusCode);

        // Lockout must hold even once the caller starts sending the right secret.
        var stillLocked = Assert.IsType<ObjectResult>(controller.Token(Request("acme", Secret)));
        Assert.Equal(StatusCodes.Status429TooManyRequests, stillLocked.StatusCode);
    }

    [Fact]
    public void A_success_resets_the_failure_counter()
    {
        var controller = Build(out var options);
        for (var i = 0; i < options.MaxFailedAttempts - 1; i++)
            controller.Token(Request("acme", "wrong"));

        Assert.IsType<OkObjectResult>(controller.Token(Request("acme", Secret)));

        for (var i = 0; i < options.MaxFailedAttempts - 1; i++)
            Assert.IsType<UnauthorizedObjectResult>(controller.Token(Request("acme", "wrong")));
    }

    [Fact]
    public void Missing_credentials_are_rejected_before_any_lookup()
    {
        var controller = Build(out _);
        Assert.IsType<BadRequestObjectResult>(controller.Token(Request("", Secret)));
        Assert.IsType<BadRequestObjectResult>(controller.Token(Request("acme", "")));
    }

    [Fact]
    public void Unsupported_grant_type_is_rejected()
    {
        var controller = Build(out _);
        var result = controller.Token(new AuthController.TokenRequest
        {
            ClientId = "acme",
            ClientSecret = Secret,
            GrantType = "password"
        });
        Assert.IsType<BadRequestObjectResult>(result);
    }

    [Fact]
    public void Client_credentials_grant_type_is_accepted_when_supplied()
    {
        var controller = Build(out _);
        var result = controller.Token(new AuthController.TokenRequest
        {
            ClientId = "acme",
            ClientSecret = Secret,
            GrantType = "client_credentials"
        });
        Assert.IsType<OkObjectResult>(result);
    }

    [Fact]
    public void A_short_signing_key_fails_closed_rather_than_issuing_a_weak_token()
    {
        var controller = Build(out _, signingKey: "too-short");
        var result = Assert.IsType<ObjectResult>(controller.Token(Request("acme", Secret)));
        Assert.Equal(StatusCodes.Status500InternalServerError, result.StatusCode);
    }
}
