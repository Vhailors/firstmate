// The operator server is launched once and outlives the shell that started it,
// so its frozen FM_* environment must not govern later browser-initiated fleet
// calls: a stale FM_GATE_REFUSE_BYPASS would silence the fleet-lifecycle
// refusal, a stale FM_PENDING_REPLY_EXISTING_CORR would reuse another turn's
// correlation id, and a stale FM_STATE_OVERRIDE or FM_CONFIG_OVERRIDE would
// resolve a different home than the bound one. Every fleet binding a child
// script needs is passed explicitly instead.
export function fleetNeutralEnv(environment: NodeJS.ProcessEnv) {
  return Object.fromEntries(Object.entries(environment).filter(([name]) => !name.startsWith('FM_')))
}
