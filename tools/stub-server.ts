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
// plus key_rejected and server_error, which answer the weather route with 401 and 503. Answers with
// radar carry a radar picture link, which the stub does not serve: the watch's image requests go
// through Garmin's image service, which cannot reach a local server.
// Switch it on GET /__stub/weather?name=<weather scenario>.
//
// POST /api/watch/voice/turn answers every clip with a short beep WAV (16 kHz, or 8 kHz for
// out=wav8; out=opus gets the 16 kHz WAV too, since the stub has no encoder) and logs the clip's
// content type and size. VOICE_DELAY_MS delays the answer; switch it on
// GET /__stub/voice-delay?ms=<ms>.
const port = Number(process.env.PORT ?? 8099)
const key = process.env.WATCH_KEY ?? 'stub-key'
let scenario = process.env.SCENARIO ?? 'alarms'

type Alarm = { id: string; name: string; fire_at: string; created_at: string; source: string }

// Milliseconds the stub waits before answering GET /api/watch/alarm (a slow link); switch it on
// GET /__stub/delay?ms=<ms>.
let alarmDelayMs = Number(process.env.ALARM_DELAY_MS ?? 0)
let weather = process.env.WEATHER ?? 'rain_soon'
let voiceDelayMs = Number(process.env.VOICE_DELAY_MS ?? 0)

// A mono 16-bit PCM WAV holding a 440 Hz tone of the given length.
function beepWav(rate: number, seconds: number): Uint8Array {
  const samples = Math.round(rate * seconds)
  const out = new DataView(new ArrayBuffer(44 + samples * 2))
  const text = (at: number, s: string) => [...s].forEach((c, i) => out.setUint8(at + i, c.charCodeAt(0)))
  text(0, 'RIFF')
  out.setUint32(4, 36 + samples * 2, true)
  text(8, 'WAVEfmt ')
  out.setUint32(16, 16, true)
  out.setUint16(20, 1, true)
  out.setUint16(22, 1, true)
  out.setUint32(24, rate, true)
  out.setUint32(28, rate * 2, true)
  out.setUint16(32, 2, true)
  out.setUint16(34, 16, true)
  text(36, 'data')
  out.setUint32(40, samples * 2, true)
  for (let i = 0; i < samples; i++) {
    const fade = Math.min(1, i / (rate * 0.02), (samples - i) / (rate * 0.02))
    out.setInt16(44 + i * 2, Math.round(Math.sin((2 * Math.PI * 440 * i) / rate) * 12000 * fade), true)
  }
  return new Uint8Array(out.buffer)
}

type Half = Record<string, unknown>
const iso = (minutes: number) => new Date(Date.now() + minutes * 60000).toISOString()
const downHalf = (reason: string): Half => ({ chance: null, verdict: 'unknown', reason })
const pictureToken = 'stub-picture'

// Twelve hours from the current one, the chance and amount following one shower peaking at hour peak.
function hours(peak: number, mm: number) {
  const first = Math.floor(Date.now() / 3600000) * 3600000
  return Array.from({ length: 12 }, (_, i) => {
    const share = Math.max(0, 1 - Math.abs(i - peak) / 3)
    const amount = Math.round(mm * share * 10) / 10
    const intensity = amount >= 4 ? 'heavy' : amount >= 1 ? 'moderate' : amount >= 0.1 ? 'light' : 'none'
    return { start: new Date(first + i * 3600000).toISOString(), chance: Math.round(10 + 90 * share), precipitation_mm: amount, intensity }
  })
}

