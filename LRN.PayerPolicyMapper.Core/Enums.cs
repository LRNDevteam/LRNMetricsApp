namespace LRN.PayerPolicyMapper.Core;

/// <summary>Where the resolved state signal came from (Step 2). Order reflects trust.</summary>
public enum StateSignalSource
{
    None,
    NameEmbedded,
    BrandMapping,
    LabState
}

/// <summary>Final decision of the matching pipeline (Step 8).</summary>
public enum MatchDecision
{
    AutoMap,
    ManualReview,
    NoMatch
}

/// <summary>
/// Which Lab Insurance Master rows a service run covers.
///  - UnmappedPending: rows still waiting for a first evaluation or pending review
///    (scheduled hourly runs - never re-grinds No Match Found rows every hour).
///  - AllUnmapped: every row without a Global Payer ID, including No Match Found
///    (rules-change and nightly runs - this is what rescues previous No Match rows).
///  - All: every record regardless of status (manual full scan). Mapped rows are
///    REVALIDATED (audit-only) - an automated run never overwrites a confirmed mapping.
/// </summary>
public enum RunScope
{
    UnmappedPending,
    AllUnmapped,
    All
}
