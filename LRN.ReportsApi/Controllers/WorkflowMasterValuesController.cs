using LRN.ReportsApi.Models;
using LRN.ReportsApi.Security;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// Admin maintenance for the seven Denial Workflow master lists — Classification, Coverage Status,
/// ICD Compliance, Denial Validity, Action Category, SLA and Priority.
///
/// Under /api/denialworkflow on purpose: that prefix is where the JWT middleware in Program.cs
/// authenticates the React app's calls (and it is the React client's base URL). /api/master-values
/// was not an option — it already belongs to the payer and insurance master API.
///
/// Every action is admin-only, reads included. The strict <see cref="PayerMasterRoles.IsLrnAdmin"/>
/// check is used rather than the Denial Mapper's Contains("ADMIN"), which also matches roles such as
/// "Payer Policy Admin" and would hand them control of the denial workflow's master data.
/// </summary>
[ApiController]
[Route("api/denialworkflow/workflow-masters")]
[Route("api/denial-workflow/workflow-masters")]
public sealed class WorkflowMasterValuesController(IWorkflowMasterValuesRepository repository) : ControllerBase
{
    [HttpGet]
    public async Task<ActionResult<WorkflowMasterValuesResponse>> Get(CancellationToken ct)
    {
        if (!PayerMasterRoles.IsLrnAdmin(User)) return Denied();
        return Ok(await repository.GetAllAsync(ct));
    }

    [HttpPost("{type}")]
    public async Task<ActionResult> Add(string type, WorkflowMasterValueSaveRequest request, CancellationToken ct)
    {
        if (!PayerMasterRoles.IsLrnAdmin(User)) return Denied();
        var master = WorkflowMasterValueRules.Find(type);
        if (master is null) return UnknownType(type);

        var validation = WorkflowMasterValueRules.Validate(master, request);
        if (validation.Error is not null) return BadRequest(new { message = validation.Error });

        return ToResult(await repository.AddAsync(master, validation.Result!, UserName(), RoleText(), ct));
    }

    [HttpPut("{type}")]
    public async Task<ActionResult> Update(string type, WorkflowMasterValueSaveRequest request, CancellationToken ct)
    {
        if (!PayerMasterRoles.IsLrnAdmin(User)) return Denied();
        var master = WorkflowMasterValueRules.Find(type);
        if (master is null) return UnknownType(type);

        // The original value travels in the body, not the route: values such as
        // "Client Info Pending / Write Off" contain slashes.
        if (string.IsNullOrWhiteSpace(request?.OriginalValue))
            return BadRequest(new { message = "The value being edited was not supplied. Reload the page and try again." });

        var validation = WorkflowMasterValueRules.Validate(master, request);
        if (validation.Error is not null) return BadRequest(new { message = validation.Error });

        return ToResult(await repository.UpdateAsync(master, request.OriginalValue, validation.Result!, UserName(), RoleText(), ct));
    }

    [HttpDelete("{type}")]
    public async Task<ActionResult> Delete(string type, [FromQuery] string? value, CancellationToken ct)
    {
        if (!PayerMasterRoles.IsLrnAdmin(User)) return Denied();
        var master = WorkflowMasterValueRules.Find(type);
        if (master is null) return UnknownType(type);
        if (string.IsNullOrWhiteSpace(value)) return BadRequest(new { message = "No value was specified to delete." });

        return ToResult(await repository.DeleteAsync(master, value, UserName(), RoleText(), ct));
    }

    private ActionResult ToResult(WorkflowMasterSaveResult result) => result.Status switch
    {
        WorkflowMasterSaveStatus.Ok => Ok(new { message = result.Message }),
        WorkflowMasterSaveStatus.NotFound => NotFound(new { message = result.Message }),
        _ => Conflict(new { message = result.Message })
    };

    private string UserName() => PayerMasterRoles.UserName(User);
    private string RoleText() => string.Join(", ", PayerMasterRoles.RoleNames(User));

    private ActionResult UnknownType(string type) =>
        NotFound(new { message = $"\"{type}\" is not a workflow master list." });

    private ActionResult Denied() =>
        StatusCode(StatusCodes.Status403Forbidden, new { message = "Only administrators can manage workflow master values." });
}
