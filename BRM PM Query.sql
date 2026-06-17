SELECT            pmforecastjp.pmnum As [PM], --- pf.pmnum Parent , 
                        PM.Facility , PM.Location , PM.DESCRIPTION [PM Description], PM.WorkGroup , pm.Craft,  
                        PM.Frequency , PM.FREQUNIT [Freq. Unit], pmforecastjp.JPnum,   CONVERT(VARCHAR(10), pf.ForecastDate, 103) AS [Forecast Date] , pm.ESTDUR as [PM Duration (Hrs)],  LOCATIONS.ADDRESS2 as [Suburb], PM.PMOWNERGROUP

FROM    pm INNER JOIN
                  pmforecast AS pf ON pf.pmnum = pm.pmnum LEFT OUTER JOIN
                  pmforecastjp ON pf.pmnum = pmforecastjp.rootancestor AND pf.forecastseqno = pmforecastjp.forecastseqno
                                                  left join locations on pm.location =locations.location
WHERE   (PM.WORKGROUP in (select value from alndomain where domainid = 'NEWORG' and description like '%workshops%')) AND

(Pm.status IN ('active')) AND (pf.forecastdate >= '2026-09-02') AND (pf.forecastdate < '2027-09-02')

            and pmforecastjp.pmnum = pf.pmnum
            
ORDER BY PM.WorkGroup,  PM.Facility, pm.craft, pf.forecastdate
