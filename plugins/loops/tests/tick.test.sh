#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" node <<'JS'
const fs = require('fs')
const src = fs.readFileSync(`${process.env.ROOT}/workflows/tick.js`, 'utf8').replace(/^export const meta/m, 'const meta')
const LOOPS = [
  { name: 'loop-green-main', every: 24, plugin: 'loops' },
  { name: 'loop-issue-queue', every: 1, plugin: 'loops' },
  { name: 'loop-pr-review', every: 1, plugin: 'loops' },
  { name: 'loop-pr-fix', every: 1, idleFor: 24, plugin: 'loops' },
  { name: 'loop-tidy', every: 24, hours: [0, 6], alone: true },
  { name: 'loop-dep-drift', every: 168, plugin: 'loops' },
]
const names = LOOPS.map((l) => l.name)
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor
let passed = 0
let failed = 0

const expect = (name, got, want) => {
  const g = JSON.stringify(got)
  const w = JSON.stringify(want)
  if (g === w) {
    console.log(`ok    ${name}`)
    passed++
  } else {
    console.log(`FAIL  ${name}\n      wanted: ${w}\n      got:    ${g}`)
    failed++
  }
}

const tick = async ({ loop = 'loop-issue-queue', state, watched, idle, panel = false, first = {}, judgment = {}, hour = '12', asks: requests = [], broken = false, loops = LOOPS }) => {
  const labels = []
  const types = []
  const prompts = []
  const workflows = []
  const asks = [...requests]
  const agent = async (prompt, opts) => {
    labels.push(opts.label)
    types.push(opts.agentType)
    prompts.push(prompt)
    if (panel && opts.label === loop) {
      return { state: { sha: 'abc1234' }, brief: 'b', resume: 'r', panel: [{ lens: 'spec', cwd: '/tmp/w', brief: 'p' }], ...first }
    }
    const ask = opts.label.startsWith(loop) && !opts.label.includes(':judgment') ? asks.shift() : undefined
    return {
      state: { sha: 'abc1234' },
      brief: 'b',
      ...(opts.label === loop ? first : {}),
      ...(opts.label === `${loop}:judgment` ? judgment : {}),
      ...(ask ? { workflow: ask, resume: 'r' } : {}),
    }
  }
  const workflow = (name, a) => {
    workflows.push([name, a])
    if (broken) throw new Error(`unknown workflow ${name}`)
    return Promise.resolve({ outcome: 'accepted' })
  }
  const args = {
    home: '/home',
    kit: '/kit',
    now: '2026-10-11T12:00:00Z',
    hour,
    loops,
    states: { [loop]: state },
    busy: names.filter((n) => n !== loop),
    watched: watched ? { [loop]: watched } : {},
    idle,
  }
  const out = await new AsyncFunction('args', 'agent', 'parallel', 'phase', 'log', 'workflow', src)(
    args,
    agent,
    (fns) => Promise.all(fns.map((f) => f())),
    () => {},
    () => {},
    workflow,
  )
  const ran = out.ran.find((r) => r.loop === loop)
  return { labels, types, prompts, workflows, quiet: out.quiet, state: ran ? ran.result.state : null, result: ran ? ran.result : null }
}

