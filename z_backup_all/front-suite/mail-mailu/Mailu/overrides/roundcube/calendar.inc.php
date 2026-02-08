<?php
// Kolab Calendar Plugin Configuration
// Requires: libkolab, libcalendaring, calendar plugins
// PEAR deps: HTTP_Request2, Net_URL2, PEAR_Exception

$config["plugins"][] = "libkolab";
$config["plugins"][] = "libcalendaring";
$config["plugins"][] = "calendar";

// Calendar driver - database (stores events in SQLite)
$config["calendar_driver"] = "database";
$config["calendar_driver_default"] = "database";

// Calendar UI settings
$config["calendar_default_view"] = "agendaWeek";
$config["calendar_first_day"] = 1;
$config["calendar_first_hour"] = 8;
$config["calendar_work_start"] = 8;
$config["calendar_work_end"] = 18;
