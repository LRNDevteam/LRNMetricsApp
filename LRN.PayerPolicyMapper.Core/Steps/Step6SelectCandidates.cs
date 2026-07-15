namespace LRN.PayerPolicyMapper.Core.Steps;

/// <summary>
/// Step 6 - candidate pool: rows whose PayerPolicyInsuranceMaster.PayerFamily matches the
/// CandidateFamily when one was classified; otherwise (or when the family bucket is empty)
/// every active row - the full-master fallback that keeps unknown brands matchable.
/// </summary>
public static class Step6SelectCandidates
{
    public static IReadOnlyList<PayerPolicyRecord> Run(MatchContext context, PayerPolicyIndex index)
    {
        var familyKey = PayerPolicyIndex.FamilyKey(context.CandidateFamily);
        if (familyKey != null && index.PolicyRecordsByFamily.TryGetValue(familyKey, out var bucket) && bucket.Count > 0)
            return bucket;
        return index.PolicyRecords;
    }
}
