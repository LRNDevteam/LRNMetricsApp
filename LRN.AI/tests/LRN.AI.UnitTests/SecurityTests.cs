using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LRN.AI.Api.Security;
using LRN.AI.Application.Common;
using LRN.AI.Application.ModelComparison;
using LRN.AI.Infrastructure.AI.Ollama;

namespace LRN.AI.UnitTests;

public sealed class LrnJwtValidatorTests
{
    private const string Key = "unit-test-signing-key-that-is-long-enough-0123456789";
    private static readonly DateTimeOffset Now = new(2026, 11, 7, 12, 0, 0, TimeSpan.Zero);

    private static string Token(object payload, string alg = "HS256", string key = Key)
    {
        static string Encode(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var header = Encode(JsonSerializer.SerializeToUtf8Bytes(new { alg, typ = "JWT" }));
        var body = Encode(JsonSerializer.SerializeToUtf8Bytes(payload));
        using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(key));
        return $"{header}.{body}.{Encode(hmac.ComputeHash(Encoding.ASCII.GetBytes($"{header}.{body}")))}";
    }

    private static object Payload(long? exp = null, string aud = "LRNReportsApi", string iss = "LRNMetrics", string? sub = "u-42") => new
    {
        iss,
        aud,
        sub,
        name = "jane.reviewer",
        exp = exp ?? Now.AddMinutes(30).ToUnixTimeSeconds(),
        roles = new[] { "Admin" },
        labs = new[] { new { labId = "7", labName = "NWL" } }
    };

    private static bool Validate(string token, out ClaimsPrincipal? principal, out string failure) =>
        LrnJwtValidator.TryValidate(token, Key, "LRNMetrics", "LRNReportsApi", Now, out principal, out failure);

    [Fact]
    public void Accepts_a_dashboard_token_and_maps_user_roles_and_labs()
    {
        Assert.True(Validate(Token(Payload()), out var principal, out _));
        Assert.NotNull(principal);
        Assert.Equal("u-42", principal.FindFirstValue(ClaimTypes.NameIdentifier));
        Assert.True(principal.IsInRole("Admin"));
        Assert.Equal("7", principal.FindFirstValue("lab_id"));
    }

    [Fact]
    public void Rejects_a_token_signed_with_another_key() =>
        Assert.False(Validate(Token(Payload(), key: "a-different-signing-key-that-is-also-long-enough"), out _, out _));

    [Fact]
    public void Rejects_an_unsigned_alg_none_token()
    {
        var token = Token(Payload(), alg: "none");
        Assert.False(Validate(token[..(token.LastIndexOf('.') + 1)], out _, out var failure));
        Assert.Contains("algorithm", failure);
    }

    [Fact]
    public void Rejects_an_expired_token() =>
        Assert.False(Validate(Token(Payload(exp: Now.AddMinutes(-5).ToUnixTimeSeconds())), out _, out _));

    [Fact]
    public void Rejects_the_wrong_audience_or_issuer()
    {
        Assert.False(Validate(Token(Payload(aud: "SomeOtherApi")), out _, out _));
        Assert.False(Validate(Token(Payload(iss: "SomeoneElse")), out _, out _));
    }

    [Fact]
    public void Rejects_a_token_without_a_user() =>
        Assert.False(Validate(Token(new { iss = "LRNMetrics", aud = "LRNReportsApi", exp = Now.AddMinutes(5).ToUnixTimeSeconds() }), out _, out _));

    [Theory]
    [InlineData("")]
    [InlineData("not-a-jwt")]
    [InlineData("a.b.c")]
    [InlineData("!!!.???.###")]
    public void Rejects_malformed_tokens(string token) => Assert.False(Validate(token, out _, out _));

    [Fact]
    public void Rejects_everything_when_the_signing_key_is_missing() =>
        Assert.False(LrnJwtValidator.TryValidate(Token(Payload()), "", "LRNMetrics", "LRNReportsApi", Now, out _, out _));
}

public sealed class LikelyPhiDetectorTests
{
    [Theory]
    [InlineData("Patient SSN 123-45-6789 was denied", "SSN")]
    [InlineData("contact jane.doe@example.com", "Email")]
    [InlineData("call (555) 123-4567 tomorrow", "Phone")]
    [InlineData("DOB: 04/12/1961", "DateOfBirth")]
    [InlineData("MRN 00482913", "MedicalRecordNumber")]
    [InlineData("member 1EG4TE5MK73", "MedicareBeneficiaryId")]
    public void Flags_identifier_shaped_text(string text, string category) =>
        Assert.Contains(category, LikelyPhiDetector.Detect(text));

    [Theory]
    [InlineData("Explain the likely causes of a CO-11 denial. Do not assume claim-specific facts.")]
    [InlineData("CPT 81003 denied with CARC 16 and RARC N290 for payer group 12; claim 4002518831.")]
    [InlineData("Billed amount 1234.56, allowed 0.00, date of service 2026-10-01.")]
    public void Does_not_flag_de_identified_denial_text(string text) =>
        Assert.Empty(LikelyPhiDetector.Detect(text));
}

public sealed class OptionsValidatorTests
{
    [Theory]
    [InlineData("http://localhost:11434", true)]
    [InlineData("http://127.0.0.1:11434", true)]
    [InlineData("https://ollama.internal.lrn:443", true)]
    [InlineData("http://10.0.0.15:11434", false)]
    [InlineData("ftp://localhost", false)]
    [InlineData("not a url", false)]
    public void Ollama_base_url_must_be_local_or_tls(string baseUrl, bool valid) =>
        Assert.Equal(valid, new OllamaOptionsValidator().Validate(null, new OllamaOptions { BaseUrl = baseUrl }).Succeeded);

    [Theory]
    [InlineData("5m", true)]
    [InlineData("0", true)]
    [InlineData("-1", true)]
    [InlineData("1h30m", true)]
    [InlineData("five minutes", false)]
    public void Ollama_keep_alive_must_be_a_duration(string keepAlive, bool valid) =>
        Assert.Equal(valid, new OllamaOptionsValidator().Validate(null, new OllamaOptions { KeepAlive = keepAlive }).Succeeded);

    [Fact]
    public void Comparison_cannot_be_configured_above_three_models()
    {
        var validator = new ComparisonOptionsValidator();
        Assert.True(validator.Validate(null, new ComparisonOptions()).Succeeded);
        Assert.False(validator.Validate(null, new ComparisonOptions { MaxModelsPerRequest = 4 }).Succeeded);
        Assert.False(validator.Validate(null, new ComparisonOptions { MaxConcurrency = 5 }).Succeeded);
        Assert.False(validator.Validate(null, new ComparisonOptions { DefaultTemperature = 1.5 }).Succeeded);
    }
}
