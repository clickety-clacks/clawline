import { generateUuidV4 } from "../shared/uuid";

const RUNTIME_SCOPE_KEY = "clawline-web:tab-runtime-scope";

let fallbackRuntimeScopeId: string | null = null;

export function getOrCreateTabRuntimeScopeId() {
  if (typeof window === "undefined") {
    return getOrCreateFallbackRuntimeScopeId();
  }

  try {
    const existing = window.sessionStorage.getItem(RUNTIME_SCOPE_KEY);
    if (existing && existing.length > 0) {
      return existing;
    }

    const generated = generateUuidV4();
    window.sessionStorage.setItem(RUNTIME_SCOPE_KEY, generated);
    return generated;
  } catch {
    return getOrCreateFallbackRuntimeScopeId();
  }
}

function getOrCreateFallbackRuntimeScopeId() {
  if (fallbackRuntimeScopeId) {
    return fallbackRuntimeScopeId;
  }

  fallbackRuntimeScopeId = generateUuidV4();
  return fallbackRuntimeScopeId;
}
