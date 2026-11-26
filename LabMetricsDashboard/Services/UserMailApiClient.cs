using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using LabMetricsDashboard.Models.DenialWorkflow;
using LabMetricsDashboard.Services.Security;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Services;

/// <summary>Outcome of an invitation email; never throws for a mail failure, only reports it.</summary>
public sealed record UserInvitationResult(bool EmailSent, string? Message);

/// <summary>Outcome of a sign-in code request (LRN.ReportsApi /api/user-mail/login-codes).</summary>
public sealed record LoginCodeSendResult(bool Sent, long? ChallengeId, string? MaskedEmail, DateTime? ExpiresUtc, string? Message);

/// <summary>
/// LRN.ReportsApi /api/user-mail: the invitation email and sent-mail log shared with the AR Workbench.
/// One Graph sender and one log (dbo.UserEmailLog) serve both applications; this app only asks for
/// an email to be sent and reads the log. Same base-URL + JWT pattern as <see cref="MenuApiClient"/>.
/// </summary>
public interface IUserMailApiClient
{
    Task<UserInvitationResult> SendInvitationAsync(int labUserId, bool isResend, CancellationToken ct);
    /// <summary>Emails the user a NEW one-time sign-in code (earlier ones stop working). Used during sign-in; never throws.</summary>
    Task<LoginCodeSendResult> SendLoginCodeAsync(int labUserId, string? ipAddress, CancellationToken ct);
    /// <summary>Raw JSON of the log page, passed through to Admin > Users and Admin > Email Log. Keys may repeat (emailType).</summary>
    Task<(int Status, string Json)> GetEmailsAsync(IEnumerable<KeyValuePair<string, string?>> query, CancellationToken ct);
    Task<(int Status, string Json)> GetEmailAsync(long emailLogId, CancellationToken ct);
    /// <summary>Every mail type in the log with counts.</summary>
    Task<(int Status, string Json)> GetEmailTypesAsync(CancellationToken ct);
}

public sealed class UserMailApiClient : IUserMailApiClient
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private readonly HttpClient _http;
    private readonly IHttpContextAccessor _httpContextAccessor;
    private readonly WorkflowJwtIssuer _jwtIssuer;
    private readonly ILogger<UserMailApiClient> _logger;

    public UserMailApiClient(HttpClient http, IOptions<DenialWorkflowOptions> options, IHttpContextAccessor httpContextAccessor,
        WorkflowJwtIssuer jwtIssuer, ILogger<UserMailApiClient> logger)
    {
        _http = http;
        _httpContextAccessor = httpContextAccessor;
        _jwtIssuer = jwtIssuer;
        _logger = logger;
        var baseUrl = options.Value.BaseUrl?.Trim();
        if (!string.IsNullOrWhiteSpace(baseUrl))
        {
            if (!baseUrl.EndsWith("/", StringComparison.Ordinal)) baseUrl += "/";
            if (Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri)) _http.BaseAddress = uri;
        }
    }

    public async Task<UserInvitationResult> SendInvitationAsync(int labUserId, bool isResend, CancellationToken ct)
    {
        try
        {
            await AuthorizeAsync(ct);
            using var response = await _http.PostAsJsonAsync($"api/user-mail/invitations/{labUserId}", new { isResend, application = "LRN Metrics" }, ct);
            var body = await response.Content.ReadAsStringAsync(ct);
            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning("Invitation for LabUserID {Id} refused by Reports API: {Status} {Body}", labUserId, (int)response.StatusCode, body);
                return new UserInvitationResult(false, $"Reports API returned {(int)response.StatusCode}.");
            }
            return JsonSerializer.Deserialize<UserInvitationResult>(body, JsonOptions) ?? new UserInvitationResult(false, "Empty response from the Reports API.");
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or InvalidOperationException)
        {
            _logger.LogError(ex, "Invitation for LabUserID {Id} could not reach the Reports API.", labUserId);
            return new UserInvitationResult(false, "The Reports API could not be reached.");
        }
        catch (Exception ex)
        {
            // Any other failure (an unreadable reply ...) is still only a mail failure: the user is
            // already created and the admin can resend, so it is reported, never thrown.
            _logger.LogError(ex, "Invitation for LabUserID {Id} failed.", labUserId);
            return new UserInvitationResult(false, "The invitation email could not be sent.");
        }
    }

    public async Task<LoginCodeSendResult> SendLoginCodeAsync(int labUserId, string? ipAddress, CancellationToken ct)
    {
        try
        {
            if (_http.BaseAddress == null) throw new InvalidOperationException("Reports API base URL is missing. Configure DenialWorkflowApi:BaseUrl.");
            // Nobody is signed in yet: a per-request header with the service token, never the shared default.
            using var request = new HttpRequestMessage(HttpMethod.Post, $"api/user-mail/login-codes/{labUserId}")
            {
                Content = JsonContent.Create(new { ipAddress })
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _jwtIssuer.CreateSignInServiceToken());
            using var response = await _http.SendAsync(request, ct);
            var body = await response.Content.ReadAsStringAsync(ct);
            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning("Sign-in code for LabUserID {Id} refused by Reports API: {Status} {Body}", labUserId, (int)response.StatusCode, body);
                return new LoginCodeSendResult(false, null, null, null, $"Reports API returned {(int)response.StatusCode}.");
            }
            return JsonSerializer.Deserialize<LoginCodeSendResult>(body, JsonOptions)
                ?? new LoginCodeSendResult(false, null, null, null, "Empty response from the Reports API.");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Sign-in code for LabUserID {Id} could not be requested.", labUserId);
            return new LoginCodeSendResult(false, null, null, null, "The sign-in code service could not be reached.");
        }
    }

    public Task<(int Status, string Json)> GetEmailTypesAsync(CancellationToken ct)
        => GetRawAsync("api/user-mail/email-types", ct);

    public async Task<(int Status, string Json)> GetEmailsAsync(IEnumerable<KeyValuePair<string, string?>> query, CancellationToken ct)
    {
        var qs = string.Join("&", query.Where(kv => !string.IsNullOrWhiteSpace(kv.Value))
            .Select(kv => $"{Uri.EscapeDataString(kv.Key)}={Uri.EscapeDataString(kv.Value!)}"));
        return await GetRawAsync($"api/user-mail/emails{(qs.Length > 0 ? "?" + qs : "")}", ct);
    }

    public Task<(int Status, string Json)> GetEmailAsync(long emailLogId, CancellationToken ct)
        => GetRawAsync($"api/user-mail/emails/{emailLogId}", ct);

    private async Task<(int Status, string Json)> GetRawAsync(string url, CancellationToken ct)
    {
        try
        {
            await AuthorizeAsync(ct);
            using var response = await _http.GetAsync(url, ct);
            return ((int)response.StatusCode, await response.Content.ReadAsStringAsync(ct));
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or InvalidOperationException)
        {
            _logger.LogError(ex, "User mail log request {Url} failed.", url);
            return (502, JsonSerializer.Serialize(new { message = "The Reports API could not be reached." }));
        }
    }

    private async Task AuthorizeAsync(CancellationToken ct)
    {
        if (_http.BaseAddress == null) throw new InvalidOperationException("Reports API base URL is missing. Configure DenialWorkflowApi:BaseUrl.");
        var user = _httpContextAccessor.HttpContext?.User;
        if (user?.Identity?.IsAuthenticated != true) return;
        var token = await _jwtIssuer.CreateTokenAsync(user, ct);
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
    }
}
