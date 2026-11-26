using System.Net;
using System.Security.Cryptography;
using LRN.ReportsApi.Services.ArWorkbench;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services.UserMail;

/// <summary>Result of a sign-in code request. MaskedEmail is safe to show on the sign-in page.</summary>
public sealed record LoginCodeResult(bool Sent, long? ChallengeId, string? MaskedEmail, DateTime? ExpiresUtc, string? Error);

public interface ILoginCodeService
{
    /// <summary>
    /// Issues a NEW one-time sign-in code for the user (earlier codes stop working), emails it and logs
    /// the email (code redacted). Called by LRN Metrics at every sign-in of an external user, after
    /// their password was accepted. Never throws.
    /// </summary>
    Task<LoginCodeResult> SendAsync(int labUserId, string? ipAddress, CancellationToken ct);
}

/// <summary>
/// Email one-time sign-in code. The code is 6 digits, stored only as a PBKDF2 hash in
/// dbo.UserLoginOtp, and checked by LRN Metrics /Account/VerifyLoginCode (5 tries, then the code is
/// revoked). Lifetime: UserMail:LoginCodeMinutes (default 10).
/// </summary>
public sealed class LoginCodeService : ILoginCodeService
{
    private const int CodeLength = 6;
    private readonly IUserMailRepository _repository;
    private readonly IUserMailSender _mail;
    private readonly IOptionsMonitor<UserMailOptions> _options;
    private readonly ILogger<LoginCodeService> _logger;

    public LoginCodeService(IUserMailRepository repository, IUserMailSender mail, IOptionsMonitor<UserMailOptions> options, ILogger<LoginCodeService> logger)
    {
        _repository = repository;
        _mail = mail;
        _options = options;
        _logger = logger;
    }

    public async Task<LoginCodeResult> SendAsync(int labUserId, string? ipAddress, CancellationToken ct)
    {
        const string subject = "Your LRN sign-in code";
        UserMailTarget? target = null;
        try
        {
            target = await _repository.GetTargetAsync(labUserId, ct);
            if (target is null || !target.IsActive) return new(false, null, null, null, "The account was not found or is inactive.");
            var (email, emailError) = ArWorkbenchUserRules.ValidateEmail(target.Email);
            if (email is null) return new(false, null, null, null, $"The account has no valid email address ({emailError}).");

            var o = _options.CurrentValue;
            var perHour = Math.Clamp(o.LoginCodesPerHour, 1, 100);
            if (await _repository.CountLoginCodesSinceAsync(labUserId, DateTime.UtcNow.AddHours(-1), ct) >= perHour)
                return new(false, null, MaskEmail(email), null, "Too many sign-in codes were requested for this account. Wait an hour and try again.");

            var code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D" + CodeLength);
            var minutes = Math.Clamp(o.LoginCodeMinutes, 2, 60);
            var expires = DateTime.UtcNow.AddMinutes(minutes);
            var challengeId = await _repository.CreateLoginCodeAsync(labUserId, ArWorkbenchUserRules.HashPassword(code), expires, ct);

            var html = BuildHtml(target.UserName, code, minutes, ipAddress, o.AllSupportEmails());
            var (sent, sendError) = await _mail.SendAsync(email, subject, html, ct);
            await EmailLogWriter.TryWriteAsync(_repository, _logger, UserMailApplications.ArWorkbench, EmailTypes.LoginCode, [email], SafeSender(), subject,
                html.Replace(code, "••••••", StringComparison.Ordinal), sent ? null : sendError ?? "Email could not be sent.", "sign-in", labUserId, target.UserName);

            if (!sent)
            {
                _logger.LogWarning("Sign-in code for {User} not sent: {Error}", target.UserName, sendError);
                return new(false, null, MaskEmail(email), null, sendError ?? "Email could not be sent.");
            }
            return new(true, challengeId, MaskEmail(email), expires, null);
        }
        catch (Exception ex)
        {
            var error = ex is Microsoft.Data.SqlClient.SqlException
                ? "the sign-in code table is missing or unreachable - run Database/LabMetricsDashboard/ArwbLoginAccounts_Setup.sql"
                : $"the sign-in code could not be sent: {ex.Message}";
            _logger.LogError(ex, "Sign-in code for LabUserID {Id} failed.", labUserId);
            return new(false, null, null, null, error);
        }
    }

