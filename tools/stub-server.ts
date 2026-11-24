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
// The answer's conditions block (symbol, temperatures, UV, four days) has a second switch beside it,
// CONDITIONS (default showers_day): showers_day, sunny_day, clear_night (frost, UV 0 all night),
// snow, down (the block says source_unavailable). Both switches combine freely; the no_location
// weather scenario forces the block's no_location. GET /__stub/conditions?name=<name> switches it
// on a running stub.
//
// The Computer call (/api/watch/voice/call...) is simulated: opening it queues the state; the audio of
// a turn must arrive with consecutive seq numbers (a gap answers 409); the press that ends a turn (on
// the last audio request as end=, or as a command) makes the stub "think", then answer with three
// pieces, each with its sentence; a press during an answer clears it. played=<n> on the events or a
// piece request reports a piece as played, and a piece asked for with wait=<s> is waited for. A turn
// the watch records (listening, or a session's recording) that sees no press for IDLE_S seconds
// (default 180; GET /__stub/call-idle?s=<s>) ends the call with ended idle; the stub transcribes
// nothing, so it counts from the turn's start. Every watch log line is printed, and GET
// /__stub/call-log says how many came and whether one was log_dropped. Faults for the next N call requests, on
// GET /__stub/call-fail?mode=<503|503after|hang>&count=<N>[&path=<substring>][&ms=<hang ms>]
// (503after handles the request, then answers 503, so the watch repeats a request the server already
// has); GET /__stub/call-expire forgets every call, so the watch gets 404 and opens a new one;
// GET /__stub/call-forget?n=<n> makes the server lose the last n chunks of the turn; mode=bad_audio answers audio with 422;
// GET /__stub/call-notice?code=<code>&text=<text> sends a notice event to every call;
// GET /__stub/call-think?ms=<ms> sets how long it thinks before speaking; GET /__stub/call-end?reason=<text> ends every call; GET /__stub/call-owner?on=1 answers the open with 403 owner_only.
//
// GET /__stub/call-session?title=<title>&phase=<wake|recording> hands every call to a session's call
// (a press there sends the turn and the session's answer, a piece without a sentence, follows in the
// wake phase); a back command, or GET /__stub/call-session?off=1, gives it back to Computer.
//
// The self-report (POST /api/watch/self-report?id=<uuid>&feel=<heavy|okay|good>&at=<time>, the body
// Ogg Opus) answers 202 {id} and keeps the upload in memory, once per id (a repeat answers 202 again
// and is not counted twice). GET /__stub/self-reports lists what arrived; GET
// /__stub/self-report-fail?count=<N>[&code=<status>] answers the next N uploads with that status
// (default 503) without keeping them.
const port = Number(process.env.PORT ?? 8099)
const key = process.env.WATCH_KEY ?? 'stub-key'
let scenario = process.env.SCENARIO ?? 'alarms'

type Alarm = { id: string; name: string; fire_at: string; created_at: string; source: string }

// Milliseconds the stub waits before answering GET /api/watch/alarm (a slow link); switch it on
// GET /__stub/delay?ms=<ms>.
let alarmDelayMs = Number(process.env.ALARM_DELAY_MS ?? 0)
let weather = process.env.WEATHER ?? 'rain_soon'
type Half = Record<string, unknown>
const iso = (minutes: number) => new Date(Date.now() + minutes * 60000).toISOString()
const downHalf = (reason: string): Half => ({ chance: null, verdict: 'unknown', reason })
// An unknown later half has no hours, like the server's.
const downLater = (reason: string): Half => ({ ...downHalf(reason), hours: [], heaviest_at: null, total_mm: null })
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

