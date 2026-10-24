export const meta = {
  name: 'tick',
  description: 'One loop-runner tick: work out which loops are due and run them, four at a time',
  whenToUse: 'From the loops:runner skill. args: the output of `loop-runner inputs`, { home, kit, now, hour, loops: [the loops of .claude/loops.json], states: { "<loop>": <state object> }, busy: ["<loop>"], watched: { "<loop>": "<fingerprint>" }, idle: ["<loop>"] }, plus events: { "<loop>": "<text>" }. Returns each loop\'s result for `loop-runner record`.',
  phases: [
    { title: 'Run', detail: 'the four most overdue loops, at most one weekly, each in its own worktree, with its review panel' },
    { title: 'Alone', detail: 'a loop marked alone, in the runner checkout, with the workflow runs it asks for' },
  ],
}

const A = args || {}
const LOOPS = A.loops || []
const HOUR = 3600 * 1000
const SLACK = 5 * 60 * 1000
const QUIET = 24 * HOUR
const now = Date.parse(A.now)
const states = A.states || {}
const atOf = (name) => (states[name] && states[name].at) || null
const events = A.events || {}
const busy = new Set(A.busy || [])
const watched = A.watched || {}
const idle = new Set(A.idle || [])

const hour = Number(A.hour)

const inHours = (l) => !l.hours || (hour >= l.hours[0] && hour < l.hours[1])

const backingOff = (l) => {
  const s = states[l.name]
  if (!s || !s.missed || !s.missedAt) return false
  return now - Date.parse(s.missedAt) < Math.min(Math.max(l.every, 24), 2 ** s.missed) * HOUR - SLACK
}

const isDue = (l) => {
  if (l.routine || busy.has(l.name) || !inHours(l) || backingOff(l)) return false
  if (events[l.name]) return true
  const at = atOf(l.name) ? Date.parse(atOf(l.name)) : Number.NaN
  return Number.isNaN(at) || now - at >= l.every * HOUR - SLACK
}

const unchanged = (l) => {
  const s = states[l.name]
  if (events[l.name]) return false
  const since = s && s.at ? now - Date.parse(s.at) : Number.NaN
  if (idle.has(l.name)) return !l.idleFor || since < l.idleFor * HOUR - SLACK
  return Boolean(s && watched[l.name] && s.watched === watched[l.name] && since < QUIET - SLACK)
}

const overdue = (l) => {
  const at = atOf(l.name) ? Date.parse(atOf(l.name)) : Number.NaN
  if (events[l.name] || Number.isNaN(at)) return Number.POSITIVE_INFINITY
  return (now - at) / (l.every * HOUR)
}

const backing = LOOPS.filter(backingOff).map((l) => `${l.name} (miss ${states[l.name].missed})`)
if (backing.length) log(`backing off after a run with no result: ${backing.join(', ')}`)
const quiet = LOOPS.filter((l) => isDue(l) && unchanged(l)).map((l) => l.name)
if (quiet.length) log(`unchanged since their last run: ${quiet.join(', ')}`)
const due = LOOPS.filter((l) => isDue(l) && !unchanged(l)).sort((a, b) => overdue(b) - overdue(a))
const loner = due.find((l) => l.alone)
const batch = []
let weekly = 0
for (const l of due) {
  if (l.alone || batch.length === 4) continue
  if (l.every >= 168) {
    if (weekly) continue
    weekly++
  }
  batch.push(l)
}
const waiting = due.filter((l) => l !== loner && !batch.includes(l)).map((l) => l.name)
if (waiting.length) log(`due next tick: ${waiting.join(', ')}`)

const RESULT = {
  type: 'object',
  required: ['state', 'brief'],
  properties: {
    state: {
      type: 'object',
      required: ['sha'],
      properties: { sha: { type: 'string' } },
    },
    brief: { type: 'string' },
    lesson: { type: 'string' },
    note: { type: 'string' },
    panel: {
      type: 'array',
      items: {
        type: 'object',
        required: ['lens', 'cwd', 'brief'],
        properties: { lens: { type: 'string' }, cwd: { type: 'string' }, brief: { type: 'string' }, model: { type: 'string' } },
      },
    },
    workflow: {
      type: 'object',
      required: ['name'],
      properties: { name: { type: 'string' }, args: { type: 'object' } },
    },
    resume: { type: 'string' },
    busy: { type: 'boolean' },
  },
}