const main = async () => {
  let t = await tick({ state: { at: '2026-10-11T10:00:00Z', sha: 'aaa', watched: 'f1' }, watched: 'f1' })
  expect('a due loop whose fingerprint matches its state is not dispatched', t.labels, [])
  expect('the skipped loop is reported as quiet', t.quiet, ['loop-issue-queue'])

  t = await tick({ state: { at: '2026-10-11T10:00:00Z', sha: 'aaa', watched: 'f1' }, watched: 'f2' })
  expect('a changed fingerprint dispatches the loop', t.labels, ['loop-issue-queue'])
  expect('the run records the fingerprint read before it started', t.state, { sha: 'abc1234', watched: 'f2' })

  t = await tick({ state: { at: '2026-10-10T11:00:00Z', sha: 'aaa', watched: 'f1' }, watched: 'f1' })
  expect('an unchanged loop still runs once its last run is a day old', t.labels, ['loop-issue-queue'])

  t = await tick({ state: { at: '2026-10-11T10:00:00Z', sha: 'aaa', watched: 'f1' } })
  expect('a tick without a fingerprint dispatches the loop', t.labels, ['loop-issue-queue'])
  expect('a run without a fingerprint leaves the stored one to the record merge', t.state, { sha: 'abc1234' })

  t = await tick({ state: { at: '2026-10-11T10:00:00Z', sha: 'aaa' }, watched: 'f1' })
  expect('a loop with no fingerprint in its state runs', t.labels, ['loop-issue-queue'])

  t = await tick({ state: { at: '2026-10-11T11:30:00Z', sha: 'aaa', watched: 'f1' }, watched: 'f1' })
  expect('a loop not yet due is not reported as quiet', t.quiet, [])

  const fix = { loop: 'loop-pr-fix', idle: ['loop-pr-fix'] }
  t = await tick({ ...fix, state: { at: '2026-10-11T10:00:00Z', sha: 'aaa', watched: 'f1' }, watched: 'f2' })
  expect('an idle loop is not dispatched even when its fingerprint changed', t.labels, [])
  expect('the idle PR fixer is reported as quiet', t.quiet, ['loop-pr-fix'])

  t = await tick({ ...fix, state: { at: '2026-10-10T11:00:00Z', sha: 'aaa', watched: 'f1' }, watched: 'f2' })
  expect('a loop with idleFor still runs once its last run is that old', t.labels, ['loop-pr-fix'])

  t = await tick({ ...fix, state: { sha: 'aaa' } })
  expect('a loop with idleFor and no recorded run time runs', t.labels, ['loop-pr-fix'])

  t = await tick({ state: { at: '2026-10-11T10:00:00Z', sha: 'aaa', watched: 'f1' }, watched: 'f2', panel: true })
  expect('a run with a panel records the fingerprint on its final result', t.state, { sha: 'abc1234', watched: 'f2' })

  const reviewed = { state: { at: '2026-10-11T10:00:00Z', sha: 'aaa' }, panel: true }
  t = await tick({ ...reviewed, first: { lesson: 'l1', note: '[ci] n1' } })
  expect('the first run\'s lesson and note reach the final result when the judgment run has none', [t.result.lesson, t.result.note], ['l1', '[ci] n1'])

  t = await tick({ ...reviewed, first: { lesson: 'l1', note: '[ci] n1' }, judgment: { lesson: 'l2', note: '[ci] n1' } })
  expect('both runs\' lessons are kept, first run first, and a repeated note once', [t.result.lesson, t.result.note], ['l1\nl2', '[ci] n1'])

  t = await tick({ ...reviewed })
  expect('a panel run with no lesson or note returns none', [t.result.lesson, t.result.note, t.result.panel], [undefined, undefined, undefined])

  const review = { loop: 'loop-pr-review', state: { at: '2026-10-11T10:00:00Z', sha: 'aaa' } }
  t = await tick({ ...review, idle: ['loop-pr-review'] })
  expect('a due loop the runner found idle is not dispatched', t.labels, [])
  expect('the idle loop is reported as quiet', t.quiet, ['loop-pr-review'])

  t = await tick({ ...review, state: { at: '2026-10-01T10:00:00Z', sha: 'aaa' }, idle: ['loop-pr-review'] })
  expect('an idle loop stays skipped however long ago it last ran', t.labels, [])

  t = await tick({ ...review, idle: [] })
  expect('a loop the runner did not find idle runs', t.labels, ['loop-pr-review'])
  expect('a run the runner did not find idle records no fingerprint', t.state, { sha: 'abc1234' })

  t = await tick({ ...review })
  expect('a tick without idle dispatches the loop', t.labels, ['loop-pr-review'])

  const missed = (n, missedAt) => ({ loop: 'loop-pr-fix', state: { at: '2026-10-11T09:00:00Z', sha: 'aaa', missed: n, missedAt } })
  t = await tick(missed(1, '2026-10-11T11:00:00Z'))
  expect('a loop whose last run returned nothing waits two hours', t.labels, [])

  t = await tick(missed(1, '2026-10-11T09:30:00Z'))
  expect('the first miss backs off two hours, then the loop runs', t.labels, ['loop-pr-fix'])

  t = await tick(missed(3, '2026-10-11T06:00:00Z'))
  expect('each miss in a row doubles the wait', t.labels, [])

  t = await tick(missed(9, '2026-10-10T11:00:00Z'))
  expect('the wait stops growing at a day, or the loop\'s own cadence when longer', t.labels, ['loop-pr-fix'])

  const survey = { name: 'tidy-survey', args: { mode: 'survey' } }
  const job = { name: 'tidy-job', args: { job: 'split-view' } }
  const alone = { loop: 'loop-tidy', hour: '2', state: { at: '2026-10-10T01:00:00Z', sha: 'aaa' } }
  t = await tick({ ...alone, asks: [survey] })
  expect('a loop that runs alone and asks for a workflow gets it with its args', t.workflows, [['tidy-survey', { mode: 'survey' }]])
  expect('the loop is dispatched again after the workflow', t.labels, ['loop-tidy', 'loop-tidy:workflow:1'])
  expect('the second dispatch reads what the workflow returned', t.prompts[1].includes('"outcome": "accepted"'), true)
  expect('the second dispatch reads where the first left off', t.prompts[1].includes('Where the last run left off:\nr'), true)
  expect('the recorded result carries no workflow request', t.result.workflow, undefined)

  t = await tick({ ...alone, asks: [survey, job] })
  expect('two workflows run in one tick', t.workflows, [['tidy-survey', { mode: 'survey' }], ['tidy-job', { job: 'split-view' }]])
  expect('each workflow run dispatches the loop again', t.labels.length, 3)

  t = await tick({ ...alone, asks: [survey], first: { lesson: 'l1', note: '[ui] n1' } })
  expect('the run that asked for the workflow keeps its lesson and note in the final result', [t.result.lesson, t.result.note], ['l1', '[ui] n1'])

  t = await tick({ ...alone, asks: [survey, job, job] })
  expect('a third workflow request in one tick is not run', t.workflows.length, 2)
  expect('the last dispatch is told no workflow run is left', t.prompts[2].includes('No workflow run is left this tick'), true)
  expect('the dropped request is not recorded', t.result.workflow, undefined)

  t = await tick({ ...alone, asks: [survey], broken: true })
  expect('a workflow that throws reaches the loop as an error', t.prompts[1].includes('unknown workflow tidy-survey'), true)
  expect('the loop still returns after a workflow that throws', t.state, { sha: 'abc1234' })

  t = await tick({ state: { at: '2026-10-11T10:00:00Z', sha: 'aaa' }, loops: LOOPS.map((l) => (l.name === 'loop-issue-queue' ? { ...l, every: 24 } : l)) })
  expect('a loop runs on the cadence the tick is given', t.labels, [])

  t = await tick({ state: { at: '2026-10-10T10:00:00Z', sha: 'aaa' }, loops: [] })
  expect('a tick given no loops runs nothing', t.labels, [])

  t = await tick({ state: { at: '2026-10-11T10:00:00Z', sha: 'aaa' }, asks: [job] })
  expect('a loop in the batch that asks for a workflow does not get one', t.workflows, [])
  expect('its workflow request is not recorded', t.result.workflow, undefined)

  t = await tick({ state: { at: '2026-10-11T10:00:00Z', sha: 'aaa' } })
  expect('a plugin loop runs as the plugin agent', t.types, ['loops:loop-issue-queue'])
  expect('its prompt names the loop conventions in the kit', t.prompts[0].includes('/kit/conventions.md'), true)
  t = await tick(alone)
  expect('a project loop runs as its own agent', t.types, ['loop-tidy'])
  t = await tick({ state: { at: '2026-10-11T10:00:00Z', sha: 'aaa' }, panel: true })
  expect('panel reviewers run as the plugin reviewer', t.types.includes('loops:loop-reviewer'), true)
  expect('a reviewer reads the panel rules in the kit', t.prompts.some((p) => p.includes('Read /kit/panel.md')), true)

  console.log(`\n${passed} passed, ${failed} failed`)
  process.exit(failed ? 1 : 0)
}

main()
JS
