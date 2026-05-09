const STORAGE_PREFIX = "clawline-web";

export function loadPreference<Value>(key: string, fallback: Value): Value {
  if (typeof window === "undefined") {
    return fallback;
  }

  try {
    const raw = window.localStorage.getItem(prefixedKey(key));
    if (raw == null) {
      return fallback;
    }
    return JSON.parse(raw) as Value;
  } catch {
    return fallback;
  }
}

export function savePreference<Value>(key: string, value: Value) {
  if (typeof window === "undefined") {
    return;
  }

  window.localStorage.setItem(prefixedKey(key), JSON.stringify(value));
}

export function clearPreference(key: string) {
  if (typeof window === "undefined") {
    return;
  }

  window.localStorage.removeItem(prefixedKey(key));
}

function prefixedKey(key: string) {
  return `${STORAGE_PREFIX}:${key}`;
}
