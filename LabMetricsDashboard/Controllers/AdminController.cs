using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.Models;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

public class AdminController : Controller
{
    private readonly IUserManagementRepository _repo;
    private readonly IPasswordHasher _hasher;

    public AdminController(IUserManagementRepository repo, IPasswordHasher hasher)
    {
        _repo = repo;
        _hasher = hasher;
    }

    [HttpGet]
    public async Task<IActionResult> Index()
    {
        var users = await _repo.GetAllUsersAsync();
        var roles = await _repo.GetAllRolesAsync();
        var vm = new AdminViewModel
        {
            Users = users,
            Roles = roles
        };
        return View(vm);
    }

    [HttpGet]
    public async Task<IActionResult> Users()
    {
        var vm = new AdminViewModel
        {
            Users = await _repo.GetAllUsersAsync(),
            Roles = await _repo.GetAllRolesAsync(),
            Labs = await _repo.GetAllLabsAsync()
        };
        // keep existing Users view for backward compatibility
        return View(vm);
    }

    [HttpGet]
    public async Task<IActionResult> CreateUser()
    {
        var vm = new AdminViewModel
        {
            Roles = await _repo.GetAllRolesAsync(),
            Labs = await _repo.GetAllLabsAsync()
        };
        return View(vm);
    }

    [HttpGet]
    public async Task<IActionResult> ListUsers()
    {
        var vm = new AdminViewModel
        {
            Users = await _repo.GetAllUsersAsync(),
            Roles = await _repo.GetAllRolesAsync(),
            Labs = await _repo.GetAllLabsAsync()
        };
        // Populate user -> labs map for server-side rendering
        var map = new Dictionary<int, IEnumerable<UserLab>>();
        foreach (var u in vm.Users)
        {
            var labs = await _repo.GetUserLabsAsync(u.LabUserID);
            map[u.LabUserID] = labs;
        }
        vm.UserLabsMap = map;

        return View(vm);
    }

    [HttpGet]
    public async Task<IActionResult> Roles()
    {
        var vm = new AdminViewModel
        {
            Roles = await _repo.GetAllRolesAsync()
        };
        return View(vm);
    }

    [HttpGet]
    public async Task<IActionResult> AssignUserRole()
    {
        var vm = new AdminViewModel
        {
            Users = await _repo.GetAllUsersAsync(),
            Roles = await _repo.GetAllRolesAsync(),
            Labs = await _repo.GetAllLabsAsync()
        };
        return View(vm);
    }

    [HttpGet]
    public async Task<IActionResult> AssignUserLabs()
    {
        var vm = new AdminViewModel
        {
            Users = await _repo.GetAllUsersAsync(),
            Roles = await _repo.GetAllRolesAsync(),
            Labs = await _repo.GetAllLabsAsync()
        };
        return View(vm);
    }

    [HttpGet]
    public async Task<IActionResult> GetUsersJson()
    {
        var users = (await _repo.GetAllUsersAsync()).ToList();

        var result = new List<object>();
        foreach (var u in users)
        {
            var labs = (await _repo.GetUserLabsAsync(u.LabUserID)).Select(ul => new { ul.ULID, ul.LabId, ul.LabName }).ToList();
            result.Add(new {
                labUserID = u.LabUserID,
                userName = u.UserName,
                firstName = u.FirstName,
                lastName = u.LastName,
                email = u.Email,
                mobile = u.Mobile,
                isExternalUser = u.IsExternalUser,
                isActive = u.IsActive,
                labs = labs
            });
        }

        return Json(result);
    }

    [HttpGet]
    public async Task<IActionResult> GetRolesJson()
    {
        var roles = await _repo.GetAllRolesAsync();
        return Json(roles);
    }

    [HttpGet]
    public async Task<IActionResult> GetLabsJson()
    {
        var labs = await _repo.GetAllLabsAsync();
        return Json(labs);
    }

    [HttpGet]
    public async Task<IActionResult> GetUserRolesJson(int userId)
    {
        if (userId <= 0) return BadRequest();
        var urs = await _repo.GetUserRolesAsync(userId);
        return Json(urs);
    }

    [HttpGet]
    public async Task<IActionResult> GetUserLabsJson(int userId)
    {
        if (userId <= 0) return BadRequest();
        var uls = await _repo.GetUserLabsAsync(userId);
        return Json(uls);
    }

