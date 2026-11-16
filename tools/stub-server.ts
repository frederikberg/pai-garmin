#!/usr/bin/env bun
// A stand-in for the server's watch alarm API, for running the watch app in the simulator without
// a real server. It keeps the alarms in memory and logs one line per request (the Bearer key
// itself is never printed).
//
//   WATCH_KEY=<key> PORT=8099 SCENARIO=alarms bun tools/stub-server.ts
//
// SCENARIO: alarms (default, two armed alarms), empty, ringing (one ringing alarm), rejected (every
// request answers 401). A running stub switches scenario, with fresh data, on
// GET /__stub/scenario?name=<scenario>.
//
// The weather answer has its own scenario, WEATHER (default rain_soon): rain_soon, raining, dry,
// forecast_only, later_down (radar answers, the 12 h forecast does not), no_location, source_down,
// plus key_rejected and server_error, which answer the weather route with 401 and 503.
// Switch it on GET /__stub/weather?name=<weather scenario>.
const port = Number(process.env.PORT ?? 8099)
const key = process.env.WATCH_KEY ?? 'stub-key'
let scenario = process.env.SCENARIO ?? 'alarms'

type Alarm = { id: string; name: string; fire_at: string; created_at: string; source: string }

let weather = process.env.WEATHER ?? 'rain_soon'

type Half = Record<string, unknown>
const iso = (minutes: number) => new Date(Date.now() + minutes * 60000).toISOString()
const downHalf = (reason: string): Half => ({ chance: null, verdict: 'unknown', reason })

// The contract's answer for the weather scenario, with times relative to now.
function weatherAnswer(name: string) {
  const now: Half = {
    chance: 70, verdict: 'rain', raining_now: false, starts_at: iso(20), ends_at: null,
    nearest_km: 8, direction: 'W', trend: 'approaching', method: 'radar', reason: null,
  }
  const later: Half = { chance: 40, verdict: 'maybe', at: iso(160), method: 'radar+forecast', reason: null }
  let location: Record<string, unknown> | null = {
    lat: 50.77, lon: 6.08, place: 'Aachen', recorded_at: iso(-12), accuracy_m: 65, source: 'ios',
  }
  if (name === 'raining') {
    Object.assign(now, { chance: 100, verdict: 'rain', raining_now: true, starts_at: null, ends_at: iso(25), nearest_km: 0, direction: null, trend: null })
    Object.assign(later, { chance: 65, verdict: 'rain', at: iso(30) })
  } else if (name === 'dry') {
    Object.assign(now, { chance: 3, verdict: 'dry', starts_at: null, nearest_km: null, direction: null, trend: null })
    Object.assign(later, { chance: 6, verdict: 'dry', at: null })
  } else if (name === 'forecast_only') {
    Object.assign(now, { chance: 20, verdict: 'unlikely', starts_at: null, nearest_km: null, direction: null, trend: null, method: 'forecast' })
    Object.assign(later, { chance: 45, verdict: 'maybe', method: 'forecast' })
    location = { ...location, place: 'Lisbon', recorded_at: iso(-60 * 5) }
  } else if (name === 'later_down') {
    Object.assign(later, downHalf('source_unavailable'))
  } else if (name === 'no_location') {
    location = null
    Object.assign(now, downHalf('no_location'))
    Object.assign(later, downHalf('no_location'))
  } else if (name === 'source_down') {
    Object.assign(now, downHalf('source_unavailable'))
    Object.assign(later, downHalf('source_unavailable'))
  }
  return { location, computed_at: iso(0), now, later, attribution: 'Radar: DWD · Forecast: Open-Meteo' }
}

let alarms: Alarm[] = []
let ringing: (Alarm & { started_at: string; ends_at: string })[] = []
let nextId = 1

const inMinutes = (minutes: number) => new Date(Math.ceil(Date.now() / 60000) * 60000 + minutes * 60000).toISOString()

function makeAlarm(fireAt: string, source = 'watch'): Alarm {
  return { id: `alarm-${nextId++}`, name: 'Alarm', fire_at: fireAt, created_at: new Date().toISOString(), source }
}

function reset(name: string) {
  scenario = name
  nextId = 1
  alarms = name === 'alarms' ? [makeAlarm(inMinutes(90), 'web'), makeAlarm(inMinutes(60 * 20), 'ios')] : []
  ringing =
    name === 'ringing'
      ? [{ ...makeAlarm(inMinutes(0)), started_at: inMinutes(0), ends_at: inMinutes(1) }]
      : []
}
reset(scenario)

const json = (body: unknown, status = 200) => Response.json(body, { status })
const sorted = () => [...alarms].sort((a, b) => a.fire_at.localeCompare(b.fire_at))

Bun.serve({
  port,
  async fetch(req) {
    const url = new URL(req.url)
    const path = url.pathname
    console.log(`${new Date().toISOString()} ${req.method} ${path}`)

    if (path === '/__stub/scenario') {
      reset(url.searchParams.get('name') ?? 'alarms')
      return json({ scenario })
    }
    if (path === '/__stub/weather') {
      weather = url.searchParams.get('name') ?? 'rain_soon'
      return json({ weather })
    }
    if (!path.startsWith('/api/watch/')) return json({ detail: 'not found' }, 404)
    const auth = req.headers.get('authorization')
    if (scenario === 'rejected' || auth !== `Bearer ${key}`) return json({ detail: 'key_rejected' }, 401)

    if (path === '/api/watch/weather' && req.method === 'GET') {
      if (weather === 'key_rejected') return json({ detail: 'key_rejected' }, 401)
      if (weather === 'server_error') return json({ detail: 'unavailable' }, 503)
      return json(weatherAnswer(weather))
    }
    if (path === '/api/watch/alarm' && req.method === 'GET') {
      return json({ alarms: sorted(), ringing, server_time: new Date().toISOString() })
    }
    if (path === '/api/watch/alarm' && req.method === 'POST') {
      const body = (await req.json().catch(() => ({}))) as { fire_at?: string }
      const at = Date.parse(body.fire_at ?? '')
      if (Number.isNaN(at) || at <= Date.now() || at > Date.now() + 7 * 86400000) return json({ detail: 'invalid fire_at' }, 422)
      const alarm = makeAlarm(new Date(at).toISOString())
      alarms.push(alarm)
      return json(alarm, 201)
    }
    if (path === '/api/watch/alarm/dismiss' && req.method === 'POST') {
      ringing = []
      return json({})
    }
    const one = path.match(/^\/api\/watch\/alarm\/([^/]+)$/)
    if (one && req.method === 'DELETE') {
      alarms = alarms.filter((a) => a.id !== one[1])
      return json({})
    }
    if (one && req.method === 'PUT') {
      const alarm = alarms.find((a) => a.id === one[1])
      if (!alarm) return json({ detail: 'not found' }, 404)
      const body = (await req.json().catch(() => ({}))) as { fire_at?: string }
      if (body.fire_at) alarm.fire_at = new Date(body.fire_at).toISOString()
      return json(alarm)
    }
    return json({ detail: 'not found' }, 404)
  },
})
console.log(`stub watch API on :${port}, scenario ${scenario}, weather ${weather}`)
