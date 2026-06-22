using System.Security.Claims;
using System.Text;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

[ApiController]
[Route("api/denialworkflow/denial-mapper")]
[Route("api/denial-workflow/denial-mapper")]
public sealed class DenialMapperController(IDenialMapperRepository repository, IDenialWorkflowService workflowService) : ControllerBase
{
    [HttpGet("dashboard")]
    public async Task<ActionResult<DenialMapperDashboard>> Dashboard([FromQuery] int? labId, CancellationToken ct)
    {
        if (!CanView()) return Denied();
        var effective=await AuthorizedLab(labId,ct); if(!IsAdmin()&&effective is null)return Denied();
        return Ok(await repository.DashboardAsync(IsAdmin() ? labId : effective, ct));
    }

    [HttpGet("super-master")]
    public async Task<ActionResult<PagedResult<DenialMapperRecord>>> SuperMaster([FromQuery] string? search, [FromQuery] string? classification, [FromQuery] int page=1, [FromQuery] int pageSize=25, CancellationToken ct=default)
    {
        if (!IsPushManager() && !IsViewer()) return Denied();
        return Ok(await repository.SuperMasterAsync(search, classification, page, pageSize, ct));
    }

    [HttpPost("super-master")]
    public async Task<ActionResult> Add(DenialMapperSaveRequest request, CancellationToken ct)
    {
        if (!IsAdmin()) return Denied(); var validation=Validate(request); if(validation is not null)return BadRequest(new{message=validation});
        var id=await repository.SaveSuperMasterAsync(null,request,UserName(),Role(),ct);return Ok(new{id,message="Super Master mapping added."});
    }

    [HttpPut("super-master/{id:long}")]
    public async Task<ActionResult> Update(long id, DenialMapperSaveRequest request, CancellationToken ct)
    {
        if (!IsAdmin()) return Denied(); var validation=Validate(request); if(validation is not null)return BadRequest(new{message=validation});
        await repository.SaveSuperMasterAsync(id,request,UserName(),Role(),ct);return Ok(new{message="Super Master mapping updated."});
    }

    [HttpDelete("super-master/{id:long}")]
    public async Task<ActionResult> Delete(long id,CancellationToken ct){if(!IsAdmin())return Denied();await repository.DeleteSuperMasterAsync(id,UserName(),Role(),ct);return Ok(new{message="Super Master mapping deleted."});}

    [HttpGet("labs")]
    public async Task<ActionResult> Labs(CancellationToken ct){if(!IsPushManager())return Denied();return Ok(await repository.LabsAsync(ct));}

    [HttpPost("compare-push")]
    public async Task<ActionResult<DenialMapperPushCompareResult>> ComparePush(DenialMapperPushRequest request,CancellationToken ct)
    {if(!IsPushManager())return Denied();return Ok(await repository.ComparePushAsync(request.LabIds,UserName(),ct));}

    [HttpPost("confirm-push")]
    public async Task<ActionResult> ConfirmPush(DenialMapperPushDecisionRequest request,CancellationToken ct)
    {if(!IsPushManager())return Denied();var count=await repository.ConfirmPushAsync(request.PushAuditIds,UserName(),Role(),ct);return Ok(new{labCount=count,message=$"Super Master pushed to {count} lab(s). Existing overrides were preserved."});}

    [HttpPost("cancel-push")]
    public async Task<ActionResult> CancelPush(DenialMapperPushDecisionRequest request,CancellationToken ct)
    {if(!IsPushManager())return Denied();await repository.CancelPushAsync(request.PushAuditIds,UserName(),ct);return Ok(new{message="Mapper push cancelled."});}

    [HttpGet("push-verification/{pushAuditId:long}")]
    public async Task<ActionResult> PushVerification(long pushAuditId,CancellationToken ct)
    {if(!IsPushManager())return Denied();var audit=await repository.PushAuditAsync(pushAuditId,ct);if(audit is null)return NotFound(new{message="Mapper push audit was not found."});var lab=await AuthorizedLab(audit.TargetLabId,ct);if(!IsAdmin()&&lab!=audit.TargetLabId)return Denied();return Ok(audit);}

