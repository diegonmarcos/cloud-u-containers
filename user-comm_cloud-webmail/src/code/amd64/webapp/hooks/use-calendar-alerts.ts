"use client";

import { useEffect, useRef, useCallback } from 'react';
import { useTranslations, useLocale } from 'next-intl';
import { useAuthStore } from '@/stores/auth-store';
import { useCalendarStore } from '@/stores/calendar-store';
import { useSettingsStore } from '@/stores/settings-store';
import { useCalendarNotificationStore } from '@/stores/calendar-notification-store';
import { useToastStore } from '@/stores/toast-store';
import { getPendingAlerts, buildAlertKey } from '@/lib/calendar-alerts';
import { playNotificationSound } from '@/lib/notification-sound';
import type { CalendarEvent } from '@/lib/jmap/types';

const CHECK_INTERVAL_MS = 60 * 1000;
const PROACTIVE_FETCH_HOURS = 24;
const PROACTIVE_THROTTLE_MS = CHECK_INTERVAL_MS * 5;

export function useCalendarAlerts() {
  const { isAuthenticated, client } = useAuthStore();
  const { events, calendars, supportsCalendar } = useCalendarStore();
  const { calendarNotificationsEnabled, calendarNotificationSound } = useSettingsStore();
  const { acknowledgedAlerts, acknowledgeAlert, cleanupStaleAlerts } = useCalendarNotificationStore();
  const addToast = useToastStore((s) => s.addToast);
  const t = useTranslations('calendar.notifications');
  const locale = useLocale();

  const lastProactiveFetchRef = useRef<number>(0);
  const proactiveEventsRef = useRef<CalendarEvent[]>([]);
  const shownKeysRef = useRef<Set<string>>(new Set());

  const checkAlerts = useCallback(() => {
    if (!calendarNotificationsEnabled || !isAuthenticated) return;

    try {
      const now = Date.now();
      const acknowledgedKeys = new Set(Object.keys(acknowledgedAlerts));
      const allEvents = [...events, ...proactiveEventsRef.current];
      const pending = getPendingAlerts(allEvents, calendars, acknowledgedKeys, now);

      for (const alert of pending) {
        const key = buildAlertKey(alert.eventId, alert.alertId, alert.fireTimeMs);
        if (shownKeysRef.current.has(key)) continue;

        shownKeysRef.current.add(key);
        acknowledgeAlert(key, alert.fireTimeMs);

        if (calendarNotificationSound) {
          playNotificationSound();
        }

        const diffMs = new Date(alert.event.utcStart || alert.event.start).getTime() - now;
        const diffMin = Math.round(diffMs / 60000);

        const timeLabel = diffMin <= 0
          ? t('alert_now')
          : t('alert_in_minutes', { count: diffMin });

        const message = alert.calendarName
          ? `${timeLabel} · ${alert.calendarName}`
          : timeLabel;

        addToast({
          type: 'info',
          title: alert.event.title || t('alert_title'),
          message,
          duration: 15000,
          onClick: () => {
            window.location.href = `/${locale}/calendar`;
          },
        });
      }
    } catch {
      // Silently ignore alert evaluation errors
    }
  }, [
    calendarNotificationsEnabled, calendarNotificationSound,
    isAuthenticated, events, calendars, acknowledgedAlerts,
    acknowledgeAlert, addToast, t, locale,
  ]);

  const proactiveFetch = useCallback(async () => {
    if (!client || !supportsCalendar || !calendarNotificationsEnabled || !isAuthenticated) return;

    const now = Date.now();
    if (now - lastProactiveFetchRef.current < PROACTIVE_THROTTLE_MS) return;

    try {
      const start = new Date(now - 10 * 60 * 1000).toISOString();
      const end = new Date(now + PROACTIVE_FETCH_HOURS * 60 * 60 * 1000).toISOString();
      const fetched = await client.queryCalendarEvents({ after: start, before: end });
      proactiveEventsRef.current = fetched;
      lastProactiveFetchRef.current = Date.now();
    } catch {
      // Silently ignore proactive fetch errors
    }
  }, [client, supportsCalendar, calendarNotificationsEnabled, isAuthenticated]);

  useEffect(() => {
    if (!calendarNotificationsEnabled || !isAuthenticated) return;

    cleanupStaleAlerts();
    proactiveFetch();

    const timer = setTimeout(() => checkAlerts(), 500);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only re-run when auth or notification setting changes, not when callback refs update
  }, [isAuthenticated, calendarNotificationsEnabled]);

  useEffect(() => {
    if (!calendarNotificationsEnabled || !isAuthenticated) return;

    const interval = setInterval(() => {
      proactiveFetch();
      checkAlerts();
    }, CHECK_INTERVAL_MS);

    return () => clearInterval(interval);
  }, [calendarNotificationsEnabled, isAuthenticated, checkAlerts, proactiveFetch]);

  useEffect(() => {
    if (!calendarNotificationsEnabled || !isAuthenticated) return;
    checkAlerts();
  }, [events, calendarNotificationsEnabled, isAuthenticated, checkAlerts]);
}
