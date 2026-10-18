using System.Net;
using System.Security.Cryptography;
using System.Text;
using LRN.ReportsApi.Services.ArWorkbench;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services.UserMail;

/// <summary>Which screen created the user; stored on the invitation and the email log.</summary>
public static class UserMailApplications
{
    public const string LrnMetrics = "LRN Metrics";
    public const string ArWorkbench = "AR Workbench";

    public static string? Normalize(string? value) => value?.Replace(" ", string.Empty).ToUpperInvariant() switch
    {
        "LRNMETRICS" or "METRICS" => LrnMetrics,
        "ARWORKBENCH" or "WORKBENCH" => ArWorkbench,
        _ => null
    };
}

public interface IUserInvitationService
{
    /// <summary>
    /// Issues a new first-login invitation for the user (revoking earlier ones), emails it to the
    /// user's email address, and logs the email. The user record is never rolled back on a mail
    /// failure: the admin resends instead.
    /// </summary>
    Task<(bool Sent, string? Error)> SendInvitationAsync(int labUserId, string application, string sentBy, bool isResend, CancellationToken ct);
}

/// <summary>
/// First-login invitation, shared by LRN Metrics and the AR Workbench. The link carries a random
/// 256-bit token; the email also carries an 8-character one-time password. Both are stored only as
/// hashes (token: SHA-256, OTP: the same PBKDF2 format as LabUsers.PasswordHash) and checked by LRN
/// Metrics /Account/SetPassword, so a leaked link alone cannot set the password.
/// </summary>
public sealed class UserInvitationService : IUserInvitationService
{
    // No 0/O, 1/I/L: the OTP is read off an email and typed by hand.
    private const string OtpAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
    private const int OtpLength = 8;

    private readonly IUserMailRepository _repository;
    private readonly IUserMailSender _mail;
    private readonly IOptionsMonitor<UserMailOptions> _options;
    private readonly ILogger<UserInvitationService> _logger;

    public UserInvitationService(IUserMailRepository repository, IUserMailSender mail,
        IOptionsMonitor<UserMailOptions> options, ILogger<UserInvitationService> logger)
    {
        _repository = repository;
        _mail = mail;
        _options = options;
        _logger = logger;
    }

    /// <summary>
    /// Never throws. A user is created whatever happens to the email: every failure - mail not
    /// configured, wrong tenant / client / secret, Graph down, invitation tables missing - comes back
    /// as (false, reason) and is recorded in the email log as a failed send where the log is reachable.
    /// </summary>
    public async Task<(bool Sent, string? Error)> SendInvitationAsync(int labUserId, string application, string sentBy, bool isResend, CancellationToken ct)
    {
        var emailType = isResend ? EmailTypes.UserInvitationResend : EmailTypes.UserInvitation;
        var subject = $"Your {(application == UserMailApplications.ArWorkbench ? "LRN AR Workbench" : "LRN Metrics")} account is ready";
        UserMailTarget? target = null;
        try
        {
            target = await _repository.GetTargetAsync(labUserId, ct);
            return await SendCoreAsync(target, labUserId, application, sentBy, emailType, subject, ct);
        }
        catch (Exception ex)
        {
            var error = ex is Microsoft.Data.SqlClient.SqlException
                ? "the invitation tables are missing or unreachable - run Database/LRN.ReportsApi/UserMail_Setup.sql"
                : $"the invitation could not be sent: {ex.Message}";
            _logger.LogError(ex, "{App} invitation for LabUserID {Id} failed; the user is kept.", application, labUserId);
            // Best effort: the log itself may be what failed.
            await EmailLogWriter.TryWriteAsync(_repository, _logger, application, emailType, [target?.Email ?? "(unknown)"], SafeSender(),
                subject, null, error, sentBy, labUserId, target?.UserName);
            return (false, error);
        }
    }

    private string? SafeSender()
    {
        try { return _mail.SenderAddress; } catch { return null; }
    }