const WORKFLOW_RUNS = 2
const KIT = A.kit || ''
const agentType = (l) => (l.plugin ? `${l.plugin}:${l.name}` : l.name)

const prompt = (l) =>
  [
    `Run ${l.name}. The loop conventions are ${KIT}/conventions.md. The loop home is ${A.home}; every .claude/loops/ path in the loop's skill and conventions is under it. You write nothing there: your result carries it back.`,
    `Your state from the last run: ${JSON.stringify(states[l.name] || null)}`,
    events[l.name] ? `This run was triggered by:\n${events[l.name]}` : '',
  ]
    .filter(Boolean)
    .join('\n\n')

const reviewer = (l, p, i, phaseTitle) =>
  agent(
    `You are one reviewer on ${l.name}'s panel. Read ${KIT}/panel.md and review as lens "${p.lens}", read-only, in ${p.cwd}.\n\n${p.brief}`,
    { agentType: 'loops:loop-reviewer', label: `${l.name}:${p.lens}:${i + 1}`, phase: phaseTitle, ...(p.model ? { model: p.model } : {}) },
  )

const resumed = (l, first, reports) =>
  [
    `Continue ${l.name} after its panel, per Panel in ${KIT}/conventions.md. The loop home is ${A.home}; you write nothing there.`,
    `Where the first run left off:\n${first.resume || ''}`,
    `Its state so far: ${JSON.stringify(first.state)}`,
    ...first.panel.map((p, i) => `Reviewer ${i + 1}, lens ${p.lens}${p.model ? `, ${p.model}` : ''}, in ${p.cwd}:\n${reports[i] || '(no report)'}`),
  ].join('\n\n')

const stamp = (l, result) => {
  if (result && result.state && watched[l.name]) result.state.watched = watched[l.name]
  return result
}

const built = (l, last, out, left) =>
  [
    `Continue ${l.name} after the ${last.workflow.name} workflow ran with ${JSON.stringify(last.workflow.args || {})}, per Workflow runs in its skill. The loop home is ${A.home}; you write nothing there.`,
    `Where the last run left off:\n${last.resume || ''}`,
    `Its state so far: ${JSON.stringify(last.state)}`,
    `The workflow returned:\n${JSON.stringify(out, null, 2)}`,
    left ? `You may ask for ${left} more workflow run this tick.` : 'No workflow run is left this tick: return your final result.',
  ].join('\n\n')

const carry = (first, result) => {
  if (!result) return result
  delete result.panel
  for (const k of ['lesson', 'note']) {
    const lines = [...new Set([first[k], result[k]].filter(Boolean))]
    if (lines.length) result[k] = lines.join('\n')
  }
  return result
}

const run = async (l, phaseTitle) => {
  const isolation = l.alone ? {} : { isolation: 'worktree' }
  let result = await agent(prompt(l), { agentType: agentType(l), label: l.name, phase: phaseTitle, schema: RESULT, ...isolation })
  if (result && result.panel && result.panel.length) {
    const first = result
    const reports = await parallel(first.panel.map((p, i) => () => reviewer(l, p, i, phaseTitle)))
    result = carry(first, await agent(resumed(l, first, reports), { agentType: agentType(l), label: `${l.name}:judgment`, phase: phaseTitle, schema: RESULT }))
  }
  for (let n = 1; l.alone && result && result.workflow && n <= WORKFLOW_RUNS; n++) {
    const last = result
    let out
    try {
      out = await workflow(last.workflow.name, last.workflow.args || {})
    } catch (e) {
      out = { error: String((e && e.message) || e) }
    }
    result = carry(last, await agent(built(l, last, out, WORKFLOW_RUNS - n), { agentType: agentType(l), label: `${l.name}:workflow:${n}`, phase: phaseTitle, schema: RESULT }))
  }
  if (result) {
    delete result.panel
    delete result.workflow
  }
  return { loop: l.name, result: stamp(l, result) }
}

phase('Run')
const ran = await parallel(batch.map((l) => () => run(l, 'Run')))

if (loner) {
  phase('Alone')
  ran.push(await run(loner, 'Alone'))
}

return { ran: ran.filter(Boolean), waiting, quiet }
