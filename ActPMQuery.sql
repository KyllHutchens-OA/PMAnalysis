-- PM_Forecast_By_RC.sql
-- Monthly scheduled PM labor forecast grouped by RC code, Jan 2025 – Dec 2029.
--
-- Logic updated to match PM_FINAL:
--   1. estdur carried through all CTEs — used in Labor Qty × estdur calculation.
--   2. PM_Avg_Actual_Labor groups by pmnum (not jpnum) so each PM's own completed-WO
--      history is used for the actuals average rather than sharing across all PMs on
--      the same job plan.
--   3. Scheduled hours = Labor Qty × estdur (not Labor Qty alone).
--   4. No-JP PMs: estdur < 24 used directly as scheduled hours; >= 24 excluded.
--   5. Actuals join uses pmnum (consistent with PM_Avg_Actual_Labor).
--   6. JP_Labor anchored to active revision via jobplanid (prevents multi-revision inflation).
--   7. firstdate filter: draft PMs require a firstdate; active PMs with future
--      firstdates are included (occurrence-level filter handles initiation date).
--      PMs starting after 2029-12-31 excluded (outside forecast window).
--   8. Day-of-week filter: DAYS-frequency PMs only counted on active days.
--
-- Used by work_order_hours_forecast.py and work_order_bu_forecast.py to add
-- deterministic scheduled PM hours on top of the Prophet-modelled reactive forecast.
--
-- Output columns: RC | Month | Total_Forecast_Scheduled_Hrs | Total_Forecast_Avg_Actual_Hrs

WITH Numbers AS (
    -- 1–1826 covers every daily occurrence across the 5-year window (2025–2030)
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM Numbers WHERE n < 1826
),

PM_Active AS (
    -- Active/draft PMs with location and jobplan filters.
    -- firstdate logic:
    --   Active PMs: included regardless of firstdate — the occurrence-level filter
    --     (Scheduled Date >= firstdate) prevents occurrences appearing before initiation.
    --   Draft PMs: must have a firstdate set (confirms scheduled intent); drafts with
    --     no firstdate have no confirmed start and are excluded.
    --   PMs with firstdate beyond the forecast window (> 2029-12-31) are excluded —
    --     they generate no occurrences within the planning horizon.
    -- Day-of-week flags and estdur are carried through for downstream calculations.
    SELECT
        pm.[pmnum]
       ,pm.[jpnum]
       ,pm.[pmcounter]
       ,pm.[frequency]
       ,pm.[frequnit]
       ,pm.[nextdate]
       ,pm.[firstdate]
       ,pm.[estdur]
       ,pm.[sunday]
       ,pm.[monday]
       ,pm.[tuesday]
       ,pm.[wednesday]
       ,pm.[thursday]
       ,pm.[friday]
       ,pm.[saturday]
    FROM [EDS].[MAXIMO].[PM] pm
    JOIN [EDS].[MAXIMO].[Locations] loc
      ON pm.[location] = loc.[location]
    LEFT JOIN [EDS].[MAXIMO].[Jobplan] jp
      ON pm.[jpnum] = jp.[jpnum]
    WHERE pm.[status] IN ('active', 'draft')
      AND (jp.[status] = 'active' OR jp.[status] IS NULL)
      AND loc.[location] NOT IN ('TWESLOC')
      AND loc.[status]   NOT IN ('PLANNED', 'REMOVED', 'SOLD')
      AND pm.[nextdate]  IS NOT NULL
      AND pm.[frequency] >  0
      AND pm.[worktype]  IN ('PM', 'OP')
      AND (pm.[status] = 'active' OR pm.[firstdate] IS NOT NULL)
      AND (pm.[firstdate] IS NULL OR pm.[firstdate] <= '2029-12-31')
),

