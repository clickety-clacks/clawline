import "@testing-library/jest-dom/vitest";
import "fake-indexeddb/auto";
import { afterEach, beforeEach } from "vitest";

async function clearDatabase(name: string) {
  await new Promise<void>((resolve, reject) => {
    const request = indexedDB.deleteDatabase(name);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
    request.onblocked = () => resolve();
  });
}

beforeEach(async () => {
  window.localStorage.clear();
  window.sessionStorage.clear();
  await clearDatabase("clawline-web");
});

afterEach(async () => {
  window.localStorage.clear();
  window.sessionStorage.clear();
  await clearDatabase("clawline-web");
});
