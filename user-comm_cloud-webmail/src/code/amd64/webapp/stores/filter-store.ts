import { create } from 'zustand';
import type { JMAPClient } from '@/lib/jmap/client';
import type { FilterRule, SieveCapabilities } from '@/lib/jmap/sieve-types';
import { parseScript } from '@/lib/sieve/parser';
import { generateScript } from '@/lib/sieve/generator';
import { debug } from '@/lib/debug';

interface FilterStore {
  rules: FilterRule[];
  isLoading: boolean;
  isSaving: boolean;
  error: string | null;
  isSupported: boolean;
  sieveCapabilities: SieveCapabilities | null;
  activeScriptId: string | null;
  isOpaque: boolean;
  rawScript: string;

  setSupported: (supported: boolean) => void;
  fetchFilters: (client: JMAPClient) => Promise<void>;
  saveFilters: (client: JMAPClient) => Promise<void>;
  validateScript: (client: JMAPClient, content: string) => Promise<{ isValid: boolean; errors?: string[] }>;
  addRule: (rule: FilterRule) => void;
  updateRule: (ruleId: string, updates: Partial<FilterRule>) => void;
  deleteRule: (ruleId: string) => void;
  reorderRules: (ruleIds: string[]) => void;
  toggleRule: (ruleId: string) => void;
  setRawScript: (content: string) => void;
  resetToVisualBuilder: () => void;
  clearState: () => void;
}

export const useFilterStore = create<FilterStore>()((set, get) => ({
  rules: [],
  isLoading: false,
  isSaving: false,
  error: null,
  isSupported: false,
  sieveCapabilities: null,
  activeScriptId: null,
  isOpaque: false,
  rawScript: '',

  setSupported: (supported) => set({ isSupported: supported }),

  fetchFilters: async (client) => {
    set({ isLoading: true, error: null });
    try {
      const capabilities = client.getSieveCapabilities();
      set({ sieveCapabilities: capabilities });

      const scripts = await client.getSieveScripts();
      debug.log('Sieve scripts fetched:', scripts.length);

      const activeScript = scripts.find(s => s.isActive) || scripts[0];
      if (!activeScript) {
        set({ isLoading: false, rules: [], activeScriptId: null, rawScript: '', isOpaque: false });
        return;
      }

      set({ activeScriptId: activeScript.id });

      const content = await client.getSieveScriptContent(activeScript.blobId);
      set({ rawScript: content });

      const result = parseScript(content);

      if (result.isOpaque) {
        debug.log('Sieve script is opaque (hand-edited)');
        set({ isLoading: false, isOpaque: true, rules: [] });
      } else {
        debug.log('Parsed', result.rules.length, 'filter rules');
        set({ isLoading: false, isOpaque: false, rules: result.rules });
      }
    } catch (error) {
      debug.error('Failed to fetch filters:', error);
      set({
        isLoading: false,
        error: error instanceof Error ? error.message : 'Failed to fetch filters',
      });
    }
  },

  saveFilters: async (client) => {
    set({ isSaving: true, error: null });
    try {
      const { isOpaque, rawScript, rules, activeScriptId } = get();

      let content: string;
      if (isOpaque) {
        content = rawScript;
      } else {
        content = generateScript(rules);
      }

      if (activeScriptId) {
        await client.updateSieveScript(activeScriptId, content, true);
      } else {
        const script = await client.createSieveScript('filters', content, true);
        set({ activeScriptId: script.id });
      }

      set({ isSaving: false, rawScript: content });
      debug.log('Filters saved successfully');
    } catch (error) {
      debug.error('Failed to save filters:', error);
      set({
        isSaving: false,
        error: error instanceof Error ? error.message : 'Failed to save filters',
      });
      throw error;
    }
  },

  validateScript: async (client, content) => {
    return client.validateSieveScript(content);
  },

  addRule: (rule) => {
    set((state) => ({ rules: [...state.rules, rule] }));
  },

  updateRule: (ruleId, updates) => {
    set((state) => ({
      rules: state.rules.map(r => r.id === ruleId ? { ...r, ...updates } : r),
    }));
  },

  deleteRule: (ruleId) => {
    set((state) => ({
      rules: state.rules.filter(r => r.id !== ruleId),
    }));
  },

  reorderRules: (ruleIds) => {
    set((state) => {
      const ruleMap = new Map(state.rules.map(r => [r.id, r]));
      const reordered = ruleIds.map(id => ruleMap.get(id)).filter(Boolean) as FilterRule[];
      return { rules: reordered };
    });
  },

  toggleRule: (ruleId) => {
    set((state) => ({
      rules: state.rules.map(r =>
        r.id === ruleId ? { ...r, enabled: !r.enabled } : r
      ),
    }));
  },

  setRawScript: (content) => set({ rawScript: content }),

  resetToVisualBuilder: () => set({ isOpaque: false, rawScript: '', rules: [] }),

  clearState: () => set({
    rules: [],
    isLoading: false,
    isSaving: false,
    error: null,
    isSupported: false,
    sieveCapabilities: null,
    activeScriptId: null,
    isOpaque: false,
    rawScript: '',
  }),
}));
