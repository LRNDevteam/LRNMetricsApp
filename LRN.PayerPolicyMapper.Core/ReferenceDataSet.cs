namespace LRN.PayerPolicyMapper.Core;

/// <summary>Raw reference rows loaded from LRNMaster; input to PayerPolicyIndex.Build.</summary>
public sealed class ReferenceDataSet
{
    public List<UsState> States { get; init; } = new();
    public List<string> PlanNetworkTypeCodes { get; init; } = new();
    public List<StateBrandMappingRow> StateBrandMappings { get; init; } = new();
    public List<ProgramTypeRuleRow> ProgramTypeRules { get; init; } = new();
    public List<PayerFamilyRuleRow> PayerFamilyRules { get; init; } = new();
    public List<PayerAliasRow> Aliases { get; init; } = new();
    public List<PayerPolicyRecord> PolicyRecords { get; init; } = new();
}

public sealed record UsState(string StateCode, string StateName);

public sealed record StateBrandMappingRow(int MappingId, string BrandKeyword, string? StateCode);

public sealed record ProgramTypeRuleRow(int RuleId, string ProgramType, string? Pattern, int Priority);

public sealed record PayerFamilyRuleRow(int RuleId, string Family, string Pattern, int Priority);

public sealed record PayerAliasRow(string CanonicalName, string? ResolvedStateCode, int GlobalPayerId);
