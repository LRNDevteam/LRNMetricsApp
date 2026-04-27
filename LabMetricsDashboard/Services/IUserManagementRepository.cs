using System.Collections.Generic;
using System.Threading.Tasks;

namespace LabMetricsDashboard.Services;

using LabMetricsDashboard.Models;

public interface IUserManagementRepository
{
    Task<int> CreateUserAsync(LabUser user);
    Task<int> CreateRoleAsync(Role role);
    Task AssignRoleAsync(int labUserId, int roleId);
    Task AssignUserLabAsync(UserLab userLab);
    Task<IEnumerable<LabUser>> GetAllUsersAsync();
    Task<IEnumerable<Role>> GetAllRolesAsync();
    Task<LabUser?> GetUserByIdAsync(int labUserId);
    Task<LabUser?> GetUserByUserNameAsync(string userName);
    Task UpdateUserAsync(LabUser user, string? passwordHash = null);
    Task<IEnumerable<UserRole>> GetUserRolesAsync(int labUserId);
    Task<IEnumerable<UserLab>> GetUserLabsAsync(int labUserId);
    Task RemoveUserRoleAsync(int userRoleId);
    Task RemoveUserLabAsync(int ulid);
    Task<IEnumerable<LabMetricsDashboard.Models.Lab>> GetAllLabsAsync();

    // ?? Lab management (LabMaster) ?????????????????????????????????
    Task<LabMetricsDashboard.Models.Lab?> GetLabByIdAsync(int labId);
    Task<LabMetricsDashboard.Models.Lab?> GetLabByNameAsync(string labName);
    Task<int> CreateLabAsync(LabMetricsDashboard.Models.Lab lab);
    Task UpdateLabAsync(LabMetricsDashboard.Models.Lab lab);
}
