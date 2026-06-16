-- futurepmsql.sql
-- One row per scheduled PM occurrence. Window: today → 2029-12-31.
-- Scheduling logic identical to PM_Forecast_By_RC.sql.
-- Column prefixes:
--   PM_       — data from the PM record itself
--   JP_       — data from the job plan / joblabor
--   Forecast_ — calculated forward-looking metrics

WITH Numbers AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM Numbers WHERE n < 1826
),

PM_Active AS (
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
    WHERE pm.[status]   IN ('active', 'draft')
      AND (jp.[status] = 'active' OR jp.[status] IS NULL)
      AND loc.[location] NOT IN ('TWESLOC')
      AND loc.[status]   NOT IN ('PLANNED', 'REMOVED', 'SOLD')
      AND pm.[nextdate]  IS NOT NULL
      AND pm.[frequency] > 0
      AND pm.[worktype]  IN ('PM', 'OP')
      AND (pm.[status] = 'active' OR pm.[firstdate] IS NOT NULL)
      AND (pm.[firstdate] IS NULL OR pm.[firstdate] <= '2029-12-31')
),

-- Step 1: collapse multiple lines of the same craft within a job plan into one row.
-- e.g. two EF lines of 1.0 each → EF with Total_Qty 2.0
JP_Labor_By_Craft AS (
    SELECT
        jl.[jobplanid]
       ,jl.[craft]
       ,SUM(jl.[quantity]) AS [Total_Qty]
    FROM [EDS].[MAXIMO].[JOBLABOR] jl
    GROUP BY jl.[jobplanid], jl.[craft]
),

-- Step 2: rank unique crafts per job plan by aggregated quantity.
JP_Labor_Ranked AS (
    SELECT
        [jobplanid]
       ,[craft]
       ,[Total_Qty]
       ,ROW_NUMBER() OVER (
            PARTITION BY [jobplanid]
            ORDER BY [Total_Qty] DESC
        ) AS [rn]
    FROM JP_Labor_By_Craft
),

-- Step 3: total headcount, primary craft, and unique craft list per active job plan.
-- Anchored to jobplanid to prevent multi-revision inflation.
JP_Labor AS (
    SELECT
        jp.[jpnum]
       ,SUM(jlr.[Total_Qty])                                    AS [Labor_Qty]
       ,MAX(CASE WHEN jlr.[rn] = 1 THEN jlr.[craft] END)        AS [Primary_Craft]
       ,STRING_AGG(
            ISNULL(jlr.[craft], 'UNSPECIFIED'), ' | '
        ) WITHIN GROUP (ORDER BY jlr.[Total_Qty] DESC)           AS [Crafts_Required]
    FROM [EDS].[MAXIMO].[Jobplan] jp
    JOIN JP_Labor_Ranked jlr ON jlr.[jobplanid] = jp.[jobplanid]
    WHERE jp.[status] = 'active'
    GROUP BY jp.[jpnum]
),