    private string? SafeSender()
    {
        try { return _mail.SenderAddress; } catch { return null; }
    }

    /// <summary>"jo***@ex***.com": enough for the user to recognise the mailbox, not to harvest it.</summary>
    public static string MaskEmail(string email)
    {
        var at = email.IndexOf('@');
        if (at <= 0) return "***";
        var local = email[..at];
        var domain = email[(at + 1)..];
        var dot = domain.LastIndexOf('.');
        var host = dot > 0 ? domain[..dot] : domain;
        var tld = dot > 0 ? domain[dot..] : string.Empty;
        static string Keep(string s, int n) => s.Length <= n ? s[..Math.Min(1, s.Length)] + "***" : s[..n] + "***";
        return $"{Keep(local, 2)}@{Keep(host, 2)}{tld}";
    }

    internal static string BuildHtml(string userName, string code, int minutes, string? ipAddress, IReadOnlyList<string> supportEmails)
    {
        static string E(string? s) => WebUtility.HtmlEncode(s ?? string.Empty);
        var links = supportEmails.Select(s => $"<a href=\"mailto:{E(s)}\" style=\"color:#1f4e79;\">{E(s)}</a>").ToList();
        var support = links.Count switch
        {
            0 => "your LRN administrator",
            1 => links[0],
            _ => string.Join(", ", links.Take(links.Count - 1)) + " or " + links[^1]
        };
        var ipHtml = string.IsNullOrWhiteSpace(ipAddress) ? string.Empty
            : $@"<p style=""margin:0 0 16px;font-size:13px;color:#52606d;"">Requested from IP address {E(ipAddress)}.</p>";

        return $@"<!DOCTYPE html>
<html lang=""en""><head><meta charset=""utf-8""><meta name=""viewport"" content=""width=device-width,initial-scale=1""><title>LRN sign-in code</title></head>
<body style=""margin:0;padding:0;background:#f3f5f8;font-family:Segoe UI,Arial,Helvetica,sans-serif;color:#1f2933;"">
<table role=""presentation"" width=""100%"" cellpadding=""0"" cellspacing=""0"" style=""background:#f3f5f8;padding:24px 0;"">
<tr><td align=""center"">
<table role=""presentation"" width=""600"" cellpadding=""0"" cellspacing=""0"" style=""max-width:600px;width:100%;background:#ffffff;border:1px solid #dde3ea;border-radius:8px;"">
<tr><td style=""background:#1f4e79;padding:20px 32px;border-radius:8px 8px 0 0;"">
  <span style=""color:#ffffff;font-size:20px;font-weight:600;"">Lab Revenue Navigator</span><br>
  <span style=""color:#c9d8e8;font-size:13px;"">LRN AR Workbench</span>
</td></tr>
<tr><td style=""padding:28px 32px 8px;font-size:15px;line-height:1.55;"">
  <p style=""margin:0 0 16px;"">Dear User,</p>
  <p style=""margin:0 0 16px;"">Use this one-time code to finish signing in as <b>{E(userName)}</b>:</p>
  <p style=""margin:0 0 20px;""><span style=""display:inline-block;padding:12px 22px;border:1px solid #dde3ea;border-radius:6px;background:#f7f9fb;font-family:Consolas,monospace;font-size:26px;font-weight:700;letter-spacing:6px;"">{E(code)}</span></p>
  <p style=""margin:0 0 16px;"">The code works once and expires in <b>{minutes} minutes</b>. Each sign-in sends a new code; earlier codes stop working.</p>
  {ipHtml}
  <p style=""margin:0 0 16px;"">If you did not just sign in, someone may know your password. Change it and contact {support}.</p>
  <p style=""margin:0 0 4px;"">Kind regards,</p>
  <p style=""margin:0 0 20px;font-weight:600;"">LRN Administration</p>
</td></tr>
<tr><td style=""padding:16px 32px;border-top:1px solid #dde3ea;font-size:12px;color:#7b8794;"">
  This is an automated message. Please do not reply to this email. Never share this code with anyone; LRN staff will never ask for it.
</td></tr>
</table>
</td></tr>
</table>
</body></html>";
    }
}
