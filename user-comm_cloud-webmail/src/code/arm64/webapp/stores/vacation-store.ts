import { create } from 'zustand';
import type { JMAPClient } from '@/lib/jmap/client';

interface VacationStore {
  isEnabled: boolean;
  fromDate: string | null;
  toDate: string | null;
  subject: string;
  textBody: string;
  htmlBody: string | null;
  isLoading: boolean;
  isSaving: boolean;
  error: string | null;
  isSupported: boolean;

  fetchVacationResponse: (client: JMAPClient) => Promise<void>;
  updateVacationResponse: (client: JMAPClient, updates: {
    isEnabled?: boolean;
    fromDate?: string | null;
    toDate?: string | null;
    subject?: string;
    textBody?: string;
    htmlBody?: string | null;
  }) => Promise<void>;
  setSupported: (supported: boolean) => void;
  clearState: () => void;
}

export const useVacationStore = create<VacationStore>()((set) => ({
  isEnabled: false,
  fromDate: null,
  toDate: null,
  subject: '',
  textBody: '',
  htmlBody: null,
  isLoading: false,
  isSaving: false,
  error: null,
  isSupported: false,

  fetchVacationResponse: async (client) => {
    set({ isLoading: true, error: null });
    try {
      const vacation = await client.getVacationResponse();
      set({
        isEnabled: vacation.isEnabled,
        fromDate: vacation.fromDate,
        toDate: vacation.toDate,
        subject: vacation.subject || '',
        textBody: vacation.textBody || '',
        htmlBody: vacation.htmlBody,
        isLoading: false,
      });
    } catch (error) {
      set({
        isLoading: false,
        error: error instanceof Error ? error.message : 'fetch_error',
      });
    }
  },

  updateVacationResponse: async (client, updates) => {
    set({ isSaving: true, error: null });
    try {
      await client.setVacationResponse(updates);
      set((state) => ({
        ...state,
        ...updates,
        isSaving: false,
      }));
    } catch (error) {
      set({
        isSaving: false,
        error: error instanceof Error ? error.message : 'save_error',
      });
      throw error;
    }
  },

  setSupported: (supported) => set({ isSupported: supported }),

  clearState: () => set({
    isEnabled: false,
    fromDate: null,
    toDate: null,
    subject: '',
    textBody: '',
    htmlBody: null,
    isLoading: false,
    isSaving: false,
    error: null,
    isSupported: false,
  }),
}));