-- Average actual labor hours per PM from completed work order history.
-- Matches the logic used by PM_Forecast_By_RC.sql / the Python pipeline.
-- NULL when a PM has never been completed.
PM_Avg_Actual_Labor AS (
    SELECT
        wo.[pmnum]
       ,CAST(AVG(wo_hrs.[Total_Hrs]) AS DECIMAL(18, 4)) AS [Avg_Actual_Labor_Hrs]
    FROM (
        SELECT
            lt.[refwo]
           ,SUM(lt.[regularhrs] + lt.[ot15] + lt.[ot20] + lt.[ot25]) AS [Total_Hrs]
        FROM [EDS].[MAXIMO].[LABTRANS] lt
        WHERE lt.[transtype] = 'WORK'
          AND lt.[transdate] >= '2024-01-01'
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
        p.[pmnum], p.[jpnum], p.[pmcounter], p.[frequency], p.[frequnit],
        p.[nextdate], p.[firstdate], p.[estdur],
        p.[sunday], p.[monday], p.[tuesday], p.[wednesday],
        p.[thursday], p.[friday], p.[saturday],
        CAST(
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
        pw.[pmnum], pw.[jpnum], pw.[pmcounter] + pw.[Offset] AS [Base_Counter],
        pw.[frequency], pw.[frequnit], pw.[firstdate], pw.[estdur],
        pw.[sunday], pw.[monday], pw.[tuesday], pw.[wednesday],
        pw.[thursday], pw.[friday], pw.[saturday],
        CASE pw.[frequnit]
            WHEN 'DAYS'   THEN DATEADD(DAY,   pw.[frequency] * pw.[Offset], pw.[nextdate])
            WHEN 'WEEKS'  THEN DATEADD(WEEK,  pw.[frequency] * pw.[Offset], pw.[nextdate])
            WHEN 'MONTHS' THEN DATEADD(MONTH, pw.[frequency] * pw.[Offset], pw.[nextdate])
            WHEN 'YEARS'  THEN DATEADD(YEAR,  pw.[frequency] * pw.[Offset], pw.[nextdate])
        END AS [First_Date]
    FROM PM_Window_Entry pw
),

PM_Scheduled_Occurrences AS (
    SELECT
        sub.[pmnum], sub.[Counter], sub.[Default_JP],
        sub.[estdur], sub.[Scheduled_Date], sub.[frequnit],
        sub.[sunday], sub.[monday], sub.[tuesday], sub.[wednesday],
        sub.[thursday], sub.[friday], sub.[saturday], sub.[firstdate]
    FROM (
        SELECT
            fw.[pmnum]
           ,fw.[Base_Counter] + num.n                        AS [Counter]
           ,fw.[jpnum]                                       AS [Default_JP]
           ,fw.[estdur]
           ,fw.[firstdate]
           ,fw.[frequnit]
           ,fw.[sunday], fw.[monday], fw.[tuesday], fw.[wednesday]
           ,fw.[thursday], fw.[friday], fw.[saturday]
           ,CASE fw.[frequnit]
                WHEN 'DAYS'   THEN DATEADD(DAY,   fw.[frequency] * (num.n - 1), fw.[First_Date])
                WHEN 'WEEKS'  THEN DATEADD(WEEK,  fw.[frequency] * (num.n - 1), fw.[First_Date])
                WHEN 'MONTHS' THEN DATEADD(MONTH, fw.[frequency] * (num.n - 1), fw.[First_Date])
                WHEN 'YEARS'  THEN DATEADD(YEAR,  fw.[frequency] * (num.n - 1), fw.[First_Date])
            END AS [Scheduled_Date]
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
    -- '2025-01-01' above is the scheduling math anchor only (same as Python pipeline).
    -- Output is filtered from today forward.
    WHERE sub.[Scheduled_Date] >= CAST(GETDATE() AS DATE)
      AND sub.[Scheduled_Date] <  '2030-01-01'
      AND (sub.[firstdate] IS NULL OR sub.[Scheduled_Date] >= sub.[firstdate])
      AND (
          sub.[frequnit] != 'DAYS'
          OR (
              (ISNULL(sub.[sunday],    0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled_Date]) = 1)
           OR (ISNULL(sub.[monday],    0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled_Date]) = 2)
           OR (ISNULL(sub.[tuesday],   0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled_Date]) = 3)
           OR (ISNULL(sub.[wednesday], 0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled_Date]) = 4)
           OR (ISNULL(sub.[thursday],  0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled_Date]) = 5)
           OR (ISNULL(sub.[friday],    0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled_Date]) = 6)
           OR (ISNULL(sub.[saturday],  0) = 1 AND DATEPART(WEEKDAY, sub.[Scheduled_Date]) = 7)
          )
      )
),

Occurrence_Best_Seq AS (
    SELECT
        occ.[pmnum], occ.[Counter],
        MAX(seq.[interval]) AS [Best_Interval]
    FROM PM_Scheduled_Occurrences occ
    JOIN [EDS].[MAXIMO].[PMSequence] seq
      ON seq.[pmnum]          = occ.[pmnum]
     AND occ.[Counter] % seq.[interval] = 0
    GROUP BY occ.[pmnum], occ.[Counter]
),

Occurrence_Seq_JP AS (
    SELECT
        obs.[pmnum], obs.[Counter],
        seq.[jpnum] AS [Sequence_JP]
    FROM Occurrence_Best_Seq obs
    JOIN [EDS].[MAXIMO].[PMSequence] seq
      ON seq.[pmnum]    = obs.[pmnum]
     AND seq.[interval] = obs.[Best_Interval]
),

-- Resolve effective JP and compute scheduled hours per occurrence.
-- Hours always use Labor_Qty × estdur, consistent with Python pipeline
-- Total_Forecast_Scheduled_Hrs.
Occurrence_Labor AS (
    SELECT
        occ.[pmnum]
       ,occ.[Counter]
       ,occ.[Scheduled_Date]
       ,occ.[Default_JP]
       ,ISNULL(sjp.[Sequence_JP], occ.[Default_JP])       AS [Effective_JP]
       ,jlab.[Labor_Qty]                                   AS [Staff_This_Occ]
       ,jlab.[Primary_Craft]                               AS [Primary_Craft]
       ,jlab.[Crafts_Required]                             AS [Crafts_Required]
       ,obs.[Best_Interval]                                AS [Sequence_Interval]
       ,CASE
            WHEN jlab.[Labor_Qty] IS NOT NULL
                THEN jlab.[Labor_Qty] * ISNULL(occ.[estdur], 0)
            WHEN occ.[Default_JP] IS NULL
                 AND ISNULL(occ.[estdur], 0) > 0
                 AND occ.[estdur] < 24
                THEN occ.[estdur]
            ELSE 0
        END                                                AS [Scheduled_Hrs_This_Occ]
    FROM PM_Scheduled_Occurrences occ
    LEFT JOIN Occurrence_Best_Seq obs
           ON obs.[pmnum]   = occ.[pmnum]
          AND obs.[Counter] = occ.[Counter]
    LEFT JOIN Occurrence_Seq_JP sjp
           ON sjp.[pmnum]   = occ.[pmnum]
          AND sjp.[Counter] = occ.[Counter]
    LEFT JOIN JP_Labor jlab
           ON jlab.[jpnum] = ISNULL(sjp.[Sequence_JP], occ.[Default_JP])
)

