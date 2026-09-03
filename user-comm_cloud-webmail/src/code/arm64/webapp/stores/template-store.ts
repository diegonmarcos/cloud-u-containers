import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import type { EmailTemplate } from '@/lib/template-types';
import {
  exportTemplates as exportUtil,
  importTemplates as importUtil,
  filterTemplates,
} from '@/lib/template-utils';

const MAX_RECENT = 5;

interface TemplateStore {
  templates: EmailTemplate[];
  recentTemplateIds: string[];

  addTemplate: (template: Omit<EmailTemplate, 'id' | 'createdAt' | 'updatedAt'>) => EmailTemplate;
  updateTemplate: (id: string, updates: Partial<Omit<EmailTemplate, 'id' | 'createdAt'>>) => void;
  deleteTemplate: (id: string) => void;
  duplicateTemplate: (id: string, nameSuffix?: string) => EmailTemplate | null;
  toggleFavorite: (id: string) => void;
  recordUsage: (id: string) => void;

  getTemplatesByCategory: () => Record<string, EmailTemplate[]>;
  getFavorites: () => EmailTemplate[];
  getRecent: () => EmailTemplate[];
  searchTemplates: (query: string) => EmailTemplate[];

  exportAllTemplates: () => string;
  importTemplates: (json: string) => { count: number; errors: string[] };
}

export const useTemplateStore = create<TemplateStore>()(
  persist(
    (set, get) => ({
      templates: [],
      recentTemplateIds: [],

      addTemplate: (data) => {
        const now = new Date().toISOString();
        const template: EmailTemplate = {
          ...data,
          id: crypto.randomUUID(),
          createdAt: now,
          updatedAt: now,
        };
        set((state) => ({
          templates: [...state.templates, template],
        }));
        return template;
      },

      updateTemplate: (id, updates) => {
        set((state) => ({
          templates: state.templates.map((t) =>
            t.id === id
              ? { ...t, ...updates, updatedAt: new Date().toISOString() }
              : t
          ),
        }));
      },

      deleteTemplate: (id) => {
        set((state) => ({
          templates: state.templates.filter((t) => t.id !== id),
          recentTemplateIds: state.recentTemplateIds.filter((rid) => rid !== id),
        }));
      },

      duplicateTemplate: (id, nameSuffix) => {
        const original = get().templates.find((t) => t.id === id);
        if (!original) return null;

        const now = new Date().toISOString();
        const duplicate: EmailTemplate = {
          ...original,
          id: crypto.randomUUID(),
          name: `${original.name} ${nameSuffix || '(copy)'}`,
          isFavorite: false,
          createdAt: now,
          updatedAt: now,
        };

        set((state) => ({
          templates: [...state.templates, duplicate],
        }));
        return duplicate;
      },

      toggleFavorite: (id) => {
        set((state) => ({
          templates: state.templates.map((t) =>
            t.id === id ? { ...t, isFavorite: !t.isFavorite, updatedAt: new Date().toISOString() } : t
          ),
        }));
      },

      recordUsage: (id) => {
        set((state) => {
          const filtered = state.recentTemplateIds.filter((rid) => rid !== id);
          return {
            recentTemplateIds: [id, ...filtered].slice(0, MAX_RECENT),
          };
        });
      },

      getTemplatesByCategory: () => {
        const { templates } = get();
        const grouped: Record<string, EmailTemplate[]> = {};
        for (const t of templates) {
          const cat = t.category || '';
          if (!grouped[cat]) grouped[cat] = [];
          grouped[cat].push(t);
        }
        return grouped;
      },

      getFavorites: () => {
        return get().templates.filter((t) => t.isFavorite);
      },

      getRecent: () => {
        const { templates, recentTemplateIds } = get();
        return recentTemplateIds
          .map((id) => templates.find((t) => t.id === id))
          .filter(Boolean) as EmailTemplate[];
      },

      searchTemplates: (query) => {
        return filterTemplates(get().templates, query);
      },

      exportAllTemplates: () => {
        return exportUtil(get().templates);
      },

      importTemplates: (json) => {
        const result = importUtil(json);
        if (result.templates.length > 0) {
          set((state) => ({
            templates: [...state.templates, ...result.templates],
          }));
        }
        return { count: result.templates.length, errors: result.errors };
      },
    }),
    {
      name: 'template-storage',
      version: 1,
    }
  )
);
