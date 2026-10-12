using System.Collections.Generic;

using System.ComponentModel.DataAnnotations;

namespace LabMetricsDashboard.Models;

public sealed class AdminViewModel
{
    // No password on create: the new user is emailed a one-time password and a link to set their own
    // (LRN.ReportsApi /api/user-mail, shared with the AR Workbench).
    public LabUser NewUser { get; set; } = new LabUser();

    public Role NewRole { get; set; } = new Role();

    // For create-user form: optionally select a role and labs to assign after creating the user
    public int? NewUserRoleId { get; set; }
    public int? NewUserLabId { get; set; }
    public List<int> NewUserLabIds { get; set; } = new();

    // List of available labs (populated by controller)
    public IEnumerable<Lab> Labs { get; set; } = new List<Lab>();

    public IEnumerable<LabUser> Users { get; set; } = new List<LabUser>();
    public IEnumerable<Role> Roles { get; set; } = new List<Role>();
    public int AssignUserId { get; set; }
    public int AssignRoleId { get; set; }
    public int AssignLabId { get; set; }
    // Map of userId -> assigned labs for server-side rendering
    public IDictionary<int, IEnumerable<UserLab>> UserLabsMap { get; set; } = new Dictionary<int, IEnumerable<UserLab>>();
    public IDictionary<int, IEnumerable<Role>> UserRolesMap { get; set; } = new Dictionary<int, IEnumerable<Role>>();
}
