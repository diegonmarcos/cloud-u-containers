import type { AppState, Snapshot } from './types';

type Listener = () => void;

const initial: AppState = {
  route: { path: 'overview', params: {} },
  snapshot: null,
};

class Store {
  private state: AppState = { ...initial };
  private listeners = new Set<Listener>();
  get(): AppState { return this.state; }
  set(patch: Partial<AppState>) { this.state = { ...this.state, ...patch }; this.listeners.forEach(l => l()); }
  subscribe(fn: Listener): () => void { this.listeners.add(fn); return () => { this.listeners.delete(fn); }; }
}
export const store = new Store();
export type { AppState, Snapshot };