let conditions = process.env.CONDITIONS ?? 'showers_day'
// The conditions block per scenario: [symbol, night, temperatures of the 12 hours, hourly symbols,
// hourly UV, the four days as [symbol, max, min, chance]].
const CONDITIONS: Record<string, { symbol: string; night: boolean; temps: number[]; symbols: string[]; uv: number[]; days: [string, number, number, number][] }> = {
  showers_day: { symbol: 'rain', night: false, temps: [11, 12, 13, 14, 14, 13, 12, 11, 10, 9, 9, 8],
    symbols: ['partly', 'partly', 'cloudy', 'rain', 'rain', 'rain', 'rain', 'cloudy', 'cloudy', 'partly', 'clear', 'clear'],
    uv: [1.2, 2.4, 3.6, 4.1, 3.2, 2.0, 1.1, 0.4, 0, 0, 0, 0],
    days: [['rain', 14, 8, 90], ['partly', 16, 7, 20], ['clear', 19, 9, 0], ['thunder', 22, 12, 65]] },
  sunny_day: { symbol: 'clear', night: false, temps: [18, 20, 22, 24, 26, 27, 27, 26, 24, 22, 20, 19],
    symbols: ['clear', 'clear', 'clear', 'clear', 'clear', 'partly', 'partly', 'clear', 'clear', 'clear', 'clear', 'clear'],
    uv: [2.1, 3.8, 5.6, 7.2, 8.1, 7.4, 5.9, 4.0, 2.2, 0.8, 0.1, 0],
    days: [['clear', 27, 15, 0], ['clear', 29, 16, 5], ['partly', 28, 17, 15], ['rain', 21, 14, 80]] },
  clear_night: { symbol: 'partly', night: true, temps: [1, 1, 0, 0, 0, 0, -1, -1, -1, -1, -1, -1],
    symbols: ['clear', 'clear', 'clear', 'partly', 'partly', 'cloudy', 'cloudy', 'cloudy', 'clear', 'partly', 'cloudy', 'cloudy'],
    uv: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    days: [['cloudy', 5, -3, 0], ['partly', 4, -1, 10], ['fog', 0, -4, 0], ['clear', 0, -5, 0]] },
  snow: { symbol: 'snow', night: false, temps: [-1, -1, 0, 0, 1, 1, 0, -1, -2, -3, -4, -4],
    symbols: ['cloudy', 'snow', 'snow', 'snow', 'sleet', 'sleet', 'snow', 'snow', 'cloudy', 'cloudy', 'clear', 'clear'],
    uv: [0.3, 0.6, 0.9, 1.0, 0.8, 0.4, 0.1, 0, 0, 0, 0, 0],
    days: [['snow', 1, -4, 85], ['sleet', 2, -1, 70], ['cloudy', 3, 0, 30], ['fog', 2, -2, 10]] },
}
// The local calendar date i days from today, as YYYY-MM-DD.
function localDate(i: number) {
  const d = new Date()
  d.setDate(d.getDate() + i)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}
function conditionsAnswer(name: string) {
  const c = CONDITIONS[name]
  if (!c) {
    return { reason: name === 'no_location' ? 'no_location' : 'source_unavailable', symbol: null, night: false,
      temp_now: null, temp_min: null, temp_max: null, hours: [], uv: null, days: [] }
  }
  const first = Math.floor(Date.now() / 3600000) * 3600000
  const peak = Math.max(...c.uv)
  return {
    reason: null, symbol: c.symbol, night: c.night, temp_now: c.temps[0],
    temp_min: Math.min(...c.temps), temp_max: Math.max(...c.temps),
    hours: c.temps.map((temp, i) => ({ start: new Date(first + i * 3600000).toISOString(), temp, symbol: c.symbols[i], night: c.night, uv: c.uv[i] })),
    uv: { now: c.uv[0], peak, peak_at: peak >= 0.5 ? new Date(first + c.uv.indexOf(peak) * 3600000).toISOString() : null },
    days: c.days.map(([symbol, temp_max, temp_min, chance], i) => ({ date: localDate(i), symbol, temp_max, temp_min, chance })),
  }
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
    Object.assign(later, downLater('source_unavailable'))
  } else if (name === 'no_location') {
    location = null
    picture = false
    Object.assign(now, downHalf('no_location'))
    Object.assign(later, downLater('no_location'))
  } else if (name === 'source_down') {
    Object.assign(now, downHalf('source_unavailable'))
    Object.assign(later, downLater('source_unavailable'))
  }
  return {
    location, computed_at: iso(0), now, later,
    radar_picture_at: picture ? iso(30) : null,
    radar_picture_path: picture ? `/api/radar-link.png?t=${pictureToken}` : null,
    attribution: 'Radar: DWD · Forecast: Open-Meteo',
    conditions: conditionsAnswer(location === null ? 'no_location' : conditions),
  }
}


