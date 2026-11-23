# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The Alarm sub-app: create, edit and delete one-off alarms from the watch, and stop a ringing alarm by opening the app. The time entry for a new alarm starts at the current time and shows it while you pick.
- The Weather sub-app: the chance of rain in the next hour and the next twelve, coloured by verdict, with place and location age. Start refreshes.
- Weather pages: Down shows the next twelve hours as bars (height the chance, colour how hard it rains) with the heaviest hour and the total amount, Down again the radar picture half an hour ahead; Up pages back. The rows name the heaviest hour and the amount, and every line shrinks its font until it fits the round screen.
- The Computer screen, for watches with Toybox.Audio: opening it starts a call with the server. Listening begins when the screen opens, before the call is up; the watch records each turn by itself as Ogg Opus 16 kHz and streams it while you speak, Start sends the turn or cuts the answer and records again, the answer plays piece by piece as it arrives (Ogg Opus, one sentence a piece, each through its own audio source) with what the server heard on screen, the watch's own cues say that the turn was sent (a beep), that it is your turn again (two rising notes) and that the call stopped (a low pair), Up and Down change the volume, which is remembered, Back hangs up and waits for the server to hear it, and an Up hold offers a new call. Requests are repeated with growing waits, the call resumes after a gap or is replaced when the server forgot it, and every error and retry goes to the server's log for the call.
- A home menu with Computer (where the watch has audio), Weather and Alarm that appears at once; a check for a ringing alarm runs behind it, and a sub-app's request waits for that check.
- A glance that shows the next alarm, or that one rings.
- Server URL and watch key as app settings in Garmin Connect.
