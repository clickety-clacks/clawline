export type StoreListener = () => void;

export interface ReadableStore<State> {
  getState(): State;
  subscribe(listener: StoreListener): () => void;
}

export interface WritableStore<State> extends ReadableStore<State> {
  setState(updater: State | ((current: State) => State)): void;
}

export function createStore<State>(initialState: State): WritableStore<State> {
  let state = initialState;
  const listeners = new Set<StoreListener>();

  return {
    getState() {
      return state;
    },
    setState(updater) {
      const nextState =
        typeof updater === "function"
          ? (updater as (current: State) => State)(state)
          : updater;

      if (Object.is(nextState, state)) {
        return;
      }

      state = nextState;
      listeners.forEach((listener) => listener());
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    }
  };
}
