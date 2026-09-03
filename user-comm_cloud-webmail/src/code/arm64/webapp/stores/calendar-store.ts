import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import type { JMAPClient } from '@/lib/jmap/client';
import type { Calendar, CalendarEvent, CalendarParticipant } from '@/lib/jmap/types';
import { debug } from '@/lib/debug';

export type CalendarViewMode = 'month' | 'week' | 'day' | 'agenda';

interface CalendarStore {
  calendars: Calendar[];
  events: CalendarEvent[];
  selectedDate: Date;
  viewMode: CalendarViewMode;
  selectedCalendarIds: string[];
  selectedEventId: string | null;
  isLoading: boolean;
  isLoadingEvents: boolean;
  supportsCalendar: boolean;
  error: string | null;
  dateRange: { start: string; end: string } | null;

  setSupported: (supported: boolean) => void;
  fetchCalendars: (client: JMAPClient) => Promise<void>;
  fetchEvents: (client: JMAPClient, start: string, end: string) => Promise<void>;
  createEvent: (client: JMAPClient, event: Partial<CalendarEvent>, sendSchedulingMessages?: boolean) => Promise<CalendarEvent | null>;
  updateEvent: (client: JMAPClient, id: string, updates: Partial<CalendarEvent>, sendSchedulingMessages?: boolean) => Promise<void>;
  deleteEvent: (client: JMAPClient, id: string, sendSchedulingMessages?: boolean) => Promise<void>;
  rsvpEvent: (client: JMAPClient, eventId: string, participantId: string, status: string) => Promise<void>;
  importEvents: (client: JMAPClient, events: Partial<CalendarEvent>[], calendarId: string) => Promise<number>;
  setSelectedDate: (date: Date) => void;
  setViewMode: (mode: CalendarViewMode) => void;
  toggleCalendarVisibility: (calendarId: string) => void;
  setSelectedEventId: (id: string | null) => void;
  clearState: () => void;
}

const initialState = {
  calendars: [],
  events: [],
  selectedDate: new Date(),
  selectedCalendarIds: [] as string[],
  selectedEventId: null as string | null,
  isLoading: false,
  isLoadingEvents: false,
  supportsCalendar: false,
  error: null as string | null,
  dateRange: null as { start: string; end: string } | null,
};

