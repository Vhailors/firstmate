import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { operatorApiPlugin } from './server/vite-plugin.ts'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), operatorApiPlugin()],
})
