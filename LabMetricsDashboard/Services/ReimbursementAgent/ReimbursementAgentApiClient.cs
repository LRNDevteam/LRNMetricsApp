using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Text.Json;
using LabMetricsDashboard.Models;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services.ReimbursementAgent;

/// <summary>
/// Asks the Reimbursement Agent proxy a question on behalf of the signed-in user.
///
/// Server-to-server on purpose. The browser posts to this app, and this app calls the proxy — so
/// the page never makes a cross-origin request. That matters here for two concrete reasons: the
/// site's Content-Security-Policy allows connect-src 'self' only, which would block a direct
/// browser call to azurewebsites.net outright; and the signing key never has to be exposed to
/// client-side script.
///
/// Never throws to the page. A proxy outage, a key mismatch, or a slow agent all come back as an
/// <see cref="AgentAnswer"/> carrying an <see cref="AgentAnswer.Error"/> the chat screen can show.
/// </summary>
public interface IReimbursementAgentApiClient
{
    Task<AgentAnswer> AskAsync(string question, ClaimsPrincipal user, CancellationToken ct);
}

/// <summary>One answer. Exactly one of <see cref="Answer"/> / <see cref="Error"/> is populated.</summary>
public sealed record AgentAnswer(string? Answer, string? Error)
{
    public static AgentAnswer Ok(string answer) => new(answer, null);
    public static AgentAnswer Failed(string error) => new(null, error);
}

public sealed class ReimbursementAgentApiClient : IReimbursementAgentApiClient
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private readonly HttpClient _http;
    private readonly ReimbursementChatTokenIssuer _tokenIssuer;
    private readonly ILogger<ReimbursementAgentApiClient> _logger;

    public ReimbursementAgentApiClient(
        HttpClient http,
        IOptions<ReimbursementAgentOptions> options,
        ReimbursementChatTokenIssuer tokenIssuer,
        ILogger<ReimbursementAgentApiClient> logger)
    {
        _http = http;
        _tokenIssuer = tokenIssuer;
        _logger = logger;

        var baseUrl = options.Value.BaseUrl?.Trim();
        if (!string.IsNullOrWhiteSpace(baseUrl))
        {
            if (!baseUrl.EndsWith("/", StringComparison.Ordinal)) baseUrl += "/";
            if (Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri)) _http.BaseAddress = uri;
        }
    }

    public async Task<AgentAnswer> AskAsync(string question, ClaimsPrincipal user, CancellationToken ct)
    {
        if (_http.BaseAddress is null)
        {
            _logger.LogError("Reimbursement chat: ReimbursementAgent:BaseUrl is missing or not an absolute URL.");
            return AgentAnswer.Failed("The reimbursement agent is not configured for this environment.");
        }

        string ticket;
        try
        {
            ticket = _tokenIssuer.CreateToken(user);
        }
        catch (InvalidOperationException ex)
        {
            _logger.LogError(ex, "Reimbursement chat: the chat ticket could not be signed.");
            return AgentAnswer.Failed("The reimbursement agent is not configured for this environment.");
        }

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, "api/ask")
            {
                Content = JsonContent.Create(new { question })
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ticket);

            using var response = await _http.SendAsync(request, ct);

            if (!response.IsSuccessStatusCode)
            {
                // The proxy answers a failure with ProblemDetails whose "detail" distinguishes its
                // two very different 500s — a run that started but did not complete, versus never
                // reaching Foundry at all. Without the body both look identical from here, which
                // is the difference between "the agent errored" and "the identity has no access".
                var detail = await ReadProblemDetailAsync(response, ct);

                _logger.LogWarning(
                    "Reimbursement chat: the agent proxy returned {Status} for a question from {User}. Proxy said: {Detail}",
                    (int)response.StatusCode, user.Identity?.Name, detail ?? "(no response body)");

                return AgentAnswer.Failed(DescribeStatus(response.StatusCode));
            }

            var payload = await response.Content.ReadFromJsonAsync<AskResponse>(JsonOptions, ct);
            var answer = payload?.Answer;

            return string.IsNullOrWhiteSpace(answer)
                ? AgentAnswer.Failed("The agent returned an empty answer. Please try rephrasing the question.")
                : AgentAnswer.Ok(answer);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // The user navigated away or closed the page — not a failure worth logging as one.
            throw;
        }
        catch (OperationCanceledException ex)
        {
            // HttpClient surfaces its own timeout as a cancellation, distinguished from the line
            // above by the request token not being the one that fired.
            _logger.LogWarning(ex, "Reimbursement chat: the agent did not answer before the timeout elapsed.");
            return AgentAnswer.Failed(
                "The agent took too long to answer. Complex questions covering many labs can time out — " +
                "try narrowing it to one payer or one CPT code.");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Reimbursement chat: the agent proxy could not be reached.");
            return AgentAnswer.Failed("The reimbursement agent is not reachable right now. Please try again shortly.");
        }
    }

    /// <summary>
    /// Best-effort read of the proxy's error body for the log. Never throws and never blocks a
    /// response we are already treating as failed — a diagnostic must not become a second fault.
    /// </summary>
    private static async Task<string?> ReadProblemDetailAsync(HttpResponseMessage response, CancellationToken ct)
    {
        try
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            if (string.IsNullOrWhiteSpace(body)) return null;

            // ProblemDetails puts the useful sentence in "detail"; anything else gets logged raw.
            try
            {
                using var document = JsonDocument.Parse(body);
                if (document.RootElement.ValueKind == JsonValueKind.Object
                    && document.RootElement.TryGetProperty("detail", out var detail)
                    && detail.ValueKind == JsonValueKind.String)
                {
                    return detail.GetString();
                }
            }
            catch (JsonException) { /* not JSON — fall through to the raw body */ }

            return body.Length > 500 ? body[..500] + "…" : body;
        }
        catch
        {
            return null;
        }
    }

    private static string DescribeStatus(HttpStatusCode status) => status switch
    {
        // The proxy rejected our ticket. In practice this is always the shared secret differing
        // between this app's ChatToken:SigningKey and the App Service's ChatToken__SigningKey.
        HttpStatusCode.Unauthorized =>
            "The reimbursement agent rejected this request's credentials. An administrator needs to confirm " +
            "the ChatToken signing key matches between this application and the agent service.",

        // The proxy rate-limits per calling IP. Every question from this site now arrives from one
        // server address, so its limit is shared across all users of this screen.
        HttpStatusCode.TooManyRequests =>
            "The reimbursement agent is handling too many questions at the moment. Please wait a minute and try again.",

        _ => "The reimbursement agent could not answer that request. Please try again shortly."
    };

    private sealed record AskResponse(string? Answer);
}
