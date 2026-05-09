import { openDB } from "idb";
import type { ChatDomainSnapshot } from "../chat/chatDomainStore";
import { getOrCreateTabRuntimeScopeId } from "./tabRuntimeScope";

const DATABASE_NAME = "clawline-web";
const DATABASE_VERSION = 1;

export interface ChatPersistence {
  load(): Promise<ChatDomainSnapshot | null>;
  save(snapshot: ChatDomainSnapshot): Promise<void>;
  clear(): Promise<void>;
}

export function createMemoryChatPersistence(
  initialSnapshot: ChatDomainSnapshot | null = null
): ChatPersistence {
  let snapshot = initialSnapshot;

  return {
    async load() {
      return snapshot;
    },
    async save(nextSnapshot) {
      snapshot = nextSnapshot;
    },
    async clear() {
      snapshot = null;
    }
  };
}

export function createIndexedDbChatPersistence(
  scopeId = getOrCreateTabRuntimeScopeId()
): ChatPersistence {
  const snapshotKey = `chat-snapshot:${scopeId}`;

  return {
    async load() {
      const database = await openDatabase();
      return (await database.get("chatSnapshots", snapshotKey)) ?? null;
    },
    async save(snapshot) {
      const database = await openDatabase();
      await database.put("chatSnapshots", snapshot, snapshotKey);
    },
    async clear() {
      const database = await openDatabase();
      await database.delete("chatSnapshots", snapshotKey);
    }
  };
}

async function openDatabase() {
  return openDB(DATABASE_NAME, DATABASE_VERSION, {
    upgrade(database) {
      if (!database.objectStoreNames.contains("chatSnapshots")) {
        database.createObjectStore("chatSnapshots");
      }
    }
  });
}