    [HttpPost]
    public async Task<IActionResult> CreateUserAjax([FromForm] AdminViewModel vm)
    {
        // Validate using ModelState and explicit checks
        var errors = new List<string>();
        if (vm == null) return BadRequest(new { success = false, errors = new[] { "Invalid request" } });

        // DataAnnotation validation for password/compare will be on ModelState
        if (!ModelState.IsValid)
        {
            errors.AddRange(ModelState.Values.SelectMany(v => v.Errors).Select(e => e.ErrorMessage));
        }

        var user = vm.NewUser;
        if (user == null || string.IsNullOrWhiteSpace(user.UserName))
            errors.Add("UserName is required");

        if (string.IsNullOrEmpty(vm.NewUserPassword))
            errors.Add("Password is required");
        else if (!string.Equals(vm.NewUserPassword, vm.NewUserConfirmPassword, StringComparison.Ordinal))
            errors.Add("Passwords do not match");

        if (errors.Count > 0) return BadRequest(new { success = false, errors });

        user.PasswordHash = _hasher.Hash(vm.NewUserPassword!);
        var id = await _repo.CreateUserAsync(user);

        // Optionally assign role and lab
        if (vm.NewUserRoleId.HasValue && vm.NewUserRoleId.Value > 0)
        {
            await _repo.AssignRoleAsync(id, vm.NewUserRoleId.Value);
        }
        if (vm.NewUserLabId.HasValue && vm.NewUserLabId.Value > 0)
        {
            await _repo.AssignUserLabAsync(new UserLab { LabUserID = id, LabId = vm.NewUserLabId.Value });
        }

        return Json(new { success = true, id });
    }

    [HttpPost]
    public async Task<IActionResult> CreateRoleAjax([FromForm] AdminViewModel vm)
    {
        var role = vm?.NewRole;
        if (role == null || string.IsNullOrWhiteSpace(role.RoleName)) return BadRequest(new { success = false, errors = new[] { "RoleName required" } });
        var id = await _repo.CreateRoleAsync(role);
        return Json(new { success = true, id });
    }

    [HttpPost]
    public async Task<IActionResult> AssignRoleAjax([FromForm] int assignUserId, [FromForm] int assignRoleId)
    {
        if (assignUserId <= 0 || assignRoleId <= 0) return BadRequest(new { success = false, errors = new[] { "Invalid user or role" } });
        await _repo.AssignRoleAsync(assignUserId, assignRoleId);
        return Json(new { success = true });
    }

    [HttpPost]
    public async Task<IActionResult> AssignUserLabAjax([FromForm] int assignUserId, [FromForm] int labId)
    {
        if (assignUserId <= 0 || labId <= 0) return BadRequest(new { success = false, errors = new[] { "Invalid user or lab" } });
        var ul = new UserLab { LabId = labId, LabUserID = assignUserId };
        await _repo.AssignUserLabAsync(ul);
        return Json(new { success = true });
    }

    [HttpPost]
    public async Task<IActionResult> RemoveUserRole([FromForm] int userRoleId)
    {
        if (userRoleId <= 0) return BadRequest();
        await _repo.RemoveUserRoleAsync(userRoleId);
        return Json(new { success = true });
    }