    private async Task<(bool Sent, string? Error)> SendCoreAsync(UserMailTarget? target, int labUserId, string application, string sentBy,
        string emailType, string subject, CancellationToken ct)
    {
        var o = _options.CurrentValue;
        if (target is null) return (false, "That user no longer exists.");
        if (!target.IsActive) return (false, "The user is inactive. Activate the account before sending an invitation.");
        var email = target.Email?.Trim();
        if (string.IsNullOrWhiteSpace(email)) return (false, "The user has no email address. Add one first.");

        if (string.IsNullOrWhiteSpace(o.FirstLoginUrl))
        {
            const string error = "UserMail:FirstLoginUrl is not configured, so no invitation link can be built.";
            await EmailLogWriter.TryWriteAsync(_repository, _logger, application, emailType, [email], SafeSender(), subject, null, error, sentBy, labUserId, target.UserName);
            return (false, error);
        }

        var token = Base64Url(RandomNumberGenerator.GetBytes(32));
        var otp = RandomNumberGenerator.GetString(OtpAlphabet, OtpLength);
        var hours = Math.Clamp(o.InvitationExpiryHours, 1, 24 * 14);
        await _repository.CreateInvitationAsync(labUserId, application, HashToken(token), ArWorkbenchUserRules.HashPassword(otp),
            DateTime.UtcNow.AddHours(hours), sentBy, ct);

        var link = $"{o.FirstLoginUrl.Trim()}{(o.FirstLoginUrl.Contains('?') ? '&' : '?')}token={token}";
        var roleLabels = target.RoleNames.Select(ArWorkbenchUserRules.RoleLabel).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var hasWorkbench = target.RoleNames.Any(ArWorkbenchUserRules.IsWorkbenchRole);
        var html = BuildHtml(application, target.UserName, roleLabels, target.LabNames, otp, link, hours,
            o.SignInUrl, hasWorkbench ? o.ArWorkbenchUrl : null, o.AllSupportEmails());
        var (sent, sendError) = await _mail.SendAsync(email, subject, html, ct);

        // The log keeps the message as sent, minus the secrets; a failed send is logged as failed.
        var redacted = html.Replace(otp, "••••••••", StringComparison.Ordinal)
                           .Replace(WebUtility.HtmlEncode(link), "[one-time link removed]", StringComparison.Ordinal)
                           .Replace(link, "[one-time link removed]", StringComparison.Ordinal);
        await EmailLogWriter.TryWriteAsync(_repository, _logger, application, emailType, [email], SafeSender(), subject, redacted,
            sent ? null : sendError ?? "Email could not be sent.", sentBy, labUserId, target.UserName);

        if (sent) _logger.LogInformation("{App} invitation emailed to {Email} for {User} by {By}", application, email, target.UserName, sentBy);
        else _logger.LogWarning("{App} invitation for {User} not sent: {Error}", application, target.UserName, sendError);
        return (sent, sendError);
    }

