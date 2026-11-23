# Using the watch app

## Setup

The app needs the address of your server and a watch key. In Garmin Connect on the phone, open the watch's Connect IQ apps, choose PAI and fill in *Server URL* and *Watch key*. Until both are set the watch says so and sends nothing; a change arrives while the app runs and takes effect at once.

The key travels through Garmin's app settings, so revoke it on the server if you stop using the app.

## Opening it

From the app list, or a hot key set to the app, a watch with audio opens straight into *Computer* and listens: no press is needed. From the glance list (the glance shows the next alarm, or that one rings, and Start opens the app) the menu comes first. The *Open with* setting in Garmin Connect changes this: *Computer* always opens Computer, *Menu* always the menu.

The menu appears at once, without waiting for the network: *Computer* (selected, only on watches with audio), *Weather* and *Alarm*. Start opens the screen you chose, and only then does anything go to the server.

Right after the app opens it also checks, in the background, whether an alarm rings. The check goes out first, so a screen opened in the meantime shows "Loading..." for a moment and its request follows once the check is over. If nothing rings, the check is invisible. If an alarm rings, the app stops every ringing alarm by itself, drops whatever you had just opened and shows the alarm's time and name with "Stopping..." and then "Alarm stopped"; Start returns to the menu. If stopping fails, the screen says why and Start tries again. The glance only shows that an alarm rings; it never stops it.

Back leaves a screen; Back on the first one exits the app. When the app opened straight into Computer, Back there hangs up and exits; the menu is one Up hold away (*Menu*).

<p align="center">
  <img src="images/ringing.png" alt="The screen after a ringing alarm was stopped: Alarm stopped, 14:39, Alarm, with the hint Enter: menu" width="30%">
  <img src="images/home.png" alt="The menu with Computer selected and Weather below it" width="30%">
</p>

## Computer

Talking to the server from the wrist, on watches with audio. Opening *Computer* starts a call, and the watch listens at once, without waiting for the call to be up. The screen is one word in a ring of the state's colour: a grey *Wait* while the microphone starts (about two seconds), then one short buzz says *speak now* and a green *Speak* shows: the microphone is recording. Start sends the turn: two short buzzes say it was taken; a yellow *Sending* shows until the server has it. Taps on the screen do nothing. While the answer is generated the screen says *Thinking* (yellow) and shows what the server heard; while it plays it says *Speaking* (blue). Red means something stopped, with the reason underneath. When the answer has finished playing the watch starts the microphone again, and the same short buzz says when you can speak. A low falling sound with a long buzz means the call stopped; the reason is on the screen. Start during the answer cuts it off at once and records again. Up and Down change the volume, which shows for a moment and is kept for the next time. Back hangs up: the screen says so and leaves once the server has heard it, two seconds at most. Holding Up opens a menu with *New call*, which drops the current call and starts a fresh one, and, when the app opened straight into Computer, *Menu*, which hangs up and shows the menu.

When requests fail the watch repeats them with growing waits, keeps what you said (up to about half a minute of speech) while the link is down, carries on with the same call when it returns and opens a new call when the server no longer knows the old one; an orange line near the bottom then names what is being repeated and how often. Everything that goes wrong, with the codes Connect IQ reports, is sent to the server's log for the call. If the server ends the call, the screen says why and Start opens a new one. A key that is not the owner's is told that Computer is only for the owner. When recording fails several times in a row (the microphone, or audio the server refuses) it stops and says why until Start tries again; a server that keeps losing the call does the same.

The app settings in Garmin Connect also have a *Mic filter* switch (noise and echo reduction on the microphone, off by default). The app settings in Garmin Connect have a *Debug log* switch. With it on, the trace of a Computer call is detailed (a line for every request and every piece), which shows where time goes; either way a turn leaves one summary line with its timings besides the errors.

Opening the app from the glance list and pressing Up or Down now and then keeps it open.

## Weather

Start on *Weather* asks the server once and shows two rows:

- **Now** is the chance of rain in the next hour, from the rain radar. When rain is on its way the time it reaches you follows, with a line below such as "8 km W, closing in"; "raining now, until 15:40" while it rains; "dry around you" when nothing is near. Where no radar covers the place the line says "forecast only".
- **Later** is the chance over the next twelve hours and, if rain is likely, when it starts, with a line naming the hour it rains hardest and how much falls in all ("heaviest 21:00 · 11 mm").

The colour follows the server's verdict: blue for rain, yellow for maybe, green for unlikely or dry, grey when there is no answer. The line under the rows names the place and how long ago the phone reported it. Start asks again, Back returns to the menu.

Down turns to the next twelve hours as bars: each bar is as tall as the hour's chance and as dark a blue as the rain is heavy, with every third hour named below. Down again shows the rain radar half an hour ahead around you, the dot in the middle being you; Up pages back. The dots on the left edge show which page is open.

<p align="center">
  <img src="images/weather.png" alt="Weather: Now 70 % with rain 8 km west closing in, Later 100 % with the heaviest hour and 11 mm, Aachen, 12 minutes ago" width="30%">
  <img src="images/weather-hours.png" alt="Weather, next 12 hours: bars rising to a peak at 22:00, heaviest 21:00 with 11 mm" width="30%">
  <img src="images/weather-unknown.png" alt="Weather without a location: pick your iPhone in PAI Settings, Location" width="30%">
</p>

Without a location the screen says to pick your iPhone in PAI Settings, Location. If the weather source is down it says to try again, and a rejected key, a missing phone connection or a server error are worded like on the other screens.

## Alarms

The Alarm screen lists *+ New* first, then the armed alarms, soonest first, each with its time and day.

| Where | Button | Does |
|---|---|---|
| Computer | Start | send the turn being recorded; during the answer, cut it and record again |
| Computer | Up / Down | volume up / down |
| Computer | hold Up | menu with New call, and Menu when the app opened here |
| Computer | Back | hang up; exits the app when it opened here |
| list | Down / Up | move through the list |
| list, on *+ New* | Start | create an alarm |
| list, on an alarm | Start | change its time |
| list, on an alarm | hold Up | open its menu, whose only entry deletes it |
| time entry | Up / Down | add / subtract one to the marked number, wrapping; held, it repeats and speeds up |
| time entry | Start | from hours to minutes, then save |
| time entry | Back | from minutes to hours, then cancel |

An alarm has no name and rings once, at the next time the clock shows the chosen hour and minute. The time entry starts at the current time for a new alarm and at the alarm's own time for a change, and shows the current time underneath while you pick. Setting a new alarm to the minute it is now means tomorrow. After saving, the list is read from the server again and the saved alarm is selected, so the list always shows what the server holds, including alarms made on other devices.

<p align="center">
  <img src="images/alarms.png" alt="The alarm list with + New above two alarms, one selected, and the hint Hold Up: delete" width="30%">
  <img src="images/new-alarm.png" alt="The time entry for a new alarm showing 15:00, the current time 15:00 underneath and the hours marked" width="30%">
</p>

## When something is wrong

The screen names the problem and Start tries again: no phone connection, server URL or key not set, key rejected, no answer within 25 seconds, or the server's HTTP status.
