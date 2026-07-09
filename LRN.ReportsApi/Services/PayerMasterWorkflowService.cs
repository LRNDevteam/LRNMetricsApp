using System.Data;
using System.Net.Mail;
using System.Text.Json;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services;

/// <summary>
/// Payer Master approval workflow (Requirements Spec v1.0):
/// approval queue for Reports Analyst actions, field-level audit trail,
/// role-based in-app + email notifications, SLA escalation, and
/// system-assigned sequential Global Payer IDs.
/// </summary>
public interface IPayerMasterWorkflowService
{
    Task<PayerMasterWorkflowActionResult> CreatePolicyPayerAsync(PayerPolicyInsuranceMasterDto dto, string userName, bool requiresApproval, CancellationToken ct);
    Task<PayerMasterWorkflowActionResult> UpdatePolicyPayerAsync(int id, PayerPolicyInsuranceMasterDto dto, string userName, bool requiresApproval, CancellationToken ct);
    Task<PayerMasterWorkflowActionResult> DeactivatePolicyPayerAsync(int id, string userName, bool requiresApproval, CancellationToken ct);

    Task<PayerMasterWorkflowActionResult> CreateInsurancePayerAsync(InsurancePayerMasterDto dto, string userName, bool requiresApproval, CancellationToken ct);
    Task<PayerMasterWorkflowActionResult> UpdateInsurancePayerAsync(int id, InsurancePayerMasterDto dto, string userName, bool requiresApproval, CancellationToken ct);
    Task<PayerMasterWorkflowActionResult> DeactivateInsurancePayerAsync(int id, string userName, bool requiresApproval, CancellationToken ct);

    Task<PagedResult<PayerMasterApprovalRequestDto>> GetApprovalsAsync(PayerMasterApprovalQuery query, CancellationToken ct);
    Task<PayerMasterApprovalDecisionResult> DecideAsync(PayerMasterApprovalDecisionRequest request, bool approve, string approver, IReadOnlyCollection<string> approverMasters, CancellationToken ct);
    Task<PagedResult<PayerMasterAuditEntryDto>> GetAuditAsync(PayerMasterAuditQuery query, CancellationToken ct);
    Task<IReadOnlyList<PayerMasterNotificationDto>> GetNotificationsAsync(IReadOnlyCollection<string> roles, string userName, int take, CancellationToken ct);
    Task<int> EscalateOverdueApprovalsAsync(CancellationToken ct);
}

public sealed class PayerMasterWorkflowService : IPayerMasterWorkflowService
{
    private const string PolicyMaster = "Policy";
    private const string LabMaster = "Lab";

    private static readonly string[] PolicyApproverRoles = ["LRN Admin", "Payer Policy Admin"];
    private static readonly string[] LabApproverRoles = ["LRN Admin", "Reports Manager"];
    private static readonly string[] PolicyChangeRoles = ["LRN Admin", "Payer Policy Admin", "Reports Analyst", "ETL"];
    private static readonly string[] LabChangeRoles = ["LRN Admin", "Reports Manager", "Reports Analyst", "ETL"];
    private static readonly string[] PolicyDeactivationRoles = ["LRN Admin", "Reports Manager", "Reports Analyst"];

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private static readonly SemaphoreSlim SchemaLock = new(1, 1);
    private static bool _schemaReady;

    private readonly string _connectionString;
    private readonly IMasterValuesRepository _repository;
    private readonly IConfiguration _configuration;
    private readonly IOptions<DenialWorkflowSupportOptions> _supportOptions;
    private readonly ILogger<PayerMasterWorkflowService> _logger;

    public PayerMasterWorkflowService(
        IMasterValuesRepository repository,
        IConfiguration configuration,
        IOptions<DenialWorkflowSupportOptions> supportOptions,
        ILogger<PayerMasterWorkflowService> logger)
    {
        _repository = repository;
        _configuration = configuration;
        _supportOptions = supportOptions;
        _logger = logger;
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster.");
    }

    private int SlaHours => int.TryParse(_configuration["PayerMaster:ApprovalSlaHours"], out var h) && h > 0 ? h : 48;

    // ── Policy master actions ────────────────────────────────────────────────

    public async Task<PayerMasterWorkflowActionResult> CreatePolicyPayerAsync(PayerPolicyInsuranceMasterDto dto, string userName, bool requiresApproval, CancellationToken ct)
    {
        await EnsureSchemaAsync(ct);
        if (requiresApproval)
            return await SubmitApprovalAsync(PolicyMaster, "Add", null, dto.PayerNameRaw, JsonSerializer.Serialize(dto, JsonOptions), userName, ct);

        if (!dto.GlobalPayerId.HasValue) dto.GlobalPayerId = await NextGlobalPayerIdAsync(ct);
        var id = await _repository.CreatePolicyPayerAsync(dto, userName, ct);
        await WriteAuditAsync(PolicyMaster, id, dto.GlobalPayerId, dto.PayerNameRaw, Diff(null, PolicyFields(dto)), "Add", userName, "Applied directly", null, null, ct);
        await NotifyAsync(PolicyMaster, "NewPayer",
            "Review Lab Insurance Master – New Payer added to Payer Policy Insurance Master",
            $"Payer: {dto.PayerNameRaw} • Global Payer ID: {dto.GlobalPayerId} • Added by {userName}",
            PolicyChangeRoles, null, ct);
        return new PayerMasterWorkflowActionResult { Id = id };
    }

    public async Task<PayerMasterWorkflowActionResult> UpdatePolicyPayerAsync(int id, PayerPolicyInsuranceMasterDto dto, string userName, bool requiresApproval, CancellationToken ct)
    {
        await EnsureSchemaAsync(ct);
        var existing = await _repository.GetPolicyPayerAsync(id, ct)
            ?? throw new ArgumentException("Payer policy insurance record was not found.");
        if (requiresApproval)
            return await SubmitApprovalAsync(PolicyMaster, "Edit", id, existing.PayerNameRaw, JsonSerializer.Serialize(dto, JsonOptions), userName, ct);

        var changes = Diff(PolicyFields(existing), PolicyFields(dto));
        var ok = await _repository.UpdatePolicyPayerAsync(id, dto, userName, ct);
        if (!ok) return new PayerMasterWorkflowActionResult { Success = false, Message = "Record was not found." };
        await WriteAuditAsync(PolicyMaster, id, dto.GlobalPayerId ?? existing.GlobalPayerId, dto.PayerNameRaw, changes, "Edit", userName, "Applied directly", null, null, ct);
        await NotifyAsync(PolicyMaster, "PayerUpdated",
            "Review Lab Insurance Master – Payer record updated in Payer Policy Insurance Master",
            $"Payer: {dto.PayerNameRaw} • Global Payer ID: {dto.GlobalPayerId ?? existing.GlobalPayerId} • Action: Edit by {userName}",
            PolicyChangeRoles, null, ct);
        return new PayerMasterWorkflowActionResult { Id = id };
    }

