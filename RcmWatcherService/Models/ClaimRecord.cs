namespace RcmWatcherService.Models;

public sealed class ClaimRecord
{
    public string  LabID                { get; init; } = string.Empty;
    public string  LabName              { get; init; } = string.Empty;
    public string  ClaimID              { get; init; } = string.Empty;
    public string  PayerName            { get; init; } = string.Empty;
    public string  PayerType            { get; init; } = string.Empty;
    public string  ClinicName           { get; init; } = string.Empty;
    public string  PanelName            { get; init; } = string.Empty;
    public string  CPTCodeUnitsModifier { get; init; } = string.Empty;
    public string  DateOfService        { get; init; } = string.Empty;
    public string  FirstBilledDate      { get; init; } = string.Empty;
    public string  ClaimStatus          { get; init; } = string.Empty;
    public string  DenialCode           { get; init; } = string.Empty;
    public decimal ChargeAmount         { get; init; }
    public decimal AllowedAmount        { get; init; }
    public decimal InsurancePayment     { get; init; }
    public decimal InsuranceAdjustments { get; init; }
    public decimal PatientAdjustments   { get; init; }
    public decimal TotalPayments        { get; init; }
    public decimal InsuranceBalance     { get; init; }
    public decimal TotalBalance         { get; init; }
    public decimal TotalAdjustments     { get; init; }
}

