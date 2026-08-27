using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Text;
using System.Text.Json;

namespace LRN.MasterFileProcessorWorker.Notifications;

public sealed class TeamsWebhookNotifier : ITeamsNotifier
{
	private readonly TeamsWebhookOptions _opt;
	private readonly IHttpClientFactory _httpFactory;
	private readonly ILogger<TeamsWebhookNotifier> _logger;

	public TeamsWebhookNotifier(
		IOptions<TeamsWebhookOptions> opt,
		IHttpClientFactory httpFactory,
		ILogger<TeamsWebhookNotifier> logger)
	{
		_opt = opt.Value;
		_httpFactory = httpFactory;
		_logger = logger;
	}

	public async Task SendAsync(TeamsNotification msg, CancellationToken ct = default)
	{
		if (!_opt.Enabled)
			return;

		if (string.IsNullOrWhiteSpace(_opt.WebhookUrl))
			throw new InvalidOperationException("Teams webhook URL is not configured.");

		if (string.IsNullOrWhiteSpace(msg.Title) && string.IsNullOrWhiteSpace(msg.Message))
			throw new ArgumentException("TeamsNotification title or message is required.");

		if (!Uri.TryCreate(_opt.WebhookUrl, UriKind.Absolute, out var uri))
			throw new InvalidOperationException("Teams webhook URL is invalid.");

		var payload = BuildAdaptiveCardWrapper(msg);
		var json = JsonSerializer.Serialize(payload);

		using var content = new StringContent(json, Encoding.UTF8, "application/json");
		var http = _httpFactory.CreateClient();

		try
		{
			using var response = await http.PostAsync(uri, content, ct);
			var body = await response.Content.ReadAsStringAsync(ct);

			if (!response.IsSuccessStatusCode)
			{
				throw new HttpRequestException(
					$"Teams webhook call failed. Status={(int)response.StatusCode} {response.ReasonPhrase}. Response={body}");
			}

			_logger.LogInformation("Teams webhook message sent successfully. Status={StatusCode}", (int)response.StatusCode);
		}
		catch (Exception ex)
		{
			_logger.LogError(ex, "Failed to send Teams webhook message.");
			throw;
		}
	}

	private static object BuildAdaptiveCardWrapper(TeamsNotification msg)
	{
		return new
		{
			type = "message",
			attachments = new object[]
			{
				new
				{
					contentType = "application/vnd.microsoft.card.adaptive",
					contentUrl = (string?)null,
					content = new Dictionary<string, object?>
					{
						["$schema"] = "http://adaptivecards.io/schemas/adaptive-card.json",
						["type"] = "AdaptiveCard",
						["version"] = "1.4",
						["body"] = new object[]
						{
							new Dictionary<string, object?>
							{
								["type"] = "TextBlock",
								["text"] = msg.Title,
								["weight"] = "Bolder",
								["size"] = "Medium",
								["wrap"] = true
							},
							new Dictionary<string, object?>
							{
								["type"] = "TextBlock",
								["text"] = msg.Message,
								["wrap"] = true
							},
							new Dictionary<string, object?>
							{
								["type"] = "TextBlock",
								["text"] = $"Time: {DateTime.Now:yyyy-MM-dd HH:mm:ss}",
								["isSubtle"] = true,
								["size"] = "Small",
								["wrap"] = true
							}
						}
					}
				}
			}
		};
	}
}