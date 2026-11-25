# Watch API

The routes the watch app calls on the server, over HTTPS through the phone's Garmin Connect app. Every request carries the watch key as `Authorization: Bearer <key>`; a missing, wrong or revoked key answers `401`, which the watch shows as "Watch key rejected".

Times are ISO 8601 in UTC with an offset, for example `2026-11-16T07:30:00+00:00`. The watch turns the hour and minute you pick into the next time the watch's own clock shows it (today if still ahead, otherwise tomorrow), converts it to UTC and sends that; the server never interprets local time.

| Route | Body | Answer |
|---|---|---|
| `GET /api/watch/alarm` | none | `200` with the state below |
| `POST /api/watch/alarm` | `{"fire_at": "<time>"}` | `201` with the new alarm |
| `PUT /api/watch/alarm/{id}` | `{"fire_at": "<time>"}` | `200` with the changed alarm; `404` for an unknown id, `409` while it rings |
| `DELETE /api/watch/alarm/{id}` | none | `200` with `{}` |
| `POST /api/watch/alarm/dismiss` | none | `200` with `{}`, stops every ringing alarm |
| `GET /api/watch/weather` | none | `200` with the weather below |
| `POST /api/watch/self-report?id=…&feel=…&at=…` | recorded audio, see Self-report | `202` with `{"id": "<id>"}` |
| `POST /api/watch/log` | `{"lines": [...]}`, see Watch log | `200 {}` |
| `POST /api/watch/voice/call` and the routes below it | see Computer call | the Computer call |

State:

```json
{
  "alarms": [{"id": "…", "name": "Alarm", "fire_at": "<time>"}],
  "ringing": [{"id": "…", "name": "Alarm", "fire_at": "<time>"}],
  "server_time": "<time>"
}
```

`alarms` holds the armed alarms by fire time, soonest first; `ringing` the ones sounding now. Entries may carry more fields, which the watch ignores.

## Weather

```json
{
  "location": {"place": "Aachen", "recorded_at": "<time>"},
  "now": {
    "chance": 70, "verdict": "rain", "raining_now": false,
    "starts_at": "<time>", "ends_at": null,
    "nearest_km": 8, "direction": "W", "trend": "approaching",
    "method": "radar", "reason": null
  },
  "later": {
    "chance": 100, "verdict": "rain", "at": "<time>", "reason": null,
    "hours": [{"start": "<time>", "chance": 40, "precipitation_mm": 0.2, "intensity": "light"}],
    "heaviest_at": "<time>", "total_mm": 11.2
  },
  "radar_picture_at": "<time>",
  "radar_picture_path": "/api/radar-link.png?t=<token>",
  "attribution": "Radar: DWD · Forecast: Open-Meteo",
  "conditions": {
    "reason": null,
    "symbol": "rain", "night": false,
    "temp_now": 11, "temp_min": 8, "temp_max": 14,
    "hours": [{"start": "<time>", "temp": 11, "symbol": "partly", "night": false, "uv": 1.2}],
    "uv": {"now": 1.2, "peak": 4.1, "peak_at": "<time>"},
    "days": [{"date": "2026-11-24", "symbol": "rain", "temp_max": 14, "temp_min": 8, "chance": 90}]
  }
}
```

`now` covers the next hour and `later` the next twelve. `chance` is 0 to 100 or `null`; `verdict` is `rain`, `maybe`, `unlikely`, `dry` or `unknown` and sets the colour of the row. `starts_at` and `at` are when the rain is expected to begin, `ends_at` when it stops while it rains now. `nearest_km`, `direction` (`N` to `NW`) and `trend` (`approaching`, `passing`, `leaving`) describe the nearest rain; `method` is `forecast` where no radar covers the place. `location` is `null` when the server has no location for the person; `reason` is `no_location` or `source_unavailable` when a half has no answer. `hours` are the twelve hours from the current one, each with its chance and how hard it rains (`none`, `light`, `moderate`, `heavy`); `heaviest_at` is the hour it rains hardest and `total_mm` the amount over the twelve hours, both `null` without rain. Other fields are ignored.

