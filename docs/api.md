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
| `POST /api/watch/voice/call` | `201 {"call": "<id>"}` opens a call; `403 {"detail": "owner_only"}` for a key that is not the owner's |
| `POST …/call/{id}/audio?turn=<t>&seq=<n>&after_press=<k>`, `Content-Type: audio/ogg`, body = the next bytes of the turn's Ogg Opus stream | `200 {"next_seq": n+1}`; a repeated `seq` is ignored (`200`); a gap answers `409 {"next_seq": <expected>}`; `422 bad_audio` when the turn cannot be decoded any more |
| `POST …/call/{id}/command` `{"action": "press", "press": <n>, "turn": <t>}` | `200 {}`; a repeated press number is ignored |
| `GET …/call/{id}/events?after=<cursor>&wait=<s>` | short poll, `wait` is 1: `{"cursor": c, "events": [...]}` with only the events after `after` |
| `GET …/call/{id}/piece/{n}` | `application/octet-stream`, a complete Ogg Opus file (mono, declared to the player as Ogg, Opus, 24 kHz, mono), one sentence of the answer (at most about 8 s); `404` for a piece that was cleared or already played |
| `POST …/call/{id}/played` `{"n": <k>}` | `200 {}`, piece `k` played through |
| `POST …/call/{id}/log` `{"sent_t": <ms>, "lines": [{"t": <ms>, "ev": "<name>", …}]}` | `200 {}`, what the watch saw: a device line at the start, request errors with their codes and the first retries, round trips of slow requests (and of every 20th), the first chunk of a turn (size, whether it starts with `OggS`), the first playback and its states, capture and playback errors, free memory. `t` and `sent_t` are the watch's uptime in milliseconds, so a late batch can be placed in time. After an overflow the first 20 lines stay and a `log_dropped` line counts the rest |
| `DELETE …/call/{id}` | `200 {}`, hangs up (also for a call that already ended) |

A call the server no longer knows answers every route with `404`, and the watch then opens a new call. A call that ended answers audio, command, played and piece with `404` while its events still work until the watch has seen `ended`; `DELETE` answers `200`. `401` is the watch key being rejected and stops the screen with that message.

`turn` counts up per call from 1 and `seq` from 0 per turn. `press` counts up per call from 1. A turn starts by itself (after the call opens, after an answer, after a cut), so the press is only ever "send" or "cut": it ends the turn being recorded, or cuts an answer, and the server tells which. Its `turn` is the turn it ends, or for a cut the turn whose answer it cuts. The watch sends the press of a turn only after every chunk of it is acknowledged, a cut's press after the `played` reports of the pieces that played, and the next turn's first chunk after that press. `after_press` on a chunk is the number of the last press sent before its turn began (0 for none); the server holds the turn's audio until that press is applied, for at most three seconds.

A turn the watch cannot finish (a `422`, a `409` it cannot repair, a capture failure) is dropped without a press: the next turn just takes the next number. After a `409` the watch sends again, from the chunk the server expects, the chunks it still holds with their original numbers; when the answer carries no readable body it sends again everything it holds, which the server skips where it already has it.

Events carry their own index `i`, which the watch uses to skip what it saw. Each is one of:

- `{"state": "ready"|"listening"|"generating"|"speaking"}`; the watch records again on `listening` once nothing is left to play
- `{"piece": n, "ref": r, "ms": d}`, a playable piece
- `{"clear": true, "dropped": k}`, drop every unplayed piece and stop playback
- `{"heard": "<text>"}`, once per turn before the state goes to `generating`, shown while the answer is being generated
- `{"notice": {"code": "…", "text": "…"}}`, its text shown briefly on screen. `heard_nothing` (a press had nothing to answer) changes nothing else: listening goes on. `turn_timed_out` (an open turn went without a press for too long, and the server dropped what it heard) makes the watch start a new turn with a new Ogg Opus stream, `seq` 0 and `after_press` at the current press count, without a press
- `{"ended": "<reason>"}`, the call is over; Start opens a new one

Each piece plays through its own audio source, one after the other. A piece is over when the player says it stopped or, if it never does, a little after the length the event gave (`ms`, else 8 s); the next one starts then and the watch reports it as played. Recording begins after the last piece in the same way, without waiting for the player.

The watch plays its own cues, never from the network: a short high beep when its press ends the turn (after the microphone has stopped), two rising notes (the go tone) when the microphone delivers its first data of a turn, which is when the screen says "Speak" (the microphone takes about two seconds after it starts, so the tone comes then and not before), and a low falling pair when the call stops. The server sends no ready phrase and no turn-taken tick. The microphone starts when the screen opens, before the call exists, and the open request goes out once the microphone has delivered its first data (after 2.5 s at the latest, so that the watch's own loop is not held up while the microphone starts): the first turn's audio is kept (about half a minute at most) and goes out, as turn 1 with `seq` 0, once the open has answered. If the open still fails after five tries the cue sounds, the microphone stops and the reason stays on screen. The watch hangs up before the screen leaves: the `DELETE` goes first, then the rest of the log, and the screen waits for them for a few seconds.

The phone link carries one request at a time, so the watch sends one request at a time, in this order: a press, audio, pieces, played reports, the log when it is due (every 15 s or 20 lines, sooner after a failure, only while the link has nothing else to carry, and at hang-up), the events. The events are asked for with the short wait and jump the queue after 5 s without one. A log batch carries a `batch` number, which stays the same when the batch is sent again.

## Watch log

`POST /api/watch/log` takes the same body as the call's log route, `{"batch": <n>, "sent_t": <ms>, "lines": [{"t": <ms>, "ev": "<name>", …}]}`, for the lines the watch has while no call is up to carry them: when the call has not opened yet and the link is idle, and once at launch with `"stored": true` for the lines the previous run kept (the end of its last turn, or its exit) and did not get to send. `t` and `sent_t` are the watch's uptime in milliseconds. During a call the lines go to the call's own `…/log`. A log request never goes ahead of audio, a press, pieces or events.

With the app setting "Debug log" on (the default of the beta) the lines also carry a heartbeat about every second (a gap in it is a stall of the watch's own loop), a `req_start` and `req_end` (`lane`, `ms`, `code`, `bytes`) for every request, the capture states, the events and the pieces' fetch and play times. With it off a turn leaves one `turn_summary` (`open_ms`, `mic_ms`, `bytes`, `pieces`, `gap_max_ms`, `starved`) besides the errors and retries.
