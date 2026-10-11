using System.Security.Claims;
using LRN.ReportsApi.Services.UserMail;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// User invitation email and the sent-mail log for LRN Metrics Admin > Users. Called server-side by
/// LabMetricsDashboard with the signed-in admin's workflow JWT (same pattern as /api/menu); the AR
/// Workbench uses the same service through /api/ar-workbench/users/*. Behind the JWT gate in
/// Program.cs, and limited here to the full admin roles (Admin, Super Admin, LRN Admin).
/// </summary>
[ApiController]
[Route("api/user-mail")]
public sealed class UserMailController : ControllerBase
{
    private static readonly HashSet<string> FullAdminRoles = new(StringComparer.Ordinal) { "ADMIN", "SUPERADMIN", "LRNADMIN" };

    private readonly IUserInvitationService _invitations;
    private readonly IUserMailRepository _repository;
    private readonly ILogger<UserMailController> _logger;

    public UserMailController(IUserInvitationService invitations, IUserMailRepository repository, ILogger<UserMailController> logger)
    {
        _invitations = invitations;
        _repository = repository;
        _logger = logger;
    }

    public sealed class SendInvitationRequest
    {
        public bool IsResend { get; set; }
        /// <summary>LRN Metrics (default) | AR Workbench</summary>
        public string? Application { get; set; }
    }

    /// <summary>Emails a first-login invitation (new link + one-time password) to the user's address.</summary>
    [HttpPost("invitations/{labUserId:int}")]
    public async Task<ActionResult> SendInvitation([FromRoute] int labUserId, [FromBody] SendInvitationRequest? request, CancellationToken ct)
    {
        if (!IsFullAdmin()) return Forbidden();
        var app = UserMailApplications.Normalize(request?.Application) ?? UserMailApplications.LrnMetrics;
        try
        {
            var (sent, error) = await _invitations.SendInvitationAsync(labUserId, app, UserName(), request?.IsResend ?? false, ct);
            return Ok(new { emailSent = sent, message = sent ? "Invitation email sent." : error });
        }
        catch (SqlException ex)
        {
            _logger.LogError(ex, "Invitation for LabUserID {Id} failed in SQL.", labUserId);
            return Ok(new { emailSent = false, message = "The invitation tables are missing - run LRN.ReportsApi/Sql/UserMail_Setup.sql." });
        }
    }

    /// <summary>Sent emails, most recent first unless oldestFirst; filter by role, status, application, search.</summary>
    [HttpGet("emails")]
    public async Task<ActionResult<UserEmailLogPage>> Emails([FromQuery] UserEmailLogQuery query, CancellationToken ct)
    {
        if (!IsFullAdmin()) return Forbidden();
        return Ok(await _repository.GetEmailLogAsync(query, null, ct));
    }

    /// <summary>Every mail type in the system email log with its counts (Admin > Email Log type filter).</summary>
    [HttpGet("email-types")]
    public async Task<ActionResult<IReadOnlyList<EmailTypeSummary>>> EmailTypes(CancellationToken ct)
    {
        if (!IsFullAdmin()) return Forbidden();
        return Ok(await _repository.GetEmailTypesAsync(null, ct));
    }

    [HttpGet("emails/{emailLogId:long}")]
    public async Task<ActionResult<UserEmailDetail>> Email([FromRoute] long emailLogId, CancellationToken ct)
    {
        if (!IsFullAdmin()) return Forbidden();
        var email = await _repository.GetEmailAsync(emailLogId, null, ct);
        return email is null ? NotFound(new { message = "That email was not found." }) : Ok(email);
    }

    private bool IsFullAdmin() => User.Claims
        .Where(c => c.Type == ClaimTypes.Role || string.Equals(c.Type, "role", StringComparison.OrdinalIgnoreCase) || string.Equals(c.Type, "roles", StringComparison.OrdinalIgnoreCase))
        .Any(c => FullAdminRoles.Contains(c.Value.Replace(" ", string.Empty).ToUpperInvariant()));

    private string UserName() => User.FindFirstValue(ClaimTypes.Name) ?? User.FindFirstValue("name") ?? "admin";

    private ObjectResult Forbidden() => StatusCode(StatusCodes.Status403Forbidden, new { message = "Only an administrator can manage user emails." });
}
