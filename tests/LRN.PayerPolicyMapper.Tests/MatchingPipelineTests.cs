using LRN.PayerPolicyMapper.Core;
using Xunit;

namespace LRN.PayerPolicyMapper.Tests;

/// <summary>
/// The 12 required behavior tests. Each encodes validated real behavior from the
/// walkthrough documents (v1.0 batch 1 + v2.0 batch 2) run against Payer Policy Master v1.9.
/// </summary>
public sealed class MatchingPipelineTests
{
    private static (MatchingPipeline Pipeline, InMemoryLabRepository Lab, InMemoryAuditRepository Audit, CountingNotificationService Notify)
        CreatePipeline(PayerPolicyIndex? index = null)
    {
        var lab = new InMemoryLabRepository();
        var audit = new InMemoryAuditRepository();
        var notify = new CountingNotificationService();
        var pipeline = new MatchingPipeline(new StaticIndexProvider(index ?? TestIndex.Build()), lab, audit, notify, new MatchingOptions());
        return (pipeline, lab, audit, notify);
    }

    private static LabInsuranceRow Row(int id, string name, string? labStateCode = null, string? planType = null, string? labState = null)
        => new() { LabInsuranceMasterId = id, PayerNameRaw = name, LabStateCode = labStateCode, LabState = labState, PlanType = planType };

    // 1. "Aetna" (lab TX) -> family Aetna, score 100, AutoMap
    [Fact]
    public void Aetna_TexasLab_AutoMapsAt100()
    {
        var (pipeline, _, _, _) = CreatePipeline();
        var result = pipeline.Evaluate(Row(1, "Aetna", "TX"), TestIndex.Build());

        Assert.Equal("AETNA", result.Context.CandidateFamily);
        Assert.Equal(MatchDecision.AutoMap, result.Decision);
        Assert.Equal(100m, result.ConfidenceScore);
        Assert.Equal(1001, result.SelectedGlobalPayerId);
    }

    // 2. "AETNA - CHOICE (POS II)" -> 1B strips to "AETNA CHOICE", final >= 95 AutoMap;
    //    PayerNameNormalized = "AETNA CHOICE" (real impact: 93.8 -> 96.3, crossing auto-map)
    [Fact]
    public async Task AetnaChoicePosII_StripsPlanCodes_AutoMaps()
    {
        var (pipeline, lab, _, _) = CreatePipeline();
        var row = Row(2, "AETNA - CHOICE (POS II)");
        lab.Add(row);

        var result = await pipeline.EvaluateAndPersistAsync(row, "Evaluate", CancellationToken.None);

        Assert.Equal("AETNA CHOICE", result.Context.CanonicalName);
        Assert.True(result.ConfidenceScore >= 95m, $"expected >= 95, got {result.ConfidenceScore}");
        Assert.Equal(MatchDecision.AutoMap, result.Decision);
        Assert.Equal("AETNA CHOICE", lab.Rows[2].PayerNameNormalized);
        Assert.Equal("Mapped", lab.Rows[2].MappingStatus);
        Assert.Equal(MatchingPipeline.SystemAutoMatch, lab.Rows[2].MappedBy);
    }

    // 3. Bare "Ambetter", no lab state -> 5-way tie at 100, StateSignalSource None -> ManualReview via tie-guard
    [Fact]
    public void BareAmbetter_NoStateSignal_TieGuardForcesManualReview()
    {
        var (pipeline, _, _, _) = CreatePipeline();
        var result = pipeline.Evaluate(Row(3, "Ambetter"), TestIndex.Build());

        Assert.Equal(StateSignalSource.None, result.Context.StateSignalSource);
        Assert.True(result.Candidates.Count >= 2);
        Assert.True(result.Candidates[0].Score - result.Candidates[1].Score <= 0.5m, "top-2 must tie");
        Assert.True(result.ConfidenceScore >= 95m, "the score alone would qualify for auto-map");
        Assert.Equal(MatchDecision.ManualReview, result.Decision);
        Assert.True(result.TieGuardTriggered);
    }

    // 4. "Blue Cross Blue Shield of Texas" -> dual-name scoring picks full-name 100
    //    (normalized-only "BCBS TX" would be ~52), AutoMap
    [Fact]
    public void BcbsTexas_DualNameScoring_PicksFullName_AutoMaps()
    {
        var (pipeline, _, _, _) = CreatePipeline();
        var result = pipeline.Evaluate(Row(4, "Blue Cross Blue Shield of Texas"), TestIndex.Build());

        Assert.Equal(MatchDecision.AutoMap, result.Decision);
        Assert.Equal(1059, result.SelectedGlobalPayerId);
        // the base score must come from the full raw name, not the short normalized form
        Assert.True(result.Candidates[0].BaseNameScore >= 95m, $"expected full-name base >= 95, got {result.Candidates[0].BaseNameScore}");
    }

