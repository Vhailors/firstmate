// @vitest-environment node
import { describe, expect, it } from 'vitest'
import { operatorTokenMatches } from './vite-plugin.ts'

describe('operator API authorization', () => {
  it('requires a non-empty exact token', () => {
    expect(operatorTokenMatches('', '')).toBe(false)
    expect(operatorTokenMatches('', 'expected')).toBe(false)
    expect(operatorTokenMatches('wrong', 'expected')).toBe(false)
    expect(operatorTokenMatches('expected', 'expected')).toBe(true)
  })
})
