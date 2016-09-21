-- p16-hrv.sql
--
-- This file is part of ActivityLog2, an fitness activity tracker
-- Copyright (C) 2016 Alex Harsanyi (AlexHarsanyi@gmail.com)
--
-- This program is free software: you can redistribute it and/or modify it
-- under the terms of the GNU General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option)
-- any later version.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
-- FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
-- more details.

.bail on

create table SESSION_HRV (
  id integer not null primary key,
  session_id integer not null,
  sdnn integer not null,                -- STDDEV of NN intervals (hrv samples)
  rmssd integer not null, -- root mean square of successive differences (delta-hrv)
  sdsd integer not null, -- stddev of successive differences (delta-hrv)
  nn50 integer not null, -- # of successive pairs that differ by more than 50ms (delta-hrv)
  nn20 integer not null, -- # of successive pairs that differ by more than 20ms (delta-hrv)
  good_samples integer not null,        -- # of samples where good-hrv? is #t
  bad_samples integer not null,         -- # of samples where good-hrv? is #f
  foreign key (session_id) references A_SESSION(id) on delete cascade
  );

create unique index IX0_SESSION_HRV on SESSION_HRV(session_id);

drop view V_ACTIVITY_LIST;

create view V_ACTIVITY_LIST as
  select S.id as session_id,
         A.guid as activity_guid,
         S.name as headline,
         S.start_time as start_time,
         S.sport_id as sport,
         S.sub_sport_id as sub_sport,
         S.rpe_scale as rpe,
         S.training_effect as te,
         S.training_stress_score as tss,
         S.intensity_factor as ifact,
         SS.total_timer_time as duration,
         SS.total_distance as distance,
         SS.total_calories as calories,
         SS.avg_speed as speed,
         SS.max_speed as max_speed,
         SS.avg_heart_rate as hr,
         SS.max_heart_rate as max_hr,
         SS.avg_cadence as cadence,
         SS.max_cadence as max_cadence,
         SS.total_distance / (2 * SS.total_cycles) as stride,
         ifnull(SS.total_corrected_ascent, SS.total_ascent) as ascent,
         ifnull(SS.total_corrected_descent, SS.total_descent) as descent,
         SS.avg_vertical_oscillation as vosc,
         SS.avg_stance_time as gct,
         SS.avg_stance_time_percent as gct_pct,
         SS.avg_power as power,
         SS.max_power as max_power,
         SS.normalized_power as np,
         SS.left_right_balance as lrbal,
         SS.avg_left_torque_effectiveness as ltorqeff,
         SS.avg_right_torque_effectiveness as rtorqeff,
         SS.avg_left_pedal_smoothness as lpdlsmth,
         SS.avg_right_pedal_smoothness as rpdlsmth,
         SS.avg_left_pco as lpco,
         SS.avg_right_pco as rpco,
         SS.avg_left_pp_start as lppstart,
         SS.avg_left_pp_end as lppend,
         SS.avg_right_pp_start as rppstart,
         SS.avg_right_pp_end as rppend,
         SS.avg_left_ppp_start as lpppstart,
         SS.avg_left_ppp_end as lpppend,
         SS.avg_right_ppp_start as rpppstart,
         SS.avg_right_ppp_end as rpppend,
         SS.aerobic_decoupling as adecl,
         (select AM1.body_weight
            from ATHLETE_METRICS AM1
           where AM1.timestamp = (
             select max(AM.timestamp)
               from ATHLETE_METRICS AM
              where AM.timestamp between S.start_time - 84600 and S.start_time)) as body_weight,
         (select SH.sdnn
            from SESSION_HRV SH
           where SH.session_id = S.id) as hrv,
         (select temperature from SESSION_WEATHER SW1 where SW1.session_id = S.id) as temperature,
         (select humidity from SESSION_WEATHER SW2 where SW2.session_id = S.id) as humidity,
         (select wind_speed from SESSION_WEATHER SW3 where SW3.session_id = S.id) as wind_speed,
         (select wind_direction from SESSION_WEATHER SW4 where SW4.session_id = S.id) as wind_direction,
         (select dew_point from SESSION_WEATHER SW1 where SW1.session_id = S.id) as dew_point
    from A_SESSION S, SECTION_SUMMARY SS, ACTIVITY A
   where S.summary_id = SS.id
     and S.activity_id = A.id;


update SCHEMA_VERSION set version = 17;