`radar_picture_path` is a link to the radar picture about half an hour ahead (`radar_picture_at`), `null` where there is none. It works for a few minutes without the key, because Connect IQ downloads images without headers; the watch adds `&size=<pixels>` and fetches it with `makeImageRequest` when the picture's page opens. An expired link answers `403`, and the next refresh brings a new one.

`conditions` is the forecast beside the rain: the symbol and temperatures of the next twelve hours, the UV index and the days ahead. It is always present, and independent of the rain halves: when it is unavailable the rain still answers, and the other way round. A server that does not send it works too; the watch then shows the rain pages only.

| Field | Meaning |
|---|---|
| `reason` | `null` when the block is filled; `no_location` or `source_unavailable` otherwise, with `symbol`, `temp_*` and `uv` `null`, `night` false, `hours` and `days` empty |
| `symbol` | the next twelve hours as one of `clear`, `partly`, `cloudy`, `fog`, `rain`, `sleet`, `snow`, `thunder`; an unknown word is drawn as `cloudy` |
| `night` | most of the twelve hours are dark; turns the sun of `clear` and `partly` into a moon |
| `temp_now`, `temp_min`, `temp_max` | whole °C; the extremes cover the twelve hours and now |
| `hours` | twelve entries from the current full hour: `start`, whole-°C `temp`, `symbol`, `night`, and `uv` (index over the hour, `null` when unknown); an entry without `start` or `temp` is left out |
| `uv` | `null` without a UV source (the UV page then does not exist); `now` is the index valid at the person's location, `peak` the highest of now and the twelve hours, `peak_at` the hour it falls in (`null` when it rounds to 0) |
| `days` | four entries, today first, by the location's calendar: `date` (`YYYY-MM-DD`; the watch derives the weekday from it), `symbol` of the day (always drawn as day), whole-°C `temp_max` and `temp_min`, and `chance` of rain 0 to 100 (`null` when unknown); an entry without a readable `date` or temperatures is left out |

The watch shows the screens listed under *Pages* below; `attribution` names the sources.

The watch shows the two halves as rows (`Now 70 % · 15:20` with a line such as `8 km W, closing in`, `raining now, until 15:40` or `dry around you`; `Later 100 % · 18:00` with `heaviest 21:00 · 11 mm`), and under them the place and how long ago the location was reported, below the twelve-hour symbol with the highest over the lowest temperature.

Pages, in the order Down walks them (Up walks back, both wrap); a page exists only when the answer holds what it shows:

| Page | Exists when |
|---|---|
| the rows with the symbol | always |
| rain bars | the `later` half has an answer |
| temperature, twelve bars with a symbol, hour and temperature every third hour | `conditions` is filled |
| UV index, the index now and twelve bars on a fixed 0 to 11 scale | `conditions` is filled and has `uv` |
| daily, four rows with weekday, symbol, highest, lowest and chance of rain, credited to Open-Meteo | `conditions` has days |
| radar picture | `radar_picture_path` is not `null` |

Start asks again on every page. While it runs the last line reads *Updating...*. When a refresh fails, or the server answers but knows nothing at all (every source down), and the answer on screen is younger than 30 minutes, the answer stays and the last line of every page reads *not updated · HH:MM*, the time that answer arrived; an older one is dropped and the screen says what failed. Without the symbol block (`conditions` unavailable) the first page reads *no forecast* where the symbol would be. Without a location it says to pick the iPhone in the server's Settings, Location. When neither half has an answer it says so as a whole; when one half has none, that row shows a dash and `no answer`.

Changing a time is a `PUT` because Connect IQ cannot send `PATCH`.

The app does not read the answer of `DELETE` and dismiss, only that one came. It also accepts an empty `204`, which the simulator reports as an error (`-400`); the app counts that code as "sent" for these two routes and reads the state again afterwards.

## Self-report

A spoken self-report: the face the wearer picked (or none, when skipped) and what they said. The body is the whole recording as one Ogg Opus stream, 16 kHz mono, `Content-Type: audio/ogg`, the same encoding the Computer call's audio uses; it stops by itself at 64 KiB. Query parameters:

