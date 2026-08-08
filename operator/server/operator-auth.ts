import { lstat, readFile, realpath } from 'node:fs/promises'
import { resolve } from 'node:path'

const MAX_TOKEN_FILE_BYTES = 1024
const TOKEN_PATTERN = /^[a-f0-9]{64}$/

export type OperatorRuntime =
  | { mode: 'fixture' }
  | { mode: 'live'; fmHome: string; repoRoot: string; tokenFile: string }

export function resolveOperatorRuntime(
  environment: NodeJS.ProcessEnv,
  defaultRepoRoot: string,
): OperatorRuntime {
  if (environment.VITE_FM_OPERATOR_FIXTURE === '1') return { mode: 'fixture' }
  if (!environment.FM_HOME) {
    throw new Error('FM_HOME is required for the live operator. Use pnpm dev:fixture only for tests.')
  }
  const fmHome = resolve(environment.FM_HOME)
  return {
    mode: 'live',
    fmHome,
    repoRoot: resolve(environment.FM_ROOT_OVERRIDE || defaultRepoRoot),
    tokenFile: resolve(environment.FM_OPERATOR_TOKEN_FILE || `${fmHome}/config/operator-token`),
  }
}

export async function readBoundOperatorToken(tokenFile: string, fmHome: string) {
  const metadata = await lstat(tokenFile)
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new Error('Operator token record must be a regular file, not a symlink.')
  }
  if (metadata.size > MAX_TOKEN_FILE_BYTES) throw new Error('Operator token record exceeds its size bound.')
  if ((metadata.mode & 0o077) !== 0) throw new Error('Operator token record permissions must be 0600 or stricter.')

  const [homeLine, tokenLine, ...extra] = (await readFile(tokenFile, 'utf8')).trimEnd().split('\n')
  if (extra.length > 0 || !homeLine?.startsWith('fm_home=') || !tokenLine?.startsWith('token=')) {
    throw new Error('Operator token record has an invalid format.')
  }
  const boundHome = await realpath(homeLine.slice('fm_home='.length))
  const expectedHome = await realpath(fmHome)
  if (boundHome !== expectedHome) throw new Error('Operator token record is bound to a different FM_HOME.')
  const token = tokenLine.slice('token='.length)
  if (!TOKEN_PATTERN.test(token)) throw new Error('Operator token record contains an invalid token.')
  return token
}
