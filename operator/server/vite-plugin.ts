import { timingSafeEqual } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Plugin } from 'vite'
import { SafeFirstmateAdapter } from './safe-adapter.ts'

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
  response.setHeader('Cache-Control', 'no-store')
  response.setHeader('X-Content-Type-Options', 'nosniff')
  response.setHeader('Content-Security-Policy', "default-src 'self'; frame-ancestors 'none'")
  response.end(JSON.stringify(body))
}

export function operatorApiPlugin(): Plugin {
  return {
    name: 'firstmate-operator-api',
    configureServer(server) {
      const repoRoot = process.env.FM_ROOT_OVERRIDE || new URL('../..', import.meta.url).pathname
      const fmHome = process.env.FM_HOME || repoRoot
      const expectedToken = process.env.FM_OPERATOR_TOKEN || ''
      const adapter = new SafeFirstmateAdapter({
        repoRoot,
        fmHome,
        skillRoots: process.env.FM_OPERATOR_SKILL_ROOTS?.split(':').filter(Boolean),
      })
      server.middlewares.use('/api', async (request, response) => {
        if (!expectedToken) {
          json(response, 503, { error: 'Live API is disabled until FM_OPERATOR_TOKEN is configured.' })
          return
        }
        if (!operatorTokenMatches(bearer(request), expectedToken)) {
          json(response, 401, { error: 'A valid operator session token is required.' })
          return
        }
        if (request.method !== 'GET' || request.url !== '/fleet') {
          json(response, 404, { error: 'No such bounded operator API route.' })
          return
        }
        try {
          json(response, 200, await adapter.read())
        } catch (error) {
          json(response, 503, { error: error instanceof Error ? error.message : 'Fleet adapter unavailable.' })
        }
      })
    },
  }
}
