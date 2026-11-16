# Watch API

The routes the watch app calls on the server, over HTTPS through the phone's Garmin Connect app. Every request carries the watch key as `Authorization: Bearer <key>`; a missing, wrong or revoked key answers `401`, which the watch shows as "Watch key rejected".

Times are ISO 8601 in UTC with an offset, for example `2026-11-16T07:30:00+00:00`. The watch turns the hour and minute you pick into the next time the watch's own clock shows it (today if still ahead, otherwise tomorrow), converts it to UTC and sends that; the server never interprets local time.

| Route | Body | Answer |
|---|---|---|
| `GET /api/watch/alarm` | none | `200` with the state below |
| `POST /api/watch/alarm` | `{"fire_at": "<time>"}` | `201` with the new alarm |
| `DELETE /api/watch/alarm/{id}` | none | `204` |
| `POST /api/watch/alarm/dismiss` | none | `204`, stops every ringing alarm |

State:

```json
{
  "alarms": [{"id": "…", "name": "Alarm", "fire_at": "<time>"}],
  "ringing": [{"id": "…", "name": "Alarm", "fire_at": "<time>"}],
  "server_time": "<time>"
}
```

`alarms` holds the armed alarms by fire time, soonest first; `ringing` the ones sounding now. Entries may carry more fields, which the watch ignores.

Connect IQ cannot send `PATCH`, so changing an alarm's time is a `POST` of the new time followed by a `DELETE` of the old alarm. A failure in between leaves both alarms, never none.

The routes that answer `204` have no body. The simulator reports such an answer as an error (`-400`), so the app treats that code as "sent" for these routes and reads the state again afterwards.
