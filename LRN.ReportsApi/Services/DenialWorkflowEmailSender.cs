using System.Net;
using System.Net.Mail;
using LRN.ReportsApi.Services.UserMail;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services;

public interface IDenialWorkflowEmailSender
{
    /// <param name="emailType">dbo.EmailLog.EmailType for the system email log (Admin > Email Log).</param>
    /// <param name="sentBy">Who triggered the email, for the log.</param>
    Task<bool> SendAsync(IReadOnlyList<string> to, string subject, string body, string? replyTo = null, CancellationToken ct = default,
        string emailType = EmailTypes.DenialWorkflowNotification, string? sentBy = null);
}

// Shared by DenialWorkflowSupportService (manual support requests) and the denial-workflow
// pipeline notifiers (e.g. unmatched denial code alerts). One SMTP config surface
// (DenialWorkflowSupportOptions) instead of a second, competing one. Every attempted send is
// recorded in dbo.EmailLog; a send skipped because SMTP is switched off is not an email and is not logged.
public sealed class SmtpDenialWorkflowEmailSender : IDenialWorkflowEmailSender
{
    private readonly IOptions<DenialWorkflowSupportOptions> _options;
    private readonly IUserMailRepository _emailLog;
    private readonly ILogger<SmtpDenialWorkflowEmailSender> _logger;

    public SmtpDenialWorkflowEmailSender(IOptions<DenialWorkflowSupportOptions> options, IUserMailRepository emailLog, ILogger<SmtpDenialWorkflowEmailSender> logger)
    {
        _options = options;
        _emailLog = emailLog;
        _logger = logger;
    }

    public async Task<bool> SendAsync(IReadOnlyList<string> to, string subject, string body, string? replyTo = null, CancellationToken ct = default,
        string emailType = EmailTypes.DenialWorkflowNotification, string? sentBy = null)
    {
        var options = _options.Value;
        if (!options.EnableSmtpEmail || string.IsNullOrWhiteSpace(options.SmtpHost) || string.IsNullOrWhiteSpace(options.SmtpFromEmail) || to.Count == 0)
            return false;

        using var message = new MailMessage
        {
            From = new MailAddress(options.SmtpFromEmail),
            Subject = subject,
            Body = body,
            IsBodyHtml = false
        };

        foreach (var email in to) message.To.Add(email);
        if (!string.IsNullOrWhiteSpace(replyTo)) message.ReplyToList.Add(replyTo);

        using var client = new SmtpClient(options.SmtpHost, options.SmtpPort)
        {
            EnableSsl = options.SmtpEnableSsl
        };

        if (!string.IsNullOrWhiteSpace(options.SmtpUserName))
            client.Credentials = new NetworkCredential(options.SmtpUserName, options.SmtpPassword);

        string? error = null;
        try
        {
            using var registration = ct.Register(client.SendAsyncCancel);
            await client.SendMailAsync(message, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Unable to send denial workflow email to {Recipients}.", string.Join(", ", to));
            error = ex.Message;
        }

        await EmailLogWriter.TryWriteAsync(_emailLog, _logger, "Denial Workflow", emailType, to, options.SmtpFromEmail, subject,
            EmailLogWriter.PlainTextBody(body), error, sentBy);
        return error is null;
    }
}