| Parameter | Meaning |
|---|---|
| `id` | a UUID the watch makes per report; a repeat carries the same one and must not create a second report |
| `feel` | `heavy`, `okay` or `good`; absent when the face was skipped |
| `at` | when the recording began, ISO 8601 in UTC with an offset (the plus sign is sent escaped) |
| `try` | present on a repeat, the attempt number; the server ignores it |

The server answers `202 {"id": "<id>"}` as soon as it has stored the bytes; turning the audio into a report happens afterwards. Any other status is shown on the watch as a failure, and Start sends the same recording again with the same `id`. A `401` reads as a rejected key, a missing phone connection or no answer within 25 seconds as such.

## Computer call

The Computer screen holds one call at a time over plain requests. All routes are under `/api/watch/voice/call`, carry the watch key, and answer JSON unless noted. A repeated request must be safe: the watch repeats a request that failed, or whose answer it never saw, with `try=<n>` appended to the query.

| Request | Answer |
|---|---|
| `POST /api/watch/voice/call` (no body needed) | `201 {"call": "<id>"}` opens a call; `403 {"detail": "owner_only"}` for a key that is not the owner's |
| `POST …/call/{id}/audio?turn=<t>&seq=<n>&after_press=<k>[&end=<p>]`, `Content-Type: audio/ogg`, body = the next bytes of the turn's Ogg Opus stream | `200 {"next_seq": n+1}`; a repeated `seq` is ignored (`200`); a gap answers `409 {"next_seq": <expected>}`; `422 bad_audio` when the turn cannot be decoded any more. `end` is the press that ends the turn, applied after this chunk, also when the chunk is a repeat |
| `POST …/call/{id}/command` `{"action": "press", "press": <n>, "turn": <t>}` | `200 {}`; a repeated press number is ignored |
| `POST …/call/{id}/command` `{"action": "back", "back": <n>}` | `200 {}`, in a session's call: give the call back to Computer; `back` counts up per call from 1 and a repeated number is ignored |
| `GET …/call/{id}/events?after=<cursor>&wait=<s>[&played=<k>]` | short poll, `wait` is 0 or 1: `{"cursor": c, "events": [...]}` with only the events after `after` |
| `GET …/call/{id}/piece/{n}[?wait=<s>][&played=<k>]` | `application/octet-stream`, a complete Ogg Opus file (mono, declared to the player as Ogg, Opus, 24 kHz, mono), one sentence of the answer (at most about 8 s); with `wait` the server waits up to `s` seconds for a piece not made yet and answers without a body (`204`) when it has not come; `404` for a piece that was cleared or already played |
| `POST …/call/{id}/log` `{"sent_t": <ms>, "lines": [{"t": <ms>, "ev": "<name>", …}]}` | `200 {}`, what the watch saw (see *Watch log*) |
| `DELETE …/call/{id}` | `200 {}`, hangs up (also for a call that already ended) |

`played=<k>` on an events or piece request reports piece `k` as played through, one report a request.

A call the server no longer knows answers every route with `404`, and the watch then opens a new call. A call that ended answers audio, command and piece with `404` while its events still work until the watch has seen `ended`; `DELETE` answers `200`. A `404` on audio or a command makes the watch stop recording and ask the events at once, which say whether the call ended. `401` is the watch key being rejected and stops the screen with that message.

`turn` counts up per call from 1 and `seq` from 0 per turn. `press` counts up per call from 1. With Computer a turn starts by itself (after the call opens, after an answer, after a cut), so the press is "send" or "cut": it ends the turn being recorded, or cuts an answer, and the server tells which. Its `turn` is the turn it ends, or for a cut the turn whose answer it cuts. The press that ends a turn rides on the turn's last audio request as `end`; after the press the watch waits up to 400 ms for the microphone's last data, so that one request carries it. When no audio is left to send (or after a failure, under the same number) the press goes as a command, as does a cut's press, after the played reports of the pieces that played. `after_press` on a chunk is the number of the last press sent before its turn began (0 for none); the server holds the turn's audio until that press is applied, for at most three seconds.

A turn the watch cannot finish (a `422`, a `409` it cannot repair, a capture failure) is dropped without a press: the next turn just takes the next number. After a `409` the watch sends again, from the chunk the server expects, the chunks it still holds with their original numbers; when the answer carries no readable body it sends again everything it holds, which the server skips where it already has it.

