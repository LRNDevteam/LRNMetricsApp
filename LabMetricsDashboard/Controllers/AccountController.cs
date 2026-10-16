using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.Services.Security;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;
using System.Globalization;
using System.Security.Claims;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Two ways in, one way out: the username/password form and "Sign in with Microsoft" (Entra ID,
/// MFA enforced by Entra) both end in <see cref="CompleteSignInAsync"/>, which issues the same auth
/// cookie with the same claims - so the AR Workbench, AuthToken and LRN.ReportsApi see no difference.
/// </summary>
[AllowAnonymous]
public class AccountController : Controller
{
    private readonly IUserManagementRepository _repo;
    private readonly IPasswordHasher _hasher;
    private readonly LrnSignInService _signIn;
    private readonly HybridAuthOptions _hybrid;
    private readonly ILogger<AccountController> _logger;
    private readonly IConfiguration _configuration;
    private readonly IMemoryCache _cache;
    private readonly IUserInvitationRepository _invitations;

    public AccountController(
        IUserManagementRepository repo,
        IPasswordHasher hasher,
        LrnSignInService signIn,
        IOptions<HybridAuthOptions> hybrid,
        ILogger<AccountController> logger,
        IConfiguration configuration,
        IMemoryCache cache,
        IUserInvitationRepository invitations)
    {
        _repo = repo;
        _hasher = hasher;
        _signIn = signIn;
        _hybrid = hybrid.Value;
        _logger = logger;
        _configuration = configuration;
        _cache = cache;
        _invitations = invitations;
    }

    private string? RemoteIp => HttpContext.Connection.RemoteIpAddress?.ToString();

    // ── First login: set a password from the invitation email ───────────────────────────
    // The link carries ?token=; the email also carries a one-time password. Both must match an open
    // dbo.UserInvitation row (see SqlUserInvitationRepository). Users invited from LRN Metrics Admin and
    // from AR Workbench User Management both land here. Five wrong one-time passwords
    // revoke the invitation and the administrator must resend it.

    [HttpGet]
    public async Task<IActionResult> SetPassword(string? token)
    {
        var invite = string.IsNullOrWhiteSpace(token) ? null : await _invitations.FindOpenAsync(token);
        var model = new SetPasswordViewModel { Token = token ?? string.Empty, UserName = invite?.UserName, LinkValid = invite is not null };
        if (invite is not null && await IsMicrosoftAccountAsync(invite.LabUserId)) RefuseMicrosoftAccount(model);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting("login")]
    public async Task<IActionResult> SetPassword(SetPasswordViewModel model)
    {
        var invite = await _invitations.FindOpenAsync(model.Token);
        model.UserName = invite?.UserName;
        model.LinkValid = invite is not null;
        if (invite is null) return View(model);

        // An invitation sent before the account was linked to Microsoft must not hand it a password.
        if (await IsMicrosoftAccountAsync(invite.LabUserId))
        {
            RefuseMicrosoftAccount(model);
            return View(model);
        }

        var policyError = ValidateNewPassword(model.NewPassword);
        if (string.IsNullOrWhiteSpace(model.OneTimePassword))
            ModelState.AddModelError(nameof(model.OneTimePassword), "Enter the one-time password from your email.");
        if (policyError is not null)
            ModelState.AddModelError(nameof(model.NewPassword), policyError);
        else if (!string.Equals(model.NewPassword, model.ConfirmPassword, StringComparison.Ordinal))
            ModelState.AddModelError(nameof(model.ConfirmPassword), "The passwords do not match.");
        if (!ModelState.IsValid) return View(model);

        var outcome = await _invitations.CompleteAsync(model.Token, model.OneTimePassword, _hasher.Hash(model.NewPassword), _hasher);
        switch (outcome)
        {
            case SetPasswordOutcome.Ok:
                _logger.LogInformation("First-login password set for {UserName} (LabUserID {Id}).", invite.UserName, invite.LabUserId);
                TempData["LoginInfo"] = $"Your password has been created. Sign in as {invite.UserName} with your new password.";
                return RedirectToAction(nameof(Login));
            case SetPasswordOutcome.WrongOtp:
                ModelState.AddModelError(nameof(model.OneTimePassword), "The one-time password is incorrect. Check the email and try again.");
                return View(model);
            case SetPasswordOutcome.TooManyAttempts:
                _logger.LogWarning("Invitation for {UserName} revoked after too many wrong one-time passwords.", invite.UserName);
                model.LinkValid = false;
                model.Message = "Too many incorrect one-time passwords. This link no longer works; ask your administrator to resend the invitation.";
                return View(model);
            default:
                model.LinkValid = false;
                return View(model);
        }
    }

    private async Task<bool> IsMicrosoftAccountAsync(int labUserId)
        => (await _repo.GetUserByIdAsync(labUserId))?.IsEntra == true;

    private static void RefuseMicrosoftAccount(SetPasswordViewModel model)
    {
        model.LinkValid = false;
        model.Message = "This account signs in with Microsoft and has no password. Use \"Sign in with Microsoft\" on the sign-in page.";
    }

    // Same rule as LRN.ReportsApi ArWorkbenchUserRules.ValidatePassword.
    private static string? ValidateNewPassword(string? password)
    {
        if (string.IsNullOrEmpty(password)) return "Enter a new password.";
        if (password.Length < 8 || password.Length > 128) return "Password must be 8 to 128 characters.";
        if (!password.Any(char.IsLetter) || !password.Any(char.IsDigit)) return "Password must contain at least one letter and one number.";
        return null;
    }

    [HttpGet]
    public IActionResult Login(string? returnUrl = null, int denied = 0, int msError = 0)
    {
        ViewData["ReturnUrl"] = returnUrl;
        ViewData["EnableMicrosoftLogin"] = _hybrid.EnableMicrosoftLogin;

        // Set by OnRedirectToAccessDenied when an already-signed-in user was refused a page. Without
        // this the refusal looked like the login form simply reloading, over and over.
        if (denied == 1 && TempData["LoginError"] is null)
        {
            _logger.LogWarning(
                "Access denied for {UserName} with roles [{Roles}] - the page is not mapped to any "
                + "of their roles in Admin > Role Menu Mapping.",
                User.Identity?.Name ?? "(anonymous)",
                string.Join(", ", User.Claims
                    .Where(c => c.Type == ClaimTypes.Role)
                    .Select(c => c.Value)));

            TempData["LoginError"] =
                "Your account does not have access to that page. Its role has no menus assigned - "
                + "ask an administrator to map menus to it under Admin > Role Menu Mapping.";
        }

        // Set by the OpenID Connect handler's OnRemoteFailure (cancelled, MFA not completed ...).
        if (msError == 1 && TempData["LoginError"] is null)
            TempData["LoginError"] = "Microsoft sign-in was cancelled or did not complete. Please try again.";

        return View(new LoginViewModel());
    }

    // ── Local: username + password ──────────────────────────────────────────────────────
    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting("login")]
    public async Task<IActionResult> Login(LoginViewModel model, string? returnUrl = null)
    {
        ViewData["ReturnUrl"] = returnUrl;
        ViewData["EnableMicrosoftLogin"] = _hybrid.EnableMicrosoftLogin;
        if (!ModelState.IsValid) return View(model);

        var login = model.UserName.Trim();
        const string invalid = "Invalid username or password.";

        var lockoutKey = LoginLockoutKey(login);
        if (_cache.TryGetValue<DateTimeOffset>(lockoutKey, out var lockedUntil) && lockedUntil > DateTimeOffset.UtcNow)
        {
            ModelState.AddModelError(string.Empty, "Too many failed sign-in attempts. Please wait a few minutes and try again.");
            return View(model);
        }

        var user = await _repo.GetUserByUserNameAsync(login);

        // Organization accounts (switch on once every staff member is linked to Microsoft).
        if (_hybrid.EnableMicrosoftLogin && _hybrid.BlockOrganizationLocalLogin
            && (_hybrid.IsOrganizationEmail(login) || _hybrid.IsOrganizationEmail(user?.Email)))
        {
            await AuditAsync(user?.LabUserID, login, LrnAuth.LocalProvider, false, "UseMicrosoft");
            ModelState.AddModelError(string.Empty, "Organization accounts sign in with Microsoft. Use the \"Sign in with Microsoft\" button.");
            return View(model);
        }

        if (user == null || !user.IsActive)
        {
            _hasher.Hash(model.Password);   // similar work either way, so timing does not reveal which usernames exist
            RecordFailedLogin(login);
            await AuditAsync(user?.LabUserID, login, LrnAuth.LocalProvider, false, user == null ? "Unknown" : "Inactive");
            ModelState.AddModelError(string.Empty, invalid);
            return View(model);
        }

        // Linked to Microsoft: the password was retired when the accounts were linked.
        if (user.IsEntra)
        {
            await AuditAsync(user.LabUserID, login, LrnAuth.LocalProvider, false, "UseMicrosoft");
            ModelState.AddModelError(string.Empty, _hybrid.EnableMicrosoftLogin
                ? "This account signs in with Microsoft. Use the \"Sign in with Microsoft\" button."
                : invalid);
            return View(model);
        }

        if (user.LockoutEndUtc > DateTime.UtcNow)
        {
            await AuditAsync(user.LabUserID, login, LrnAuth.LocalProvider, false, "LockedOut");
            ModelState.AddModelError(string.Empty, "This account is temporarily locked after too many failed sign-in attempts. Try again later or contact your administrator.");
            return View(model);
        }

        if (string.IsNullOrEmpty(user.PasswordHash) || !_hasher.Verify(user.PasswordHash, model.Password))
        {
            RecordFailedLogin(login);
            await _repo.RecordFailedLoginAsync(user.LabUserID,
                _configuration.GetValue<int?>("Security:LoginLockout:MaxFailedAttempts") ?? 5,
                _configuration.GetValue<int?>("Security:LoginLockout:LockoutMinutes") ?? 15);
            await AuditAsync(user.LabUserID, login, LrnAuth.LocalProvider, false, "BadPassword");
            ModelState.AddModelError(string.Empty, invalid);
            return View(model);
        }

        ClearFailedLogin(login);
        return await CompleteSignInAsync(user, LrnAuth.LocalProvider, login, returnUrl);
    }

    // ── Microsoft Entra ID ──────────────────────────────────────────────────────────────
    // A plain GET link from the login page: a form POST would need login.microsoftonline.com in the
    // CSP form-action list. The OpenID Connect handler signs the result into the short-lived external
    // cookie, and MicrosoftCallback lets LabUsers decide.

    [HttpGet]
    public IActionResult MicrosoftLogin(string? returnUrl = null)
    {
        if (!_hybrid.EnableMicrosoftLogin) return RedirectToAction(nameof(Login));

        var callback = Url.Action(nameof(MicrosoftCallback),
            new { returnUrl = !string.IsNullOrEmpty(returnUrl) && Url.IsLocalUrl(returnUrl) ? returnUrl : null });
        return Challenge(
            new OpenIdConnectChallengeProperties { RedirectUri = callback, Prompt = "select_account" },
            LrnAuth.EntraScheme);
    }

    [HttpGet]
    public async Task<IActionResult> MicrosoftCallback(string? returnUrl = null)
    {
        if (!_hybrid.EnableMicrosoftLogin) return RedirectToAction(nameof(Login));

        var external = await HttpContext.AuthenticateAsync(LrnAuth.ExternalScheme);
        await HttpContext.SignOutAsync(LrnAuth.ExternalScheme);   // one-time use

        if (!external.Succeeded || external.Principal is null)
        {
            TempData["LoginError"] = "Microsoft sign-in did not complete. Please try again.";
            return RedirectToAction(nameof(Login));
        }

        var p = external.Principal;
        var upn = p.FindFirstValue("preferred_username") ?? p.FindFirstValue("email") ?? string.Empty;
        var tenantText = p.FindFirstValue("tid");

        // Single-tenant registration, but checked here as well: only this tenant's accounts get in.
        if (!Guid.TryParse(p.FindFirstValue("oid"), out var objectId)
            || !Guid.TryParse(tenantText, out var tenantId)
            || !Guid.TryParse(_configuration["MFAAzureAd:TenantId"], out var expectedTenant)
            || tenantId != expectedTenant)
        {
            await AuditAsync(null, upn, LrnAuth.EntraProvider, false, "WrongTenantOrClaims");
            TempData["LoginError"] = "This Microsoft account cannot be used here.";
            return RedirectToAction(nameof(Login));
        }

        // Match ONLY on the object id. Never link to a local account by email or UPN automatically:
        // an administrator does that (Admin > Manage Users > Link).
        var user = await _repo.GetUserByEntraObjectIdAsync(objectId);
        if (user is null)
        {
            user = await _repo.GetOrCreateEntraUserAsync(objectId, tenantId, upn, p.FindFirstValue("email"), p.FindFirstValue("name"));
            await AuditAsync(user.LabUserID, upn, LrnAuth.EntraProvider, false, "Provisioned");
            _logger.LogInformation("Provisioned Microsoft user {Upn} ({ObjectId}) as LabUserID {Id} with no role.", upn, objectId, user.LabUserID);
        }

        return await CompleteSignInAsync(user, LrnAuth.EntraProvider, upn, returnUrl);
    }

    // ── Shared tail for both providers ──────────────────────────────────────────────────
    private async Task<IActionResult> CompleteSignInAsync(LabUser user, string provider, string loginValue, string? returnUrl)
    {
        var result = await _signIn.BuildAsync(user);
        switch (result.Outcome)
        {
            case LrnSignInOutcome.Inactive:
                await AuditAsync(user.LabUserID, loginValue, provider, false, "Inactive");
                TempData["LoginError"] = "Your account is inactive. Please contact your administrator.";
                return RedirectToAction(nameof(Login));
            case LrnSignInOutcome.NoRole:
                await AuditAsync(user.LabUserID, loginValue, provider, false, "NoRole");
                TempData["PendingUser"] = user.UserName;
                return RedirectToAction(nameof(AccessPending));
            case LrnSignInOutcome.NoLabs:
                await AuditAsync(user.LabUserID, loginValue, provider, false, "NoLabs");
                TempData["LoginError"] = "Your account has no lab assignments. Please contact your administrator.";
                return RedirectToAction(nameof(Login));
            case LrnSignInOutcome.LabsNotMapped:
                await AuditAsync(user.LabUserID, loginValue, provider, false, "LabsNotMapped");
                TempData["LoginError"] = "Your assigned lab(s) are not mapped in this environment. Please contact your administrator.";
                return RedirectToAction(nameof(Login));
        }

        var properties = new AuthenticationProperties
        {
            // Always a session cookie (no browser Expires/Max-Age), so closing the browser ends
            // the session and forces a fresh login on reopen. The 8h ExpiresUtc still caps an
            // idle session within the same browser run. RememberMe no longer persists across
            // browser close by design.
            IsPersistent = false,
            ExpiresUtc   = DateTimeOffset.UtcNow.AddHours(8)
        };
        properties.Items[LrnAuth.ValidatedItem] = DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture);
        await HttpContext.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, result.Principal!, properties);

        await _repo.RecordSuccessfulLoginAsync(user.LabUserID);
        await AuditAsync(user.LabUserID, loginValue, provider, true, null);

        // Honor ?returnUrl=... if it's local
        if (!string.IsNullOrEmpty(returnUrl) && Url.IsLocalUrl(returnUrl))
            return Redirect(returnUrl);

        // Admin without a Denial Workflow / AR Workbench role => Report Control Board (the landing page).
        if (result.IsAdmin && !result.IsDenialWorkflowUser)
            return RedirectToAction("Index", "ReportBoard");

        Response.Cookies.Append("lmd_selected_lab", result.DefaultLabName!, new CookieOptions
        {
            Expires     = DateTimeOffset.UtcNow.AddDays(30),
            HttpOnly    = false,
            SameSite    = SameSiteMode.Lax,
            Secure      = Request.IsHttps,
            IsEssential = true
        });

        // AR and AR Workbench users go directly to the AR Workbench.
        if (result.IsDenialWorkflowUser)
        {
            var workflowUrl = _configuration["DenialWorkflowReactUrl"];
            if (!string.IsNullOrWhiteSpace(workflowUrl))
            {
                // LRN.ARWorkbench (replaced LRN.WebUI) opens on its dashboard at the root; it has
                // no #dashboard route.
                return Redirect(workflowUrl.Trim());
            }

            return RedirectToAction("Index", "DenialWorkflow", new { tab = "dashboard" });
        }

        // Report Control Board is the landing/home page for everyone. The selected lab is remembered
        // via the lmd_selected_lab cookie above, so the Revenue dashboard opens on the right lab.
        return RedirectToAction("Index", "ReportBoard");
    }

    /// <summary>The audit trail must never be the reason a sign-in fails.</summary>
    private async Task AuditAsync(int? labUserId, string? loginValue, string provider, bool succeeded, string? reason)
    {
        try
        {
            await _repo.WriteLoginAuditAsync(labUserId, loginValue, provider, succeeded, reason, RemoteIp);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not write LoginAudit for {Login} ({Provider}, {Reason}).", loginValue, provider, reason ?? "Success");
        }
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public Task<IActionResult> Logout() => LrnSignOut.SignOutAsync(this);

    [HttpGet]
    public IActionResult AccessDenied() => View();

    /// <summary>Signed in successfully (password or Microsoft), but no role yet: no cookie was issued.</summary>
    [HttpGet]
    public IActionResult AccessPending()
    {
        ViewData["EnableMicrosoftLogin"] = _hybrid.EnableMicrosoftLogin;
        return View();
    }

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

public sealed class SetPasswordViewModel
{
    public string Token { get; set; } = string.Empty;
    public string OneTimePassword { get; set; } = string.Empty;

    [System.ComponentModel.DataAnnotations.DataType(System.ComponentModel.DataAnnotations.DataType.Password)]
    public string NewPassword { get; set; } = string.Empty;

    [System.ComponentModel.DataAnnotations.DataType(System.ComponentModel.DataAnnotations.DataType.Password)]
    public string ConfirmPassword { get; set; } = string.Empty;

    // Display only; never bound from the form.
    [Microsoft.AspNetCore.Mvc.ModelBinding.BindNever] public string? UserName { get; set; }
    [Microsoft.AspNetCore.Mvc.ModelBinding.BindNever] public bool LinkValid { get; set; }
    [Microsoft.AspNetCore.Mvc.ModelBinding.BindNever] public string? Message { get; set; }
}