// ---- the Computer call

// Ogg Opus tone files (24 kHz mono, 1.5 s each) standing in for the server's pieces
const pieceFiles = [440, 550, 660].map((hz) => Bun.file(new URL(`./stub-pieces/tone${hz}.opus`, import.meta.url)))
const PIECE_MS = 1500
// the sentences of Computer's answer, one a piece
const SENTENCES = [
  'Rain reaches Aachen around ten tonight and stays until the early morning hours.',
  'Tomorrow stays dry after two.',
  'Take the rain jacket for the ride home.',
]

type CallEvent = Record<string, unknown> & { i: number }
type Call = {
  id: string
  events: CallEvent[]
  waiters: (() => void)[]
  expected: Map<number, number>
  bytes: number
  chunks: number
  presses: Set<number>
  pressApplied: number
  ended: boolean
  state: string
  pieces: Map<number, Uint8Array>
  nextPiece: number
  played: Set<number>
  generation: number
  timers: ReturnType<typeof setTimeout>[]
  idle: ReturnType<typeof setTimeout> | null
  owner: string
  session: string | null
  backs: Set<number>
}
const calls = new Map<string, Call>()
let ownerOnly = false
// how long the stub "thinks" before it speaks; GET /__stub/call-think?ms=<ms>
let thinkMs = 900
let idleS = Number(process.env.IDLE_S ?? 180)
let logDropped = 0
let fail: { mode: string; count: number; path: string; ms: number } = { mode: '', count: 0, path: '', ms: 0 }
let logLines = 0
type SelfReport = { id: string; feel: string | null; at: string | null; bytes: number; ogg: boolean; tries: number }
const selfReports = new Map<string, SelfReport>()
let selfReportFail = { count: 0, code: 503 }