    // 5. "Medicare Florida", no FL Medicare in master -> every candidate -20, top < 70 -> NoMatch,
    //    Remarks alert, no notification call
    [Fact]
    public async Task MedicareFlorida_NoFloridaRecord_NoMatch_RemarksAlert_NoNotification()
    {
        var (pipeline, lab, _, notify) = CreatePipeline();
        var row = Row(5, "Medicare Florida");
        lab.Add(row);

        var result = await pipeline.EvaluateAndPersistAsync(row, "Evaluate", CancellationToken.None);

        Assert.Equal("FL", result.Context.ResolvedStateCode);
        Assert.All(result.Candidates, c => Assert.Equal(-20, c.StateAdjustment));
        Assert.Equal(MatchDecision.NoMatch, result.Decision);
        Assert.Equal("No Match Found", lab.Rows[5].MappingStatus);
        Assert.Contains(MatchingPipeline.NoMatchRemark, lab.Rows[5].Remarks);
        Assert.Equal(0, notify.Count); // NoMatch is intentionally silent
    }

    // 6. "Empire Blue Cross Blue Shield" from UT lab -> Step 2 sub-step 2 -> NY,
    //    StateSignalSource = BrandMapping (NOT UT)
    [Fact]
    public void EmpireBcbs_UtahLab_BrandMappingResolvesNewYork()
    {
        var (pipeline, _, _, _) = CreatePipeline();
        var result = pipeline.Evaluate(Row(6, "Empire Blue Cross Blue Shield", "UT", labState: "Utah"), TestIndex.Build());

        Assert.Equal("NY", result.Context.ResolvedStateCode);
        Assert.Equal(StateSignalSource.BrandMapping, result.Context.StateSignalSource);
    }

    // Companion to 6: a single-word brand keyword must match whole words only - "MEDICA" (MN)
    // must never fire inside "MEDICARE" via the space-insensitive containment (real regression).
    [Fact]
    public void SingleWordBrandKeyword_DoesNotMatchInsideLongerWord()
    {
        var index = TestIndex.Build(d => d.StateBrandMappings.Add(new StateBrandMappingRow(3, "MEDICA", "MN")));
        var (pipeline, _, _, _) = CreatePipeline(index);

        var result = pipeline.Evaluate(Row(20, "AARP MEDICARE COMPLETE"), index);
        Assert.NotEqual(StateSignalSource.BrandMapping, result.Context.StateSignalSource);

        var exact = pipeline.Evaluate(Row(21, "MEDICA CHOICE PLAN"), index);
        Assert.Equal("MN", exact.Context.ResolvedStateCode);
        Assert.Equal(StateSignalSource.BrandMapping, exact.Context.StateSignalSource);
    }

    // 7. Composite alias: ("MEDICARE","IL") -> 1195 and ("MEDICARE",null) -> 1186;
    //    IL lab hits 1195, no-state hits 1186, WI lab misses the alias and falls through to scoring
    [Fact]
    public void CompositeAliasKey_StateVariantsResolveDifferently()
    {
        var (pipeline, _, _, _) = CreatePipeline();
        var index = TestIndex.Build();

        var il = pipeline.Evaluate(Row(7, "Medicare", "IL"), index);
        Assert.True(il.Context.AliasHit);
        Assert.Equal(MatchDecision.AutoMap, il.Decision);
        Assert.Equal(1195, il.SelectedGlobalPayerId);

        var noState = pipeline.Evaluate(Row(8, "Medicare"), index);
        Assert.True(noState.Context.AliasHit);
        Assert.Equal(1186, noState.SelectedGlobalPayerId);

        var wi = pipeline.Evaluate(Row(9, "Medicare", "WI"), index);
        Assert.False(wi.Context.AliasHit); // never CanonicalName alone - falls through to scoring
        Assert.NotEmpty(wi.Candidates);
    }

    // 8. Unknown brand "ZORRO HEALTH PLAN" -> CandidateFamily null -> full-master fallback, not an exception
    [Fact]
    public void UnknownBrand_NullFamily_FullMasterFallback()
    {
        var (pipeline, _, _, _) = CreatePipeline();
        var result = pipeline.Evaluate(Row(10, "ZORRO HEALTH PLAN"), TestIndex.Build());

        Assert.Null(result.Context.CandidateFamily);
        Assert.NotEmpty(result.Candidates); // scored against the full master instead of stopping
        Assert.Equal(MatchDecision.NoMatch, result.Decision);
    }