    /// <summary>Must match LabMetricsDashboard SqlUserInvitationRepository.HashToken.</summary>
    public static string HashToken(string token) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));

    private static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    internal static string BuildHtml(string application, string userName, IReadOnlyList<string> roles, IReadOnlyList<string> labNames,
        string otp, string link, int expiryHours, string? signInUrl, string? workbenchUrl, IReadOnlyList<string> supportEmails)
    {
        static string E(string? s) => WebUtility.HtmlEncode(s ?? string.Empty);
        static string Row(string label, string valueHtml, bool first = false)
        {
            var border = first ? string.Empty : "border-top:1px solid #dde3ea;";
            return $@"<tr><td style=""padding:10px 14px;background:#f7f9fb;width:38%;color:#52606d;{border}"">{label}</td><td style=""padding:10px 14px;{border}"">{valueHtml}</td></tr>";
        }

        var product = application == UserMailApplications.ArWorkbench ? "LRN AR Workbench" : "LRN Metrics";
        var expiry = expiryHours % 24 == 0 ? $"{expiryHours / 24} day{(expiryHours == 24 ? "" : "s")}" : $"{expiryHours} hours";
        // "a@x.com", "a@x.com or b@x.com", "a@x.com, b@x.com or c@x.com" - each a mailto link.
        var links = supportEmails.Select(s => $"<a href=\"mailto:{E(s)}\" style=\"color:#1f4e79;\">{E(s)}</a>").ToList();
        var support = links.Count switch
        {
            0 => "your LRN administrator",
            1 => links[0],
            _ => string.Join(", ", links.Take(links.Count - 1)) + " or " + links[^1]
        };
        var helpHtml = links.Count == 0 ? string.Empty
            : $@"<p style=""margin:0 0 16px;"">Need help signing in? Contact LRN Support at {support}.</p>";

        var after = new List<string>();
        if (!string.IsNullOrWhiteSpace(signInUrl))
            after.Add($"LRN Metrics: <a href=\"{E(signInUrl)}\" style=\"color:#1f4e79;\">{E(signInUrl)}</a>");
        if (!string.IsNullOrWhiteSpace(workbenchUrl))
            after.Add($"AR Workbench: <a href=\"{E(workbenchUrl)}\" style=\"color:#1f4e79;\">{E(workbenchUrl)}</a>");
        var afterHtml = after.Count == 0 ? string.Empty
            : $@"<p style=""margin:0 0 6px;"">After you set your password, sign in with your username and new password at:</p><p style=""margin:0 0 16px;"">{string.Join("<br>", after)}</p>";

        var details =
            Row("Username", $@"<span style=""font-weight:600;font-family:Consolas,monospace;"">{E(userName)}</span>", first: true) +
            Row("One-time password", $@"<span style=""font-weight:600;font-family:Consolas,monospace;font-size:17px;letter-spacing:2px;"">{E(otp)}</span>") +
            Row("Role", E(roles.Count == 0 ? "To be assigned by your administrator" : string.Join(", ", roles))) +
            Row("Lab access", E(labNames.Count == 0 ? "—" : string.Join(", ", labNames)));

        return $@"<!DOCTYPE html>
<html lang=""en""><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width,initial-scale=1""><title>{E(product)}</title></head>
<body style=""margin:0;padding:0;background:#f3f5f8;font-family:Segoe UI,Arial,Helvetica,sans-serif;color:#1f2933;"">
<table role=""presentation"" width=""100%"" cellpadding=""0"" cellspacing=""0"" style=""background:#f3f5f8;padding:24px 0;"">
<tr><td align=""center"">
<table role=""presentation"" width=""600"" cellpadding=""0"" cellspacing=""0"" style=""max-width:600px;width:100%;background:#ffffff;border:1px solid #dde3ea;border-radius:8px;"">
<tr><td style=""background:#1f4e79;padding:20px 32px;border-radius:8px 8px 0 0;"">
  <span style=""color:#ffffff;font-size:20px;font-weight:600;"">Lab Revenue Navigator</span><br>
  <span style=""color:#c9d8e8;font-size:13px;"">{E(product)}</span>
</td></tr>
<tr><td style=""padding:28px 32px 8px;font-size:15px;line-height:1.55;"">
  <p style=""margin:0 0 16px;"">Dear User,</p>
  <p style=""margin:0 0 16px;"">An account has been created for you on {E(product)}. Please use the details below to complete your first sign-in and create your password.</p>
  <table role=""presentation"" cellpadding=""0"" cellspacing=""0"" style=""width:100%;border:1px solid #dde3ea;border-radius:6px;margin:0 0 20px;font-size:14px;"">{details}</table>
  <p style=""margin:0 0 20px;"">Select the button below, enter the one-time password shown above, and choose a new password for your account.</p>
  <table role=""presentation"" cellpadding=""0"" cellspacing=""0"" style=""margin:0 0 20px;""><tr><td style=""background:#1f4e79;border-radius:6px;"">
    <a href=""{E(link)}"" style=""display:inline-block;padding:12px 26px;color:#ffffff;font-weight:600;text-decoration:none;font-size:15px;"">Create your password</a>
  </td></tr></table>
  <p style=""margin:0 0 16px;font-size:13px;color:#52606d;"">If the button does not work, copy this link into your browser:<br><span style=""word-break:break-all;color:#1f4e79;"">{E(link)}</span></p>
  <p style=""margin:0 0 16px;"">This link and one-time password can be used once and expire in <b>{E(expiry)}</b>. If they expire, please ask your administrator to resend the invitation.</p>
  {afterHtml}
  {helpHtml}
  <p style=""margin:0 0 16px;"">If you did not expect this email, please contact {support} and do not use the link.</p>
  <p style=""margin:0 0 4px;"">Kind regards,</p>
  <p style=""margin:0 0 20px;font-weight:600;"">LRN Administration</p>
</td></tr>
<tr><td style=""padding:16px 32px;border-top:1px solid #dde3ea;font-size:12px;color:#7b8794;"">
  This is an automated message. Please do not reply to this email. Never share your password or one-time password with anyone; LRN staff will never ask for it.
</td></tr>
</table>
</td></tr>
</table>
</body></html>";
    }
}