SELECT
    -- ── PM record fields ──────────────────────────────────────────────
    ol.[pmnum]                                                                  AS [PM_Number]
   ,pm.[rcglsegment]                                                           AS [PM_RC]
   ,pm.[description]                                                           AS [PM_Description]
   ,pm.[location]                                                              AS [PM_Location]
   ,pm.[facility]
   ,loc.[description]                                                          AS [PM_Location_Description]
   ,pm.[worktype]                                                              AS [PM_Work_Type]
   ,CAST(pm.[frequency] AS VARCHAR(10)) + ' ' + pm.[frequnit]                 AS [PM_Schedule]
   ,pm.[estdur]                                                                AS [PM_Est_Duration_Hrs]

    -- ── Occurrence fields ─────────────────────────────────────────────
   ,ol.[Scheduled_Date]                                                        AS [Occurrence_Date]
   ,ol.[Staff_This_Occ]                                                        AS [JP_Labor_Qty]

    -- ── Job plan fields ───────────────────────────────────────────────
   ,ol.[Default_JP]                                                            AS [JP_Number]
   ,CASE WHEN ol.[Default_JP] IS NOT NULL THEN 'Yes' ELSE 'No' END            AS [JP_Has_Job_Plan]
   ,ol.[Primary_Craft]                                                         AS [JP_Primary_Craft]
   ,ol.[Crafts_Required]                                                       AS [JP_Crafts_Required]

    -- ── Effective job plan ────────────────────────────────────────────
    -- Effective_JP_Number: the JP actually used for this occurrence.
    -- Matches JP_Number on standard occurrences; differs when a PMSequence
    -- override fires (e.g. the 13th occurrence uses a major-service JP).
   ,ol.[Effective_JP]                                                          AS [Effective_JP_Number]
   ,eff_jp.[description]                                                       AS [Effective_JP_Description]

    -- ── Sequence / cycle fields ───────────────────────────────────────
    -- Sequence_Interval: the PMSequence interval that fired for this occurrence
    -- (e.g. 13 means every 13th occurrence). NULL = standard base occurrence.
   ,ol.[Sequence_Interval]                                                     AS [Sequence_Interval]
    -- Effective_PM_Schedule: combines base frequency × sequence interval so a
    -- weekly PM on its 13th occurrence shows '13 WEEKS' instead of '1 WEEKS'.
   ,CAST(pm.[frequency] * ISNULL(ol.[Sequence_Interval], 1) AS VARCHAR(10))
        + ' ' + pm.[frequnit]                                                  AS [Effective_PM_Schedule]

    -- ── Forecast / scheduled metrics ─────────────────────────────────
   ,CAST(ol.[Scheduled_Hrs_This_Occ] AS DECIMAL(18,2))                        AS [Forecast_Scheduled_Hrs]

    -- ── Actuals-based metrics (matches Python pipeline logic) ─────────
    -- Avg_Actual_Hrs_Per_Occurrence: raw historical average from completed WOs.
    -- NULL means this PM has never been completed — no actuals history exists.
   ,avg_act.[Avg_Actual_Labor_Hrs]                                             AS [Avg_Actual_Hrs_Per_Occurrence]
    -- Forecast_Avg_Actual_Hrs: pipeline-equivalent blended figure.
    -- Uses actuals average when available; falls back to scheduled hours.
    -- This is what work_order_hours_forecast.csv shows as pm_hours for type=forecast.
   ,CAST(
        CASE
            WHEN avg_act.[Avg_Actual_Labor_Hrs] IS NOT NULL
                THEN avg_act.[Avg_Actual_Labor_Hrs]
            ELSE ol.[Scheduled_Hrs_This_Occ]
        END
    AS DECIMAL(18,2))                                                          AS [Forecast_Avg_Actual_Hrs]

FROM Occurrence_Labor ol
JOIN [EDS].[MAXIMO].[PM] pm
  ON pm.[pmnum] = ol.[pmnum]
JOIN [EDS].[MAXIMO].[Locations] loc
  ON loc.[location] = pm.[location]
LEFT JOIN PM_Avg_Actual_Labor avg_act
       ON avg_act.[pmnum] = ol.[pmnum]
LEFT JOIN [EDS].[MAXIMO].[Jobplan] eff_jp
       ON eff_jp.[jpnum]   = ol.[Effective_JP]
      AND eff_jp.[status]  = 'active'
ORDER BY
    pm.[rcglsegment]
   ,ol.[pmnum]
   ,ol.[Scheduled_Date]
OPTION (MAXRECURSION 1826);
