import { render } from "@testing-library/react";
import type { ReactElement } from "react";
import { MemoryRouter } from "react-router-dom";
import {
  AuthSessionStoreProvider,
  createAuthSessionStore,
  type AuthSessionStore
} from "../../runtime/auth/authSessionStore";
import {
  ChatDomainStoreProvider,
  createChatDomainStore,
  type ChatDomainStore
} from "../../runtime/chat/chatDomainStore";
import { createMemoryChatPersistence } from "../../runtime/persistence/indexedDbChatPersistence";
import {
  SettingsStoreProvider,
  createSettingsStore,
  type SettingsStore
} from "../../runtime/settings/settingsStore";
import {
  TransportMachineProvider,
  createTransportMachine,
  type TransportMachine
} from "../../runtime/transport/transportMachine";
import type { WebSocketFactory } from "../../runtime/transport/wsClient";

interface Options {
  authStore?: AuthSessionStore;
  chatStore?: ChatDomainStore;
  route?: string;
  settingsStore?: SettingsStore;
  transportMachine?: TransportMachine;
  webSocketFactory?: WebSocketFactory;
}

export function renderWithProviders(element: ReactElement, options: Options = {}) {
  const authStore = options.authStore ?? createAuthSessionStore();
  const chatStore =
    options.chatStore ??
    createChatDomainStore({ persistence: createMemoryChatPersistence() });
  const settingsStore = options.settingsStore ?? createSettingsStore();
  const transportMachine =
    options.transportMachine ??
    createTransportMachine({
      authSessionStore: authStore,
      chatDomainStore: chatStore,
      webSocketFactory: options.webSocketFactory
    });

  return {
    authStore,
    chatStore,
    settingsStore,
    transportMachine,
    ...render(
      <SettingsStoreProvider value={settingsStore}>
        <AuthSessionStoreProvider value={authStore}>
          <ChatDomainStoreProvider value={chatStore}>
            <TransportMachineProvider value={transportMachine}>
              <MemoryRouter initialEntries={[options.route ?? "/"]}>
                {element}
              </MemoryRouter>
            </TransportMachineProvider>
          </ChatDomainStoreProvider>
        </AuthSessionStoreProvider>
      </SettingsStoreProvider>
    )
  };
}
