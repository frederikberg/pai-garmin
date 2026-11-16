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
const port = Number(process.env.PORT ?? 8099)
const key = process.env.WATCH_KEY ?? 'stub-key'
let scenario = process.env.SCENARIO ?? 'alarms'

type Alarm = { id: string; name: string; fire_at: string; created_at: string; source: string }

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
    if (!path.startsWith('/api/watch/')) return json({ detail: 'not found' }, 404)
    const auth = req.headers.get('authorization')
    if (scenario === 'rejected' || auth !== `Bearer ${key}`) return json({ detail: 'key_rejected' }, 401)

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
      return new Response(null, { status: 204 })
    }
    const one = path.match(/^\/api\/watch\/alarm\/([^/]+)$/)
    if (one && req.method === 'DELETE') {
      alarms = alarms.filter((a) => a.id !== one[1])
      return new Response(null, { status: 204 })
    }
    if (one && req.method === 'PATCH') {
      const alarm = alarms.find((a) => a.id === one[1])
      if (!alarm) return json({ detail: 'not found' }, 404)
      const body = (await req.json().catch(() => ({}))) as { fire_at?: string }
      if (body.fire_at) alarm.fire_at = new Date(body.fire_at).toISOString()
      return json(alarm)
    }
    return json({ detail: 'not found' }, 404)
  },
})
console.log(`stub watch API on :${port}, scenario ${scenario}`)