    [HttpPost]
    public async Task<IActionResult> RemoveUserLab([FromForm] int ulid)
    {
        if (ulid <= 0) return BadRequest();
        await _repo.RemoveUserLabAsync(ulid);
        return Json(new { success = true });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CreateUser(AdminViewModel vm)
    {
        // Server-side validation via ModelState
        if (!ModelState.IsValid)
        {
            vm.Users = await _repo.GetAllUsersAsync();
            vm.Roles = await _repo.GetAllRolesAsync();
            vm.Labs = await _repo.GetAllLabsAsync();

            // Populate labs map for the list view
            var map = new Dictionary<int, IEnumerable<UserLab>>();
            foreach (var u in vm.Users)
            {
                var labs = await _repo.GetUserLabsAsync(u.LabUserID);
                map[u.LabUserID] = labs;
            }
            vm.UserLabsMap = map;

            ViewData["OpenCreateUserModal"] = true;
            return View("ListUsers", vm);
        }

        var user = vm.NewUser;
        user.PasswordHash = _hasher.Hash(vm.NewUserPassword ?? string.Empty);
        var id = await _repo.CreateUserAsync(user);

        if (vm.NewUserRoleId.HasValue && vm.NewUserRoleId.Value > 0)
        {
            await _repo.AssignRoleAsync(id, vm.NewUserRoleId.Value);
        }
        if (vm.NewUserLabId.HasValue && vm.NewUserLabId.Value > 0)
        {
            await _repo.AssignUserLabAsync(new UserLab { LabUserID = id, LabId = vm.NewUserLabId.Value });
        }
        return RedirectToAction("ListUsers");
    }

    [HttpGet]
    public async Task<IActionResult> Edit(int id)
    {
        var user = await _repo.GetUserByIdAsync(id);
        if (user == null) return NotFound();
        return View(user);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit([FromForm] LabUser user, [FromForm] string? Password, [FromForm] string? ConfirmPassword)
    {
        if (user == null || user.LabUserID <= 0) return RedirectToAction(nameof(ListUsers));

        // Preserve non-editable fields (e.g. IsExternalUser, MiddleName) by loading the existing record.
        var existing = await _repo.GetUserByIdAsync(user.LabUserID);
        if (existing == null) return NotFound();

        existing.UserName = user.UserName;
        existing.FirstName = user.FirstName;
        existing.LastName = user.LastName;
        existing.Email = user.Email;
        existing.Mobile = user.Mobile;
        existing.IsActive = user.IsActive;

        string? pwdHash = null;
        if (!string.IsNullOrEmpty(Password))
        {
            if (Password != ConfirmPassword)
            {
                TempData["AdminError"] = "Password and confirmation do not match.";
                return RedirectToAction("Edit", new { id = user.LabUserID });
            }
            pwdHash = _hasher.Hash(Password);
        }

        await _repo.UpdateUserAsync(existing, pwdHash);
        return RedirectToAction(nameof(ListUsers));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CreateRole(Role role)
    {
        if (string.IsNullOrWhiteSpace(role.RoleName))
            return RedirectToAction("Index");

        await _repo.CreateRoleAsync(role);
        return RedirectToAction("Index");
    }

// (Hashing moved to IPasswordHasher implementation)

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> AssignRole(int assignUserId, int assignRoleId)
    {
        if (assignUserId <= 0 || assignRoleId <= 0)
            return RedirectToAction("Index");

        await _repo.AssignRoleAsync(assignUserId, assignRoleId);
        return RedirectToAction("Index");
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> AssignUserLab(int assignUserId, int labId)
    {
        if (assignUserId <= 0 || labId <= 0)
            return RedirectToAction("Index");

        var ul = new UserLab { LabId = labId, LabUserID = assignUserId };
        await _repo.AssignUserLabAsync(ul);
        return RedirectToAction("Index");
    }

    // ?????????????????????????????????????????????????????????????
    // Lab Master management
    // ?????????????????????????????????????????????????????????????

    [HttpGet]
    public async Task<IActionResult> ManageLabs()
    {
        var labs = await _repo.GetAllLabsAsync();
        return View(labs);
    }

    /// <summary>
    /// AJAX endpoint used by the create-lab form to check name uniqueness.
    /// Returns { available: true/false }.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> IsLabNameAvailable(string labName, int? excludeId = null)
    {
        if (string.IsNullOrWhiteSpace(labName))
            return Json(new { available = false, reason = "Lab Name is required" });

        var existing = await _repo.GetLabByNameAsync(labName.Trim());
        var available = existing == null || (excludeId.HasValue && existing.LabId == excludeId.Value);
        return Json(new { available });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CreateLab(Lab lab)
    {
        if (lab == null || string.IsNullOrWhiteSpace(lab.LabName))
        {
            ModelState.AddModelError(nameof(Lab.LabName), "Lab Name is required");
        }
        else
        {
            var existing = await _repo.GetLabByNameAsync(lab.LabName.Trim());
            if (existing != null)
            {
                ModelState.AddModelError(nameof(Lab.LabName), $"A lab with the name '{lab.LabName}' already exists.");
            }
        }

        if (!ModelState.IsValid)
        {
            TempData["LabError"] = string.Join("; ", ModelState.Values
                .SelectMany(v => v.Errors).Select(e => e.ErrorMessage));
            return RedirectToAction(nameof(ManageLabs));
        }

        lab!.LabName = lab.LabName.Trim();
        lab.CreatedBy = User?.Identity?.Name ?? "system";
        await _repo.CreateLabAsync(lab);
        TempData["LabSuccess"] = $"Lab '{lab.LabName}' created successfully.";
        return RedirectToAction(nameof(ManageLabs));
    }

    [HttpGet]
    public async Task<IActionResult> EditLab(int id)
    {
        var lab = await _repo.GetLabByIdAsync(id);
        if (lab == null) return NotFound();
        return View(lab);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> EditLab(Lab lab)
    {
        if (lab == null || lab.LabId <= 0) return RedirectToAction(nameof(ManageLabs));

        if (string.IsNullOrWhiteSpace(lab.LabName))
        {
            ModelState.AddModelError(nameof(Lab.LabName), "Lab Name is required");
        }
        else
        {
            var existing = await _repo.GetLabByNameAsync(lab.LabName.Trim());
            if (existing != null && existing.LabId != lab.LabId)
            {
                ModelState.AddModelError(nameof(Lab.LabName), $"A lab with the name '{lab.LabName}' already exists.");
            }
        }

        if (!ModelState.IsValid)
        {
            return View(lab);
        }

        lab.LabName = lab.LabName.Trim();
        lab.ModifiedBy = User?.Identity?.Name ?? "system";
        await _repo.UpdateLabAsync(lab);
        TempData["LabSuccess"] = $"Lab '{lab.LabName}' updated successfully.";
        return RedirectToAction(nameof(ManageLabs));
    }
}
