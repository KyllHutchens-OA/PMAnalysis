Select distinct pm.pmnum, pm.parent, pm.workgroup, pm.description as PMDesc, pm.facility, f.description as 'FacilityName', pm.location, l.description as LocDesc, pm.frequency, pm.frequnit, 
Concat(pm.frequency,' ', pm.frequnit) AS 'Frequency',
pm.status as PMStatus, pm.pmownergroup, pm.priority, pm.jpnum, pm.sawtraining, pm.nextdate, 
pm.sunday, pm.monday, pm.tuesday, pm.wednesday, pm.thursday, pm.friday, pm.saturday, pm.estdur, j.jpduration
,IIF(pm.description like '%;%',substring(pm.description,1,(charindex(';',pm.description)-1)),null) as PMDescshort, 
CASE 
    WHEN pm.frequnit = 'WEEKS'
        THEN 365.0 / (pm.frequency * 7.0)
    WHEN pm.frequnit = 'MONTHS'
        THEN 365.0 / (pm.frequency * 30.0)
    WHEN pm.frequnit = 'YEARS'
        THEN 365.0 / (pm.frequency * 365.0)
    WHEN pm.frequnit = 'DAYS'
        THEN (
            (IIF(pm.sunday = 1, 1, 0) +
             IIF(pm.monday = 1, 1, 0) +
             IIF(pm.tuesday = 1, 1, 0) +
             IIF(pm.wednesday = 1, 1, 0) +
             IIF(pm.thursday = 1, 1, 0) +
             IIF(pm.friday = 1, 1, 0) +
             IIF(pm.saturday = 1, 1, 0))
            * (365.0 / 7.0)
        )
    ELSE pm.frequency 
END AS PerYear
from maximo.pm as pm
left join maximo.locations as l on pm.location = l.location	
left join maximo.pmstatus as pms on pm.status = pms.status 
left join maximo.jobplan as j on pm.jpnum = j.jpnum AND j.status = 'ACTIVE'
left join maximo.joblabor as jl on j.jobplanid = jl.jobplanid
left join maximo.locations as f on pm.facility = f.location
where pm.workgroup in ('WTP-NORTH','WTP-CENTRAL','WTP-SOUTH','WTP-FARNORTH','WTP-RIV','WTP-MMURRAY','WTP-LMURRAY','WWTP-SOUTH','WWTP-CENTRAL','WWTP-NORTH')
and pm.parent is null
and pm.status = 'ACTIVE' 
