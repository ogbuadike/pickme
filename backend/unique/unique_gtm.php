<?php

	$user_time_offset = +1;
	$QTimeGMT = gmdate("g:iA", time()+($user_time_offset*3600));
	$QTime12 = gmdate("H:i:s", time()+($user_time_offset*3600));
	$QDateDescrip = gmdate("l, jS F Y", time()+($user_time_offset*3600));
	$QDatePlane = gmdate("Y-m-d", time()+($user_time_offset*3600));
	$QmonthPlane = gmdate("m", time()+($user_time_offset*3600));
	$QDateLessDescrip = gmdate("jS M Y", time()+($user_time_offset*3600));
	$QDate1 = gmdate("d/m/y", time()+($user_time_offset*3600));
	$QDate2 = gmdate("d/m/Y", time()+($user_time_offset*3600));
	$QHour = gmdate("g", time()+($user_time_offset*3600));
	$QMinute = gmdate("i", time()+($user_time_offset*3600));
	$QTimeMode = gmdate("A", time()+($user_time_offset*3600));
	$QDayDescrip = gmdate("l", time()+($user_time_offset*3600));
	$QWeek = gmdate("W", time()+($user_time_offset*3600));
	$QMonth = gmdate("F", time()+($user_time_offset*3600));
	$QYear = gmdate("Y", time()+($user_time_offset*3600));
	$WEEKday = gmdate("W-F-Y", time()+($user_time_offset*3600));
	$DateTime= gmdate("Y-m-d g:i:s", time()+($user_time_offset*3600));


	//SCRIPTED DATE OUTPUTS
	$strDate = strtotime(gmdate("Y-m-d", time()+($user_time_offset*3600)));
	$strTime = strtotime(gmdate("Y-m-d H:i:s", time()+($user_time_offset*3600)));

	$strDateF = date("Y-m-01", strtotime($QDatePlane));
	$strDateL = date("Y-m-t", strtotime($QDatePlane)); 
	
	$strDatetime = date("Y-m-d H:i:s", strtotime($DateTime)); 
	$coded_datetime=strtotime($strDatetime);

	$strDateF_STR = strtotime($strDateF);
	$strDateL_STR = strtotime($strDateL); 


	//SCRIPTED YEAR OUTPUTS
	$strYearF = date("Y-01-01", strtotime($QDatePlane));
	$strYearL = date("Y-12-t", strtotime($QDatePlane)); 

	$strYearF_STR = strtotime($strYearF);
	$strYearL_STR = strtotime($strYearL); 


	//SCRIPTED WEEK OUTPUTS
	$strWeekF = date("Y-m-d", strtotime('monday this week'));
	$strWeekL = date("Y-m-d", strtotime('sunday this week')); 

	$strWeekF_STR = strtotime($strWeekF);
	$strWeekL_STR = strtotime($strWeekL); 

//echo $QDateLessDescrip;



?>