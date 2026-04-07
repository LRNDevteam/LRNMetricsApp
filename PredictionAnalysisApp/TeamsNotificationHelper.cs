using LRN.Notifications.Abstractions;
using LRN.Notifications.Models;
using PredictionAnalysis.Services;

namespace PredictionAnalysis;

public class TeamsNotificationHelper
{
    private readonly ITeamsNotifier _teamsNotifier;

    public TeamsNotificationHelper(ITeamsNotifier teamsNotifier)
    {
        _teamsNotifier = teamsNotifier;
    }

    // ── Timestamp ─────────────────────────────────────────────────────────────
    private static string GetTimestamp()
    {
        var utc = DateTimeOffset.UtcNow;
        var ist = TimeZoneInfo.ConvertTime(utc,
            TimeZoneInfo.FindSystemTimeZoneById("India Standard Time"));
        return $"{utc:yyyy-MM-dd HH:mm:ss} UTC  |  {ist:HH:mm:ss} IST";
    }

    // ── Adaptive Card builder ─────────────────────────────────────────────────
    private static TeamsNotification CreateAdaptiveCard(
        string title,
        string themeColor,
        List<(string Label, string Value)> facts,
        List<object>? actions = null)
    {
        string accentColor = themeColor switch
        {
            "FF0000" => "Attention",
            "2EB886" => "Good",
            "FFA500" => "Warning",
            _        => "Accent"
        };

        var factItems = facts.Select(f => (object)new
        {
            type    = "ColumnSet",
            columns = new object[]
            {
                new { type = "Column", width = "auto",
                      items = new object[] {
                          new { type = "TextBlock", text = f.Label,
                                weight = "Bolder", size = "Small", wrap = true }
                      }},
                new { type = "Column", width = "stretch",
                      items = new object[] {
                          new { type = "TextBlock", text = f.Value,
                                size = "Small", wrap = true }
                      }}
            }
        }).ToList<object>();

        factItems.Add(new
        {
            type = "TextBlock",
            text = $"🕒 {GetTimestamp()}",
            size = "Small", isSubtle = true,
            wrap = true, spacing = "Small", separator = true
        });

        var adaptiveCard = new
        {
            type    = "AdaptiveCard",
            version = "1.4",
            body    = new object[]
            {
                new
                {
                    type    = "ColumnSet",
                    columns = new object[]
                    {
                        new
                        {
                            type  = "Column", width = "auto",
                            items = new object[]
                            {
                                new { type = "TextBlock", text = "▌",
                                      size = "ExtraLarge", weight = "Bolder", color = accentColor }
                            }
                        },
                        new
                        {
                            type  = "Column", width = "stretch",
                            items = new object[]
                            {
                                new { type = "TextBlock", text = title,
                                      weight = "Bolder", size = "Medium", color = accentColor }
                            }
                            .Concat(factItems).ToArray()
                        }
                    }
                }
            },
            actions = actions
        };

        var payload = new
        {
            type        = "message",
            attachments = new[]
            {
                new
                {
                    contentType = "application/vnd.microsoft.card.adaptive",
                    content     = adaptiveCard
                }
            }
        };

        return new TeamsNotification
        {
            Title      = title,
            Message    = title,
            ThemeColor = themeColor,
            CardJson   = System.Text.Json.JsonSerializer.Serialize(payload)
        };
    }

    // ── Notification events ───────────────────────────────────────────────────

    /// <summary>Sent once when the application starts.</summary>
    public Task SendAppStarted(string[] labNames) =>
        _teamsNotifier.SendAsync(CreateAdaptiveCard(
            "▶ Prediction Analysis — Run Started", "0076D7",
            [
                ("Date", DateTime.Today.ToString("MMMM dd, yyyy")),
                ("Labs", string.Join(", ", labNames))
            ]));

    /// <summary>Sent once when all labs have been processed.</summary>
    public Task SendAppStopped(int success, int failed, TimeSpan elapsed) =>
        _teamsNotifier.SendAsync(CreateAdaptiveCard(
            "⏹ Prediction Analysis — Run Finished",
            failed > 0 ? "FF0000" : "2EB886",
            [
                ("Labs Succeeded", success.ToString()),
                ("Labs Failed",    failed.ToString()),
                ("Elapsed",        $"{elapsed:mm\\:ss}")
            ]));

    /// <summary>Sent when processing starts for a specific lab.</summary>
    public Task SendLabStarted(string labName, int labIndex, int labTotal) =>
        _teamsNotifier.SendAsync(CreateAdaptiveCard(
            $"⚙️ Processing Lab {labIndex}/{labTotal}: {labName}", "0076D7",
            [
                ("Lab",      labName),
                ("Progress", $"{labIndex} of {labTotal}")
            ]));

    /// <summary>Sent when the source file was already processed in a previous run.</summary>
    public Task SendSkipped(string labName, string fileName) =>
        _teamsNotifier.SendAsync(CreateAdaptiveCard(
            "⏭ Lab Skipped — Already Processed", "0076D7",
            [
                ("Lab",    labName),
                ("File",   fileName),
                ("Reason", "File matches LastProcessedFile — no new data to process.")
            ]));

