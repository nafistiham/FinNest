/**
 * Sign-in state, held in one place.
 *
 * The token is a signed claim from the service, not a client-side flag: clearing localStorage logs
 * you out, but forging the key does not log you in. It lives in localStorage rather than a cookie
 * because the console and the API are the same origin in production and a different one in
 * development, and a bearer header behaves the same in both.
 */

const KEY = 'bhorosha-admin-token'
const NAME = 'bhorosha-admin-user'

export interface Session {
  token: string
  username: string
  expires_at: number
}

export const session = (): Session | null => {
  try {
    const token = localStorage.getItem(KEY)
    const username = localStorage.getItem(NAME)
    if (!token || !username) return null
    const claims = JSON.parse(atob(token.split('.')[0]!.replace(/-/g, '+').replace(/_/g, '/'))) as {
      exp: number
    }
    if (claims.exp * 1000 < Date.now()) {
      clearSession()
      return null
    }
    return { token, username, expires_at: claims.exp }
  } catch {
    return null
  }
}

export const saveSession = (s: Session): void => {
  localStorage.setItem(KEY, s.token)
  localStorage.setItem(NAME, s.username)
}

export const clearSession = (): void => {
  localStorage.removeItem(KEY)
  localStorage.removeItem(NAME)
}

export class SignInError extends Error {
  constructor(readonly status: number) {
    super(`sign-in failed: HTTP ${status}`)
  }
}

export async function signIn(username: string, password: string): Promise<Session> {
  const response = await fetch('/v1/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password }),
  })
  /* The status travels as data, not prose, so the sign-in screen can say it in either language. */
  if (!response.ok) throw new SignInError(response.status)
  const payload = (await response.json()) as Session
  saveSession(payload)
  return payload
}

/** Hours left on the session, for the settings screen. */
export const hoursLeft = (s: Session): number => Math.max(0, (s.expires_at * 1000 - Date.now()) / 3600000)
