using LRN.PayerPolicyMapper.Core.Abstractions;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace LRN.PayerPolicyMapper.Core.Data;

/// <summary>
/// Review notifications through the solution's existing Payer Master notification mechanism
/// (dbo.PayerMasterNotifications, surfaced on the Payer Master Notifications screen). Falls back
/// to logging when the table has not been deployed.
/// </summary>
public sealed class PayerMasterNotificationService : INotificationService
{
    private readonly string _connectionString;
    private readonly ILogger<PayerMasterNotificationService> _logger;
    // Same audience the Lab master change notifications go to (PayerMasterWorkflowService.LabChangeRoles).
    private static readonly string[] RecipientRoles = { "LRN Admin", "Reports Manager" };

    public PayerMasterNotificationService(string connectionString, ILogger<PayerMasterNotificationService> logger)
    {
        _connectionString = connectionString;
        _logger = logger;
    }

    public async Task NotifyReviewNeededAsync(LabInsuranceRow row, MatchResult result, CancellationToken ct)
    {
        var top = result.Candidates.Count > 0 ? result.Candidates[0] : null;
        var message = top is null
            ? $"Payer: {row.PayerNameRaw}"
            : $"Payer: {row.PayerNameRaw} • Best candidate: {top.Record.PayerNameRaw} (score {top.Score}{(top.MissingGlobalPayerId ? ", candidate missing Global Payer ID" : $", Global Payer ID {top.Record.GlobalPayerId}")})";
        try
        {
            await using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync(ct);
            foreach (var role in RecipientRoles)
            {
                await using var cmd = new SqlCommand("""
                    IF OBJECT_ID('dbo.PayerMasterNotifications', 'U') IS NOT NULL
                        INSERT INTO dbo.PayerMasterNotifications (Master, TriggerType, Title, Message, RecipientRole, RecipientUser)
                        VALUES ('Lab', 'MappingReviewNeeded', @Title, @Message, @Role, NULL);
                    """, conn);
                cmd.Parameters.AddWithValue("@Title", "Payer mapping suggestions ready for review in the Lab Insurance Master");
                cmd.Parameters.AddWithValue("@Message", message.Length > 1000 ? message[..1000] : message);
                cmd.Parameters.AddWithValue("@Role", role);
                await cmd.ExecuteNonQueryAsync(ct);
            }
        }
        catch (Exception ex)
        {
            // Notifications are best-effort; a failure must never abort the mapping pipeline.
            _logger.LogWarning(ex, "Review notification for LabInsuranceMasterId {Id} could not be written", row.LabInsuranceMasterId);
        }
        _logger.LogInformation("Manual review needed for LabInsuranceMasterId {Id}: {Message}", row.LabInsuranceMasterId, message);
    }
}

/// <summary>Logging-only stub for hosts without the Payer Master notification tables.</summary>
public sealed class LoggingNotificationService : INotificationService
{
    private readonly ILogger<LoggingNotificationService> _logger;

    public LoggingNotificationService(ILogger<LoggingNotificationService> logger) => _logger = logger;

    public Task NotifyReviewNeededAsync(LabInsuranceRow row, MatchResult result, CancellationToken ct)
    {
        _logger.LogInformation("Manual review needed for LabInsuranceMasterId {Id} ('{Payer}'), {Count} candidate(s), top score {Score}",
            row.LabInsuranceMasterId, row.PayerNameRaw, result.Candidates.Count,
            result.Candidates.Count > 0 ? result.Candidates[0].Score : (decimal?)null);
        return Task.CompletedTask;
    }
}
