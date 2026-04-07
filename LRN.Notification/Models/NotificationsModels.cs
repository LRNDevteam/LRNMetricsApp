namespace LRN.Notifications.Models;

public sealed class EmailNotification
{
    public string From { get; set; } = "";
    public List<string> To { get; set; } = new();
    public List<string> Cc { get; set; } = new();
    public List<string> Bcc { get; set; } = new();

    public string Subject { get; set; } = "";
    public string Content { get; set; } = "";

    // Optional (nice to have)
    public bool IsHtml { get; set; } = false;
}
public sealed class TeamsNotification
{
    public string Title { get; set; } = "Notification";
    public string Message { get; set; } = "";

    // Optional UI enhancements
    public string? ThemeColor { get; set; }

    // Status summary fields
    public object[]? Facts { get; set; }

    // Buttons (download links etc.)
    public object[]? Actions { get; set; }

    public string? CardJson { get; set; }
}

public sealed class SmtpOptions
{
    public bool Enabled { get; set; } = true;
    public string Host { get; set; } = "";
    public int Port { get; set; } = 587;
    public bool UseStartTls { get; set; } = true;

    public string Username { get; set; } = "";
    public string Password { get; set; } = "";
}

public sealed class TeamsWebhookOptions
{
    public bool Enabled { get; set; } = true;
    public string WebhookUrl { get; set; } = "";
}