    [HttpGet("push-verification/{pushAuditId:long}/export")]
    public async Task<ActionResult> ExportPushVerification(long pushAuditId,CancellationToken ct)
    {
        if(!IsPushManager())return Denied();var audit=await repository.PushAuditAsync(pushAuditId,ct);if(audit is null)return NotFound();var lab=await AuthorizedLab(audit.TargetLabId,ct);if(!IsAdmin()&&lab!=audit.TargetLabId)return Denied();
        static string Csv(string? value)=>$"\"{(value??string.Empty).Replace("\"","\"\"")}\"";
        var csv=new StringBuilder("Target Lab,Denial Code,ICD Compliance Status,Coverage Status,Existing Action Code,New Action Code,Existing Action Category,New Action Category,Existing Task,New Task,Existing Short Category,New Short Category,Difference Type,Open Assigned Task Count\r\n");
        foreach(var d in audit.Differences)csv.AppendLine(string.Join(',',Csv(d.TargetLabName),Csv(d.DenialCode),Csv(d.ICDComplianceStatus),Csv(d.CoverageStatus),Csv(d.ExistingActionCode),Csv(d.NewActionCode),Csv(d.ExistingActionCategory),Csv(d.NewActionCategory),Csv(d.ExistingTask),Csv(d.NewTask),Csv(d.ExistingShortCategory),Csv(d.NewShortCategory),Csv(d.DifferenceType),d.OpenAssignedTaskCount));
        return File(Encoding.UTF8.GetBytes(csv.ToString()),"text/csv",$"DenialMapperPush_{pushAuditId}_Differences.csv");
    }

    [HttpGet("notifications")]
    public async Task<ActionResult> Notifications([FromQuery]int labId,CancellationToken ct)
    {if(!IsArManager())return Denied();var effective=await AuthorizedLab(labId,ct);if(effective is null)return Denied();return Ok(await repository.PendingNotificationsAsync(effective.Value,UserName(),ct));}

    [HttpPost("notifications/{pushAuditId:long}/acknowledge")]
    public async Task<ActionResult> Acknowledge(long pushAuditId,[FromQuery]int labId,CancellationToken ct)
    {if(!IsArManager())return Denied();var effective=await AuthorizedLab(labId,ct);if(effective is null)return Denied();await repository.AcknowledgeNotificationAsync(pushAuditId,effective.Value,UserName(),ct);return Ok(new{message="Mapper update acknowledged."});}

    [HttpGet("lab-master")]
    public async Task<ActionResult> LabMaster([FromQuery]int labId,[FromQuery]string? search,[FromQuery]string? classification,[FromQuery]int page=1,[FromQuery]int pageSize=25,CancellationToken ct=default){if(!CanView())return Denied();var effective=await AuthorizedLab(labId,ct);if(effective is null)return Denied();return Ok(await repository.LabMasterAsync(effective.Value,search,classification,page,pageSize,ct));}

    [HttpPut("lab-master/{superMasterId:long}/override")]
    public async Task<ActionResult> Override(long superMasterId,[FromQuery]int labId,DenialMapperOverrideRequest request,CancellationToken ct){if(!CanOverride())return Denied();var effective=await AuthorizedLab(labId,ct);if(effective is null)return Denied();var error=Validate(request);if(error is not null)return BadRequest(new{message=error});await repository.SaveOverrideAsync(effective.Value,superMasterId,request,UserName(),Role(),ct);return Ok(new{message="Lab override saved. Super Master remains unchanged."});}

    [HttpDelete("lab-master/{superMasterId:long}/override")]
    public async Task<ActionResult> RemoveOverride(long superMasterId,[FromQuery]int labId,CancellationToken ct){if(!CanOverride())return Denied();var effective=await AuthorizedLab(labId,ct);if(effective is null)return Denied();await repository.RemoveOverrideAsync(effective.Value,superMasterId,UserName(),Role(),ct);return Ok(new{message="Lab override removed."});}

    [HttpGet("audit")]
    public async Task<ActionResult> Audit([FromQuery]int? labId,[FromQuery]int take=100,CancellationToken ct=default){if(!IsAdmin()&&!IsManager())return Denied();var effective=await AuthorizedLab(labId,ct);if(!IsAdmin()&&effective is null)return Denied();return Ok(await repository.AuditAsync(IsAdmin()?labId:effective,take,ct));}

    [HttpGet("classifications")]
    public async Task<ActionResult> Classifications([FromQuery]int? labId,CancellationToken ct){if(!CanView())return Denied();if(labId.HasValue){var effective=await AuthorizedLab(labId,ct);if(effective is null)return Denied();return Ok(await repository.ClassificationsAsync(effective,ct));}if(!IsAdmin()&&!IsViewer())return Denied();return Ok(await repository.ClassificationsAsync(null,ct));}

    [HttpPost("upload")]
    [RequestSizeLimit(100_000_000)]
    public async Task<ActionResult<DenialCodeMasterImportResult>> Upload([FromForm] DenialCodeMasterImportRequest request,CancellationToken ct){if(!IsAdmin())return Denied();if(request.File is null||request.File.Length==0)return BadRequest(new{message="Select a mapper Excel file."});await using var stream=request.File.OpenReadStream();return Ok(await repository.ImportSuperMasterAsync(stream,request.File.FileName,UserName(),Role(),ct));}

    private async Task<int?> AuthorizedLab(int? requested, CancellationToken ct)
    {
        if(IsAdmin())return requested;
        var claim=First("labId","LabId","lab_id");
        if(int.TryParse(claim,out var id)&&id>0)return !requested.HasValue||requested==id?id:null;
        var labs=await workflowService.GetLabsForUserAsync(UserName(),ct);
        var allowed=labs.Select(x=>x.LabId).ToHashSet();
        if(requested is >0&&allowed.Contains(requested.Value))return requested;
        return !requested.HasValue&&allowed.Count==1?allowed.First():null;
    }
    private bool IsAdmin()=>TokenRole().Contains("ADMIN");
    private bool IsArManager()=>TokenRole().Contains("ARMANAGER");
    private bool IsPushManager()=>IsAdmin()||IsArManager();
    private bool IsManager()=>TokenRole().Contains("CLIENTMANAGER")||TokenRole().Contains("ACCOUNTMANAGER");
    private bool IsViewer()=>TokenRole().Contains("VIEWER")||TokenRole().Contains("READONLY");
    private bool CanView()=>IsAdmin()||IsManager()||IsViewer()||TokenRole().Contains("LABUSER");
    private bool CanOverride()=>IsManager();
    private string TokenRole()=>new(Role().Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
    private string Role()=>First(ClaimTypes.Role,"role","roles")??"";
    private string UserName()=>First(ClaimTypes.Name,"name","preferred_username","unique_name","upn")??"ReactWorkflow";
    private string? First(params string[] names){foreach(var n in names){var v=User.Claims.FirstOrDefault(c=>string.Equals(c.Type,n,StringComparison.OrdinalIgnoreCase))?.Value;if(!string.IsNullOrWhiteSpace(v))return v;}return null;}
    private ActionResult Denied()=>StatusCode(StatusCodes.Status403Forbidden,new{message="You do not have permission to use this Denial Mapper action."});
    private static string? Validate(DenialMapperSaveRequest q)=>Required(q.DenialCode,q.ActionCode,q.ActionCategory,q.Task,q.RecommendedAction,q.SLA,q.Priority);
    private static string? Validate(DenialMapperOverrideRequest q)=>Required(q.ActionCode,q.ActionCategory,q.Task,q.RecommendedAction);
    private static string? Required(params string?[] values)=>values.Any(string.IsNullOrWhiteSpace)?"Complete all required fields.":null;
}
