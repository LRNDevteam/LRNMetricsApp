using System.Net.Http.Json;
using Microsoft.Extensions.Options;

namespace DenialDatabaseProcessorWorker.Notifications;

public sealed class TeamsWebhookNotifier : ITeamsNotifier
{

	public sealed class TeamsNotificationOptions
	{
		public bool Enabled { get; set; } = false;
		public string WebhookUrl { get; set; } = "";
	}

	private readonly HttpClient _http;
	private readonly TeamsNotificationOptions _opt;
	private readonly ILogger<TeamsWebhookNotifier> _log;

	public TeamsWebhookNotifier(HttpClient http, IOptions<TeamsNotificationOptions> opt, ILogger<TeamsWebhookNotifier> log)
	{
		_http = http;
		_opt = opt.Value;
		_log = log;
	}

	public async Task SendAsync(string title, string message, CancellationToken ct = default)
	{
		if (!_opt.Enabled || string.IsNullOrWhiteSpace(_opt.WebhookUrl))
			return;

		try
		{
			using var response = await _http.PostAsJsonAsync(_opt.WebhookUrl, new
			{
				title,
				message,
				text = $"{title}\n{message}"
			}, ct);

			if (!response.IsSuccessStatusCode)
			{
				var body = await response.Content.ReadAsStringAsync(ct);
				_log.LogWarning(
					"Teams notification failed. Status={StatusCode}. Response={Response}",
					(int)response.StatusCode,
					body);
			}
		}
		catch (Exception ex)
		{
			_log.LogWarning(ex, "Teams notification send failed.");
		}
	}
}
