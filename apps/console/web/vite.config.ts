import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The console is served from the admin service at / in production and from Vite in development.
// `base: './'` keeps the built asset paths relative, so the same dist/ works whether it is mounted
// at the root of Cloud Run or opened from a file path during a demo.
export default defineConfig({
  plugins: [react()],
  base: './',
  build: { outDir: 'dist', sourcemap: true },
  server: {
    port: 5173,
    // main.tsx imports design-system/web/finnest.css (and its fonts) straight from the
    // design system at the repo root, three directories up. The build bundles it; the dev server must be allowed to
    // read it.
    fs: { allow: ['.', '../../../design-system'] },
    // The admin API runs on 8099 in development; proxying keeps the console's fetch calls
    // same-origin so there is one less thing that behaves differently from production.
    proxy: { '/v1/admin': 'http://127.0.0.1:8099', '/v1/auth': 'http://127.0.0.1:8099', '/health': 'http://127.0.0.1:8099' },
  },
})
