using System.Text.Json;
using LRN.ReportsApi.Security;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// Admin CRUD for the payer-mapper rule tables. Writes are restricted to LRN Admin /
/// Payer Policy Admin (rule edits change matching behavior globally, so no analyst
/// approval flow applies); policy-view roles may read.
/// </summary>
[ApiController]
[Route("api/master-values/payer-rules")]
public sealed class PayerRulesAdminController : ControllerBase
{
    private readonly IPayerRulesAdminService _service;

    public PayerRulesAdminController(IPayerRulesAdminService service) => _service = service;

    private bool CanView => PayerMasterRoles.CanViewPolicy(User) || PayerMasterRoles.CanViewLab(User);
    private bool CanWrite => PayerMasterRoles.IsLrnAdmin(User) || PayerMasterRoles.IsPayerPolicyAdmin(User);
    private string UserName() => PayerMasterRoles.UserName(User);

    [HttpGet("tables")]
    public ActionResult<IReadOnlyList<RuleTableMetadata>> Tables()
        => CanView ? Ok(_service.GetTables()) : Denied();

    [HttpGet("{table}")]
    public async Task<ActionResult> List([FromRoute] string table, CancellationToken ct)
    {
        if (!CanView) return Denied();
        try { return Ok(await _service.ListAsync(table, ct)); }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPost("{table}")]
    public async Task<ActionResult> Create([FromRoute] string table, [FromBody] Dictionary<string, JsonElement> values, CancellationToken ct)
    {
        if (!CanWrite) return Denied();
        try
        {
            var (id, rebuilt) = await _service.CreateAsync(table, values ?? new(), UserName(), ct);
            return Ok(new { id, indexRebuilt = rebuilt });
        }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPut("{table}/{id}")]
    public async Task<ActionResult> Update([FromRoute] string table, [FromRoute] string id, [FromBody] Dictionary<string, JsonElement> values, CancellationToken ct)
    {
        if (!CanWrite) return Denied();
        try
        {
            return await _service.UpdateAsync(table, id, values ?? new(), UserName(), ct)
                ? Ok(new { success = true })
                : NotFound(new { message = "The rule record was not found." });
        }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    public sealed class RuleStatusRequest { public bool IsActive { get; set; } }

    [HttpPatch("{table}/{id}/status")]
    public async Task<ActionResult> Status([FromRoute] string table, [FromRoute] string id, [FromBody] RuleStatusRequest request, CancellationToken ct)
    {
        if (!CanWrite) return Denied();
        try
        {
            return await _service.SetActiveAsync(table, id, request?.IsActive ?? false, UserName(), ct)
                ? Ok(new { success = true })
                : NotFound(new { message = "The rule record was not found." });
        }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPost("rebuild-index")]
    public async Task<ActionResult> RebuildIndex(CancellationToken ct)
    {
        if (!CanWrite) return Denied();
        var rebuilt = await _service.RebuildIndexAsync(ct);
        return Ok(new { indexRebuilt = rebuilt });
    }

    private ActionResult Denied() => StatusCode(StatusCodes.Status403Forbidden, new { message = "Access denied. Your role does not permit this action on the Payer Mapping Rules." });
}
