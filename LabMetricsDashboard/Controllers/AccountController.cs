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

        var userLabs   = (await _repo.GetUserLabsAsync(user.LabUserID)).ToList();
        var labIdNames = userLabs
            .Select(ul =>
            {
                // Lab name resolution priority:
                //  1) joined dbo.Labs.LabName from GetUserLabsAsync
                //  2) LabConfig:LabsID mapping in appsettings.json (legacy)
                var name = !string.IsNullOrWhiteSpace(ul.LabName)
                    ? ul.LabName
                    : _labConfig.GetLabNameById(ul.LabId);
                return new { ul.LabId, Name = name };
            })
            .Where(x => !string.IsNullOrWhiteSpace(x.Name))
            .ToList();

        // Lab assignments that don't have a matching per-lab JSON file in
        // LabSettings.Labs are still allowed (the user can log in), but we
        // log them so admins can fix the configuration.
        var assignedLabsKnownToConfig = labIdNames
            .Where(x => _labSettings.Labs.ContainsKey(x.Name!))
            .ToList();

        if (labIdNames.Count > 0 && assignedLabsKnownToConfig.Count == 0)
        {
            _logger.LogWarning(
                "User {UserName} has lab assignments [{Ids}] but none of them match a configured lab in LabSettings.Labs. Check LabConfig:Labs in appsettings.json and the per-lab JSON files.",
                user.UserName, string.Join(",", labIdNames.Select(l => $"{l.LabId}:{l.Name}")));
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
        foreach (var lab in labIdNames)
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
        if (labIdNames.Count == 0)
        {
            TempData["LoginError"] =
                "Your account has no lab assignments. Please contact your administrator.";
            await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            return RedirectToAction(nameof(Login));
        }

        // 2b) Non-admin has lab assignments but none match the application's
        //     configured labs (LabSettings.Labs). This usually means the
        //     dbo.Labs entry is missing or the per-lab JSON file isn't deployed.
        if (assignedLabsKnownToConfig.Count == 0)
        {
            TempData["LoginError"] =
                "Your assigned lab(s) are not configured in this environment. " +
                "Please contact your administrator.";
            await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            return RedirectToAction(nameof(Login));
        }

        // 3) Non-admin (1 or many labs) ? Revenue Dashboard.
        //    Default to the first assigned lab that is known to the config and
        //    persist it via cookie so the navbar lab selector reflects the choice.
        var defaultLabName = assignedLabsKnownToConfig[0].Name!;
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
