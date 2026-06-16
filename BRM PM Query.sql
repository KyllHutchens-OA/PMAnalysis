SELECT locations.Service, CLASSSTRUCTURE.DESCRIPTION as Class , case when locations.workgroup in ('metrofac','metronet')  then 'Metro' else 'Regional' end as 'Region', 
pm.Facility, locations_1.description AS [Facility Description],
locations.Location, locations.description AS [Location Description], 
pm.pmnum AS PM, pm.Route, pm.estdur as [PM Duration (Hrs)],   JOBPLAN.JPDURATION as [JP Duration (Hrs)], 
pm.description AS [PM Description], pm.status AS Status, pm.frequency AS [Freq.], pm.frequnit AS [Freq. Unit],
CONVERT(VARCHAR(10), pm.firstdate, 103) AS [First Start Date], 
pm.workgroup AS [Work Group], pm.craft AS Craft, JOBLABOR.QUANTITY labor, pm.crewid AS Crew, 
pmsequence.interval AS Interval,  pmsequence.jpnum AS [Job Plan],JOBPLAN.DESCRIPTION as [JP Description] , PM.PMOWNERGROUP
