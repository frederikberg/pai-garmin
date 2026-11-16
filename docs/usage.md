# Using the watch app

## Setup

The app needs the address of your server and a watch key. In Garmin Connect on the phone, open the watch's Connect IQ apps, choose PAI and fill in *Server URL* and *Watch key*. Until both are set the watch says so and sends nothing; a change arrives while the app runs and takes effect at once.

The key travels through Garmin's app settings, so revoke it on the server if you stop using the app.

## Opening it

From the glance list: the glance shows the next alarm (or that one rings), and Start opens the app. From the app list the app works the same way.

When the app opens it asks the server what is going on:

- **An alarm is ringing:** opening the app stops every ringing alarm by itself. The screen shows its time and name, "Stopping..." and then "Alarm stopped"; Start goes on to the menu. If stopping fails, the screen says why and Start tries again. The glance only shows that an alarm rings; it never stops it.
- **Otherwise** the menu: *Weather* (first, selected) and *Alarm*. Start opens the screen you chose.

Back leaves a screen; Back on the first one exits the app.

<p align="center">
  <img src="images/ringing.png" alt="The screen after a ringing alarm was stopped: Alarm stopped, 14:39, Alarm, with the hint Enter: menu" width="30%">
  <img src="images/home.png" alt="The menu with Weather selected and Alarm below it" width="30%">
</p>

## Weather

Start on *Weather* asks the server once and shows two rows:

- **Now** is the chance of rain in the next hour, from the rain radar. When rain is on its way the time it reaches you follows, with a line below such as "8 km W, closing in"; "raining now, until 15:40" while it rains; "dry around you" when nothing is near. Where no radar covers the place the line says "forecast only".
- **Later** is the chance over the next twelve hours and, if rain is likely, when it starts.

The colour follows the server's verdict: blue for rain, yellow for maybe, green for unlikely or dry, grey when there is no answer. The line under the rows names the place and how long ago the phone reported it. Start asks again, Back returns to the menu.

<p align="center">
  <img src="images/weather.png" alt="Weather: Now 70 % with rain 8 km west closing in, Later 40 % with rain possible, Aachen, 12 minutes ago" width="30%">
  <img src="images/weather-unknown.png" alt="Weather without a location: pick your iPhone in PAI Settings, Location" width="30%">
</p>

Without a location the screen says to pick your iPhone in PAI Settings, Location. If the weather source is down it says to try again, and a rejected key, a missing phone connection or a server error are worded like on the other screens.

## Alarms

The Alarm screen lists *+ New* first, then the armed alarms, soonest first, each with its time and day.

| Where | Button | Does |
|---|---|---|
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
