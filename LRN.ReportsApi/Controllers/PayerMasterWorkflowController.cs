using LRN.ReportsApi.Models;
using LRN.ReportsApi.Security;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// Payer Master approval queue, audit trail, and notifications
/// (Requirements Spec §3.2, §4.3, §6, §7.2).
/// </summary>
[ApiController]
[Route("api/master-values/workflow")]
public sealed class PayerMasterWorkflowController : ControllerBase
{
    private readonly IPayerMasterWorkflowService _workflow;

    public PayerMasterWorkflowController(IPayerMasterWorkflowService workflow)
    {
        _workflow = workflow;
    }

    private IReadOnlyCollection<string> ApproverMasters()
    {
        var masters = new List<string>();
        if (PayerMasterRoles.CanApprovePolicy(User)) masters.Add("Policy");
        if (PayerMasterRoles.CanApproveLab(User)) masters.Add("Lab");
        return masters;
    }

    private bool HasAnyMasterAccess => PayerMasterRoles.CanViewPolicy(User) || PayerMasterRoles.CanViewLab(User);

    [HttpGet("approvals")]
    public async Task<ActionResult<PagedResult<PayerMasterApprovalRequestDto>>> Approvals([FromQuery] PayerMasterApprovalQuery query, CancellationToken ct)
    {
        var approverMasters = ApproverMasters();
        if (approverMasters.Count == 0)
        {
            // Non-approvers (Reports Analyst) may only see their own submissions.
            if (!PayerMasterRoles.IsReportsAnalyst(User)) return Denied();
            query.SubmittedBy = PayerMasterRoles.UserName(User);
        }
        else if (!string.IsNullOrWhiteSpace(query.Master) && !approverMasters.Contains(query.Master.Trim()))
        {
            return Denied();
        }
        else if (string.IsNullOrWhiteSpace(query.Master) && approverMasters.Count == 1)
        {
            query.Master = approverMasters.First();
        }

        return Ok(await _workflow.GetApprovalsAsync(query, ct));
    }

    [HttpPost("approvals/approve")]
    public async Task<ActionResult<PayerMasterApprovalDecisionResult>> Approve(PayerMasterApprovalDecisionRequest request, CancellationToken ct)
    {
        var approverMasters = ApproverMasters();
        if (approverMasters.Count == 0) return Denied();
        if (request.Ids.Count == 0) return BadRequest(new { message = "Select at least one pending request." });
        return Ok(await _workflow.DecideAsync(request, approve: true, PayerMasterRoles.UserName(User), approverMasters, ct));
    }

    [HttpPost("approvals/reject")]
    public async Task<ActionResult<PayerMasterApprovalDecisionResult>> Reject(PayerMasterApprovalDecisionRequest request, CancellationToken ct)
    {
        var approverMasters = ApproverMasters();
        if (approverMasters.Count == 0) return Denied();
        if (request.Ids.Count == 0) return BadRequest(new { message = "Select at least one pending request." });
        if (string.IsNullOrWhiteSpace(request.Reason)) return BadRequest(new { message = "A rejection reason is required." });
        return Ok(await _workflow.DecideAsync(request, approve: false, PayerMasterRoles.UserName(User), approverMasters, ct));
    }

    [HttpGet("audit")]
    public async Task<ActionResult<PagedResult<PayerMasterAuditEntryDto>>> Audit([FromQuery] PayerMasterAuditQuery query, CancellationToken ct)
    {
        if (!HasAnyMasterAccess) return Denied();
        // Restrict to masters the caller can view (audit is view-only for all roles with access, incl. ETL).
        if (string.IsNullOrWhiteSpace(query.Master))
        {
            if (!PayerMasterRoles.CanViewPolicy(User)) query.Master = "Lab";
            else if (!PayerMasterRoles.CanViewLab(User)) query.Master = "Policy";
        }
        else
        {
            var m = query.Master.Trim();
            if (m == "Policy" && !PayerMasterRoles.CanViewPolicy(User)) return Denied();
            if (m == "Lab" && !PayerMasterRoles.CanViewLab(User)) return Denied();
        }
        return Ok(await _workflow.GetAuditAsync(query, ct));
    }

    [HttpGet("notifications")]
    public async Task<ActionResult<IReadOnlyList<PayerMasterNotificationDto>>> Notifications([FromQuery] int take, CancellationToken ct)
    {
        if (!HasAnyMasterAccess) return Denied();
        return Ok(await _workflow.GetNotificationsAsync(PayerMasterRoles.RoleNames(User), PayerMasterRoles.UserName(User), take, ct));
    }

    private ActionResult Denied() => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. Your role does not permit this Payer Master workflow action." });
}
