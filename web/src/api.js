// Set when the server runs with H3_API_TOKEN; kept per browser and sent as a bearer token.
const TOKEN_KEY = 'h3.apiToken'
let declined = false

function storedToken() {
  try { return localStorage.getItem(TOKEN_KEY) || '' } catch { return '' }
}

function askToken() {
  if (declined) return false
  const entered = window.prompt('This Studio requires an API token (H3_API_TOKEN). Enter it to continue:')?.trim()
  if (!entered) { declined = true; return false }
  try { localStorage.setItem(TOKEN_KEY, entered) } catch { /* private mode: ask again next load */ }
  return true
}

// fetch with the stored token; on 401 asks once and retries. Concurrent polls that failed with an
// old token retry with the newly stored one instead of asking again.
async function authFetch(url, init = {}) {
  for (let attempt = 0; ; attempt++) {
    const token = storedToken()
    const res = await fetch(url, token ? { ...init, headers: { ...init.headers, Authorization: `Bearer ${token}` } } : init)
    if (res.status !== 401 || attempt) return res
    if (storedToken() === token && !askToken()) return res
  }
}

async function request(method, url, body) {
  const res = await authFetch(url, { method, body })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `${res.status} ${res.statusText}`)
  return data
}

export const api = {
  health: () => request('GET', '/api/health'),
  presets: () => request('GET', '/api/presets'),
  // One page of jobs, newest first, plus the total from X-Total-Count.
  jobs: async (limit, offset = 0, kind = '', imageModel = '', audioModel = '') => {
    const res = await authFetch(`/api/jobs?limit=${limit}&offset=${offset}${kind ? `&kind=${encodeURIComponent(kind)}` : ''}${imageModel ? `&image_model=${encodeURIComponent(imageModel)}` : ''}${audioModel ? `&audio_model=${encodeURIComponent(audioModel)}` : ''}`)
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
    const items = await res.json()
    return { items, total: Number(res.headers.get('X-Total-Count') ?? items.length) }
  },
  create: (form) => request('POST', '/api/jobs', form),
  cancel: (id) => request('POST', `/api/jobs/${id}/cancel`),
  upscale: (id, upscaler, target) => {
    const form = new FormData()
    form.append('upscaler', upscaler)
    form.append('target', target)
    return request('POST', `/api/jobs/${id}/upscale`, form)
  },
  remove: (id) => request('DELETE', `/api/jobs/${id}`),
}
