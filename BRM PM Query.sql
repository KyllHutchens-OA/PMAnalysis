SELECT locations.Service, CLASSSTRUCTURE.DESCRIPTION as Class , case when locations.workgroup in ('metrofac','metronet')  then 'Metro' else 'Regional' end as 'Region', 
pm.Facility, locations_1.description AS [Facility Description],
locations.Location, locations.description AS [Location Description], 
pm.pmnum AS PM, pm.Route, pm.estdur as [PM Duration (Hrs)],   JOBPLAN.JPDURATION as [JP Duration (Hrs)], 
pm.description AS [PM Description], pm.status AS Status, pm.frequency AS [Freq.], pm.frequnit AS [Freq. Unit],
CONVERT(VARCHAR(10), pm.firstdate, 103) AS [First Start Date], 
pm.workgroup AS [Work Group], pm.craft AS Craft, JOBLABOR.QUANTITY labor, pm.crewid AS Crew, 
pmsequence.interval AS Interval,  pmsequence.jpnum AS [Job Plan],JOBPLAN.DESCRIPTION as [JP Description] , PM.PMOWNERGROUP


FROM               dbo.pm INNER JOIN
                         dbo.locations ON pm.location = locations.location  left JOIN
                        dbo.locoper ON dbo.locations.location = dbo.locoper.location AND dbo.pm.location = dbo.locoper.location LEFT JOIN
                         dbo.risk ON dbo.locoper.risk = dbo.risk.risk LEFT OUTER JOIN
                         dbo.locations AS locations_1 ON pm.facility = locations_1.location LEFT OUTER JOIN
                         dbo.pmsequence ON pm.pmnum = pmsequence.pmnum LEFT OUTER JOIN
                         dbo.jobplan ON pmsequence.jpnum = jobplan.jpnum LEFT OUTER JOIN
                         dbo.JOBLABOR ON jobplan.jpnum = JOBLABOR.jpnum AND jobplan.pluscrevnum = JOBLABOR.pluscjprevnum LEFT OUTER JOIN
                         dbo.classstructure ON locations.classstructureid = classstructure.classstructureid         left join 
asset on locations.location=asset.location
                                                                        

WHERE (jobplan.status='active' OR jobplan.status IS NULL) and pm.status IN ('active','draft') and locations.Location NOT IN ('TWESLOC') and locations.status not in ('PLANNED','REMOVED','SOLD')

ORDER BY  pm.facility ,craft, pm.parent, pm.pmnum,Interval