    public async Task<PayerMasterWorkflowActionResult> DeactivatePolicyPayerAsync(int id, string userName, bool requiresApproval, CancellationToken ct)
    {
        await EnsureSchemaAsync(ct);
        var existing = await _repository.GetPolicyPayerAsync(id, ct)
            ?? throw new ArgumentException("Payer policy insurance record was not found.");
        if (requiresApproval)
            return await SubmitApprovalAsync(PolicyMaster, "Deactivate", id, existing.PayerNameRaw, null, userName, ct);

        var ok = await _repository.UpdatePolicyPayerStatusAsync(id, "Inactive", userName, ct);
        if (!ok) return new PayerMasterWorkflowActionResult { Success = false, Message = "Record was not found." };
        await WriteAuditAsync(PolicyMaster, id, existing.GlobalPayerId, existing.PayerNameRaw,
            [("Is Active", existing.IsActive, "Inactive")], "Deactivate", userName, "Applied directly", null, null, ct);
        await NotifyAsync(PolicyMaster, "PayerDeactivated",
            "Payer deactivated – review Lab Insurance Master",
            $"{existing.PayerNameRaw} (Global Payer ID {existing.GlobalPayerId}) was deactivated in the Payer Policy Insurance Master. Please review and deactivate linked Lab Insurance Master record(s) manually.",
            PolicyDeactivationRoles, null, ct);
        return new PayerMasterWorkflowActionResult { Id = id };
    }

    // ── Lab master actions ───────────────────────────────────────────────────

    public async Task<PayerMasterWorkflowActionResult> CreateInsurancePayerAsync(InsurancePayerMasterDto dto, string userName, bool requiresApproval, CancellationToken ct)
    {
        await EnsureSchemaAsync(ct);
        if (requiresApproval)
            return await SubmitApprovalAsync(LabMaster, "Add", null, dto.PayerNameRaw, JsonSerializer.Serialize(dto, JsonOptions), userName, ct);

        var id = await _repository.CreateInsurancePayerAsync(dto, userName, ct);
        await WriteAuditAsync(LabMaster, id, dto.GlobalPayerID, dto.PayerNameRaw, Diff(null, LabFields(dto)), "Add", userName, "Applied directly", null, null, ct);
        await NotifyAsync(LabMaster, dto.GlobalPayerID.HasValue ? "PayerUpdated" : "NewUnmappedPayer",
            dto.GlobalPayerID.HasValue
                ? "Existing Payer record updated in Lab Insurance Master"
                : "New Payer record added to the Lab Insurance Master, Review to map the payer",
            $"Payer: {dto.PayerNameRaw} • Lab: {dto.LabName} • Added by {userName}",
            LabChangeRoles, null, ct);
        return new PayerMasterWorkflowActionResult { Id = id };
    }

    public async Task<PayerMasterWorkflowActionResult> UpdateInsurancePayerAsync(int id, InsurancePayerMasterDto dto, string userName, bool requiresApproval, CancellationToken ct)
    {
        await EnsureSchemaAsync(ct);
        var existing = await _repository.GetInsurancePayerAsync(id, ct)
            ?? throw new ArgumentException("Insurance payer was not found.");
        var isMapping = !existing.GlobalPayerID.HasValue && dto.GlobalPayerID.HasValue;
        if (requiresApproval)
            return await SubmitApprovalAsync(LabMaster, isMapping ? "Map" : "Edit", id, existing.PayerNameRaw, JsonSerializer.Serialize(dto, JsonOptions), userName, ct);

        var changes = Diff(LabFields(existing), LabFields(dto));
        var ok = await _repository.UpdateInsurancePayerAsync(id, dto, userName, ct);
        if (!ok) return new PayerMasterWorkflowActionResult { Success = false, Message = "Record was not found." };
        await WriteAuditAsync(LabMaster, id, dto.GlobalPayerID ?? existing.GlobalPayerID, existing.PayerNameRaw, changes, isMapping ? "Map" : "Edit", userName, "Applied directly", null, null, ct);
        await NotifyAsync(LabMaster, "PayerUpdated",
            "Existing Payer record updated in Lab Insurance Master",
            $"Payer: {existing.PayerNameRaw} • Global Payer ID: {dto.GlobalPayerID ?? existing.GlobalPayerID} • Action: {(isMapping ? "Map" : "Edit")} by {userName}",
            LabChangeRoles, null, ct);
        return new PayerMasterWorkflowActionResult { Id = id };
    }

    public async Task<PayerMasterWorkflowActionResult> DeactivateInsurancePayerAsync(int id, string userName, bool requiresApproval, CancellationToken ct)
    {
        await EnsureSchemaAsync(ct);
        var existing = await _repository.GetInsurancePayerAsync(id, ct)
            ?? throw new ArgumentException("Insurance payer was not found.");
        if (requiresApproval)
            return await SubmitApprovalAsync(LabMaster, "Deactivate", id, existing.PayerNameRaw, null, userName, ct);

        var ok = await _repository.UpdateInsurancePayerStatusAsync(id, "Inactive", userName, ct);
        if (!ok) return new PayerMasterWorkflowActionResult { Success = false, Message = "Record was not found." };
        await WriteAuditAsync(LabMaster, id, existing.GlobalPayerID, existing.PayerNameRaw,
            [("Is Active", existing.IsActive, "Inactive")], "Deactivate", userName, "Applied directly", null, null, ct);
        await NotifyAsync(LabMaster, "PayerUpdated",
            "Existing Payer record updated in Lab Insurance Master",
            $"Payer: {existing.PayerNameRaw} • Lab: {existing.LabName} • Action: Deactivate by {userName}",
            LabChangeRoles, null, ct);
        return new PayerMasterWorkflowActionResult { Id = id };
    }

    // ── Approval queue ───────────────────────────────────────────────────────