export const useCalendarStore = create<CalendarStore>()(
  persist(
    (set, get) => ({
      ...initialState,
      viewMode: 'month' as CalendarViewMode,

      setSupported: (supported) => set({ supportsCalendar: supported }),

      fetchCalendars: async (client) => {
        set({ isLoading: true, error: null });
        try {
          const calendars = await client.getCalendars();
          const { selectedCalendarIds } = get();
          const validIds = calendars.map(c => c.id);
          const stillValid = selectedCalendarIds.filter(id => validIds.includes(id));
          set({
            calendars,
            isLoading: false,
            selectedCalendarIds: stillValid.length > 0 ? stillValid : validIds,
          });
        } catch (error) {
          debug.error('Failed to fetch calendars:', error);
          set({ error: 'Failed to load calendars', isLoading: false });
        }
      },

      fetchEvents: async (client, start, end) => {
        set({ isLoadingEvents: true, error: null });
        try {
          const events = await client.queryCalendarEvents({
            after: start,
            before: end,
          });
          set({ events, isLoadingEvents: false, dateRange: { start, end } });
        } catch (error) {
          debug.error('Failed to fetch events:', error);
          set({ error: 'Failed to load events', isLoadingEvents: false });
        }
      },

      createEvent: async (client, event, sendSchedulingMessages) => {
        set({ error: null });
        try {
          const created = await client.createCalendarEvent(event, sendSchedulingMessages);
          set((state) => ({ events: [...state.events, created] }));
          return created;
        } catch (error) {
          debug.error('Failed to create event:', error);
          set({ error: 'Failed to create event' });
          return null;
        }
      },

      updateEvent: async (client, id, updates, sendSchedulingMessages) => {
        set({ error: null });
        try {
          await client.updateCalendarEvent(id, updates, sendSchedulingMessages);
          set((state) => ({
            events: state.events.map(e => e.id === id ? { ...e, ...updates } : e),
          }));
        } catch (error) {
          debug.error('Failed to update event:', error);
          set({ error: 'Failed to update event' });
          throw error;
        }
      },

      rsvpEvent: async (client, eventId, participantId, status) => {
        set({ error: null });
        if (!/^[a-zA-Z0-9_-]+$/.test(participantId)) {
          set({ error: 'Invalid participant ID' });
          throw new Error('Invalid participant ID');
        }
        try {
          const patchKey = `participants/${participantId}/participationStatus`;
          await client.updateCalendarEvent(
            eventId,
            { [patchKey]: status } as unknown as Partial<CalendarEvent>,
            true
          );
          set((state) => ({
            events: state.events.map(e => {
              if (e.id !== eventId || !e.participants?.[participantId]) return e;
              return {
                ...e,
                participants: {
                  ...e.participants,
                  [participantId]: { ...e.participants[participantId], participationStatus: status as CalendarParticipant['participationStatus'] },
                },
              };
            }),
          }));
        } catch (error) {
          debug.error('Failed to RSVP:', error);
          set({ error: 'Failed to update RSVP' });
          throw error;
        }
      },

      importEvents: async (client, events, calendarId) => {
        let imported = 0;
        for (const event of events) {
          const src = event as Partial<CalendarEvent>;
          try {
            let cleanParticipants: Record<string, CalendarParticipant> | null = null;
            if (src.participants) {
              cleanParticipants = {};
              for (const [key, p] of Object.entries(src.participants)) {
                const participant: Record<string, unknown> = {
                  '@type': 'Participant',
                  name: p.name,
                  email: p.email,
                  description: p.description,
                  sendTo: p.sendTo,
                  kind: p.kind,
                  roles: p.roles,
                  participationStatus: p.participationStatus,
                  participationComment: p.participationComment,
                  expectReply: p.expectReply,
                  scheduleAgent: p.scheduleAgent,
                  scheduleForceSend: p.scheduleForceSend,
                  scheduleId: p.scheduleId,
                  delegatedTo: p.delegatedTo,
                  delegatedFrom: p.delegatedFrom,
                  memberOf: p.memberOf,
                  locationId: p.locationId,
                  language: p.language,
                  links: p.links,
                };
                Object.keys(participant).forEach(k => {
                  if (participant[k] === undefined || participant[k] === null) delete participant[k];
                });
                cleanParticipants[key] = participant as unknown as CalendarParticipant;
              }
            }

            const data: Partial<CalendarEvent> = {
              calendarIds: { [calendarId]: true },
              uid: src.uid,
              title: src.title,
              description: src.description,
              descriptionContentType: src.descriptionContentType,
              start: src.start,
              duration: src.duration,
              timeZone: src.timeZone,
              showWithoutTime: src.showWithoutTime,
              status: src.status,
              freeBusyStatus: src.freeBusyStatus,
              privacy: src.privacy,
              color: src.color,
              keywords: src.keywords,
              categories: src.categories,
              locale: src.locale,
              locations: src.locations,
              virtualLocations: src.virtualLocations,
              links: src.links,
              recurrenceRules: src.recurrenceRules,
              recurrenceOverrides: src.recurrenceOverrides,
              excludedRecurrenceRules: src.excludedRecurrenceRules,
              alerts: src.alerts,
              participants: cleanParticipants,
            };
            Object.keys(data).forEach(k => {
              const v = (data as Record<string, unknown>)[k];
              if (v === undefined || v === null) delete (data as Record<string, unknown>)[k];
            });
            const created = await client.createCalendarEvent(data);
            set((state) => ({ events: [...state.events, created] }));
            imported++;
          } catch (error) {
            const msg = error instanceof Error ? error.message : '';
            if (msg.includes('already exists') && src.uid) {
              const { events: storeEvents } = get();
              const alreadyInStore = storeEvents.some((e) => e.uid === src.uid);
              if (alreadyInStore) {
                imported++;
                continue;
              }
              try {
                const all = await client.queryCalendarEvents({});
                const matching = all.filter((e) => e.uid === src.uid);
                if (matching.length > 0) {
                  const existingIds = new Set(storeEvents.map((e) => e.id));
                  const newEvents = matching.filter((e) => !existingIds.has(e.id));
                  if (newEvents.length > 0) {
                    set((state) => ({ events: [...state.events, ...newEvents] }));
                  }
                  imported++;
                  continue;
                }
              } catch {
                // fall through to error
              }
            }
            debug.error('Failed to import event:', event.title, error);
          }
        }
        return imported;
      },

      deleteEvent: async (client, id, sendSchedulingMessages) => {
        set({ error: null });
        try {
          await client.deleteCalendarEvent(id, sendSchedulingMessages);
          set((state) => ({
            events: state.events.filter(e => e.id !== id),
            selectedEventId: state.selectedEventId === id ? null : state.selectedEventId,
          }));
        } catch (error) {
          debug.error('Failed to delete event:', error);
          set({ error: 'Failed to delete event' });
          throw error;
        }
      },

      setSelectedDate: (date) => set({ selectedDate: date }),
      setViewMode: (mode) => set({ viewMode: mode }),

      toggleCalendarVisibility: (calendarId) => set((state) => {
        const ids = state.selectedCalendarIds;
        return {
          selectedCalendarIds: ids.includes(calendarId)
            ? ids.filter(id => id !== calendarId)
            : [...ids, calendarId],
        };
      }),

      setSelectedEventId: (id) => set({ selectedEventId: id }),

      clearState: () => {
        set({
          ...initialState,
          selectedDate: new Date(),
        });
        import('./calendar-notification-store').then(({ useCalendarNotificationStore }) => {
          useCalendarNotificationStore.getState().clearAll();
        }).catch(() => {});
      },
    }),
    {
      name: 'calendar-storage',
      partialize: (state) => ({
        selectedCalendarIds: state.selectedCalendarIds,
        viewMode: state.viewMode,
      }),
    }
  )
);
