namespace LabMetricsDashboard.Models;

/// <summary>
/// One row of the NorthWest Clinic Summary "By Facility" tree.
/// Level 1 = clinic, 2 = clinic + payer, 3 = clinic + payer + referring provider.
/// NoOfClaims counts unique ClaimIDs at the row's own level.
/// </summary>
public sealed record NwFacilityRow(
    int Level,
    string ClinicName,
    string PayerName,
    string ReferringProvider,
    int NoOfClaims,
    decimal ChargeAmount,
    decimal InsuranceBalance,
    decimal PatientBalance);

/// <summary>NorthWest Clinic Summary "By Facility": ClinicName &gt; PayerName_Raw &gt; ReferringProvider.</summary>
public sealed class NwByFacilityViewModel
{
    public string SelectedLab { get; init; } = string.Empty;
    public string? ErrorMessage { get; init; }

    /// <summary>Clinic, payer and provider rows (levels 1-3), each level sorted by Claim Count.</summary>
    public List<NwFacilityRow> Rows { get; init; } = [];

    public NwFacilityRow? GrandTotal { get; init; }

    public IEnumerable<NwFacilityRow> Clinics => Rows.Where(r => r.Level == 1);
}

/// <summary>One clinic row of the NorthWest "Facility vs Payment (%)" tab.</summary>
public sealed record NwFacilityPaymentPctRow(string ClinicName, int NoOfClaims, decimal? AvgPaymentPct);

/// <summary>NorthWest Clinic Summary "Facility vs Payment (%)": InsurancePayment &gt; 0, by ClinicName.</summary>
public sealed class NwFacilityPaymentPctViewModel
{
    public string SelectedLab { get; init; } = string.Empty;
    public string? ErrorMessage { get; init; }
    public List<NwFacilityPaymentPctRow> Rows { get; init; } = [];
    public NwFacilityPaymentPctRow? GrandTotal { get; init; }
}