    /// <summary>Sent when no source files are found for a lab.</summary>
    public Task SendNoFilesAvailable(string labName, string inputPath) =>
        _teamsNotifier.SendAsync(CreateAdaptiveCard(
            "⚠️ No Files Available", "FFA500",
            [
                ("Lab",          labName),
                ("Input Folder", inputPath),
                ("Status",       "No .xlsx files found — lab skipped.")
            ]));

    /// <summary>Sent when the output report is successfully written.</summary>
    public Task SendOutputGenerated(string labName, string runId, string weekFolder,
        string outputFilePath) =>
        _teamsNotifier.SendAsync(CreateAdaptiveCard(
            "📁 Output Report Generated", "2EB886",
            [
                ("Lab",         labName),
                ("RunID",       runId),
                ("Week",        weekFolder),
                ("Output File", Path.GetFileName(outputFilePath))
            ]));



    public Task SendLabCompleted(
       string labName, string runId, string weekFolder,
       string sourceFile, string outputFilePath,
       SummaryResult s) =>
       _teamsNotifier.SendAsync(CreateAdaptiveCard(
           $"✅ {labName} — Report Generated", "2EB886",
           [
               ("Lab",                    labName),
                ("Run ID",                 runId),
                ("Week",                   weekFolder),
                ("Source File",            sourceFile),
                ("Output File",            Path.GetFileName(outputFilePath)),
              
           ]));
    /// <summary>
    /// Sent when a new file is processed successfully — includes the full summary breakdown.
    /// </summary>
    public Task SendLabCompletedNew(
        string labName, string runId, string weekFolder,
        string sourceFile, string outputFilePath,
        SummaryResult s) =>
        _teamsNotifier.SendAsync(CreateAdaptiveCard(
            $"✅ {labName} — Report Generated", "2EB886",
            [
                ("Lab",                    labName),
                ("Run ID",                 runId),
                ("Week",                   weekFolder),
                ("Source File",            sourceFile),
                ("Output File",            Path.GetFileName(outputFilePath)),
                ("──── Predicted To Pay",  "────────────────────────────"),
                ("Claims",                 $"{s.TotalPredictedClaims:N0}"),
                ("Allowed Amount",         $"{s.TotalPredictedAllowed:C}"),
                ("Insurance Payment",      $"{s.TotalPredictedInsurance:C}"),
                ("──── Paid",              "────────────────────────────"),
                ("Claims",                 $"{s.TotalPaidClaims:N0}  |  {s.PaymentRatioCount:N1}% of Predicted"),
                ("Pred. Allowed",          $"{s.TotalPaidPredAllowed:C}  |  {s.PaymentRatioAllowed:N1}%"),
                ("Pred. Insurance",        $"{s.TotalPaidPredInsurance:C}  |  {s.PaymentRatioInsurance:N1}%"),
                ("──── Unpaid",            "────────────────────────────"),
                ("Claims",                 $"{s.TotalUnpaidClaims:N0}  |  {s.NonPaymentRateCount:N1}% of Predicted"),
                ("Pred. Allowed",          $"{s.TotalUnpaidPredAllowed:C}  |  {s.NonPaymentRateAllowed:N1}%"),
                ("Pred. Insurance",        $"{s.TotalUnpaidPredInsurance:C}  |  {s.NonPaymentRateInsurance:N1}%"),
                ("──── Denied",            "────────────────────────────"),
                ("Claims",                 $"{s.DeniedClaims:N0}  |  {s.DeniedRatioCount:N1}% of Unpaid"),
                ("Pred. Allowed",          $"{s.DeniedPredAllowed:C}  |  {s.DeniedRatioAllowed:N1}%"),
                ("──── No Response",       "────────────────────────────"),
                ("Claims",                 $"{s.NoResponseClaims:N0}  |  {s.NoResponseRatioCount:N1}% of Unpaid"),
                ("Pred. Allowed",          $"{s.NoResponsePredAllowed:C}  |  {s.NoResponseRatioAllowed:N1}%"),
                ("──── Adjusted",          "────────────────────────────"),
                ("Claims",                 $"{s.AdjustedClaims:N0}  |  {s.AdjustedRatioCount:N1}% of Unpaid"),
                ("Pred. Allowed",          $"{s.AdjustedPredAllowed:C}  |  {s.AdjustedRatioAllowed:N1}%"),
                ("──── Prediction Accuracy","────────────────────────────"),
                ("Paid vs Predicted",      $"{s.PredVsActualRatioCount:N1}%  (claims)"),
                ("Allowed Accuracy",       $"{s.PredVsActualRatioAllowed:N1}%"),
                ("Insurance Accuracy",     $"{s.PredVsActualRatioInsurance:N1}%"),
            ]));

    /// <summary>Sent when a lab fails with an exception.</summary>
    public Task SendLabFailed(string labName, string runId, string errorMessage) =>
        _teamsNotifier.SendAsync(CreateAdaptiveCard(
            "✖ Lab Processing Failed", "FF0000",
            [
                ("Lab",   labName),
                ("RunID", string.IsNullOrWhiteSpace(runId) ? "N/A" : runId),
                ("Error", errorMessage)
            ]));

    /// <summary>General error — used for config/startup failures.</summary>
    public Task SendError(string message) =>
        _teamsNotifier.SendAsync(CreateAdaptiveCard(
            "✖ Error", "FF0000",
            [("Details", message)]));
}