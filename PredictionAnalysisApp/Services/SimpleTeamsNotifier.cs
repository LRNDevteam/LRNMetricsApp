using System.Text;
using System.Text.Json;
using LRN.Notifications.Abstractions;
using LRN.Notifications.Models;

namespace PredictionAnalysis.Services;

/// <summary>
/// Posts a pre-built Adaptive Card (TeamsNotification.CardJson) to a
/// Teams incoming-webhook URL via a plain HttpClient.
/// Falls back to a minimal text card when CardJson is null.
/// Failures are logged to Console but never thrown — notifications must
/// never crash the main analysis pipeline.
/// </summary>
public sealed class SimpleTeamsNotifier : ITeamsNotifier
{
    private readonly HttpClient _http;
    private readonly string _webhookUrl;

    private static readonly JsonSerializerOptions _jsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    public SimpleTeamsNotifier(HttpClient httpClient, string webhookUrl)
    {
        _http = httpClient;
        _webhookUrl = webhookUrl;
    }

    public async Task SendAsync(TeamsNotification msg, CancellationToken ct = default)
    {
        // ── Skip silently if no webhook is configured ──────────────────────────
        if (string.IsNullOrWhiteSpace(_webhookUrl))
        {
            Console.WriteLine($"[Teams] WebhookUrl not configured — skipped: {msg.Title}");
            return;
        }

        try
        {
            // ── Use pre-built CardJson if available, else build a plain card ───
            var json = !string.IsNullOrWhiteSpace(msg.CardJson)
                ? msg.CardJson
                : BuildFallbackCardJson(msg.Title, msg.Message);

            using var content = new StringContent(json, Encoding.UTF8, "application/json");
            using var response = await _http.PostAsync(_webhookUrl, content, ct);

            if (response.IsSuccessStatusCode)
            {
                Console.WriteLine($"[Teams] ✔ Sent: {msg.Title}");
            }
            else
            {
                var body = await response.Content.ReadAsStringAsync(ct);
                Console.WriteLine($"[Teams] ✖ HTTP {(int)response.StatusCode} for '{msg.Title}': {body}");
            }
        }
        catch (TaskCanceledException)
        {
            Console.WriteLine($"[Teams] Timeout sending '{msg.Title}'.");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Teams] Failed sending '{msg.Title}': {ex.Message}");
        }
    }

    // ── Fallback plain Adaptive Card when CardJson is not pre-built ───────────
    private static string BuildFallbackCardJson(string title, string message)
    {
        var payload = new
        {
            type = "message",
            attachments = new[]
            {
                new
                {
                    contentType = "application/vnd.microsoft.card.adaptive",
                    content     = new
                    {
                        type    = "AdaptiveCard",
                        version = "1.4",
                        body    = new object[]
                        {
                            new { type = "TextBlock", text = title,
                                  weight = "Bolder", size = "Medium" },
                            new { type = "TextBlock", text = message,
                                  wrap = true, spacing = "Small" }
                        }
                    }
                }
            }
        };

        return JsonSerializer.Serialize(payload, _jsonOptions);
    }
}