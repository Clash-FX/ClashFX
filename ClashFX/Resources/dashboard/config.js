window.__METACUBEXD_CONFIG__ = {
  ...(window.__METACUBEXD_CONFIG__ || {}),
  defaultBackendURL:
    (window.__METACUBEXD_CONFIG__ && window.__METACUBEXD_CONFIG__.defaultBackendURL) ||
    `${window.location.protocol}//${window.location.host}`,
}

;(function installClashFXRuleTimeCompatibility() {
  const originalFetch = window.fetch.bind(window)

  function isMeaningfulRuleTime(count, value) {
    if (Number(count) <= 0 || typeof value !== "string") {
      return false
    }

    const milliseconds = Date.parse(value)
    return Number.isFinite(milliseconds) && milliseconds > 0
  }

  function sanitizeRuleTimes(payload) {
    if (!payload || typeof payload !== "object") {
      return false
    }

    const rules = Array.isArray(payload.rules)
      ? payload.rules
      : Object.values(payload.rules || {})
    let changed = false

    for (const rule of rules) {
      const extra = rule && rule.extra
      if (!extra || typeof extra !== "object") {
        continue
      }

      if (!isMeaningfulRuleTime(extra.hitCount, extra.hitAt) && "hitAt" in extra) {
        delete extra.hitAt
        changed = true
      }
      if (!isMeaningfulRuleTime(extra.missCount, extra.missAt) && "missAt" in extra) {
        delete extra.missAt
        changed = true
      }
    }

    return changed
  }

  window.fetch = async function (input, init) {
    const response = await originalFetch(input, init)
    const inputURL = input instanceof Request ? input.url : input
    let path

    try {
      path = new URL(String(inputURL), window.location.href).pathname.replace(/\/+$/, "")
    } catch (_) {
      return response
    }

    if (!path.endsWith("/rules") || !response.ok) {
      return response
    }

    let payload
    try {
      payload = await response.clone().json()
    } catch (_) {
      return response
    }

    if (!sanitizeRuleTimes(payload)) {
      return response
    }

    const headers = new Headers(response.headers)
    headers.delete("content-length")
    return new Response(JSON.stringify(payload), {
      status: response.status,
      statusText: response.statusText,
      headers,
    })
  }
})()
