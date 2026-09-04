using LRN.ReportsApi.Models;
using LRN.ReportsApi.Security;
using LRN.ReportsApi.Services;
using Microsoft.AspNetCore.Mvc;

namespace LRN.ReportsApi.Controllers;

/// <summary>
/// Dynamic role-based menu management (Menu Master + Role Menu Mapping).
/// Navbar fetch is available to every authenticated user; management
/// endpoints are restricted to LRN Admin.
/// </summary>
[ApiController]
[Route("api/menu")]
public sealed class MenuController : ControllerBase
{
    private readonly IMenuRepository _repository;

    public MenuController(IMenuRepository repository)
    {
        _repository = repository;
    }

    private bool IsAdmin => PayerMasterRoles.IsLrnAdmin(User);
    private string UserName() => PayerMasterRoles.UserName(User);
    private ActionResult Denied() => StatusCode(StatusCodes.Status403Forbidden,
        new { message = "You do not have access to menu management." });

    /// <summary>Menus visible to the current user (union across all of the user's roles).</summary>
    [HttpGet("my")]
    public async Task<ActionResult<IReadOnlyList<MenuItemDto>>> MyMenus(CancellationToken ct)
        => Ok(await _repository.GetMenusForRolesAsync(PayerMasterRoles.RoleNames(User), ct));

    /// <summary>All controller/action routes managed by the menu master (for server-side enforcement).</summary>
    [HttpGet("routes")]
    public async Task<ActionResult<IReadOnlyList<MenuRouteDto>>> ManagedRoutes(CancellationToken ct)
        => Ok(await _repository.GetManagedRoutesAsync(ct));

    // ── Menu Master (admin) ────────────────────────────────────────────────

    [HttpGet("items")]
    public async Task<ActionResult<IReadOnlyList<MenuItemDto>>> Items(CancellationToken ct)
        => IsAdmin ? Ok(await _repository.GetAllMenuItemsAsync(ct)) : Denied();

    [HttpGet("items/{id:int}")]
    public async Task<ActionResult<MenuItemDto>> Item(int id, CancellationToken ct)
    {
        if (!IsAdmin) return Denied();
        var item = await _repository.GetMenuItemAsync(id, ct);
        return item is null ? NotFound(new { message = "Menu item was not found." }) : Ok(item);
    }

    [HttpPost("items")]
    public async Task<ActionResult> Create(MenuItemSaveRequest request, CancellationToken ct)
    {
        if (!IsAdmin) return Denied();
        try
        {
            var id = await _repository.CreateMenuItemAsync(request, UserName(), ct);
            return Ok(new { id, success = true });
        }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPut("items/{id:int}")]
    public async Task<ActionResult> Update(int id, MenuItemSaveRequest request, CancellationToken ct)
    {
        if (!IsAdmin) return Denied();
        try
        {
            var updated = await _repository.UpdateMenuItemAsync(id, request, UserName(), ct);
            return updated ? Ok(new { success = true }) : NotFound(new { message = "Menu item was not found." });
        }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    [HttpPatch("items/{id:int}/disabled")]
    public async Task<ActionResult> SetDisabled(int id, MenuDisabledRequest request, CancellationToken ct)
    {
        if (!IsAdmin) return Denied();
        var updated = await _repository.SetMenuItemDisabledAsync(id, request.IsDisabled, UserName(), ct);
        return updated ? Ok(new { success = true }) : NotFound(new { message = "Menu item was not found." });
    }

    [HttpDelete("items/{id:int}")]
    public async Task<ActionResult> Delete(int id, CancellationToken ct)
    {
        if (!IsAdmin) return Denied();
        try
        {
            var deleted = await _repository.SoftDeleteMenuItemAsync(id, UserName(), ct);
            return deleted ? Ok(new { success = true }) : NotFound(new { message = "Menu item was not found." });
        }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }

    // ── Role Menu Mapping (admin) ──────────────────────────────────────────

    [HttpGet("roles")]
    public async Task<ActionResult<IReadOnlyList<MenuRoleOptionDto>>> Roles(CancellationToken ct)
        => IsAdmin ? Ok(await _repository.GetRolesAsync(ct)) : Denied();

    [HttpGet("roles/{roleId:int}/menus")]
    public async Task<ActionResult<IReadOnlyList<int>>> RoleMenus(int roleId, CancellationToken ct)
        => IsAdmin ? Ok(await _repository.GetRoleMenuIdsAsync(roleId, ct)) : Denied();

    [HttpPut("roles/{roleId:int}/menus")]
    public async Task<ActionResult> SaveRoleMenus(int roleId, RoleMenuSaveRequest request, CancellationToken ct)
    {
        if (!IsAdmin) return Denied();
        await _repository.ReplaceRoleMenusAsync(roleId, request.MenuIds ?? new List<int>(), UserName(), ct);
        return Ok(new { success = true });
    }

    // ── Role feature access (header icon / help bubble, admin) ─────────────

    /// <summary>Explicit feature settings for the current user, resolved across their roles.</summary>
    [HttpGet("my/features")]
    public async Task<ActionResult<IReadOnlyList<RoleFeatureDto>>> MyFeatures(CancellationToken ct)
        => Ok(await _repository.GetFeaturesForRolesAsync(PayerMasterRoles.RoleNames(User), ct));

    /// <summary>The togglable features the Role Menu Mapping screen renders.</summary>
    [HttpGet("features")]
    public ActionResult<IReadOnlyList<MenuFeatureDto>> Features()
        => IsAdmin ? Ok(MenuFeatureCatalog.All) : Denied();

    [HttpGet("roles/{roleId:int}/features")]
    public async Task<ActionResult<IReadOnlyList<RoleFeatureDto>>> RoleFeatures(int roleId, CancellationToken ct)
        => IsAdmin ? Ok(await _repository.GetRoleFeaturesAsync(roleId, ct)) : Denied();

    [HttpPut("roles/{roleId:int}/features")]
    public async Task<ActionResult> SaveRoleFeatures(int roleId, RoleFeatureSaveRequest request, CancellationToken ct)
    {
        if (!IsAdmin) return Denied();
        try
        {
            await _repository.ReplaceRoleFeaturesAsync(roleId, request.Features ?? new List<RoleFeatureDto>(), UserName(), ct);
            return Ok(new { success = true });
        }
        catch (ArgumentException ex) { return BadRequest(new { message = ex.Message }); }
    }
}