// The contract's answer for the weather scenario, with times relative to now.
function weatherAnswer(name: string) {
  const now: Half = {
    chance: 70, verdict: 'rain', raining_now: false, starts_at: iso(20), ends_at: null,
    nearest_km: 8, direction: 'W', trend: 'approaching', method: 'radar', reason: null,
  }
  const later: Half = {
    chance: 100, verdict: 'rain', at: iso(160), method: 'radar+forecast', reason: null,
    hours: hours(5, 4.5), heaviest_at: iso(300), total_mm: 11.2,
  }
  let picture = true
  let location: Record<string, unknown> | null = {
    lat: 50.77, lon: 6.08, place: 'Aachen', recorded_at: iso(-12), accuracy_m: 65, source: 'ios',
  }
  if (name === 'raining') {
    Object.assign(now, { chance: 100, verdict: 'rain', raining_now: true, starts_at: null, ends_at: iso(25), nearest_km: 0, direction: null, trend: null })
    Object.assign(later, { chance: 65, verdict: 'rain', at: iso(30), hours: hours(0, 2), heaviest_at: iso(0), total_mm: 3.4 })
  } else if (name === 'dry') {
    Object.assign(now, { chance: 3, verdict: 'dry', starts_at: null, nearest_km: null, direction: null, trend: null })
    Object.assign(later, { chance: 6, verdict: 'dry', at: null, hours: hours(-9, 0), heaviest_at: null, total_mm: null })
  } else if (name === 'forecast_only') {
    Object.assign(now, { chance: 20, verdict: 'unlikely', starts_at: null, nearest_km: null, direction: null, trend: null, method: 'forecast' })
    Object.assign(later, { chance: 45, verdict: 'maybe', method: 'forecast', hours: hours(8, 0.6), heaviest_at: iso(480), total_mm: 0.6 })
    picture = false
    location = { ...location, place: 'Lisbon', recorded_at: iso(-60 * 5) }
  } else if (name === 'later_down') {
    Object.assign(later, downHalf('source_unavailable'))
  } else if (name === 'no_location') {
    location = null
    picture = false
    Object.assign(now, downHalf('no_location'))
    Object.assign(later, downHalf('no_location'))
  } else if (name === 'source_down') {
    Object.assign(now, downHalf('source_unavailable'))
    Object.assign(later, downHalf('source_unavailable'))
  }
  return {
    location, computed_at: iso(0), now, later,
    radar_picture_at: picture ? iso(30) : null,
    radar_picture_path: picture ? `/api/radar-link.png?t=${pictureToken}` : null,
    attribution: 'Radar: DWD · Forecast: Open-Meteo',
  }
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
    if (path === '/__stub/delay') {
      alarmDelayMs = Number(url.searchParams.get('ms') ?? 0)
      return json({ alarmDelayMs })
    }
    if (path === '/__stub/voice-delay') {
      voiceDelayMs = Number(url.searchParams.get('ms') ?? 0)
      return json({ voiceDelayMs })
    }
    if (path === '/__stub/weather') {
      weather = url.searchParams.get('name') ?? 'rain_soon'
      return json({ weather })
    }
    if (!path.startsWith('/api/watch/')) return json({ detail: 'not found' }, 404)
    const auth = req.headers.get('authorization')
    if (scenario === 'rejected' || auth !== `Bearer ${key}`) return json({ detail: 'key_rejected' }, 401)

    if (path === '/api/watch/voice/turn' && req.method === 'POST') {
      const clip = new Uint8Array(await req.arrayBuffer())
      const out = url.searchParams.get('out') ?? 'wav'
      console.log(`  clip ${clip.length} B ${req.headers.get('content-type')}, out=${out}`)
      if (clip.length === 0) return json({ detail: 'empty' }, 400)
      if (!['wav', 'wav8', 'opus'].includes(out)) return json({ detail: 'unknown out' }, 422)
      if (voiceDelayMs > 0) await new Promise((resolve) => setTimeout(resolve, voiceDelayMs))
      return new Response(beepWav(out === 'wav8' ? 8000 : 16000, 0.6), {
        headers: { 'content-type': 'application/octet-stream' },
      })
    }
    if (path === '/api/watch/weather' && req.method === 'GET') {
      if (weather === 'key_rejected') return json({ detail: 'key_rejected' }, 401)
      if (weather === 'server_error') return json({ detail: 'unavailable' }, 503)
      return json(weatherAnswer(weather))
    }
    if (path === '/api/watch/alarm' && req.method === 'GET') {
      if (alarmDelayMs > 0) await new Promise((resolve) => setTimeout(resolve, alarmDelayMs))
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