function emit(call: Call, event: Record<string, unknown>) {
  const last = call.events.length ? call.events[call.events.length - 1].i : 0
  call.events.push({ ...event, i: last + 1 })
  const waiting = call.waiters.splice(0)
  waiting.forEach((wake) => wake())
}
function setState(call: Call, state: string) {
  call.state = state
  emit(call, { state, owner: call.owner, session: call.session })
  // a turn the watch records ends the call when no press comes for idleS
  if (call.idle) clearTimeout(call.idle)
  call.idle = null
  if (state === 'listening' || state === 'recording') {
    call.idle = setTimeout(() => {
      console.log(`  idle for ${idleS} s: ended`)
      call.ended = true
      emit(call, { ended: 'idle' })
    }, idleS * 1000)
  }
}
// A press: in a session's call it sends the turn; with Computer it ends the turn or cuts the answer.
function applyPress(call: Call, press: number, turn: number) {
  console.log(`  press ${press} for turn ${turn} in state ${call.state}`)
  if (call.presses.has(press)) return
  call.presses.add(press)
  if (call.idle) clearTimeout(call.idle)
  call.idle = null
  call.pressApplied = Math.max(call.pressApplied, press)
  const unheard = [...call.pieces.keys()].some((n) => !call.played.has(n))
  if (call.state === 'generating' || call.state === 'speaking' || unheard) {
    call.generation++
    call.timers.forEach(clearTimeout)
    const unplayed = [...call.pieces.keys()].filter((n) => !call.played.has(n)).length
    emit(call, { clear: true, dropped: unplayed })
    call.pieces.forEach((_, n) => !call.played.has(n) && call.pieces.delete(n))
    setState(call, call.owner === 'session' ? 'wake' : 'listening')
  } else if (call.owner === 'session') {
    emit(call, { heard: `Sent to ${call.session}.` })
    setState(call, 'wake')
    later(call, thinkMs, () => void addPiece(call, 0, false))
  } else {
    answer(call)
  }
}
// Computer's pieces carry their sentence, a session's do not.
async function addPiece(call: Call, k: number, sentence: boolean) {
  const n = call.nextPiece++
  call.pieces.set(n, new Uint8Array(await pieceFiles[k % pieceFiles.length].arrayBuffer()))
  emit(call, sentence ? { piece: n, ref: `r${n}`, ms: PIECE_MS, text: SENTENCES[k % SENTENCES.length] } : { piece: n, ref: `r${n}`, ms: PIECE_MS })
}
function later(call: Call, ms: number, fn: () => void) {
  const generation = call.generation
  call.timers.push(setTimeout(() => generation === call.generation && fn(), ms))
}
function answer(call: Call) {
  emit(call, { heard: `Stub heard ${call.bytes} bytes in ${call.chunks} chunks.` })
  setState(call, 'generating')
  later(call, thinkMs, () => {
    setState(call, 'speaking')
    for (let k = 0; k < 3; k++) later(call, 300 + k * 500, () => void addPiece(call, k, true))
    later(call, 300 + 3 * 500 + 200, () => setState(call, 'listening'))
  })
}
function toComputer(call: Call) {
  call.generation++
  call.owner = 'computer'
  call.session = null
  setState(call, 'listening')
}
function openCall(): Call {
  const call: Call = {
    id: crypto.randomUUID(), events: [], waiters: [], expected: new Map(), bytes: 0, chunks: 0, presses: new Set(), pressApplied: 0, ended: false,
    state: 'ready', pieces: new Map(), nextPiece: 0, played: new Set(), generation: 0, timers: [], idle: null,
    owner: 'computer', session: null, backs: new Set(),
  }
  calls.set(call.id, call)
  setState(call, 'ready')
  setState(call, 'listening')
  return call
}
function dropCall(call: Call) {
  call.generation++
  call.timers.forEach(clearTimeout)
  if (call.idle) clearTimeout(call.idle)
  calls.delete(call.id)
}

async function callRoute(req: Request, url: URL, path: string): Promise<Response> {
  const sub = path.slice('/api/watch/voice/call'.length)
  if (fail.count > 0 && (fail.path === '' || path.includes(fail.path))) {
    fail.count--
    console.log(`  injected ${fail.mode}`)
    if (fail.mode === 'hang') {
      await new Promise((resolve) => setTimeout(resolve, fail.ms || 40000))
      return json({ detail: 'late' }, 504)
    }
    if (fail.mode === '503') return json({ detail: 'injected' }, 503)
    if (fail.mode === 'bad_audio') return json({ detail: 'bad_audio' }, 422)
    // 503after falls through: the request is handled, the answer is replaced below
    const real = await callRoute2(req, url, sub)
    void real
    return json({ detail: 'injected' }, 503)
  }
  return callRoute2(req, url, sub)
}

