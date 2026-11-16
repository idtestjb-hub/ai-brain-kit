/*
  usage-guard: warns before the plan's usage limits (5-hour and weekly windows) run out.
  This is about plan usage, not the context window.
    WARN and PREPARE: a notice, a status line and a note asking the assistant to tell the user
                      and suggest another assistant for the task in hand.
    HANDOFF:          a note asking the assistant to finish the current step and write a handoff
                      (the Handoff section of AGENTS.md in the vault).
  Each level fires once per window. The engine pushes the numbers through session.measure
  (the same numbers as the status line's rate_limits). Runs inside the engine, so it behaves the
  same on Windows and macOS and never calls the operating system.
  Turn it on or off with usage-guard.ps1 (Windows) or brain.py usage-guard (macOS); they also set
  the three levels in the next line.
*/
import type { EngineInterface, Register, SessionRateLimit } from 'claude-code'

const WARN = 80, PREPARE = 90, HANDOFF = 95
const BANDS = [WARN, PREPARE, HANDOFF]
const TAG = '[usage-guard] (optional mod from the AI Brain kit; turn it off with usage-guard.ps1 -Off or brain.py usage-guard --off)'
const LABEL: Record<string, string> = { five_hour: '5-hour window', seven_day: 'weekly window', spend_limit: 'spend limit' }

type Memo = { warned: Record<string, number>; forPrompt?: string; forTool?: string }
const memo: Memo = { warned: {} } // window + reset time -> level already shown; the pending note for the assistant (next prompt, next tool result)

function label(kind: string): string {
  return LABEL[kind] ?? kind
}

function left(now: number, iso?: string): string {
  const t = iso ? Date.parse(iso) : NaN
  if (!Number.isFinite(t) || t <= now) return ''
  const m = Math.round((t - now) / 60000)
  const d = Math.floor(m / 1440)
  const h = Math.floor((m % 1440) / 60)
  return d > 0 ? `resets in ${d} d ${h} h` : `resets in ${h} h ${m % 60} min`
}

async function check($: EngineInterface, limits: readonly SessionRateLimit[], st: Memo): Promise<void> {
  const now = await $.clock.now()
  const top = Math.max(0, ...limits.map(r => r.percentUsed))
  const summary = limits.map(r => `${label(r.kind)} ${Math.round(r.percentUsed)}%`).join(' · ')
  $.ui.status(top >= WARN ? `Plan usage: ${summary}` : undefined)

  let hit: { r: SessionRateLimit; band: number } | undefined
  for (const r of limits) {
    const band = Math.max(0, ...BANDS.filter(b => r.percentUsed >= b))
    const key = `${r.kind}|${r.resetsAt ?? ''}`
    if (band > (st.warned[key] ?? 0)) {
      st.warned[key] = band
      if (!hit || band > hit.band) hit = { r, band }
    }
  }
  if (!hit) return

  const { r, band } = hit
  const when = left(now, r.resetsAt)
  const where = `${label(r.kind)} at ${Math.round(r.percentUsed)}%${when ? ` (${when})` : ''}`
  if (band >= HANDOFF) {
    $.ui.toast(`Plan usage: ${where}. This session will write a handoff after the current step.`, { timeoutMs: 20000 })
    setNote(st, `${TAG} Plan usage: ${where}; all windows: ${summary}. At ${HANDOFF}% and above: finish the step in progress, then write a handoff right away as the Handoff section of AGENTS.md in the vault describes, without waiting for the user to ask. In the handoff, note when the limit resets and which assistant could take the next task. Start your reply with one line telling the user.`)
  } else {
    $.ui.toast(`Plan usage: ${where}. Get ready to hand off; another assistant can continue from the handoff.`, { timeoutMs: 15000 })
    setNote(st, `${TAG} Plan usage: ${where}; all windows: ${summary}. Start your reply with one line telling the user, and suggest which other assistant could continue the current task if the limit runs out. ${band >= PREPARE ? 'Keep the work in a state that can stop after each step. ' : ''}No handoff yet (it happens at ${HANDOFF}%).`)
  }
}

function setNote(st: Memo, note: string): void {
  st.forPrompt = note
  st.forTool = note
}

export const register: Register = on => {
  on('session.measure', async ($, e, next) => {
    if (e.changed.includes('rateLimits')) await check($, e.rateLimits, memo)
    return next(e)
  })

  // The note reaches the assistant with the next user message...
  on('prompt.submit', ($, e, next) => {
    const note = memo.forPrompt
    if (!note || e.command) return next(e)
    memo.forPrompt = undefined
    return next({ ...e, context: [...(e.context ?? []), note] })
  })

  // ...and earlier, after the next tool call of the main thread during a long run
  // (this copy does not replace the one beside the message: assistants trust that channel more)
  on('tool.call', async ($, e, next) => {
    const r = await next(e)
    const note = memo.forTool
    if (!note || e.agentId || r.deny !== undefined) return r
    memo.forTool = undefined
    return { ...r, context: [...(r.context ?? []), note] }
  })
}
