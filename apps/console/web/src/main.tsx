import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
// The design system first, straight from its source of truth (tokens, @font-face for SolaimanLipi
// and Baloo Da 2, light/dark, bn/en type scale, reduced motion). Vite bundles it and its fonts into
// dist/, which is what scripts/deploy.sh ships; nothing is copied or forked here.
import '../../../../design-system/web/finnest.css'
import './styles.css'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
