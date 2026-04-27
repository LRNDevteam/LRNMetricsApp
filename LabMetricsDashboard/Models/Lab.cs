using System.ComponentModel.DataAnnotations;

namespace LabMetricsDashboard.Models;

public sealed class Lab
{
    public int LabId { get; set; }

    [Required(ErrorMessage = "Lab Name is required")]
    [StringLength(200, ErrorMessage = "Lab Name must be 200 characters or fewer")]
    public string LabName { get; set; } = string.Empty;

    public bool IsActive { get; set; } = true;

    public string? CreatedBy { get; set; }
    public DateTime? CreatedDate { get; set; }
    public string? ModifiedBy { get; set; }
    public DateTime? ModifiedDate { get; set; }
}