    // 9. "AETNA BETTER HEALTH OF KENTUCKY" -> family AETNA_BETTER_HEALTH (priority 10) beats AETNA (50);
    //    the candidate with NULL GlobalPayerId is suggested but capped at ManualReview with the missing-id flag
    [Fact]
    public void AetnaBetterHealthKentucky_SubBrandFamilyWins_MissingIdCandidateCappedAtReview()
    {
        var (pipeline, _, _, _) = CreatePipeline();
        var result = pipeline.Evaluate(Row(11, "AETNA BETTER HEALTH OF KENTUCKY"), TestIndex.Build());

        Assert.Equal("AETNA_BETTER_HEALTH", result.Context.CandidateFamily);
        Assert.Equal(MatchDecision.ManualReview, result.Decision);
        var top = result.Candidates[0];
        Assert.Equal("Aetna Betterhealth", top.Record.PayerNameRaw);
        Assert.True(top.MissingGlobalPayerId, "candidate has no Global Payer ID and must carry the flag");
    }

    // Companion to 9: even at a perfect score, a missing-id candidate can never AutoMap.
    [Fact]
    public void MissingGlobalPayerId_CandidateNeverAutoMaps_EvenAt100()
    {
        var index = TestIndex.Build(d =>
        {
            d.PolicyRecords.Add(new PayerPolicyRecord
            {
                PPInsuranceMasterId = 99,
                GlobalPayerId = null,
                PayerNameRaw = "Zeta Health",
                PayerFamily = "ZETA",
                PlanType = "Commercial",
                PayerState = "TX"
            });
            d.PayerFamilyRules.Add(new PayerFamilyRuleRow(99, "ZETA", "ZETA HEALTH", 10));
        });
        var (pipeline, _, _, _) = CreatePipeline(index);
        var result = pipeline.Evaluate(Row(12, "Zeta Health", "TX"), index);

        Assert.True(result.ConfidenceScore >= 95m);
        Assert.Equal(MatchDecision.ManualReview, result.Decision);
        Assert.Null(result.SelectedGlobalPayerId);
    }

    // 10. Populated LabInsuranceMaster.PlanType overrides the name-inferred program type;
    //     "DUAL COMPLETE" hits Dual (priority 5) before Medicare/Medicaid (priority 10)
    [Fact]
    public void PlanTypeOverridesNameInference_AndDualBeatsMedicareMedicaid()
    {
        var (pipeline, _, _, _) = CreatePipeline();
        var index = TestIndex.Build();

        var overridden = pipeline.Evaluate(Row(13, "Medicare Advantage Plan", planType: "Medicaid"), index);
        Assert.Equal("Medicaid", overridden.Context.ResolvedProgramType); // PlanType wins over the MEDICARE keyword

        var dual = pipeline.Evaluate(Row(14, "UHC DUAL COMPLETE MEDICARE MEDICAID"), index);
        Assert.Equal("Dual", dual.Context.ResolvedProgramType);
    }

    // 11. Concurrent claim: two workers never process the same LabInsuranceMasterId
    [Fact]
    public async Task ConcurrentClaim_NeverReturnsTheSameRowTwice()
    {
        var lab = new InMemoryLabRepository();
        for (var i = 1; i <= 100; i++) lab.Add(Row(i, $"Payer {i}"));

        var claims = await Task.WhenAll(
            Enumerable.Range(0, 4).Select(_ => Task.Run(() => lab.ClaimUnmappedBatchAsync(30, CancellationToken.None))));

        var all = claims.SelectMany(c => c.Select(r => r.LabInsuranceMasterId)).ToList();
        Assert.Equal(all.Count, all.Distinct().Count()); // no id claimed twice
        Assert.Equal(100, all.Count);                    // and nothing left behind
        Assert.Empty(await lab.ClaimUnmappedBatchAsync(30, CancellationToken.None));
    }

    // 12. Re-running AutoMap for the same (CanonicalName, state) is idempotent - exactly one PayerAlias row
    [Fact]
    public async Task RerunningAutoMap_UpsertsExactlyOneAliasRow()
    {
        var (pipeline, lab, audit, _) = CreatePipeline();
        var row = Row(15, "Aetna", "TX");
        lab.Add(row);

        await pipeline.EvaluateAndPersistAsync(row, "Evaluate", CancellationToken.None);
        lab.Rows[15].GlobalPayerId = null; // simulate a re-evaluation of the same name
        await pipeline.EvaluateAndPersistAsync(row, "Evaluate", CancellationToken.None);

        Assert.Equal(2, audit.AliasUpsertCalls);
        Assert.Single(audit.Aliases); // unique (CanonicalName, ResolvedStateCode) key - one row, not two
        Assert.Equal(1001, audit.Aliases[("AETNA", "TX")]);
    }
}