JP_Labor AS (
    -- Estimated labor quantity per job plan joined through jobplanid to the
    -- active revision only, preventing multi-revision jpnums inflating the sum.
    SELECT
        jp.[jpnum]
       ,SUM(jl.[quantity]) AS [Labor Qty]
    FROM [EDS].[MAXIMO].[Jobplan] jp
    JOIN [EDS].[MAXIMO].[JOBLABOR] jl ON jl.[jobplanid] = jp.[jobplanid]
    WHERE jp.[status] = 'active'
    GROUP BY jp.[jpnum]
),

PM_Avg_Actual_Labor AS (
    -- Average actual labor hours per PM derived from LABTRANS history.
    -- Sums regularhrs + overtime tiers per WO, then averages across all
    -- completed WOs linked back to a pmnum.
    -- Grouped by pmnum so averages reflect each PM's own history, not a shared JP.
    SELECT
        wo.[pmnum]
       ,CAST(AVG(wo_hrs.[Total_Hrs]) AS DECIMAL(18, 4)) AS [Avg Actual Labor Hrs]
    FROM (
        SELECT
            lt.[refwo]
           ,SUM(lt.[regularhrs] + lt.[ot15] + lt.[ot20] + lt.[ot25]) AS [Total_Hrs]
        FROM [EDS].[MAXIMO].[LABTRANS] lt
        WHERE lt.[transtype] = 'WORK'
          AND lt.[transdate] >= '2021-01-01'
        GROUP BY lt.[refwo]
    ) wo_hrs
    JOIN [EDS].[MAXIMO].[Workorder] wo
      ON wo.[wonum]    = wo_hrs.[refwo]
    WHERE wo.[pmnum]     IS NOT NULL
      AND wo.[status]   IN ('COMP', 'CLOSE', 'WCLOSE')
      AND wo.[worktype] IN ('PM', 'OP')
    GROUP BY wo.[pmnum]
),

PM_Window_Entry AS (
    SELECT
        p.[pmnum]
       ,p.[jpnum]
       ,p.[pmcounter]
       ,p.[frequency]
       ,p.[frequnit]
       ,p.[nextdate]
       ,p.[firstdate]
       ,p.[estdur]
       ,p.[sunday]
       ,p.[monday]
       ,p.[tuesday]
       ,p.[wednesday]
       ,p.[thursday]
       ,p.[friday]
       ,p.[saturday]
       ,CAST(
            CASE
                WHEN p.[nextdate] >= '2025-01-01' THEN
                    -FLOOR(
                        CASE p.[frequnit]
                            WHEN 'DAYS'   THEN DATEDIFF(DAY,   '2025-01-01', p.[nextdate]) * 1.0 / p.[frequency]
                            WHEN 'WEEKS'  THEN DATEDIFF(WEEK,  '2025-01-01', p.[nextdate]) * 1.0 / p.[frequency]
                            WHEN 'MONTHS' THEN DATEDIFF(MONTH, '2025-01-01', p.[nextdate]) * 1.0 / p.[frequency]
                            WHEN 'YEARS'  THEN DATEDIFF(YEAR,  '2025-01-01', p.[nextdate]) * 1.0 / p.[frequency]
                        END
                    )
                ELSE
                    CEILING(
                        CASE p.[frequnit]
                            WHEN 'DAYS'   THEN DATEDIFF(DAY,   p.[nextdate], '2025-01-01') * 1.0 / p.[frequency]
                            WHEN 'WEEKS'  THEN DATEDIFF(WEEK,  p.[nextdate], '2025-01-01') * 1.0 / p.[frequency]
                            WHEN 'MONTHS' THEN DATEDIFF(MONTH, p.[nextdate], '2025-01-01') * 1.0 / p.[frequency]
                            WHEN 'YEARS'  THEN DATEDIFF(YEAR,  p.[nextdate], '2025-01-01') * 1.0 / p.[frequency]
                        END
                    )
            END
        AS INT) AS [Offset]
    FROM PM_Active p
),

