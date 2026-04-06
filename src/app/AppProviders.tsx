import { ReactNode } from "react";
import {
  AuthSessionStoreProvider,
  createAuthSessionStore
} from "../runtime/auth/authSessionStore";
import {
  SettingsStoreProvider,
  createSettingsStore
} from "../runtime/settings/settingsStore";
import {
  ChatDomainStoreProvider,
  createChatDomainStore
} from "../runtime/chat/chatDomainStore";
import {
  TransportMachineProvider,
  createTransportMachine
} from "../runtime/transport/transportMachine";

const authSessionStore = createAuthSessionStore();
const settingsStore = createSettingsStore();
const chatDomainStore = createChatDomainStore();
const transportMachine = createTransportMachine({
  authSessionStore,
  chatDomainStore
});

export function AppProviders({ children }: { children: ReactNode }) {
  return (
    <SettingsStoreProvider value={settingsStore}>
      <AuthSessionStoreProvider value={authSessionStore}>
        <ChatDomainStoreProvider value={chatDomainStore}>
          <TransportMachineProvider value={transportMachine}>
            {children}
          </TransportMachineProvider>
        </ChatDomainStoreProvider>
      </AuthSessionStoreProvider>
    </SettingsStoreProvider>
  );
}