Events carry their own index `i`, which the watch uses to skip what it saw. Each is one of:

- `{"state": "ready"|"listening"|"generating"|"speaking"|"wake"|"recording", "owner": "computer"|"session", "session": "<title>"}`; the watch records again on `listening` once nothing is left to play. `owner` and `session` say who has the call (see *A session's call*); without `owner` it is Computer
- `{"piece": n, "ref": r, "ms": d, "text": "<sentence>"}`, a playable piece; Computer's pieces carry the sentence they speak, a session's carry no `text`
- `{"clear": true, "dropped": k}`, drop every unplayed piece and stop playback
- `{"heard": "<text>"}`, once per turn before the state goes to `generating`, shown while Computer's answer is being generated
- `{"notice": {"code": "…", "text": "…"}}`, its text shown briefly on screen. `heard_nothing` (a press had nothing to answer) changes nothing else: listening goes on
- `{"ended": "<reason>"}`, the call is over. The server ends it with `idle` when 180 s pass in a turn the watch records with no word transcribed (counted from the turn's start or its last transcribed word), and Computer can end it. The watch records nothing more, lets what the player already holds finish, buzzes *bye*, hangs up and returns to the menu

Once the state is `generating`, the watch asks for the answer's first piece (the number after the last one it knows) before the events announce it, with `wait=2`, and after an empty answer asks the events once with `wait=0` before it asks again. When that piece has arrived and plays, it asks for the next one the same way, once, with `wait=1`, so the second piece downloads while the first plays; the pieces after it are fetched as the events announce them, also while one plays. The event of a piece fetched ahead still arrives and brings its sentence. Until then the watch takes the piece to be as long as its bytes last at 16 kbit/s. A `404` ends the asking ahead, and the events name the next piece.

Each piece plays through its own audio source, one after the other. A piece is over when the player says it stopped or, if it never does, a little after the length the event gave (`ms`, else 8 s); the next one starts then and the watch reports it as played. Recording begins after the last piece in the same way, without waiting for the player. While a piece of Computer's answer plays, the screen shows its sentence, shortened to fit.

The microphone starts when the screen opens, before the call exists, and the open request goes out once the microphone has delivered its first data (after 2.5 s at the latest, so that the watch's own loop is not held up while the microphone starts): the first turn's audio is kept (about half a minute at most) and goes out, as turn 1 with `seq` 0, once the open has answered. If the open still fails after five tries the error signal sounds, the microphone stops and the reason stays on screen. The watch hangs up before the screen leaves: the screen waits for the `DELETE` to be answered, two seconds at most, then the menu shows again. Log lines not sent by then are kept on the watch and go out with the next launch's log.

The phone link carries one request at a time, so the watch sends one request at a time, in this order: a press, a played report when no piece is left to fetch (on an events request, so that the next turn's press never overtakes it), audio, pieces, the log when it is due (every 15 s or 20 lines, sooner after a failure, and only while an answer plays or nothing is going on, never between a press and its answer), the events. While a turn is open (recorded, or its audio or press not yet taken) nothing is expected from the server: the events are then asked only every 5 s, with `wait=0`, and audio goes out in requests of about 2 KB, the rest at once when the turn ends. Otherwise the events are asked for with the short wait and jump the queue after 5 s without one. A log batch carries a `batch` number, which stays the same when the batch is sent again.

## Signals

The watch signals by itself, never from the network, with buzzes only (no sound plays while the microphone runs), and every press it takes is confirmed by one:

| Signal | Buzz | When |
|---|---|---|
| speak | one short buzz (120 ms) | the microphone delivers its first data of a turn, which is when the screen says *Speak*; also when a waiting session has finished speaking (Start is the next move) |
| sent | two short buzzes | Start ended a turn: once the microphone has stopped, so the buzz is not in the recording (after 1.5 s if it never says so) |
| tap | one very short buzz (40 ms) | Start cut an answer, began a turn (in a session's call, after a press that had nothing to answer), tried again after a stop, or a send found nothing recorded; Back in a session's call asked for Computer. It comes at the press; the speak buzz follows when the microphone delivers |
| bye | two short buzzes and a longer one | the call is over: Back hung up, or the server ended it |
| error | one long buzz and the error tone | the call stopped for a reason shown on screen |

Every buzz leaves a `buzz` line (`cue`: `speak`, `sent`, `tap`, `bye`, `error`) in the log.

## A session's call

Computer can hand the call to a session. State events then carry `"owner": "session"` and the session's title. The screen shows only the state (*Speak* while recording, *Listening* while the session may speak, *Speaking* while it does) and the session's name in the middle of the screen, never the words of either side. The session's phases are `recording` (the watch starts a turn by itself, as on `listening`) and `wake` (it does not; Start begins a turn, and what the session answers plays). Computer can land the call in either phase; after a session's answer only Start begins a turn. Start ends a turn or cuts what plays, as with Computer. Back sends the `back` command instead of hanging up: a turn being recorded is not sent (no press): the microphone stops, the turn's remaining audio goes out and the back command follows it, and the server keeps what it heard in the session's draft, unsent. No turn starts until a state event names Computer as the owner again, and the call goes on there. Any other end of a session's call while its turn records (the hang-up, the idle end, the call lost) also leaves what was heard in the draft. A session says `wake` once, when it has the press, so that state ends the watch's wait for it whichever poll brings it. Start in `wake` with nothing playing begins a turn and sends no press.

## Watch log

`POST /api/watch/log` takes the same body as the call's log route, `{"batch": <n>, "sent_t": <ms>, "lines": [{"t": <ms>, "ev": "<name>", …}]}`, for the lines the watch has while no call is up to carry them. During a call the lines go to the call's own `…/log`. A log request never goes ahead of audio, a press, pieces or events. `t` and `sent_t` are the watch's uptime in milliseconds, so a late batch can be placed in time. The watch keeps up to 120 lines; after an overflow the first 20 stay and a `log_dropped` line counts the rest.

What the lines say: a `device` line at the start of a call, request errors with their codes and the first retries, round trips of slow requests, the first chunk of a turn (size, whether it starts with `OggS`), the first playback and its states, capture and playback errors, free memory, every `buzz`, every tap on the call screen (`tap`, `uptime_ms`; a tap does nothing else, and Start acts only on the button), and every Start the call took (`start`, `action`: 1 try again, 2 send, 3 cut, 4 begin a turn). A `launch` line says how the app was opened (`how`: the launch state as the watch gives it, and `glance`), `mic_live` (`since_launch_ms`) how long the first *speak* took from there, and an `exit` line why the app ended (`cause`: `back` for Back on the menu, `system` for anything else, such as the glance list's timeout, another app or the watch closing it), after how long (`uptime_ms`) and whether a call was up (`in_call`). An `inactive` line marks the app being hidden while it keeps running, and an `active` line its return, with how long it was away (`hidden_ms`), whether a call was up (`in_call`) and whether it kept its screen (`kept`) instead of returning to the menu. An `open` line names the sub-app chosen on the menu (`app`). The alarm check leaves `alarm_ringing` (`count`) and `alarm_stopped` (`ok`) when it finds one ringing, and a `buzz` line with `cue` `alarm`. The lines a run did not get to send, the `exit` line among them, are kept on the watch at its exit; the next launch puts them at the front of its log, closed by a `stored_end` line (`lines`: how many came before it), and they leave with that run's first batch, on whichever of the two routes it uses.

With the app setting "Debug log" on (the default of the beta) the lines also carry a `req` (`lane`, `ms`, `code`, `bytes`) for every answered request, the capture states, the events and the pieces' fetch and play times. With it on or off, a turn leaves one `turn_summary` besides the errors and retries: `mic_ms` (microphone start to its first data), `bytes`, then counted from the press `stop_ms` (the capture stopped), `sent_ms` (the server had the press) and `sound_ms` (the first piece began to play), `piece_ms` (from the press being taken to the first piece being known), `fetch_ms` (that piece's download), `pieces` and `gap_max_ms` (the longest silence between pieces); a step that did not happen is `-1`. A `stall` line (`gap_ms`) marks a gap of more than 1.5 s in the watch's own loop.
