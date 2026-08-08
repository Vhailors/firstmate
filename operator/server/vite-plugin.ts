import { timingSafeEqual } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { fileURLToPath } from 'node:url'
import type { Plugin, PreviewServer, ViteDevServer } from 'vite'
import { InstructionController, InstructionMutationError } from './instruction-controller.ts'
import { readBoundOperatorToken, resolveOperatorRuntime } from './operator-auth.ts'
import { SafeFirstmateAdapter } from './safe-adapter.ts'

const MAX_REQUEST_BYTES = 16 * 1024

// bin/fm-operator.sh probes this header to prove the loopback port belongs to
// this home's operator and not to an unrelated listener. Its wire form is a
// contract; operator/server/vite-plugin.test.ts pins it.
export const OPERATOR_API_MARKER_HEADER = 'X-Firstmate-Operator'
export const OPERATOR_API_MARKER_VALUE = 'bounded-api'

export function operatorTokenMatches(candidate: string, expected: string) {
  if (!candidate || !expected) return false
  const left = Buffer.from(candidate)
  const right = Buffer.from(expected)
  return left.length === right.length && timingSafeEqual(left, right)
}

function bearer(request: IncomingMessage) {
  const authorization = request.headers.authorization ?? ''
  return authorization.startsWith('Bearer ') ? authorization.slice(7) : ''
}

function json(response: ServerResponse, status: number, body: unknown) {
  response.statusCode = status
  response.setHeader('Content-Type', 'application/json; charset=utf-8')
  response.setHeader(OPERATOR_API_MARKER_HEADER, OPERATOR_API_MARKER_VALUE)
  response.setHeader('Cache-Control', 'no-store')
  response.setHeader('X-Content-Type-Options', 'nosniff')
  response.setHeader('Content-Security-Policy', "default-src 'self'; frame-ancestors 'none'")
  response.end(JSON.stringify(body))
}

async function readJson(request: IncomingMessage) {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
    size += buffer.length
    if (size > MAX_REQUEST_BYTES) throw new InstructionMutationError(413, 'Operator request exceeds its size bound.')
    chunks.push(buffer)
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8')) as Record<string, unknown>
  } catch {
    throw new InstructionMutationError(400, 'Operator request body must be valid JSON.')
  }
}

function describe(error: unknown) {
  return error instanceof Error ? error.message : 'unknown error'
}

function logDiagnostic(message: string) {
  process.stderr.write(`${message}\n`)
}

function stringField(body: Record<string, unknown>, field: string) {
  const value = body[field]
  if (typeof value !== 'string') throw new InstructionMutationError(400, `${field} must be a string.`)
  return value
}

export function operatorApiPlugin(environment: NodeJS.ProcessEnv = process.env): Plugin {
  const defaultRepoRoot = fileURLToPath(new URL('../..', import.meta.url))
  function configure(server: ViteDevServer | PreviewServer) {
    const runtime = resolveOperatorRuntime(environment, defaultRepoRoot)
    if (runtime.mode === 'fixture') return
    const adapter = new SafeFirstmateAdapter({
      repoRoot: runtime.repoRoot,
      fmHome: runtime.fmHome,
      skillRoots: environment.FM_OPERATOR_SKILL_ROOTS?.split(':').filter(Boolean),
    })
    const instructions = new InstructionController({
      repoRoot: runtime.repoRoot,
      fmHome: runtime.fmHome,
      readSnapshot: () => adapter.read(),
    })
    server.middlewares.use('/api', async (request, response) => {
      // Everything before the token comparison answers an unauthenticated
      // caller, so its body stays fixed: the home path and the credential
      // file's state belong in the server log, not in that response.
      let expectedToken: string
      try {
        expectedToken = await readBoundOperatorToken(runtime.tokenFile, runtime.fmHome)
      } catch (error) {
        logDiagnostic(`fm-operator: operator session credential unusable: ${describe(error)}`)
        json(response, 503, { error: 'The operator session credential is unavailable.' })
        return
      }
      if (!operatorTokenMatches(bearer(request), expectedToken)) {
        json(response, 401, { error: 'A valid operator session token is required.' })
        return
      }
      try {
        if (request.method === 'GET' && request.url === '/fleet') {
          json(response, 200, await adapter.read())
          return
        }
        if (request.method === 'POST' && request.url === '/instructions/preview') {
          const body = await readJson(request)
          json(response, 200, await instructions.preview(stringField(body, 'workerId'), stringField(body, 'instruction')))
          return
        }
        if (request.method === 'POST' && request.url === '/instructions/confirm') {
          const body = await readJson(request)
          json(response, 202, await instructions.confirm(stringField(body, 'previewId')))
          return
        }
        json(response, 404, { error: 'No such bounded operator API route.' })
      } catch (error) {
        if (error instanceof InstructionMutationError) {
          json(response, error.status, { error: error.message, delivered: error.delivered })
          return
        }
        logDiagnostic(`fm-operator: bounded API request failed: ${describe(error)}`)
        json(response, 503, { error: 'Operator API unavailable.' })
      }
    })
  }

  return {
    name: 'firstmate-operator-api',
    configureServer: configure,
    configurePreviewServer: configure,
  }
}
