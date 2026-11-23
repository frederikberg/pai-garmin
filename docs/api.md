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
  "radar_picture_path": "/api/radar-link.png?t=<token>"
}
```

`now` covers the next hour and `later` the next twelve. `chance` is 0 to 100 or `null`; `verdict` is `rain`, `maybe`, `unlikely`, `dry` or `unknown` and sets the colour of the row. `starts_at` and `at` are when the rain is expected to begin, `ends_at` when it stops while it rains now. `nearest_km`, `direction` (`N` to `NW`) and `trend` (`approaching`, `passing`, `leaving`) describe the nearest rain; `method` is `forecast` where no radar covers the place. `location` is `null` when the server has no location for the person; `reason` is `no_location` or `source_unavailable` when a half has no answer. `hours` are the twelve hours from the current one, each with its chance and how hard it rains (`none`, `light`, `moderate`, `heavy`); `heaviest_at` is the hour it rains hardest and `total_mm` the amount over the twelve hours, both `null` without rain. Other fields are ignored.

`radar_picture_path` is a link to the radar picture about half an hour ahead (`radar_picture_at`), `null` where there is none. It works for a few minutes without the key, because Connect IQ downloads images without headers; the watch adds `&size=<pixels>` and fetches it with `makeImageRequest` when the picture's page opens. An expired link answers `403`, and the next refresh brings a new one.

The watch shows the two halves as rows (`Now 70 % · 15:20` with a line such as `8 km W, closing in`, `raining now, until 15:40` or `dry around you`; `Later 100 % · 18:00` with `heaviest 21:00 · 11 mm`), and under them the place and how long ago the location was reported. Down shows the twelve hours as bars, Down again the radar picture. Without a location it says to pick the iPhone in the server's Settings, Location. When neither half has an answer it says so as a whole; when one half has none, that row shows a dash and `no answer`.

Changing a time is a `PUT` because Connect IQ cannot send `PATCH`.

The app does not read the answer of `DELETE` and dismiss, only that one came. It also accepts an empty `204`, which the simulator reports as an error (`-400`); the app counts that code as "sent" for these two routes and reads the state again afterwards.

## Computer call

The Computer screen holds one call at a time over plain requests. All routes are under `/api/watch/voice/call`, carry the watch key, and answer JSON unless noted. A repeated request must be safe: the watch repeats a request that failed, or whose answer it never saw, with `try=<n>` appended to the query.

| Request | Answer |
|---|---|
| `POST /api/watch/voice/call` | `201 {"call": "<id>", "features": [...]}` opens a call (`features` names the optional features the server offers, see below; without it the watch uses the plain routes); `403 {"detail": "owner_only"}` for a key that is not the owner's |
| `POST …/call/{id}/audio?turn=<t>&seq=<n>&after_press=<k>`, `Content-Type: audio/ogg`, body = the next bytes of the turn's Ogg Opus stream | `200 {"next_seq": n+1}`; a repeated `seq` is ignored (`200`); a gap answers `409 {"next_seq": <expected>}`; `422 bad_audio` when the turn cannot be decoded any more |
| `POST …/call/{id}/command` `{"action": "press", "press": <n>, "turn": <t>}` | `200 {}`; a repeated press number is ignored |
| `POST …/call/{id}/command` `{"action": "back", "back": <n>}` | `200 {}`, in a session's call: give the call back to Computer; `back` counts up per call from 1 and a repeated number is ignored |
| `GET …/call/{id}/events?after=<cursor>&wait=<s>` | short poll, `wait` is 1: `{"cursor": c, "events": [...]}` with only the events after `after` |
| `GET …/call/{id}/piece/{n}` | `application/octet-stream`, a complete Ogg Opus file (mono, declared to the player as Ogg, Opus, 24 kHz, mono), one sentence of the answer (at most about 8 s); `404` for a piece that was cleared or already played |
| `POST …/call/{id}/played` `{"n": <k>}` | `200 {}`, piece `k` played through |
| `POST …/call/{id}/log` `{"sent_t": <ms>, "lines": [{"t": <ms>, "ev": "<name>", …}]}` | `200 {}`, what the watch saw: a device line at the start, request errors with their codes and the first retries, round trips of slow requests, a summary of every turn, the first chunk of a turn (size, whether it starts with `OggS`), the first playback and its states, capture and playback errors, free memory. `t` and `sent_t` are the watch's uptime in milliseconds, so a late batch can be placed in time. After an overflow the first 20 lines stay and a `log_dropped` line counts the rest |
| `DELETE …/call/{id}` | `200 {}`, hangs up (also for a call that already ended) |

A call the server no longer knows answers every route with `404`, and the watch then opens a new call. A call that ended answers audio, command, played and piece with `404` while its events still work until the watch has seen `ended`; `DELETE` answers `200`. `401` is the watch key being rejected and stops the screen with that message.

`turn` counts up per call from 1 and `seq` from 0 per turn. `press` counts up per call from 1. A turn starts by itself (after the call opens, after an answer, after a cut), so the press is only ever "send" or "cut": it ends the turn being recorded, or cuts an answer, and the server tells which. Its `turn` is the turn it ends, or for a cut the turn whose answer it cuts. The watch sends the press of a turn only after every chunk of it is acknowledged, a cut's press after the `played` reports of the pieces that played, and the next turn's first chunk after that press. `after_press` on a chunk is the number of the last press sent before its turn began (0 for none); the server holds the turn's audio until that press is applied, for at most three seconds.

A turn the watch cannot finish (a `422`, a `409` it cannot repair, a capture failure) is dropped without a press: the next turn just takes the next number. After a `409` the watch sends again, from the chunk the server expects, the chunks it still holds with their original numbers; when the answer carries no readable body it sends again everything it holds, which the server skips where it already has it.

Events carry their own index `i`, which the watch uses to skip what it saw. Each is one of:

- `{"state": "ready"|"listening"|"generating"|"speaking"|"wake"|"recording", "owner": "computer"|"session", "session": "<title>"}`; the watch records again on `listening` once nothing is left to play. `owner` and `session` say who has the call (see *A session's call*); without `owner` it is Computer
- `{"piece": n, "ref": r, "ms": d}`, a playable piece
- `{"clear": true, "dropped": k}`, drop every unplayed piece and stop playback
- `{"heard": "<text>"}`, once per turn before the state goes to `generating`, shown while the answer is being generated
- `{"notice": {"code": "…", "text": "…"}}`, its text shown briefly on screen. `heard_nothing` (a press had nothing to answer) changes nothing else: listening goes on. `turn_timed_out` (an open turn went without a press for too long, and the server dropped what it heard) makes the watch start a new turn with a new Ogg Opus stream, `seq` 0 and `after_press` at the current press count, without a press
- `{"ended": "<reason>"}`, the call is over; Start opens a new one

Each piece plays through its own audio source, one after the other. A piece is over when the player says it stopped or, if it never does, a little after the length the event gave (`ms`, else 8 s); the next one starts then and the watch reports it as played. Recording begins after the last piece in the same way, without waiting for the player.

The watch signals by itself, never from the network: one short buzz when the microphone delivers its first data of a turn, which is when the screen says "Speak" (the microphone takes a while after it starts, so the buzz comes then and not before), two short buzzes when its press ends the turn (once the microphone has stopped, or 300 ms after the press if it has not said so by then), and, when the call stops, a sound and a long buzz. The server sends no ready phrase and no turn-taken tick. The microphone starts when the screen opens, before the call exists, and the open request goes out once the microphone has delivered its first data (after 2.5 s at the latest, so that the watch's own loop is not held up while the microphone starts): the first turn's audio is kept (about half a minute at most) and goes out, as turn 1 with `seq` 0, once the open has answered. If the open still fails after five tries the cue sounds, the microphone stops and the reason stays on screen. The watch hangs up before the screen leaves: the screen waits for the `DELETE` to be answered, two seconds at most. Log lines not sent by then are kept on the watch and go to `POST /api/watch/log` at the next launch.

The phone link carries one request at a time, so the watch sends one request at a time, in this order: a press, audio, pieces, played reports, the log when it is due (every 15 s or 20 lines, sooner after a failure, and only while an answer plays or nothing is going on, never between a press and its answer), the events. While a turn is open (recorded, or its audio or press not yet taken) nothing is expected from the server: the events are then asked only every 5 s, with `wait=0`, and audio goes out in requests of about 2 KB, the rest at once when the turn ends. Otherwise the events are asked for with the short wait and jump the queue after 5 s without one. A log batch carries a `batch` number, which stays the same when the batch is sent again.

## Optional features

The open's answer lists what the server offers beyond the plain routes; the watch uses each only when it is listed, so either side works with an older other side.

- `end_on_audio`: the press that ends a turn rides on the turn's last audio request as `&end=<press>`, and the server applies it after that chunk, also when the chunk is a repeat. The watch then sends no command for that press. It keeps the number: after a failure the same press goes again on the audio request, or as a command when no audio is left to send. After the press the watch waits up to 400 ms for the microphone's last data, so that one request carries it.
- `played_param`: `played=<n>` on `GET …/events` or `GET …/piece/{n}` reports piece `n` as played, one report a request, in place of `POST …/played`. A press that cuts an answer waits for the reports of the pieces that played, as it does for the posts.
- `piece_wait`: `GET …/piece/{n}?wait=<s>` waits up to `s` seconds for piece `n` and answers without a body (`204`) when it has not come. Once the state is `generating`, the watch asks this way for the answer's first piece (the number after the last one it knows) with a wait of 2 s, and after an empty answer asks the events once with `wait=0` before it asks again. The piece's own event still arrives and is skipped. Until then the watch takes the piece to be as long as its bytes last at 16 kbit/s. A `404` ends the asking ahead, and the events name the next piece.
- `no_speech`: a notice with the code `no_speech`, sent when a turn after an answer has had no speech for a while. With Computer the watch then ends the call by itself: two short buzzes and a longer one, the hang-up, and the screen leaves. It ignores the notice before the first answer and in a session's call.
- `session_mode`: the server may hand the call to a session's call and says so on the state events.

## A session's call

Computer can hand the call to a session. State events then carry `"owner": "session"` and the session's title, which the screen shows in place of "Computer". The session's phases are `recording` (the watch starts a turn by itself, as on `listening`) and `wake` (it does not; Start begins a turn, and what the session answers plays). Start ends a turn or cuts what plays, as with Computer. Back sends the `back` command instead of hanging up: a turn being recorded is dropped without a press, no turn starts until a state event names Computer as the owner again, and the call goes on there.

## Watch log

`POST /api/watch/log` takes the same body as the call's log route, `{"batch": <n>, "sent_t": <ms>, "lines": [{"t": <ms>, "ev": "<name>", …}]}`, for the lines the watch has while no call is up to carry them. The lines a run did not get to send are kept on the watch at its exit; the next launch puts them at the front of its log, closed by a `stored_end` line (`lines`: how many came before it), and they leave with that run's first batch, on whichever of the two routes it uses. A `launch` line says how the app was opened (`how`: the launch state as the watch gives it, `glance`, the `open_with` setting, and whether it went to `computer`), and `mic_live` (`since_launch_ms`) how long the first "speak" took from there. `t` and `sent_t` are the watch's uptime in milliseconds. During a call the lines go to the call's own `…/log`. A log request never goes ahead of audio, a press, pieces or events.

With the app setting "Debug log" on (the default of the beta) the lines also carry a `req` (`lane`, `ms`, `code`, `bytes`) for every answered request, the capture states, the events and the pieces' fetch and play times. With it on or off, a turn leaves one `turn_summary` besides the errors and retries: `mic_ms` (microphone start to its first data), `bytes`, then counted from the press `stop_ms` (the capture stopped), `sent_ms` (the server had the press) and `sound_ms` (the first piece began to play), `piece_ms` (from the press being taken to the first piece being known), `fetch_ms` (that piece's download), `pieces` and `gap_max_ms` (the longest silence between pieces); a step that did not happen is `-1`. A `stall` line (`gap_ms`) marks a gap of more than 1.5 s in the watch's own loop.
