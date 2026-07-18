using System.Security.Claims;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Caching.Memory;
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
    private readonly IConfiguration _configuration;
    private readonly IMemoryCache _cache;

    public AccountController(
        IUserManagementRepository repo,
        IPasswordHasher hasher,
        LabConfigOptions labConfig,
        LabSettings labSettings,
        ILogger<AccountController> logger,
        IConfiguration configuration,
        IMemoryCache cache)
    {
        _repo = repo;
        _hasher = hasher;
        _labConfig = labConfig;
        _labSettings = labSettings;
        _logger = logger;
        _configuration = configuration;
        _cache = cache;
    }

    [HttpGet]
    public IActionResult Login(string? returnUrl = null)
    {
        ViewData["ReturnUrl"] = returnUrl;
        return View(new LoginViewModel());
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting("login")]
    public async Task<IActionResult> Login(LoginViewModel model, string? returnUrl = null)
    {
        ViewData["ReturnUrl"] = returnUrl;
        if (!ModelState.IsValid) return View(model);

        var lockoutKey = LoginLockoutKey(model.UserName);
        if (_cache.TryGetValue<DateTimeOffset>(lockoutKey, out var lockedUntil) && lockedUntil > DateTimeOffset.UtcNow)
        {
            ModelState.AddModelError(string.Empty, "Too many failed sign-in attempts. Please wait a few minutes and try again.");
            return View(model);
        }

        var user = await _repo.GetUserByUserNameAsync(model.UserName);
        if (user == null || !user.IsActive)
        {
            RecordFailedLogin(model.UserName);
            ModelState.AddModelError(string.Empty, "Invalid username or password.");
            return View(model);
        }

        if (string.IsNullOrEmpty(user.PasswordHash) || !_hasher.Verify(user.PasswordHash, model.Password))
        {
            RecordFailedLogin(model.UserName);
            ModelState.AddModelError(string.Empty, "Invalid username or password.");
            return View(model);
        }

        ClearFailedLogin(model.UserName);

        // Resolve roles + labs for the user.
        // These three queries are independent — run them concurrently instead of
        // sequentially. Against a remote SQL server this cuts login time by two
        // full network round trips (each repo call opens its own pooled connection).
        var rolesForUserTask = _repo.GetUserRolesAsync(user.LabUserID);
        var allRolesTask     = _repo.GetAllRolesAsync();
        var userLabsTask     = _repo.GetUserLabsAsync(user.LabUserID);
        await Task.WhenAll(rolesForUserTask, allRolesTask, userLabsTask);

        var rolesForUser = await rolesForUserTask;
        var allRoles     = (await allRolesTask).ToDictionary(r => r.RoleID, r => r.RoleName);
        var roleNames = rolesForUser
            .Select(r => allRoles.TryGetValue(r.RoleID, out var n) ? n : string.Empty)
            .Where(n => !string.IsNullOrWhiteSpace(n))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        var userLabs = (await userLabsTask).ToList();

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
        var isArManager = roleNames.Any(r => IsRole(r, "AR Manager") || IsRole(r, "ARManager"));
        var isArReviewer = roleNames.Any(r => IsRole(r, "AR Reviewer") || IsRole(r, "ARReviewer") || IsRole(r, "AR Analyser") || IsRole(r, "ARAnalyser") || IsRole(r, "AR Analyzer") || IsRole(r, "ARAnalyzer"));
        var isClientManager = roleNames.Any(r => IsRole(r, "Client Manager") || IsRole(r, "ClientManager"));
        var isAccountManager = roleNames.Any(r => IsRole(r, "Account Manager") || IsRole(r, "AccountManager"));

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
        var isDenialWorkflowUser = isArManager || isArReviewer || isClientManager || isAccountManager;

        // 1) Admin without a Denial Workflow role => home page (full landing with lab tiles).
        //    Users with Denial Workflow roles are routed to the workflow dashboard below.
        if (isAdmin && !isDenialWorkflowUser)
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

        // 3) Non-admin (1 or many labs). AR users go directly to Denial Database.
        var defaultLabName = mappedLabs[0].Name!;
        Response.Cookies.Append("lmd_selected_lab", defaultLabName, new CookieOptions
        {
            Expires     = DateTimeOffset.UtcNow.AddDays(30),
            HttpOnly    = false,
            SameSite    = SameSiteMode.Lax,
            Secure      = Request.IsHttps,
            IsEssential = true
        });

        if (isDenialWorkflowUser)
        {
            var workflowUrl = _configuration["DenialWorkflowReactUrl"];
            if (!string.IsNullOrWhiteSpace(workflowUrl))
            {
                var url = workflowUrl.Trim();
                if (!url.Contains('#')) url += "#dashboard";
                return Redirect(url);
            }

            return RedirectToAction("Index", "DenialWorkflow", new { tab = "dashboard" });
        }

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

    private static bool IsRole(string? actual, string expected)
        => string.Equals(NormalizeRoleToken(actual), NormalizeRoleToken(expected), StringComparison.OrdinalIgnoreCase);

    private static string NormalizeRoleToken(string? value)
        => new string((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

    private string LoginFailureKey(string userName)
        => $"login-fail:{HttpContext.Connection.RemoteIpAddress}:{NormalizeUserName(userName)}";

    private string LoginLockoutKey(string userName)
        => $"login-lock:{HttpContext.Connection.RemoteIpAddress}:{NormalizeUserName(userName)}";

    private void RecordFailedLogin(string userName)
    {
        var failureKey = LoginFailureKey(userName);
        var attempts = _cache.Get<int>(failureKey) + 1;
        var maxAttempts = _configuration.GetValue<int?>("Security:LoginLockout:MaxFailedAttempts") ?? 5;
        var windowMinutes = _configuration.GetValue<int?>("Security:LoginLockout:WindowMinutes") ?? 15;
        var lockoutMinutes = _configuration.GetValue<int?>("Security:LoginLockout:LockoutMinutes") ?? 15;

        _cache.Set(failureKey, attempts, TimeSpan.FromMinutes(windowMinutes));
        if (attempts >= maxAttempts)
        {
            var until = DateTimeOffset.UtcNow.AddMinutes(lockoutMinutes);
            _cache.Set(LoginLockoutKey(userName), until, TimeSpan.FromMinutes(lockoutMinutes));
            _cache.Remove(failureKey);
            _logger.LogWarning("Login lockout applied for user key {UserKey} from IP {RemoteIp}.", NormalizeUserName(userName), HttpContext.Connection.RemoteIpAddress);
        }
    }

    private void ClearFailedLogin(string userName)
    {
        _cache.Remove(LoginFailureKey(userName));
        _cache.Remove(LoginLockoutKey(userName));
    }

    private static string NormalizeUserName(string? value)
        => (value ?? string.Empty).Trim().ToUpperInvariant();
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
