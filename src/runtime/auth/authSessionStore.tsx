import type { ReactNode } from "react";
import { createContext, useContext } from "react";
import { createStore } from "../shared/store";
import { useStoreValue } from "../shared/useStoreValue";
import {
  clearPreference,
  loadPreference,
  savePreference
} from "../persistence/preferences";
import { generateUuidV4, isUuidV4 } from "../shared/uuid";

export interface AuthSessionRecord {
  claimedName: string;
  deviceId: string;
  isAdmin: boolean;
  serverUrl: string;
  token: string;
  userId: string;
}

export interface PairingDraft {
  claimedName: string;
  serverUrl: string;
}

export interface AuthSessionState {
  session: AuthSessionRecord | null;
  draft: PairingDraft;
  status: "ready";
}

export interface AuthSessionStore {
  getState(): AuthSessionState;
  subscribe(listener: () => void): () => void;
  updateDraft(draft: Partial<PairingDraft>): void;
  storePairingSession(session: Omit<AuthSessionRecord, "isAdmin"> & { isAdmin?: boolean }): void;
  updateAdminStatus(isAdmin: boolean): void;
  logout(): void;
}

const AUTH_SESSION_KEY = "auth-session";
const PAIRING_DRAFT_KEY = "pairing-draft";
const DEVICE_ID_KEY = "device-id";

const AuthSessionStoreContext = createContext<AuthSessionStore | null>(null);

export function createAuthSessionStore(): AuthSessionStore {
  const persistedSession = loadPreference<AuthSessionRecord | null>(
    AUTH_SESSION_KEY,
    null
  );
  const persistedDraft = loadPreference<PairingDraft>(PAIRING_DRAFT_KEY, {
    claimedName: "",
    serverUrl: ""
  });
  const baseStore = createStore<AuthSessionState>({
    session: persistedSession,
    draft: persistedDraft,
    status: "ready"
  });

  return {
    getState: baseStore.getState,
    subscribe: baseStore.subscribe,
    updateDraft(draft) {
      baseStore.setState((current) => {
        const nextState = {
          ...current,
          draft: {
            ...current.draft,
            ...draft
          }
        };
        savePreference(PAIRING_DRAFT_KEY, nextState.draft);
        return nextState;
      });
    },
    storePairingSession(session) {
      baseStore.setState((current) => {
        const nextState = {
          ...current,
          session: {
            ...session,
            isAdmin: session.isAdmin ?? false
          }
        };
        savePreference(AUTH_SESSION_KEY, nextState.session);
        return nextState;
      });
    },
    updateAdminStatus(isAdmin) {
      baseStore.setState((current) => {
        if (!current.session) {
          return current;
        }
        const nextState = {
          ...current,
          session: {
            ...current.session,
            isAdmin
          }
        };
        savePreference(AUTH_SESSION_KEY, nextState.session);
        return nextState;
      });
    },
    logout() {
      clearPreference(AUTH_SESSION_KEY);
      baseStore.setState((current) => ({
        ...current,
        session: null
      }));
    }
  };
}

export function AuthSessionStoreProvider({
  children,
  value
}: {
  children: ReactNode;
  value: AuthSessionStore;
}) {
  return (
    <AuthSessionStoreContext.Provider value={value}>
      {children}
    </AuthSessionStoreContext.Provider>
  );
}

export function useAuthSessionStore() {
  const store = useContext(AuthSessionStoreContext);
  if (!store) {
    throw new Error("AuthSessionStoreProvider is missing");
  }

  const state = useStoreValue(store, (snapshot) => snapshot);
  return { store, state };
}

export function getOrCreateDeviceId(existingDeviceId?: string) {
  if (isUuidV4(existingDeviceId)) {
    savePreference(DEVICE_ID_KEY, existingDeviceId);
    return existingDeviceId;
  }

  const persistedDeviceId = loadPreference<string | null>(DEVICE_ID_KEY, null);
  if (isUuidV4(persistedDeviceId)) {
    return persistedDeviceId;
  }

  const generated = generateUuidV4();
  savePreference(DEVICE_ID_KEY, generated);
  return generated;
}
