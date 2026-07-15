using LRN.PayerPolicyMapper.Core;

namespace LRN.PayerPolicyMapper.Tests;

/// <summary>
/// In-memory Step 0 index stub mirroring the deployed reference seed data
/// (Payer_Matching_Reference_Tables_DDL_and_Seed.sql) and the walkthrough's
/// Payer Policy Insurance Master rows. The tests encode validated real behavior.
/// </summary>
public static class TestIndex
{
    public static PayerPolicyIndex Build(Action<ReferenceDataSet>? customize = null)
    {
        var data = new ReferenceDataSet
        {
            States =
            {
                new("AL", "Alabama"), new("AK", "Alaska"), new("AZ", "Arizona"), new("AR", "Arkansas"),
                new("CA", "California"), new("CO", "Colorado"), new("CT", "Connecticut"), new("DE", "Delaware"),
                new("FL", "Florida"), new("GA", "Georgia"), new("HI", "Hawaii"), new("ID", "Idaho"),
                new("IL", "Illinois"), new("IN", "Indiana"), new("IA", "Iowa"), new("KS", "Kansas"),
                new("KY", "Kentucky"), new("LA", "Louisiana"), new("ME", "Maine"), new("MD", "Maryland"),
                new("MA", "Massachusetts"), new("MI", "Michigan"), new("MN", "Minnesota"), new("MS", "Mississippi"),
                new("MO", "Missouri"), new("MT", "Montana"), new("NE", "Nebraska"), new("NV", "Nevada"),
                new("NH", "New Hampshire"), new("NJ", "New Jersey"), new("NM", "New Mexico"), new("NY", "New York"),
                new("NC", "North Carolina"), new("ND", "North Dakota"), new("OH", "Ohio"), new("OK", "Oklahoma"),
                new("OR", "Oregon"), new("PA", "Pennsylvania"), new("RI", "Rhode Island"), new("SC", "South Carolina"),
                new("SD", "South Dakota"), new("TN", "Tennessee"), new("TX", "Texas"), new("UT", "Utah"),
                new("VT", "Vermont"), new("VA", "Virginia"), new("WA", "Washington"), new("WV", "West Virginia"),
                new("WI", "Wisconsin"), new("WY", "Wyoming"), new("DC", "District of Columbia")
            },
            PlanNetworkTypeCodes = { "POS II", "HDHP/HSA", "PPO", "HMO", "EPO", "POS", "HDHP", "HSA", "CDHP", "FFS", "ACO", "SNP", "PFFS" },
            StateBrandMappings =
            {
                new(1, "EMPIRE BLUECROSS", "NY"),
                new(2, "HEALTH FIRST HEALTH PLANS", null) // state must come from raw name or manual review
            },
            ProgramTypeRules =
            {
                new(1, "Dual", @"\bDUAL\b|\bDUAL COMPLETE\b|\bDUAL ELIGIBLE\b|\bMMAI\b|\bMMP\b|\bD-SNP\b|\bDSNP\b", 5),
                new(2, "Medicare", @"\bRAILROAD MEDICARE\b|\bRRB\b|\bPALMETTO GBA\b", 8),
                new(3, "Medicaid", @"\bMEDICAID\b|\bIDPA\b|\bBETTER HEALTH\b|\bMANAGED MEDICAID\b|\bCHIP\b", 10),
                new(4, "Medicare", @"\bMEDICARE\b|\bMEDICARE ADVANTAGE\b|\bHEALTHSPRING\b|\bAARP\b|\bALLWELL\b|\bSNP\b|\bPFFS\b|\bMEDIGAP\b|\bMEDICARE SUPPLEMENT\b|\bPART D\b|\bPDP\b", 10),
                new(5, "Exchange", @"\bMARKETPLACE\b|\bEXCHANGE\b|\bQHP\b|\bON EXCHANGE\b|\bOFF EXCHANGE\b|\bAMBETTER\b", 20),
                new(6, "Federal", @"\bFEP\b|\bFEPBLUE\b|\bFEDERAL EMPLOYEE\b|\bFEHB\b|\bTRICARE\b|\bCHAMPVA\b|\bCHAMPUS\b|\bHUMANA MILITARY\b|\bGEHA\b", 20),
                new(7, "Commercial", null, 999)
            },
            PayerFamilyRules =
            {
                new(1, "AETNA_BETTER_HEALTH", "AETNA BETTER HEALTH|AETNA BETTER HEATH|BETTER HEALTH", 10),
                new(2, "PALMETTO_GBA", "RAILROAD MEDICARE|MEDICARE RAILROAD|PALMETTO GBA", 10),
                new(3, "AETNA", "AETNA", 50),
                new(4, "AMBETTER", "AMBETTER", 50),
                new(5, "MEDICARE", "MEDICARE", 50),
                new(6, "MEDICAID", "MEDICAID", 50),
                new(7, "UHC", "UNITED HEALTH CARE|UNITEDHEALTHCARE|UHC|AARP", 50),
                new(8, "BCBS", "BCBS|BLUE CROSS|BLUE SHIELD|BLUECROSS|BLUESHIELD", 900)
            },
            Aliases =
            {
                new("MEDICARE", "IL", 1195),
                new("MEDICARE", null, 1186)
            },
            PolicyRecords =
            {
                Policy(1, 1001, "Aetna", null, "AETNA", "Commercial", null),
                Policy(2, null, "Aetna Betterhealth", null, "AETNA_BETTER_HEALTH", "Medicaid", null),
                Policy(3, 1002, "Ambetter", "Ambetter", "AMBETTER", "Exchange", null),
                Policy(4, 1003, "Ambetter of Alabama", "Ambetter", "AMBETTER", "Exchange", "AL"),
                Policy(5, 1004, "Ambetter of Arkansas", "Ambetter", "AMBETTER", "Exchange", "AR"),
                Policy(6, 1005, "Ambetter of New Hampshire", "Ambetter", "AMBETTER", "Exchange", "NH"),
                Policy(7, 1006, "Ambetter of Tennessee", "Ambetter", "AMBETTER", "Exchange", "TN"),
                Policy(8, 1059, "Blue Cross Blue Shield of Texas", "BCBS TX", "BCBS", "Commercial", "TX"),
                Policy(9, 1060, "Blue Cross Blue Shield of Tennessee", "BCBS TN", "BCBS", "Commercial", "TN"),
                Policy(10, 1107, "Medicare AK", "Medicare AK", "MEDICARE", "Medicare", "AK"),
                Policy(11, 1108, "Medicare Georgia", "Medicare GA", "MEDICARE", "Medicare", "GA"),
                Policy(12, 1186, "Medicare Mississippi", "Medicare MS", "MEDICARE", "Medicare", "MS"),
                Policy(13, 1195, "Medicare Illinois", "Medicare IL", "MEDICARE", "Medicare", "IL")
            }
        };
        customize?.Invoke(data);
        return PayerPolicyIndex.Build(data);
    }

    private static PayerPolicyRecord Policy(int id, int? gid, string raw, string? normalized, string family, string? planType, string? state) => new()
    {
        PPInsuranceMasterId = id,
        GlobalPayerId = gid,
        PayerNameRaw = raw,
        PayerNameNormalized = normalized,
        PayerFamily = family,
        PlanType = planType,
        PayerState = state
    };
}