PM_First_In_Window AS (
    SELECT
        pw.[pmnum]
       ,pw.[jpnum]
       ,pw.[pmcounter] + pw.[Offset]  AS [Base_Counter]
       ,pw.[frequency]
       ,pw.[frequnit]
       ,pw.[firstdate]
       ,pw.[estdur]
       ,pw.[sunday]
       ,pw.[monday]
       ,pw.[tuesday]
       ,pw.[wednesday]
       ,pw.[thursday]
       ,pw.[friday]
       ,pw.[saturday]
       ,CASE pw.[frequnit]
            WHEN 'DAYS'   THEN DATEADD(DAY,   pw.[frequency] * pw.[Offset], pw.[nextdate])
            WHEN 'WEEKS'  THEN DATEADD(WEEK,  pw.[frequency] * pw.[Offset], pw.[nextdate])
            WHEN 'MONTHS' THEN DATEADD(MONTH, pw.[frequency] * pw.[Offset], pw.[nextdate])
            WHEN 'YEARS'  THEN DATEADD(YEAR,  pw.[frequency] * pw.[Offset], pw.[nextdate])
        END AS [First_Date]
    FROM PM_Window_Entry pw
),

PM_Scheduled_Occurrences AS (
    SELECT
        sub.[pmnum]
       ,sub.[Counter]
       ,sub.[Default JP]
       ,sub.[estdur]
       ,sub.[Scheduled Date]
    FROM (
        SELECT
            fw.[pmnum]
           ,fw.[Base_Counter] + num.n          AS [Counter]
           ,fw.[jpnum]                         AS [Default JP]
           ,fw.[estdur]
           ,fw.[firstdate]
           ,fw.[frequnit]
           ,fw.[sunday]
           ,fw.[monday]
           ,fw.[tuesday]
           ,fw.[wednesday]
           ,fw.[thursday]
           ,fw.[friday]
           ,fw.[saturday]
           ,CASE fw.[frequnit]
                WHEN 'DAYS'   THEN DATEADD(DAY,   fw.[frequency] * (num.n - 1), fw.[First_Date])
                WHEN 'WEEKS'  THEN DATEADD(WEEK,  fw.[frequency] * (num.n - 1), fw.[First_Date])
                WHEN 'MONTHS' THEN DATEADD(MONTH, fw.[frequency] * (num.n - 1), fw.[First_Date])
                WHEN 'YEARS'  THEN DATEADD(YEAR,  fw.[frequency] * (num.n - 1), fw.[First_Date])
            END                                AS [Scheduled Date]
        FROM PM_First_In_Window fw
        JOIN Numbers num
          ON num.n <= CASE fw.[frequnit]
                WHEN 'DAYS'   THEN CEILING(DATEDIFF(DAY,   fw.[First_Date], '2030-01-01') * 1.0 / fw.[frequency])
                WHEN 'WEEKS'  THEN CEILING(DATEDIFF(WEEK,  fw.[First_Date], '2030-01-01') * 1.0 / fw.[frequency])
                WHEN 'MONTHS' THEN CEILING(DATEDIFF(MONTH, fw.[First_Date], '2030-01-01') * 1.0 / fw.[frequency])
                WHEN 'YEARS'  THEN CEILING(DATEDIFF(YEAR,  fw.[First_Date], '2030-01-01') * 1.0 / fw.[frequency])
             END
        WHERE fw.[First_Date] IS NOT NULL
    ) sub
    WHERE sub.[Scheduled Date] >= '2025-01-01'
      AND sub.[Scheduled Date] <  '2030-01-01'
      -- exclude occurrences before the PM was first initiated
      -- (PMs with NULL firstdate are treated as always initiated)
      AND (sub.[firstdate] IS NULL OR sub.[Scheduled Date] >= sub.[firstdate])
      -- for DAYS frequency, only include days matching the active day-of-week flags
      AND (
          sub.[frequnit] != 'DAYS'
          OR (
              (ISNULL(sub.[sunday],    0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled Date]) = 1)
           OR (ISNULL(sub.[monday],    0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled Date]) = 2)
           OR (ISNULL(sub.[tuesday],   0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled Date]) = 3)
           OR (ISNULL(sub.[wednesday], 0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled Date]) = 4)
           OR (ISNULL(sub.[thursday],  0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled Date]) = 5)
           OR (ISNULL(sub.[friday],    0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled Date]) = 6)
           OR (ISNULL(sub.[saturday],  0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled Date]) = 7)
          )
      )
),

