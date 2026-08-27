using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.MasterFileProcessorWorker.Notifications;

/// <summary>
/// Email notifier backed by the Microsoft Graph sendMail API.
///
/// SMTP was removed: the tenant no longer supports it. Graph is the replacement, but the send
/// itself is not implemented yet - drop the Graph call into <see cref="SendAsync"/> when it is
/// ready. Until then this notifier is inert, and "Notifications:Email:Enabled" is false, so
/// nothing reaches this code path in normal operation.
/// </summary>
public sealed class GraphEmailNotifier : IEmailNotifier
{
	private readonly EmailOptions _opt;
	private readonly ILogger<GraphEmailNotifier> _logger;

	public GraphEmailNotifier(IOptions<EmailOptions> opt, ILogger<GraphEmailNotifier> logger)
	{
		_opt = opt.Value;
		_logger = logger;
	}

	public Task SendAsync(EmailNotification email, CancellationToken ct = default)
	{
		if (!_opt.Enabled)
			return Task.CompletedTask;

		// TODO: POST https://graph.microsoft.com/v1.0/users/{_opt.From}/sendMail with an app-only
		// token. The tenant/client/secret and the token flow are the same ones SharePointDownloader
		// already uses; sending additionally needs the Mail.Send application permission.
		_logger.LogWarning(
			"Notifications:Email:Enabled is true but the Graph email notifier is not implemented yet. " +
			"Dropping message. Subject={Subject}",
			email.Subject);

		return Task.CompletedTask;
	}
}
