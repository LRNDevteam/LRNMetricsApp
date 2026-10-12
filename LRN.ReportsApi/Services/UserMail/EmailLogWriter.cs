using System.Net;

namespace LRN.ReportsApi.Services.UserMail;

/// <summary>
/// Records a sent (or failed) email in dbo.EmailLog without ever failing the caller: a missing
/// table or a database hiccup is logged and ignored, because the email itself already went out.
/// </summary>
public static class EmailLogWriter
{
    /// <summary>Wraps a plain-text body so the Email Log preview keeps its line breaks.</summary>
    public static string PlainTextBody(string? body) =>
        $"<pre style=\"font-family:Consolas,monospace;font-size:13px;white-space:pre-wrap;margin:16px;\">{WebUtility.HtmlEncode(body ?? string.Empty)}</pre>";

    public static async Task TryWriteAsync(IUserMailRepository repository, ILogger logger, string application, string emailType,
        IEnumerable<string> to, string? from, string subject, string? bodyHtml, string? error, string? sentBy, int? labUserId = null, string? userName = null)
    {
        try
        {
            await repository.WriteEmailLogAsync(labUserId, userName, application, emailType, string.Join(", ", to), from,
                subject, bodyHtml, error is null, error, sentBy ?? "system", CancellationToken.None);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Could not record {Type} email in dbo.EmailLog (run Sql/UserMail_Setup.sql).", emailType);
        }
    }
}
