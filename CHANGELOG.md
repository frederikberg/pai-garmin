# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The Alarm sub-app: create, edit and delete one-off alarms from the watch, and stop a ringing alarm by opening the app. The time entry for a new alarm starts at the current time and shows it while you pick.
- The Weather sub-app: the chance of rain in the next hour and the next twelve, coloured by verdict, with place and location age. Start refreshes.
- Weather pages: Down shows the next twelve hours as bars (height the chance, colour how hard it rains) with the heaviest hour and the total amount, Down again the radar picture half an hour ahead; Up pages back. The rows name the heaviest hour and the amount, and every line shrinks its font until it fits the round screen.
- A home menu with Weather and Alarm that appears at once; a check for a ringing alarm runs behind it, and a sub-app's request waits for that check.
- A glance that shows the next alarm, or that one rings.
- Server URL and watch key as app settings in Garmin Connect.
