import { useSyncExternalStore } from "react";
import type { ReadableStore } from "./store";

export function useStoreValue<State, Selected>(
  store: ReadableStore<State>,
  selector: (state: State) => Selected
) {
  return useSyncExternalStore(
    store.subscribe,
    () => selector(store.getState()),
    () => selector(store.getState())
  );
}
