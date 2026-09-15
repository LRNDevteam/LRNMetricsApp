using System.Net;
using System.Net.Mail;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services;

public interface IDenialWorkflowEmailSender
{
    Task<bool> SendAsync(IReadOnlyList<string> to, string subject, string body, string? replyTo = null, CancellationToken ct = default);
}

// Shared by DenialWorkflowSupportService (manual support requests) and the denial-workflow
// pipeline notifiers (e.g. unmatched denial code alerts). One SMTP config surface
// (DenialWorkflowSupportOptions) instead of a second, competing one.
public sealed class SmtpDenialWorkflowEmailSender : IDenialWorkflowEmailSender
{
    private readonly IOptions<DenialWorkflowSupportOptions> _options;
    private readonly ILogger<SmtpDenialWorkflowEmailSender> _logger;

    public SmtpDenialWorkflowEmailSender(IOptions<DenialWorkflowSupportOptions> options, ILogger<SmtpDenialWorkflowEmailSender> logger)
    {
        _options = options;
        _logger = logger;
    }

    public async Task<bool> SendAsync(IReadOnlyList<string> to, string subject, string body, string? replyTo = null, CancellationToken ct = default)
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

        try
        {
            using var registration = ct.Register(client.SendAsyncCancel);
            await client.SendMailAsync(message, ct);
            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Unable to send denial workflow email to {Recipients}.", string.Join(", ", to));
            return false;
        }
    }
}
