import type { ReactNode } from "react";
import { createContext, useContext } from "react";
import { createStore } from "../shared/store";
import { useStoreValue } from "../shared/useStoreValue";
import { loadPreference, savePreference } from "../persistence/preferences";

export type AppearanceMode = "system" | "dark" | "light";
export type FontScale = "compact" | "default" | "comfortable";

export interface SettingsState {
  appearance: AppearanceMode;
  diagnostics: boolean;
  fontScale: FontScale;
}

export interface SettingsStore {
  getState(): SettingsState;
  subscribe(listener: () => void): () => void;
  setAppearance(mode: AppearanceMode): void;
  setDiagnostics(enabled: boolean): void;
  setFontScale(scale: FontScale): void;
}

const SETTINGS_KEY = "settings";

const SettingsStoreContext = createContext<SettingsStore | null>(null);

export function createSettingsStore(): SettingsStore {
  const persistedState = loadPreference<SettingsState>(SETTINGS_KEY, {
    appearance: "dark",
    diagnostics: false,
    fontScale: "default"
  });
  const baseStore = createStore<SettingsState>(persistedState);

  return {
    getState: baseStore.getState,
    subscribe: baseStore.subscribe,
    setAppearance(mode) {
      persist(baseStore, {
        ...baseStore.getState(),
        appearance: mode
      });
    },
    setDiagnostics(enabled) {
      persist(baseStore, {
        ...baseStore.getState(),
        diagnostics: enabled
      });
    },
    setFontScale(scale) {
      persist(baseStore, {
        ...baseStore.getState(),
        fontScale: scale
      });
    }
  };
}

function persist(store: ReturnType<typeof createStore<SettingsState>>, state: SettingsState) {
  savePreference(SETTINGS_KEY, state);
  store.setState(state);
}

export function SettingsStoreProvider({
  children,
  value
}: {
  children: ReactNode;
  value: SettingsStore;
}) {
  return (
    <SettingsStoreContext.Provider value={value}>
      {children}
    </SettingsStoreContext.Provider>
  );
}

export function useSettingsStore() {
  const store = useContext(SettingsStoreContext);
  if (!store) {
    throw new Error("SettingsStoreProvider is missing");
  }

  const state = useStoreValue(store, (snapshot) => snapshot);
  return { store, state };
}