Occurrence_Best_Seq AS (
    SELECT
        occ.[pmnum]
       ,occ.[Counter]
       ,MAX(seq.[interval])    AS [Best Interval]
    FROM PM_Scheduled_Occurrences occ
    JOIN [EDS].[MAXIMO].[PMSequence] seq
      ON seq.[pmnum] = occ.[pmnum]
     AND occ.[Counter] % seq.[interval] = 0
    GROUP BY occ.[pmnum], occ.[Counter]
),

Occurrence_Seq_JP AS (
    SELECT
        obs.[pmnum]
       ,obs.[Counter]
       ,seq.[jpnum]            AS [Sequence JP]
    FROM Occurrence_Best_Seq obs
    JOIN [EDS].[MAXIMO].[PMSequence] seq
      ON seq.[pmnum]    = obs.[pmnum]
     AND seq.[interval] = obs.[Best Interval]
)

SELECT
    pm_rc.[rcglsegment]                                                          AS [RC]
   ,DATEFROMPARTS(YEAR(occ.[Scheduled Date]), MONTH(occ.[Scheduled Date]), 1)   AS [Month]
   ,SUM(
        CASE
            -- PM has a JP with labor lines: Labor Qty × estdur
            WHEN jlab.[Labor Qty] IS NOT NULL
                THEN jlab.[Labor Qty] * ISNULL(occ.[estdur], 0)
            -- PM has no JP: use estdur directly if < 24 hrs (single-person task)
            WHEN occ.[Default JP] IS NULL AND ISNULL(occ.[estdur], 0) > 0
                 AND occ.[estdur] < 24
                THEN occ.[estdur]
            ELSE 0
        END
    )                                                                            AS [Total_Forecast_Scheduled_Hrs]
   ,SUM(
        CASE
            -- Actual history exists for this PM: use it
            WHEN jact.[Avg Actual Labor Hrs] IS NOT NULL
                THEN jact.[Avg Actual Labor Hrs]
            -- No actual history: fall back to scheduled calculation
            WHEN jlab.[Labor Qty] IS NOT NULL
                THEN jlab.[Labor Qty] * ISNULL(occ.[estdur], 0)
            WHEN occ.[Default JP] IS NULL AND ISNULL(occ.[estdur], 0) > 0
                 AND occ.[estdur] < 24
                THEN occ.[estdur]
            ELSE 0
        END
    )                                                                            AS [Total_Forecast_Avg_Actual_Hrs]
FROM PM_Scheduled_Occurrences occ
JOIN [EDS].[MAXIMO].[PM] pm_rc
  ON pm_rc.[pmnum] = occ.[pmnum]
LEFT JOIN Occurrence_Seq_JP sjp
       ON sjp.[pmnum]   = occ.[pmnum]
      AND sjp.[Counter] = occ.[Counter]
LEFT JOIN JP_Labor jlab
       ON jlab.[jpnum] = ISNULL(sjp.[Sequence JP], occ.[Default JP])
LEFT JOIN PM_Avg_Actual_Labor jact
       ON jact.[pmnum] = occ.[pmnum]
GROUP BY
    pm_rc.[rcglsegment]
   ,DATEFROMPARTS(YEAR(occ.[Scheduled Date]), MONTH(occ.[Scheduled Date]), 1)
ORDER BY
    [RC]
   ,[Month]
OPTION (MAXRECURSION 1826);