    private async Task<PayerMasterWorkflowActionResult> SubmitApprovalAsync(string master, string actionType, int? targetId, string? payerName, string? payloadJson, string userName, CancellationToken ct)
    {
        int requestId;
        await using (var conn = Open())
        {
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand("""
                INSERT INTO dbo.PayerMasterApprovalRequests (Master, ActionType, TargetId, PayerName, PayloadJson, SubmittedBy)
                OUTPUT INSERTED.ApprovalRequestId
                VALUES (@Master, @ActionType, @TargetId, @PayerName, @PayloadJson, @SubmittedBy);
                """, conn);
            cmd.Parameters.AddWithValue("@Master", master);
            cmd.Parameters.AddWithValue("@ActionType", actionType);
            cmd.Parameters.AddWithValue("@TargetId", (object?)targetId ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@PayerName", (object?)payerName ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@PayloadJson", (object?)payloadJson ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@SubmittedBy", userName);
            requestId = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
        }

        await WriteAuditAsync(master, targetId, null, payerName,
            [("Approval Request", null, $"{actionType} submitted for approval (request #{requestId})")],
            actionType, userName, "Pending", null, null, ct);

        var approvers = master == PolicyMaster ? PolicyApproverRoles : LabApproverRoles;
        await NotifyAsync(master, "ApprovalPending",
            $"Approval pending – {actionType} {payerName}",
            $"{userName} (Reports Analyst) submitted a {actionType} action for \"{payerName}\" in the {MasterLabel(master)}. Awaiting review.",
            approvers, null, ct);

        return new PayerMasterWorkflowActionResult { PendingApproval = true, ApprovalRequestId = requestId };
    }

    public async Task<PagedResult<PayerMasterApprovalRequestDto>> GetApprovalsAsync(PayerMasterApprovalQuery query, CancellationToken ct)
    {
        await EnsureSchemaAsync(ct);
        await EscalateOverdueApprovalsAsync(ct);

        query.Page = Math.Max(1, query.Page);
        query.PageSize = Math.Clamp(query.PageSize <= 0 ? 50 : query.PageSize, 10, 200);
        var result = new PagedResult<PayerMasterApprovalRequestDto> { Page = query.Page, PageSize = query.PageSize };

        var where = new List<string> { "1=1" };
        var parameters = new List<SqlParameter>();
        if (!string.IsNullOrWhiteSpace(query.Master)) { where.Add("Master = @Master"); parameters.Add(new("@Master", query.Master.Trim())); }
        if (!string.IsNullOrWhiteSpace(query.SubmittedBy)) { where.Add("SubmittedBy = @SubmittedBy"); parameters.Add(new("@SubmittedBy", query.SubmittedBy.Trim())); }
        where.Add("Status = @Status");
        parameters.Add(new("@Status", string.IsNullOrWhiteSpace(query.Status) ? "Pending" : query.Status.Trim()));
        var whereSql = string.Join(" AND ", where);

        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using (var count = new SqlCommand($"SELECT COUNT(1) FROM dbo.PayerMasterApprovalRequests WHERE {whereSql};", conn))
        {
            count.Parameters.AddRange(parameters.Select(p => new SqlParameter(p.ParameterName, p.Value)).ToArray());
            result.TotalCount = Convert.ToInt32(await count.ExecuteScalarAsync(ct) ?? 0);
        }
        await using var cmd = new SqlCommand($"""
            SELECT ApprovalRequestId, Master, ActionType, TargetId, PayerName, PayloadJson, SubmittedBy, SubmittedOn,
                   Status, DecidedBy, DecidedOn, RejectionReason, EscalatedOn
            FROM dbo.PayerMasterApprovalRequests
            WHERE {whereSql}
            ORDER BY SubmittedOn ASC
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """, conn);
        cmd.Parameters.AddRange(parameters.ToArray());
        cmd.Parameters.AddWithValue("@Offset", (query.Page - 1) * query.PageSize);
        cmd.Parameters.AddWithValue("@PageSize", query.PageSize);
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct)) result.Items.Add(MapApproval(reader));
        }

        foreach (var item in result.Items)
        {
            item.SlaDeadline = item.SubmittedOn.AddHours(SlaHours);
            item.IsOverdue = item.Status == "Pending" && DateTime.UtcNow > item.SlaDeadline;
            item.ChangeSummary = await BuildChangeSummaryAsync(item, ct);
        }
        return result;
    }

    public async Task<PayerMasterApprovalDecisionResult> DecideAsync(PayerMasterApprovalDecisionRequest request, bool approve, string approver, IReadOnlyCollection<string> approverMasters, CancellationToken ct)
    {
        await EnsureSchemaAsync(ct);
        var result = new PayerMasterApprovalDecisionResult();
        if (!approve && string.IsNullOrWhiteSpace(request.Reason))
        {
            result.Failed = request.Ids.Count;
            result.Errors.Add("A rejection reason is required.");
            return result;
        }

        foreach (var id in request.Ids.Distinct())
        {
            try
            {
                var req = await GetApprovalRequestAsync(id, ct);
                if (req is null || req.Status != "Pending")
                {
                    result.Failed++;
                    result.Errors.Add($"Request #{id} is not pending.");
                    continue;
                }
                if (!approverMasters.Contains(req.Master))
                {
                    result.Failed++;
                    result.Errors.Add($"Request #{id}: you are not an eligible approver for the {MasterLabel(req.Master)}.");
                    continue;
                }

                if (approve) await ApplyApprovedRequestAsync(req, approver, ct);
                await MarkDecisionAsync(id, approve, approver, request.Reason, ct);

                if (!approve)
                {
                    await WriteAuditAsync(req.Master, req.TargetId, null, req.PayerName,
                        [("Approval Request", $"Pending (request #{id})", "Rejected")],
                        "Reject", approver, "Rejected", approver, request.Reason, ct);
                }

                await NotifyAsync(req.Master, "ApprovalOutcome",
                    approve ? "Your request was approved" : "Your request was rejected",
                    approve
                        ? $"{req.ActionType} \"{req.PayerName}\" in the {MasterLabel(req.Master)} was approved by {approver}."
                        : $"{req.ActionType} \"{req.PayerName}\" in the {MasterLabel(req.Master)} was rejected by {approver} – Reason: \"{request.Reason}\"",
                    Array.Empty<string>(), req.SubmittedBy, ct);

                result.Processed++;
            }
            catch (Exception ex)
            {
                result.Failed++;
                result.Errors.Add($"Request #{id}: {ex.Message}");
                _logger.LogError(ex, "Payer Master approval decision failed for request {RequestId}.", id);
            }
        }
        return result;
    }

    private async Task ApplyApprovedRequestAsync(PayerMasterApprovalRequestDto req, string approver, CancellationToken ct)
    {
        if (req.Master == PolicyMaster)
        {
            switch (req.ActionType)
            {
                case "Add":
                {
                    var dto = JsonSerializer.Deserialize<PayerPolicyInsuranceMasterDto>(req.PayloadJson ?? "{}", JsonOptions)
                        ?? throw new InvalidOperationException("Approval payload is empty.");
                    if (!dto.GlobalPayerId.HasValue) dto.GlobalPayerId = await NextGlobalPayerIdAsync(ct);
                    var id = await _repository.CreatePolicyPayerAsync(dto, req.SubmittedBy, ct);
                    await WriteAuditAsync(PolicyMaster, id, dto.GlobalPayerId, dto.PayerNameRaw, Diff(null, PolicyFields(dto)), "Add", req.SubmittedBy, "Approved", approver, null, ct);
                    await NotifyAsync(PolicyMaster, "NewPayer",
                        "Review Lab Insurance Master – New Payer added to Payer Policy Insurance Master",
                        $"Payer: {dto.PayerNameRaw} • Global Payer ID: {dto.GlobalPayerId} • Submitted by {req.SubmittedBy}, approved by {approver}",
                        PolicyChangeRoles, null, ct);
                    break;
                }
                case "Edit":
                {
                    var dto = JsonSerializer.Deserialize<PayerPolicyInsuranceMasterDto>(req.PayloadJson ?? "{}", JsonOptions)
                        ?? throw new InvalidOperationException("Approval payload is empty.");
                    var existing = await _repository.GetPolicyPayerAsync(req.TargetId!.Value, ct)
                        ?? throw new InvalidOperationException("Target record no longer exists.");
                    var changes = Diff(PolicyFields(existing), PolicyFields(dto));
                    if (!await _repository.UpdatePolicyPayerAsync(req.TargetId.Value, dto, req.SubmittedBy, ct))
                        throw new InvalidOperationException("Target record no longer exists.");
                    await WriteAuditAsync(PolicyMaster, req.TargetId, dto.GlobalPayerId ?? existing.GlobalPayerId, dto.PayerNameRaw, changes, "Edit", req.SubmittedBy, "Approved", approver, null, ct);
                    await NotifyAsync(PolicyMaster, "PayerUpdated",
                        "Review Lab Insurance Master – Payer record updated in Payer Policy Insurance Master",
                        $"Payer: {dto.PayerNameRaw} • Global Payer ID: {dto.GlobalPayerId ?? existing.GlobalPayerId} • Action: Edit by {req.SubmittedBy}, approved by {approver}",
                        PolicyChangeRoles, null, ct);
                    break;
                }
                case "Deactivate":
                {
                    var existing = await _repository.GetPolicyPayerAsync(req.TargetId!.Value, ct)
                        ?? throw new InvalidOperationException("Target record no longer exists.");
                    await _repository.UpdatePolicyPayerStatusAsync(req.TargetId.Value, "Inactive", req.SubmittedBy, ct);
                    await WriteAuditAsync(PolicyMaster, req.TargetId, existing.GlobalPayerId, existing.PayerNameRaw,
                        [("Is Active", existing.IsActive, "Inactive")], "Deactivate", req.SubmittedBy, "Approved", approver, null, ct);
                    await NotifyAsync(PolicyMaster, "PayerDeactivated",
                        "Payer deactivated – review Lab Insurance Master",
                        $"{existing.PayerNameRaw} (Global Payer ID {existing.GlobalPayerId}) was deactivated in the Payer Policy Insurance Master. Please review and deactivate linked Lab Insurance Master record(s) manually.",
                        PolicyDeactivationRoles, null, ct);
                    break;
                }
                default: throw new InvalidOperationException($"Unknown action type '{req.ActionType}'.");
            }
            return;
        }

        switch (req.ActionType)
        {
            case "Add":
            {
                var dto = JsonSerializer.Deserialize<InsurancePayerMasterDto>(req.PayloadJson ?? "{}", JsonOptions)
                    ?? throw new InvalidOperationException("Approval payload is empty.");
                var id = await _repository.CreateInsurancePayerAsync(dto, req.SubmittedBy, ct);
                await WriteAuditAsync(LabMaster, id, dto.GlobalPayerID, dto.PayerNameRaw, Diff(null, LabFields(dto)), "Add", req.SubmittedBy, "Approved", approver, null, ct);
                break;
            }
            case "Edit":
            case "Map":
            {
                var dto = JsonSerializer.Deserialize<InsurancePayerMasterDto>(req.PayloadJson ?? "{}", JsonOptions)
                    ?? throw new InvalidOperationException("Approval payload is empty.");
                var existing = await _repository.GetInsurancePayerAsync(req.TargetId!.Value, ct)
                    ?? throw new InvalidOperationException("Target record no longer exists.");
                if (!string.IsNullOrWhiteSpace(existing.PayerCode)) dto.PayerCode = existing.PayerCode;
                dto.PayerNameRaw = existing.PayerNameRaw;
                var changes = Diff(LabFields(existing), LabFields(dto));
                if (!await _repository.UpdateInsurancePayerAsync(req.TargetId.Value, dto, req.SubmittedBy, ct))
                    throw new InvalidOperationException("Target record no longer exists.");
                await WriteAuditAsync(LabMaster, req.TargetId, dto.GlobalPayerID ?? existing.GlobalPayerID, existing.PayerNameRaw, changes, req.ActionType, req.SubmittedBy, "Approved", approver, null, ct);
                break;
            }
            case "Deactivate":
            {
                var existing = await _repository.GetInsurancePayerAsync(req.TargetId!.Value, ct)
                    ?? throw new InvalidOperationException("Target record no longer exists.");
                await _repository.UpdateInsurancePayerStatusAsync(req.TargetId.Value, "Inactive", req.SubmittedBy, ct);
                await WriteAuditAsync(LabMaster, req.TargetId, existing.GlobalPayerID, existing.PayerNameRaw,
                    [("Is Active", existing.IsActive, "Inactive")], "Deactivate", req.SubmittedBy, "Approved", approver, null, ct);
                break;
            }
            default: throw new InvalidOperationException($"Unknown action type '{req.ActionType}'.");
        }

        await NotifyAsync(LabMaster, "PayerUpdated",
            "Existing Payer record updated in Lab Insurance Master",
            $"Payer: {req.PayerName} • Action: {req.ActionType} by {req.SubmittedBy}, approved by {approver}",
            LabChangeRoles, null, ct);
    }

    public async Task<int> EscalateOverdueApprovalsAsync(CancellationToken ct)
    {
        await EnsureSchemaAsync(ct);
        var overdue = new List<(int Id, string Master, string ActionType, string? PayerName, DateTime SubmittedOn)>();
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using (var cmd = new SqlCommand("""
            SELECT ApprovalRequestId, Master, ActionType, PayerName, SubmittedOn
            FROM dbo.PayerMasterApprovalRequests
            WHERE Status = 'Pending' AND EscalatedOn IS NULL AND SubmittedOn < DATEADD(HOUR, -@SlaHours, SYSUTCDATETIME());
            """, conn))
        {
            cmd.Parameters.AddWithValue("@SlaHours", SlaHours);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                overdue.Add((reader.GetInt32(0), reader.GetString(1), reader.GetString(2), reader.IsDBNull(3) ? null : reader.GetString(3), reader.GetDateTime(4)));
        }

        foreach (var item in overdue)
        {
            await using (var update = new SqlCommand("UPDATE dbo.PayerMasterApprovalRequests SET EscalatedOn = SYSUTCDATETIME() WHERE ApprovalRequestId = @Id AND EscalatedOn IS NULL;", conn))
            {
                update.Parameters.AddWithValue("@Id", item.Id);
                if (await update.ExecuteNonQueryAsync(ct) == 0) continue; // another instance already escalated it
            }
            var approvers = item.Master == PolicyMaster ? PolicyApproverRoles : LabApproverRoles;
            await NotifyAsync(item.Master, "SlaEscalation",
                "SLA escalation – approval overdue",
                $"{item.ActionType} request for \"{item.PayerName}\" in the {MasterLabel(item.Master)} has exceeded the {SlaHours}h approval SLA window (submitted {item.SubmittedOn:yyyy-MM-dd HH:mm} UTC).",
                approvers, null, ct);
        }
        return overdue.Count;
    }

    // ── Audit trail ──────────────────────────────────────────────────────────

    public async Task<PagedResult<PayerMasterAuditEntryDto>> GetAuditAsync(PayerMasterAuditQuery query, CancellationToken ct)
    {
        await EnsureSchemaAsync(ct);
        query.Page = Math.Max(1, query.Page);
        query.PageSize = Math.Clamp(query.PageSize <= 0 ? 50 : query.PageSize, 10, 200);
        var result = new PagedResult<PayerMasterAuditEntryDto> { Page = query.Page, PageSize = query.PageSize };

        var where = new List<string> { "1=1" };
        var parameters = new List<SqlParameter>();
        if (!string.IsNullOrWhiteSpace(query.Master)) { where.Add("Master = @Master"); parameters.Add(new("@Master", query.Master.Trim())); }
        if (!string.IsNullOrWhiteSpace(query.ActionType)) { where.Add("ActionType = @ActionType"); parameters.Add(new("@ActionType", query.ActionType.Trim())); }
        if (!string.IsNullOrWhiteSpace(query.Search))
        {
            where.Add("(PayerName LIKE @Search OR PerformedBy LIKE @Search OR FieldName LIKE @Search)");
            parameters.Add(new("@Search", $"%{query.Search.Trim()}%"));
        }
        var whereSql = string.Join(" AND ", where);

        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using (var count = new SqlCommand($"SELECT COUNT(1) FROM dbo.PayerMasterAuditTrail WHERE {whereSql};", conn))
        {
            count.Parameters.AddRange(parameters.Select(p => new SqlParameter(p.ParameterName, p.Value)).ToArray());
            result.TotalCount = Convert.ToInt32(await count.ExecuteScalarAsync(ct) ?? 0);
        }
        await using var cmd = new SqlCommand($"""
            SELECT AuditId, Master, RecordId, GlobalPayerID, PayerName, FieldName, OldValue, NewValue,
                   ActionType, PerformedBy, PerformedOn, ApprovalStatus, Approver, RejectionReason
            FROM dbo.PayerMasterAuditTrail
            WHERE {whereSql}
            ORDER BY PerformedOn DESC, AuditId DESC
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """, conn);
        cmd.Parameters.AddRange(parameters.ToArray());
        cmd.Parameters.AddWithValue("@Offset", (query.Page - 1) * query.PageSize);
        cmd.Parameters.AddWithValue("@PageSize", query.PageSize);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            result.Items.Add(new PayerMasterAuditEntryDto
            {
                AuditId = reader.GetInt64(0),
                Master = reader.GetString(1),
                RecordId = reader.IsDBNull(2) ? null : reader.GetInt32(2),
                GlobalPayerID = reader.IsDBNull(3) ? null : reader.GetInt32(3),
                PayerName = reader.IsDBNull(4) ? null : reader.GetString(4),
                FieldName = reader.GetString(5),
                OldValue = reader.IsDBNull(6) ? null : reader.GetString(6),
                NewValue = reader.IsDBNull(7) ? null : reader.GetString(7),
                ActionType = reader.GetString(8),
                PerformedBy = reader.GetString(9),
                PerformedOn = reader.GetDateTime(10),
                ApprovalStatus = reader.IsDBNull(11) ? null : reader.GetString(11),
                Approver = reader.IsDBNull(12) ? null : reader.GetString(12),
                RejectionReason = reader.IsDBNull(13) ? null : reader.GetString(13)
            });
        }
        return result;
    }

    private async Task WriteAuditAsync(string master, int? recordId, int? globalPayerId, string? payerName,
        IReadOnlyList<(string Field, string? Old, string? New)> changes, string actionType, string performedBy,
        string? approvalStatus, string? approver, string? rejectionReason, CancellationToken ct)
    {
        if (changes.Count == 0) changes = [("(no field changes)", null, null)];
        await using var conn = Open();
        await conn.OpenAsync(ct);
        foreach (var (field, oldValue, newValue) in changes)
        {
            await using var cmd = new SqlCommand("""
                INSERT INTO dbo.PayerMasterAuditTrail
                    (Master, RecordId, GlobalPayerID, PayerName, FieldName, OldValue, NewValue, ActionType, PerformedBy, ApprovalStatus, Approver, RejectionReason)
                VALUES
                    (@Master, @RecordId, @GlobalPayerID, @PayerName, @FieldName, @OldValue, @NewValue, @ActionType, @PerformedBy, @ApprovalStatus, @Approver, @RejectionReason);
                """, conn);
            cmd.Parameters.AddWithValue("@Master", master);
            cmd.Parameters.AddWithValue("@RecordId", (object?)recordId ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@GlobalPayerID", (object?)globalPayerId ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@PayerName", (object?)payerName ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@FieldName", field);
            cmd.Parameters.AddWithValue("@OldValue", (object?)Truncate(oldValue, 1000) ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@NewValue", (object?)Truncate(newValue, 1000) ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@ActionType", actionType);
            cmd.Parameters.AddWithValue("@PerformedBy", performedBy);
            cmd.Parameters.AddWithValue("@ApprovalStatus", (object?)approvalStatus ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@Approver", (object?)approver ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@RejectionReason", (object?)rejectionReason ?? DBNull.Value);
            await cmd.ExecuteNonQueryAsync(ct);
        }
    }

    // ── Notifications (in-app + best-effort email) ───────────────────────────

    public async Task<IReadOnlyList<PayerMasterNotificationDto>> GetNotificationsAsync(IReadOnlyCollection<string> roles, string userName, int take, CancellationToken ct)
    {
        await EnsureSchemaAsync(ct);
        take = Math.Clamp(take <= 0 ? 50 : take, 1, 200);
        var effectiveRoles = ExpandRoles(roles);

        var items = new List<PayerMasterNotificationDto>();
        await using var conn = Open();
        await conn.OpenAsync(ct);

        var roleParams = effectiveRoles.Select((r, i) => new SqlParameter($"@Role{i}", r)).ToList();
        var roleList = roleParams.Count > 0 ? string.Join(", ", roleParams.Select(p => p.ParameterName)) : "NULL";
        await using var cmd = new SqlCommand($"""
            SELECT TOP (@Take) NotificationId, Master, TriggerType, Title, Message, RecipientRole, RecipientUser, CreatedOn
            FROM dbo.PayerMasterNotifications
            WHERE RecipientRole IN ({roleList}) OR RecipientUser = @User
            ORDER BY CreatedOn DESC, NotificationId DESC;
            """, conn);
        cmd.Parameters.AddWithValue("@Take", take);
        cmd.Parameters.AddWithValue("@User", userName);
        cmd.Parameters.AddRange(roleParams.ToArray());
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            items.Add(new PayerMasterNotificationDto
            {
                NotificationId = reader.GetInt32(0),
                Master = reader.GetString(1),
                TriggerType = reader.GetString(2),
                Title = reader.GetString(3),
                Message = reader.IsDBNull(4) ? null : reader.GetString(4),
                RecipientRole = reader.IsDBNull(5) ? null : reader.GetString(5),
                RecipientUser = reader.IsDBNull(6) ? null : reader.GetString(6),
                CreatedOn = reader.GetDateTime(7)
            });
        }
        return items;
    }

    private async Task NotifyAsync(string master, string triggerType, string title, string? message,
        IReadOnlyCollection<string> recipientRoles, string? recipientUser, CancellationToken ct)
    {
        await using (var conn = Open())
        {
            await conn.OpenAsync(ct);
            foreach (var role in recipientRoles.DefaultIfEmpty(null!))
            {
                if (role is null && recipientUser is null) continue;
                await using var cmd = new SqlCommand("""
                    INSERT INTO dbo.PayerMasterNotifications (Master, TriggerType, Title, Message, RecipientRole, RecipientUser)
                    VALUES (@Master, @TriggerType, @Title, @Message, @RecipientRole, @RecipientUser);
                    """, conn);
                cmd.Parameters.AddWithValue("@Master", master);
                cmd.Parameters.AddWithValue("@TriggerType", triggerType);
                cmd.Parameters.AddWithValue("@Title", Truncate(title, 300));
                cmd.Parameters.AddWithValue("@Message", (object?)Truncate(message, 1000) ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@RecipientRole", (object?)role ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@RecipientUser", (object?)(role is null ? recipientUser : null) ?? DBNull.Value);
                await cmd.ExecuteNonQueryAsync(ct);
            }
        }
        SendEmailsBestEffort(title, message, recipientRoles);
    }

    /// <summary>
    /// Email channel. Uses the shared SMTP settings (DenialWorkflowSupport section) plus a
    /// role-to-address map under PayerMaster:RoleEmails:&lt;role name&gt;. Failures are logged, never thrown.
    /// </summary>
    private void SendEmailsBestEffort(string title, string? message, IReadOnlyCollection<string> recipientRoles)
    {
        var options = _supportOptions.Value;
        if (!options.EnableSmtpEmail || string.IsNullOrWhiteSpace(options.SmtpHost) || string.IsNullOrWhiteSpace(options.SmtpFromEmail)) return;

        var recipients = recipientRoles
            .SelectMany(role => _configuration.GetSection($"PayerMaster:RoleEmails:{role}").Get<string[]>() ?? [])
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (recipients.Count == 0) return;

        _ = Task.Run(() =>
        {
            try
            {
                using var client = new SmtpClient(options.SmtpHost, options.SmtpPort) { EnableSsl = options.SmtpEnableSsl };
                if (!string.IsNullOrWhiteSpace(options.SmtpUserName))
                    client.Credentials = new System.Net.NetworkCredential(options.SmtpUserName, options.SmtpPassword);
                using var mail = new MailMessage { From = new MailAddress(options.SmtpFromEmail), Subject = $"[LRN Payer Master] {title}", Body = message ?? title };
                foreach (var to in recipients) mail.To.Add(to);
                client.Send(mail);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Payer Master notification email failed for '{Title}'.", title);
            }
        });
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private async Task<PayerMasterApprovalRequestDto?> GetApprovalRequestAsync(int id, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT ApprovalRequestId, Master, ActionType, TargetId, PayerName, PayloadJson, SubmittedBy, SubmittedOn,
                   Status, DecidedBy, DecidedOn, RejectionReason, EscalatedOn
            FROM dbo.PayerMasterApprovalRequests WHERE ApprovalRequestId = @Id;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? MapApproval(reader) : null;
    }

    private async Task MarkDecisionAsync(int id, bool approve, string approver, string? reason, CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            UPDATE dbo.PayerMasterApprovalRequests
            SET Status = @Status, DecidedBy = @DecidedBy, DecidedOn = SYSUTCDATETIME(), RejectionReason = @Reason
            WHERE ApprovalRequestId = @Id AND Status = 'Pending';
            """, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        cmd.Parameters.AddWithValue("@Status", approve ? "Approved" : "Rejected");
        cmd.Parameters.AddWithValue("@DecidedBy", approver);
        cmd.Parameters.AddWithValue("@Reason", (object?)reason ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private async Task<string?> BuildChangeSummaryAsync(PayerMasterApprovalRequestDto item, CancellationToken ct)
    {
        try
        {
            if (item.ActionType == "Deactivate") return "Is Active: Active → Inactive";
            if (string.IsNullOrWhiteSpace(item.PayloadJson)) return null;
            List<(string Field, string? Old, string? New)> changes;
            if (item.Master == PolicyMaster)
            {
                var dto = JsonSerializer.Deserialize<PayerPolicyInsuranceMasterDto>(item.PayloadJson, JsonOptions);
                if (dto is null) return null;
                var existing = item.TargetId.HasValue ? await _repository.GetPolicyPayerAsync(item.TargetId.Value, ct) : null;
                changes = Diff(existing is null ? null : PolicyFields(existing), PolicyFields(dto));
            }
            else
            {
                var dto = JsonSerializer.Deserialize<InsurancePayerMasterDto>(item.PayloadJson, JsonOptions);
                if (dto is null) return null;
                var existing = item.TargetId.HasValue ? await _repository.GetInsurancePayerAsync(item.TargetId.Value, ct) : null;
                changes = Diff(existing is null ? null : LabFields(existing), LabFields(dto));
            }
            var parts = changes.Take(5).Select(c => item.TargetId.HasValue
                ? $"{c.Field}: {c.Old ?? "—"} → {c.New ?? "—"}"
                : $"{c.Field}: {c.New ?? "—"}");
            var summary = (item.TargetId.HasValue ? "" : "New record — ") + string.Join(", ", parts);
            return changes.Count > 5 ? summary + $" (+{changes.Count - 5} more)" : summary;
        }
        catch
        {
            return null;
        }
    }

    private async Task<int> NextGlobalPayerIdAsync(CancellationToken ct)
    {
        await using var conn = Open();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("SELECT NEXT VALUE FOR dbo.PayerMasterGlobalPayerIdSeq;", conn);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
    }

    private static PayerMasterApprovalRequestDto MapApproval(SqlDataReader reader) => new()
    {
        ApprovalRequestId = reader.GetInt32(0),
        Master = reader.GetString(1),
        ActionType = reader.GetString(2),
        TargetId = reader.IsDBNull(3) ? null : reader.GetInt32(3),
        PayerName = reader.IsDBNull(4) ? null : reader.GetString(4),
        PayloadJson = reader.IsDBNull(5) ? null : reader.GetString(5),
        SubmittedBy = reader.GetString(6),
        SubmittedOn = reader.GetDateTime(7),
        Status = reader.GetString(8),
        DecidedBy = reader.IsDBNull(9) ? null : reader.GetString(9),
        DecidedOn = reader.IsDBNull(10) ? null : reader.GetDateTime(10),
        RejectionReason = reader.IsDBNull(11) ? null : reader.GetString(11),
        EscalatedOn = reader.IsDBNull(12) ? null : reader.GetDateTime(12)
    };

    private static Dictionary<string, string?> PolicyFields(PayerPolicyInsuranceMasterDto d) => new()
    {
        ["Payer Name"] = d.PayerNameRaw,
        ["Payer Name Normalized"] = d.PayerNameNormalized,
        ["Global Payer ID"] = d.GlobalPayerId?.ToString(),
        ["Global Payer Code"] = d.GlobalPayerCode,
        ["Payer Short Code"] = d.PayerShortCode,
        ["Payer Group Code"] = d.PayerGroupCode?.ToString(),
        ["Plan Type"] = d.PlanType,
        ["Payer State"] = d.PayerState,
        ["Is Active"] = d.IsActive,
        ["Benefit Manager"] = d.BenefitAdministrator,
        ["Benefit Manager Code"] = d.BenefitAdminCode,
        ["Remarks"] = d.Remarks
    };

    private static Dictionary<string, string?> LabFields(InsurancePayerMasterDto d) => new()
    {
        ["Payer Name (Raw)"] = d.PayerNameRaw,
        ["Payer Name Normalized"] = d.PayerNameNormalized,
        ["Global Payer ID"] = d.GlobalPayerID?.ToString(),
        ["Payer Common Code"] = d.PayerCommonCode,
        ["Payer Group Code"] = d.PayerGroupCode,
        ["Plan Type"] = d.PlanType,
        ["Payer State"] = d.PayerState,
        ["Is Active"] = d.IsActive,
        ["Lab Name"] = d.LabName,
        ["Lab State"] = d.LabState,
        ["Remarks"] = d.Remarks
    };

    private static List<(string Field, string? Old, string? New)> Diff(Dictionary<string, string?>? oldFields, Dictionary<string, string?> newFields)
    {
        var changes = new List<(string, string?, string?)>();
        foreach (var (field, newValue) in newFields)
        {
            var oldValue = oldFields is not null && oldFields.TryGetValue(field, out var v) ? v : null;
            if (oldFields is null)
            {
                if (!string.IsNullOrWhiteSpace(newValue)) changes.Add((field, null, newValue));
            }
            else if (!string.Equals(oldValue?.Trim() ?? "", newValue?.Trim() ?? "", StringComparison.Ordinal))
            {
                changes.Add((field, oldValue, newValue));
            }
        }
        return changes;
    }

    private static IReadOnlyList<string> ExpandRoles(IReadOnlyCollection<string> roles)
    {
        var set = new HashSet<string>(roles, StringComparer.OrdinalIgnoreCase);
        // "Admin" is the legacy full-access role and receives LRN Admin notifications.
        if (set.Contains("Admin") || set.Contains("LRNAdmin")) set.Add("LRN Admin");
        if (set.Contains("PayerPolicyAdmin")) set.Add("Payer Policy Admin");
        if (set.Contains("ReportsAnalyst")) set.Add("Reports Analyst");
        if (set.Contains("ReportsManager")) set.Add("Reports Manager");
        return set.ToList();
    }

    private static string MasterLabel(string master) => master == PolicyMaster ? "Payer Policy Insurance Master" : "Lab Insurance Master";
    private static string? Truncate(string? value, int max) => value is null || value.Length <= max ? value : value[..max];
    private SqlConnection Open() => new(_connectionString);

    private async Task EnsureSchemaAsync(CancellationToken ct)
    {
        if (_schemaReady) return;
        await SchemaLock.WaitAsync(ct);
        try
        {
            if (_schemaReady) return;
            await using var conn = Open();
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(SchemaSql, conn) { CommandTimeout = 120 };
            await cmd.ExecuteNonQueryAsync(ct);
            _schemaReady = true;
        }
        finally
        {
            SchemaLock.Release();
        }
    }

    // Mirrors Sql/PayerMaster_Workflow_Setup.sql so a missed deployment step cannot break the workflow.
    private const string SchemaSql = """
        IF OBJECT_ID('dbo.PayerMasterApprovalRequests', 'U') IS NULL
        BEGIN
            CREATE TABLE dbo.PayerMasterApprovalRequests
            (
                ApprovalRequestId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PayerMasterApprovalRequests PRIMARY KEY,
                Master            NVARCHAR(20)  NOT NULL,
                ActionType        NVARCHAR(20)  NOT NULL,
                TargetId          INT           NULL,
                PayerName         NVARCHAR(250) NULL,
                PayloadJson       NVARCHAR(MAX) NULL,
                SubmittedBy       NVARCHAR(100) NOT NULL,
                SubmittedOn       DATETIME2(0)  NOT NULL CONSTRAINT DF_PMApproval_SubmittedOn DEFAULT SYSUTCDATETIME(),
                Status            NVARCHAR(20)  NOT NULL CONSTRAINT DF_PMApproval_Status DEFAULT 'Pending',
                DecidedBy         NVARCHAR(100) NULL,
                DecidedOn         DATETIME2(0)  NULL,
                RejectionReason   NVARCHAR(1000) NULL,
                EscalatedOn       DATETIME2(0)  NULL
            );
            CREATE INDEX IX_PMApproval_Status_Master ON dbo.PayerMasterApprovalRequests (Status, Master) INCLUDE (SubmittedOn);
            CREATE INDEX IX_PMApproval_SubmittedBy ON dbo.PayerMasterApprovalRequests (SubmittedBy);
        END;

        IF OBJECT_ID('dbo.PayerMasterAuditTrail', 'U') IS NULL
        BEGIN
            CREATE TABLE dbo.PayerMasterAuditTrail
            (
                AuditId         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PayerMasterAuditTrail PRIMARY KEY,
                Master          NVARCHAR(20)  NOT NULL,
                RecordId        INT           NULL,
                GlobalPayerID   INT           NULL,
                PayerName       NVARCHAR(250) NULL,
                FieldName       NVARCHAR(100) NOT NULL,
                OldValue        NVARCHAR(1000) NULL,
                NewValue        NVARCHAR(1000) NULL,
                ActionType      NVARCHAR(20)  NOT NULL,
                PerformedBy     NVARCHAR(100) NOT NULL,
                PerformedOn     DATETIME2(0)  NOT NULL CONSTRAINT DF_PMAudit_PerformedOn DEFAULT SYSUTCDATETIME(),
                ApprovalStatus  NVARCHAR(30)  NULL,
                Approver        NVARCHAR(100) NULL,
                RejectionReason NVARCHAR(1000) NULL
            );
            CREATE INDEX IX_PMAudit_Master_PerformedOn ON dbo.PayerMasterAuditTrail (Master, PerformedOn DESC);
            CREATE INDEX IX_PMAudit_RecordId ON dbo.PayerMasterAuditTrail (Master, RecordId);
        END;

        IF OBJECT_ID('dbo.PayerMasterNotifications', 'U') IS NULL
        BEGIN
            CREATE TABLE dbo.PayerMasterNotifications
            (
                NotificationId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PayerMasterNotifications PRIMARY KEY,
                Master          NVARCHAR(20)  NOT NULL,
                TriggerType     NVARCHAR(40)  NOT NULL,
                Title           NVARCHAR(300) NOT NULL,
                Message         NVARCHAR(1000) NULL,
                RecipientRole   NVARCHAR(50)  NULL,
                RecipientUser   NVARCHAR(100) NULL,
                CreatedOn       DATETIME2(0)  NOT NULL CONSTRAINT DF_PMNotif_CreatedOn DEFAULT SYSUTCDATETIME()
            );
            CREATE INDEX IX_PMNotif_Role_CreatedOn ON dbo.PayerMasterNotifications (RecipientRole, CreatedOn DESC);
            CREATE INDEX IX_PMNotif_User_CreatedOn ON dbo.PayerMasterNotifications (RecipientUser, CreatedOn DESC);
        END;

        IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE name = 'PayerMasterGlobalPayerIdSeq' AND schema_id = SCHEMA_ID('dbo'))
        BEGIN
            DECLARE @MaxId INT = 1000;
            SELECT @MaxId = MAX(v) FROM (VALUES
                (ISNULL((SELECT MAX(TRY_CONVERT(INT, GlobalPayerId)) FROM dbo.PayerPolicyInsuranceMaster), 1000)),
                (ISNULL((SELECT MAX(GlobalPayerID) FROM dbo.LabInsuranceMaster), 1000)),
                (1000)) AS x(v);
            DECLARE @Sql NVARCHAR(400) =
                N'CREATE SEQUENCE dbo.PayerMasterGlobalPayerIdSeq AS INT START WITH ' + CAST(@MaxId + 1 AS NVARCHAR(20)) + N' INCREMENT BY 1 NO CYCLE;';
            EXEC sys.sp_executesql @Sql;
        END;
        """;
}

/// <summary>Hourly background check that escalates approval requests past the SLA window (Spec 5.2).</summary>
public sealed class PayerMasterSlaEscalationService : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<PayerMasterSlaEscalationService> _logger;

    public PayerMasterSlaEscalationService(IServiceScopeFactory scopeFactory, ILogger<PayerMasterSlaEscalationService> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromHours(1));
        try
        {
            do
            {
                try
                {
                    using var scope = _scopeFactory.CreateScope();
                    var escalated = await scope.ServiceProvider.GetRequiredService<IPayerMasterWorkflowService>()
                        .EscalateOverdueApprovalsAsync(stoppingToken);
                    if (escalated > 0)
                        _logger.LogInformation("Payer Master SLA escalation notified approvers for {Count} overdue request(s).", escalated);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    _logger.LogError(ex, "Payer Master SLA escalation sweep failed.");
                }
            }
            while (await timer.WaitForNextTickAsync(stoppingToken));
        }
        catch (OperationCanceledException)
        {
            // shutdown
        }
    }
}
