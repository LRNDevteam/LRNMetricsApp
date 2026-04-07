using LRN.Notifications.Abstractions;
using LRN.Notifications.Models;
using MailKit.Net.Smtp;
using MailKit.Security;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using MimeKit;


namespace LRN.Notifications.Implementations;

public sealed class SmtpEmailNotifier : IEmailNotifier
{
    private readonly SmtpOptions _opt;
    private readonly ILogger<SmtpEmailNotifier> _logger;

    public SmtpEmailNotifier(IOptions<SmtpOptions> opt, ILogger<SmtpEmailNotifier> logger)
    {
        _opt = opt.Value;
        _logger = logger;
    }

    public async Task SendAsync(EmailNotification email, CancellationToken ct = default)
    {
        if (!_opt.Enabled) return;

        ValidateEmail(email);

        var msg = new MimeMessage();
        msg.From.Add(MailboxAddress.Parse(email.From));

        foreach (var to in email.To) msg.To.Add(MailboxAddress.Parse(to));
        foreach (var cc in email.Cc) msg.Cc.Add(MailboxAddress.Parse(cc));
        foreach (var bcc in email.Bcc) msg.Bcc.Add(MailboxAddress.Parse(bcc));

        msg.Subject = email.Subject ?? "";

        msg.Body = email.IsHtml
            ? new TextPart("html") { Text = email.Content ?? "" }
            : new TextPart("plain") { Text = email.Content ?? "" };

        using var client = new SmtpClient();

        var secure = _opt.UseStartTls ? SecureSocketOptions.StartTls : SecureSocketOptions.Auto;

        try
        {
            await client.ConnectAsync(_opt.Host, _opt.Port, secure, ct);

            if (!string.IsNullOrWhiteSpace(_opt.Username))
                await client.AuthenticateAsync(_opt.Username, _opt.Password, ct);

            await client.SendAsync(msg, ct);
            await client.DisconnectAsync(true, ct);

            _logger.LogInformation("Email sent to: {Recipients}", string.Join(", ", email.To));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to send email.");
            throw;
        }
    }

    private static void ValidateEmail(EmailNotification email)
    {
        if (string.IsNullOrWhiteSpace(email.From))
            throw new ArgumentException("Email.From is required.");

        if (email.To is null || email.To.Count == 0)
            throw new ArgumentException("Email.To must contain at least one recipient.");

        if (string.IsNullOrWhiteSpace(email.Subject))
            throw new ArgumentException("Email.Subject is required.");

        if (string.IsNullOrWhiteSpace(email.Content))
            throw new ArgumentException("Email.Content is required.");
    }
}