async function callRoute2(req: Request, url: URL, sub: string): Promise<Response> {
  if (sub === '' && req.method === 'POST') {
    if (ownerOnly) return json({ detail: 'owner_only' }, 403)
    const call = openCall()
    return json({ call: call.id }, 201)
  }
  const m = sub.match(/^\/([^/]+)(\/.*)?$/)
  if (!m) return json({ detail: 'not found' }, 404)
  const call = calls.get(m[1])
  const rest = m[2] ?? ''
  if (rest === '' && req.method === 'DELETE') {
    if (call) dropCall(call)
    return json({})
  }
  if (!call) return json({ detail: 'unknown call' }, 404)
  // an ended call keeps answering its events, and nothing else
  if (call.ended && rest !== '/events') return json({ detail: 'ended' }, 404)

  if (rest === '/audio' && req.method === 'POST') {
    const turn = Number(url.searchParams.get('turn'))
    const seq = Number(url.searchParams.get('seq'))
    const afterPress = Number(url.searchParams.get('after_press') ?? 0)
    // a new turn's audio waits (at most 3 s) until the press before it has been applied
    for (let waited = 0; call.pressApplied < afterPress && waited < 3000; waited += 100) await new Promise((r) => setTimeout(r, 100))
    const body = new Uint8Array(await req.arrayBuffer())
    const expected = call.expected.get(turn) ?? 0
    console.log(`  audio turn ${turn} seq ${seq} ${body.length} B ${req.headers.get('content-type')} after_press ${afterPress} (expected ${expected})`)
    if (seq > expected) return json({ next_seq: expected }, 409)
    if (seq === expected) {
      call.expected.set(turn, expected + 1)
      call.bytes += body.length
      call.chunks += 1
    }
    // the press that ends the turn may ride on its last chunk
    const end = Number(url.searchParams.get('end') ?? 0)
    if (end > 0) applyPress(call, end, turn)
    return json({ next_seq: call.expected.get(turn) })
  }
  if (rest === '/command' && req.method === 'POST') {
    const body = (await req.json().catch(() => ({}))) as { action?: string; press?: number; turn?: number; back?: number }
    if (body.action === 'back' && Number.isInteger(body.back)) {
      console.log(`  back ${body.back} with ${call.owner}`)
      if (!call.backs.has(body.back!) && call.owner === 'session') toComputer(call)
      call.backs.add(body.back!)
      return json({})
    }
    const press = Number(body.press)
    if (body.action !== 'press' || !Number.isInteger(press) || !Number.isInteger(body.turn)) return json({ detail: 'bad command' }, 422)
    applyPress(call, press, body.turn!)
    return json({})
  }
  const played = url.searchParams.get('played')
  if (played !== null && (rest === '/events' || rest.startsWith('/piece/'))) {
    console.log(`  played ${played} (on ${rest})`)
    call.played.add(Number(played))
  }
  if (rest === '/events' && req.method === 'GET') {
    const after = Number(url.searchParams.get('after') ?? 0)
    const wait = Math.min(Number(url.searchParams.get('wait') ?? 0), 15)
    const fresh = () => call.events.filter((e) => e.i > after)
    if (fresh().length === 0 && wait > 0) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, wait * 1000)
        call.waiters.push(() => {
          clearTimeout(timer)
          resolve()
        })
      })
    }
    const events = fresh()
    return json({ cursor: events.length ? events[events.length - 1].i : after, events })
  }
  const piece = rest.match(/^\/piece\/(\d+)$/)
  if (piece && req.method === 'GET') {
    const n = Number(piece[1])
    const wait = Math.min(Number(url.searchParams.get('wait') ?? 0), 15)
    for (let waited = 0; !call.pieces.has(n) && waited < wait * 1000; waited += 50) await new Promise((r) => setTimeout(r, 50))
    if (wait > 0 && !call.pieces.has(n)) return new Response(null, { status: 204 })
    const data = call.pieces.get(n)
    if (!data || call.played.has(n)) return json({ detail: 'gone' }, 404)
    return new Response(data, { headers: { 'content-type': 'application/octet-stream' } })
  }
  if (rest === '/log' && req.method === 'POST') {
    const body = (await req.json().catch(() => ({}))) as { lines?: unknown[] }
    for (const line of body.lines ?? []) {
      logLines++
      if ((line as { ev?: string }).ev === 'log_dropped') logDropped++
      console.log(`  watch log: ${JSON.stringify(line)}`)
    }
    return json({})
  }
  return json({ detail: 'not found' }, 404)
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
  // a long-poll waits up to 15 s
  idleTimeout: 30,
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
    if (path === '/__stub/call-fail') {
      fail = {
        mode: url.searchParams.get('mode') ?? '503', count: Number(url.searchParams.get('count') ?? 1),
        path: url.searchParams.get('path') ?? '', ms: Number(url.searchParams.get('ms') ?? 0),
      }
      return json(fail)
    }
    if (path === '/__stub/call-expire') {
      const n = calls.size
      calls.forEach(dropCall)
      return json({ expired: n })
    }
    if (path === '/__stub/call-end') {
      const reason = url.searchParams.get('reason') ?? 'idle'
      calls.forEach((call) => {
        call.ended = true
        emit(call, { ended: reason })
      })
      return json({ ended: reason })
    }
    if (path === '/__stub/call-think') {
      thinkMs = Number(url.searchParams.get('ms') ?? 900)
      return json({ thinkMs })
    }
    if (path === '/__stub/call-forget') {
      // the server loses the last n chunks of every turn: the next chunk answers 409 with an earlier next_seq
      const n = Number(url.searchParams.get('n') ?? 1)
      calls.forEach((call) => call.expected.forEach((v, turn) => call.expected.set(turn, Math.max(0, v - n))))
      return json({ forgot: n })
    }
    if (path === '/__stub/call-notice') {
      const notice = { code: url.searchParams.get('code') ?? 'note', text: url.searchParams.get('text') ?? 'A notice.' }
      calls.forEach((call) => emit(call, { notice }))
      return json({ notice })
    }
    if (path === '/__stub/call-idle') {
      idleS = Number(url.searchParams.get('s') ?? 180)
      return json({ idleS })
    }
    if (path === '/__stub/call-log') {
      return json({ lines: logLines, dropped: logDropped })
    }
    if (path === '/__stub/call-session') {
      const off = url.searchParams.get('off') === '1'
      calls.forEach((call) => {
        if (off) return toComputer(call)
        call.owner = 'session'
        call.session = url.searchParams.get('title') ?? 'A session'
        setState(call, url.searchParams.get('phase') ?? 'wake')
      })
      return json({ session: !off })
    }
    if (path === '/__stub/self-reports') return json({ reports: [...selfReports.values()] })
    if (path === '/__stub/self-report-fail') {
      selfReportFail = { count: Number(url.searchParams.get('count') ?? 1), code: Number(url.searchParams.get('code') ?? 503) }
      return json(selfReportFail)
    }
    if (path === '/__stub/call-owner') {
      ownerOnly = url.searchParams.get('on') === '1'
      return json({ ownerOnly })
    }
    if (path === '/__stub/conditions') {
      conditions = url.searchParams.get('name') ?? 'showers_day'
      return json({ conditions })
    }
    if (path === '/__stub/weather') {
      weather = url.searchParams.get('name') ?? 'rain_soon'
      return json({ weather })
    }
    if (!path.startsWith('/api/watch/')) return json({ detail: 'not found' }, 404)
    const auth = req.headers.get('authorization')
    if (scenario === 'rejected' || auth !== `Bearer ${key}`) return json({ detail: 'key_rejected' }, 401)

    if (path === '/api/watch/log' && req.method === 'POST') {
      const body = (await req.json().catch(() => ({}))) as { lines?: unknown[] }
      for (const line of body.lines ?? []) {
        logLines++
        if ((line as { ev?: string }).ev === 'log_dropped') logDropped++
        console.log(`  watch log (no call): ${JSON.stringify(line)}`)
      }
      return json({})
    }
    if (path === '/api/watch/self-report' && req.method === 'POST') {
      const id = url.searchParams.get('id') ?? ''
      const feel = url.searchParams.get('feel')
      const at = url.searchParams.get('at')
      const body = new Uint8Array(await req.arrayBuffer())
      const ogg = body.length >= 4 && body[0] === 0x4f && body[1] === 0x67 && body[2] === 0x67 && body[3] === 0x53
      console.log(`  self-report ${id} feel ${feel ?? 'none'} at ${at} ${body.length} B ${req.headers.get('content-type')} ogg ${ogg} try ${url.searchParams.get('try') ?? 0}`)
      if (selfReportFail.count > 0) {
        selfReportFail.count--
        return json({ detail: 'injected' }, selfReportFail.code)
      }
      if (!/^[0-9a-f-]{36}$/.test(id) || (feel !== null && !['heavy', 'okay', 'good'].includes(feel)) || body.length === 0) {
        return json({ detail: 'invalid' }, 422)
      }
      const known = selfReports.get(id)
      if (known) known.tries++
      else selfReports.set(id, { id, feel, at, bytes: body.length, ogg, tries: 1 })
      return json({ id }, 202)
    }
    if (path.startsWith('/api/watch/voice/call')) return callRoute(req, url, path)
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
