/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** risk-mw base URL the Live panel calls, e.g. https://risk-mw.example.com. */
  readonly VITE_RISK_MW_URL?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
