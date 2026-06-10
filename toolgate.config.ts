import { definePolicy, allow, deny, next } from '/Users/bryce/.bun/install/global/node_modules/toolgate/src/index'
import { safeBashCommandOrPipeline } from '/Users/bryce/.bun/install/global/node_modules/toolgate/policies/parse-bash-ast'

const PIXELWATCH_DEBUG_BIN = '/Users/bryce/Dev/pixelwatch/.build/debug/pixelwatch'

export default definePolicy([
  {
    name: 'Allow pixelwatch debug binary',
    description: `Permits running ${PIXELWATCH_DEBUG_BIN}, optionally piped through safe filters`,
    handler: async (call) => {
      const tokens = await safeBashCommandOrPipeline(call)
      if (!tokens) return next()
      if (tokens[0] !== PIXELWATCH_DEBUG_BIN) return next()
      return allow()
    },
  },
])

// Disable built-in or inherited policies by name.
// Use `toolgate disable --json` to see all loaded policies.
export const disable: string[] = []
