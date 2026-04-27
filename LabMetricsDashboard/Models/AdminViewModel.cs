using System.Collections.Generic;

using System.ComponentModel.DataAnnotations;

namespace LabMetricsDashboard.Models;

public sealed class AdminViewModel
{
    public LabUser NewUser { get; set; } = new LabUser();
    [Required]
    [MinLength(8)]
    public string? NewUserPassword { get; set; }
    [Required]
    [Compare("NewUserPassword", ErrorMessage = "Passwords do not match")]
    public string? NewUserConfirmPassword { get; set; }

    public Role NewRole { get; set; } = new Role();

    // For create-user form: optionally select a role and a lab to assign after creating the user
    public int? NewUserRoleId { get; set; }
    public int? NewUserLabId { get; set; }

    // List of available labs (populated by controller)
    public IEnumerable<Lab> Labs { get; set; } = new List<Lab>();

    public IEnumerable<LabUser> Users { get; set; } = new List<LabUser>();
    public IEnumerable<Role> Roles { get; set; } = new List<Role>();
    public int AssignUserId { get; set; }
    public int AssignRoleId { get; set; }
    public int AssignLabId { get; set; }
    // Map of userId -> assigned labs for server-side rendering
    public IDictionary<int, IEnumerable<UserLab>> UserLabsMap { get; set; } = new Dictionary<int, IEnumerable<UserLab>>();
}
