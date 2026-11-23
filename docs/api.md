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
| `POST …/call/{id}/audio?turn=<t>&seq=<n>`, `Content-Type: audio/ogg`, body = the next bytes of the turn's Ogg Opus stream | `200 {"next_seq": n+1}`; a repeated `seq` is ignored (`200`); a gap answers `409 {"next_seq": <expected>}` |
| `POST …/call/{id}/command` `{"action": "press", "press": <n>}` | `200 {}`; a repeated press number is ignored |
| `GET …/call/{id}/events?after=<cursor>&wait=<s>` | long-poll, `wait` is 10: `{"cursor": c, "events": [...]}` with only the events after `after` |
| `GET …/call/{id}/piece/{n}` | `application/octet-stream`, raw PCM s16le 16 kHz mono; `404` for a piece that was cleared or already played |
| `POST …/call/{id}/played` `{"n": <k>}` | `200 {}`, piece `k` played through |
| `POST …/call/{id}/log` `{"lines": [{"t": <ms>, "ev": "<name>", …}]}` | `200 {}`, what the watch saw: request errors with their codes, retries, playback and capture errors, free memory |
| `DELETE …/call/{id}` | `200 {}`, hangs up (also for a call that already ended) |

Any route of a call the server no longer knows answers `404`; the watch then opens a new call. `401` is the watch key being rejected and stops the screen with that message.

`turn` counts up per call from 1 and `seq` from 0 per turn. `press` counts up per call from 1. A turn starts by itself (after the call opens, after an answer, after a cut), so the press is only ever "send" or "cut": it ends the turn being recorded, or cuts an answer, and the server tells which. The watch sends the press of a turn only after every chunk of it is acknowledged, a cut's press after the `played` reports of the pieces that played, and the next turn's first chunk after that press.

Events carry their own index `i`, which the watch uses to skip what it saw. Each is one of:

- `{"state": "ready"|"listening"|"generating"|"speaking"}`; the watch starts recording on `listening` once nothing is left to play
- `{"piece": n, "ref": r, "ms": d}`, a playable piece
- `{"clear": true, "dropped": k}`, drop every unplayed piece and stop playback
- `{"heard": "<text>"}`, shown while the answer is being generated
- `{"said": "<sentence>", "ref": r}`, appended to the line shown while speaking
- `{"notice": {"code": "…", "text": "…"}}`, shown on screen
- `{"ended": "<reason>"}`, the call is over; Start opens a new one

The pieces play through one streaming source as 16 kHz mono PCM behind a 44-byte WAV header the watch prepends to each stream.
