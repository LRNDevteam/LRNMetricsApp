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
