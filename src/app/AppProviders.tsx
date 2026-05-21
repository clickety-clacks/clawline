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
  CrossChatNotificationStoreProvider,
  createCrossChatNotificationStore
} from "../runtime/chat/crossChatNotificationStore";
import {
  TransportMachineProvider,
  createTransportMachine
} from "../runtime/transport/transportMachine";

const authSessionStore = createAuthSessionStore();
const settingsStore = createSettingsStore();
const chatDomainStore = createChatDomainStore();
const crossChatNotificationStore = createCrossChatNotificationStore();
const transportMachine = createTransportMachine({
  authSessionStore,
  chatDomainStore,
  crossChatNotificationStore
});

export function AppProviders({ children }: { children: ReactNode }) {
  return (
    <SettingsStoreProvider value={settingsStore}>
      <AuthSessionStoreProvider value={authSessionStore}>
        <ChatDomainStoreProvider value={chatDomainStore}>
          <CrossChatNotificationStoreProvider value={crossChatNotificationStore}>
            <TransportMachineProvider value={transportMachine}>
              {children}
            </TransportMachineProvider>
          </CrossChatNotificationStoreProvider>
        </ChatDomainStoreProvider>
      </AuthSessionStoreProvider>
    </SettingsStoreProvider>
  );
}
