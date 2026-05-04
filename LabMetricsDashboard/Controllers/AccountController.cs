using System.Security.Claims;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

[AllowAnonymous]
public class AccountController : Controller
{
    private readonly IUserManagementRepository _repo;
    private readonly IPasswordHasher _hasher;
    private readonly LabConfigOptions _labConfig;
    private readonly LabSettings _labSettings;
    private readonly ILogger<AccountController> _logger;

    public AccountController(
        IUserManagementRepository repo,
        IPasswordHasher hasher,
        LabConfigOptions labConfig,
        LabSettings labSettings,
        ILogger<AccountController> logger)
    {
        _repo = repo;
        _hasher = hasher;
        _labConfig = labConfig;
        _labSettings = labSettings;
        _logger = logger;
    }

    [HttpGet]
    public IActionResult Login(string? returnUrl = null)
    {
        ViewData["ReturnUrl"] = returnUrl;
        return View(new LoginViewModel());
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Login(LoginViewModel model, string? returnUrl = null)
    {
        ViewData["ReturnUrl"] = returnUrl;
        if (!ModelState.IsValid) return View(model);

        var user = await _repo.GetUserByUserNameAsync(model.UserName);
        if (user == null || !user.IsActive)
        {
            ModelState.AddModelError(string.Empty, "Invalid username or password.");
            return View(model);
        }

        if (string.IsNullOrEmpty(user.PasswordHash) || !_hasher.Verify(user.PasswordHash, model.Password))
        {
            ModelState.AddModelError(string.Empty, "Invalid username or password.");
            return View(model);
        }

        // Resolve roles + labs for the user
        var rolesForUser = await _repo.GetUserRolesAsync(user.LabUserID);
        var allRoles     = (await _repo.GetAllRolesAsync()).ToDictionary(r => r.RoleID, r => r.RoleName);
        var roleNames = rolesForUser
            .Select(r => allRoles.TryGetValue(r.RoleID, out var n) ? n : string.Empty)
            .Where(n => !string.IsNullOrWhiteSpace(n))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        var userLabs = (await _repo.GetUserLabsAsync(user.LabUserID)).ToList();

        // IMPORTANT:
        // For login redirects and lab claims, rely on LabConfig:LabsID mapping from appsettings.json.
        // This makes the behavior consistent across environments even if dbo.Labs entries differ.
        var mappedLabs = userLabs
            .Select(ul => new { ul.ULID, ul.LabId, Name = _labConfig.GetLabNameById(ul.LabId) })
            .Where(x => !string.IsNullOrWhiteSpace(x.Name))
            // If the user has multiple labs, keep them unique by LabId but preserve the
            // "most recently assigned" ordering. We treat the newest UserLabs row as the
            // most recent assignment (highest ULID).
            .OrderByDescending(x => x.ULID)
            .DistinctBy(x => x.LabId)
            .ToList();

        var unmappedLabIds = userLabs
            .Select(ul => ul.LabId)
            .Where(id => string.IsNullOrWhiteSpace(_labConfig.GetLabNameById(id)))
            .Distinct()
            .ToList();

        if (unmappedLabIds.Count > 0)
        {
            _logger.LogWarning(
                "User {UserName} has UserLabs assignments with LabId(s) not found in LabConfig:LabsID: [{LabIds}]",
                user.UserName, string.Join(",", unmappedLabIds));
        }

        // For downstream UI lab selector, it still uses LabSettings.Labs keys.
        // We log if mapped labs are missing per-lab JSON config so deployment can be fixed.
        var mappedButMissingJson = mappedLabs.Where(x => !_labSettings.Labs.ContainsKey(x.Name!)).ToList();
        if (mappedButMissingJson.Count > 0)
        {
            _logger.LogWarning(
                "User {UserName} mapped labs [{Labs}] are not present in LabSettings.Labs (missing per-lab JSON / LabConfig:Labs).",
                user.UserName, string.Join(",", mappedButMissingJson.Select(l => $"{l.LabId}:{l.Name}")));
        }

        var isAdmin = roleNames.Any(r => string.Equals(r, "Admin", StringComparison.OrdinalIgnoreCase));

        // Build claims
        var claims = new List<Claim>
        {
            new(ClaimTypes.NameIdentifier, user.LabUserID.ToString()),
            new(ClaimTypes.Name,           user.UserName),
            new("FullName",                $"{user.FirstName} {user.LastName}".Trim()),
        };
        foreach (var rn in roleNames)
        {
            claims.Add(new Claim(ClaimTypes.Role, rn));
        }
        foreach (var lab in mappedLabs)
        {
            claims.Add(new Claim("LabName", lab.Name!));
        }

        var identity  = new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme);
        var principal = new ClaimsPrincipal(identity);
        await HttpContext.SignInAsync(
            CookieAuthenticationDefaults.AuthenticationScheme,
            principal,
            new AuthenticationProperties
            {
                IsPersistent = model.RememberMe,
                ExpiresUtc   = DateTimeOffset.UtcNow.AddHours(model.RememberMe ? 24 * 14 : 8)
            });

        // Honor ?returnUrl=... if it's local
        if (!string.IsNullOrEmpty(returnUrl) && Url.IsLocalUrl(returnUrl))
        {
            return Redirect(returnUrl);
        }

        // Routing rules
        // 1) Admin ? home page (full landing with lab tiles)
        if (isAdmin)
        {
            return RedirectToAction("Index", "Home");
        }

        // 2) Non-admin with no lab assignments at all ? friendly error
        if (userLabs.Count == 0)
        {
            TempData["LoginError"] =
                "Your account has no lab assignments. Please contact your administrator.";
            await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            return RedirectToAction(nameof(Login));
        }

        // 2b) Non-admin has lab assignments, but the environment doesn't have LabConfig:LabsID mapping.
        //     In this case we cannot resolve which lab name to route to.
        if (mappedLabs.Count == 0)
        {
            TempData["LoginError"] =
                "Your assigned lab(s) are not mapped in this environment. Please contact your administrator.";
            await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            return RedirectToAction(nameof(Login));
        }

        // 3) Non-admin (1 or many labs) ? Revenue Dashboard.
        //    Default to the first mapped lab from LabConfig:LabsID and persist it
        //    via cookie so the navbar lab selector reflects the choice.
        var defaultLabName = mappedLabs[0].Name!;
        Response.Cookies.Append("lmd_selected_lab", defaultLabName, new CookieOptions
        {
            Expires     = DateTimeOffset.UtcNow.AddDays(30),
            HttpOnly    = false,
            SameSite    = SameSiteMode.Lax,
            IsEssential = true
        });
        return RedirectToAction("Index", "Dashboard", new { lab = defaultLabName });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Logout()
    {
        await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        return RedirectToAction(nameof(Login));
    }

    [HttpGet]
    public IActionResult AccessDenied() => View();
}

public sealed class LoginViewModel
{
    [System.ComponentModel.DataAnnotations.Required]
    public string UserName { get; set; } = string.Empty;

    [System.ComponentModel.DataAnnotations.Required]
    [System.ComponentModel.DataAnnotations.DataType(System.ComponentModel.DataAnnotations.DataType.Password)]
    public string Password { get; set; } = string.Empty;

    public bool RememberMe { get; set; }
}
