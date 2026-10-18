/*==============================================================================
  PATCH for usp_RefreshBT_ExecutiveSummary : the 'V' Fully Adjusted logic.

  Fully Adjusted = #Base rows where BillStatus='Billed' AND ClaimStatus='Complete W/O'
  (in #Base, BillStatus is the aliased BilledUnbilled column.)

  Two blocks change. Both now:
    * apply the write-off filter explicitly, and
    * use EXISTS against #Base instead of INNER JOIN, so a ClaimID that appears
      on multiple #Base rows (multiple service dates) is NOT double-counted.
  Result: parent V == SUM of its V.n children, and with the v3 BTWOSummary each
  equals the distinct write-off claim count.
==============================================================================*/


/*==============================================================================
  BLOCK 1  --  replace the existing  "-- V  Fully Adjusted ..."  UNION ALL block
             inside the BeechTree_ES_PMS insert  WITH THIS:
==============================================================================*/
        -- V  Fully Adjusted – SUM(MatchingCount) from BTWOSummary, restricted to
        --    write-off claims (BillStatus='Billed' AND ClaimStatus='Complete W/O').
        --    EXISTS avoids fan-out when a ClaimID spans multiple #Base rows.
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'V', 'Fully Adjusted',
               ISNULL(SUM(ws.MatchingCount), 0)
        FROM #Periods p
        LEFT JOIN (
            SELECT
                ws2.MatchingCount,
                YEAR (TRY_CAST(ws2.DateofService AS DATE)) AS WOYear,
                MONTH(TRY_CAST(ws2.DateofService AS DATE)) AS WOMonth
            FROM   dbo.BTWOSummary ws2
            WHERE  TRY_CAST(ws2.DateofService AS DATE) IS NOT NULL
              AND  EXISTS (
                    SELECT 1
                    FROM   #Base b
                    WHERE  LTRIM(RTRIM(CAST(b.ClaimID   AS NVARCHAR(50))))
                         = LTRIM(RTRIM(CAST(ws2.ClaimID AS NVARCHAR(50))))
                      AND  b.BillStatus  = 'Billed'
                      AND  b.ClaimStatus = 'Complete W/O'
              )
        ) ws ON (p.ESYear = 0 OR (ws.WOYear = p.ESYear AND ws.WOMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth


/*==============================================================================
  BLOCK 2  --  replace the ENTIRE  "V.n Fully Adjusted sub-rows"  INSERT
             (the second INSERT INTO dbo.BeechTree_ES_PMS ... FROM (...) agg;)
             WITH THIS:
==============================================================================*/
    INSERT INTO dbo.BeechTree_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT
        'V.' + CAST(ROW_NUMBER() OVER (PARTITION BY agg.ESYear, agg.ESMonth
                                       ORDER BY agg.MatchingCount DESC, agg.TransactionCodeCombined
                                      ) AS NVARCHAR(10)) AS RoleID,
        '  ' + agg.TransactionCodeCombined              AS Description,
        agg.ESYear,
        agg.ESMonth,
        agg.MatchingCount                               AS ESMonthClaimCount,
        0                                               AS ESMonthChargeAmount,
        GETDATE()                                       AS RefreshedAt
    FROM (
        SELECT
            p.ESYear,
            p.ESMonth,
            ws.TransactionCodeCombined,
            SUM(ws.MatchingCount) AS MatchingCount
        FROM #Periods p
        JOIN (
            SELECT
                ws2.TransactionCodeCombined,
                ws2.MatchingCount,
                YEAR (TRY_CAST(ws2.DateofService AS DATE)) AS WOYear,
                MONTH(TRY_CAST(ws2.DateofService AS DATE)) AS WOMonth
            FROM   dbo.BTWOSummary ws2
            WHERE  ws2.TransactionCodeCombined IS NOT NULL
              AND  TRY_CAST(ws2.DateofService AS DATE) IS NOT NULL
              AND  EXISTS (
                    SELECT 1
                    FROM   #Base b
                    WHERE  LTRIM(RTRIM(CAST(b.ClaimID   AS NVARCHAR(50))))
                         = LTRIM(RTRIM(CAST(ws2.ClaimID AS NVARCHAR(50))))
                      AND  b.BillStatus  = 'Billed'
                      AND  b.ClaimStatus = 'Complete W/O'
              )
        ) ws ON (p.ESYear = 0 OR (ws.WOYear = p.ESYear AND ws.WOMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, ws.TransactionCodeCombined
    ) agg;
