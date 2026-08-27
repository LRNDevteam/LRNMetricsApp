namespace LRN.MasterFileProcessorWorker.Notifications;

public sealed class EmailNotification
{
	public string From { get; set; } = "";
	public List<string> To { get; set; } = new();
	public List<string> Cc { get; set; } = new();
	public List<string> Bcc { get; set; } = new();

	public string Subject { get; set; } = "";
	public string Content { get; set; } = "";
	public bool IsHtml { get; set; } = false;
}

public sealed class TeamsNotification
{
	public string Title { get; set; } = "Notification";
	public string Message { get; set; } = "";
}

/// <summary>
/// Bound to "Notifications:Email". Email is sent through the Microsoft Graph sendMail API;
/// SMTP is no longer supported by the tenant.
/// </summary>
public sealed class EmailOptions
{
	/// <summary>Single on/off switch for all outgoing email.</summary>
	public bool Enabled { get; set; } = false;

	/// <summary>Mailbox that Graph sends as, e.g. "watchdog@3eclaimsprocessingllc.com".</summary>
	public string From { get; set; } = "";

	/// <summary>Default recipients used when a caller does not supply its own.</summary>
	public List<string> To { get; set; } = new();
}

/// <summary>Bound to "Notifications:Teams".</summary>
public sealed class TeamsWebhookOptions
{
	/// <summary>Single on/off switch for all Teams notifications.</summary>
	public bool Enabled { get; set; } = false;

	/// <summary>
	/// Incoming-webhook URL. Supplied from appsettings.Secrets.json, not Key Vault - the URL is
	/// longer than the 256-character limit on the vault tags these settings are managed through.
	/// </summary>
	public string WebhookUrl { get; set; } = "";
}
