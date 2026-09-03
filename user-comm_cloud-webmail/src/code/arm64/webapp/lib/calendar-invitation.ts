import type { Email, Attachment, CalendarEvent, CalendarParticipant } from '@/lib/jmap/types';

export function findCalendarAttachment(email: Email): Attachment | null {
  if (email.attachments) {
    for (const att of email.attachments) {
      if (
        att.type === 'text/calendar' ||
        att.type === 'application/ics' ||
        att.name?.toLowerCase().endsWith('.ics') ||
        att.name?.toLowerCase().endsWith('.ical')
      ) {
        return att;
      }
    }
  }

  if (email.textBody) {
    for (const part of email.textBody) {
      if (part.type === 'text/calendar' && part.blobId) {
        return {
          partId: part.partId,
          blobId: part.blobId,
          size: part.size,
          name: part.name || 'invite.ics',
          type: 'text/calendar',
        };
      }
    }
  }

  return null;
}

export function getInvitationMethod(
  event: Partial<CalendarEvent>
): 'request' | 'reply' | 'cancel' | 'unknown' {
  if (event.status === 'cancelled') {
    return 'cancel';
  }

  if (event.participants && Object.keys(event.participants).length > 0) {
    const hasOrganizer = Object.values(event.participants).some(
      (p: CalendarParticipant) => p.roles?.owner || p.roles?.chair
    );
    if (hasOrganizer) {
      return 'request';
    }
  }

  return 'unknown';
}

export interface EventSummary {
  title: string;
  start: string | null;
  end: string | null;
  location: string | null;
  organizer: string | null;
  organizerEmail: string | null;
  attendeeCount: number;
}

export function formatEventSummary(event: Partial<CalendarEvent>): EventSummary {
  let location: string | null = null;
  if (event.locations) {
    const firstLocation = Object.values(event.locations)[0];
    if (firstLocation?.name) {
      location = firstLocation.name;
    }
  }

  let organizer: string | null = null;
  let organizerEmail: string | null = null;
  let attendeeCount = 0;

  if (event.participants) {
    for (const p of Object.values(event.participants)) {
      if (p.roles?.owner || p.roles?.chair) {
        organizer = p.name || p.email || null;
        organizerEmail = p.email || null;
      }
      if (p.roles?.attendee) {
        attendeeCount++;
      }
    }
  }

  let end: string | null = null;
  if (event.utcEnd) {
    end = event.utcEnd;
  } else if (event.start && event.duration) {
    end = addDurationToDate(event.start, event.duration, event.timeZone);
  }

  return {
    title: event.title || '',
    start: event.utcStart || event.start || null,
    end,
    location,
    organizer,
    organizerEmail,
    attendeeCount,
  };
}

function addDurationToDate(start: string, duration: string, _timeZone?: string | null): string | null {
  const match = duration.match(/^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/);
  if (!match) return null;

  const days = parseInt(match[1] || '0');
  const hours = parseInt(match[2] || '0');
  const minutes = parseInt(match[3] || '0');
  const seconds = parseInt(match[4] || '0');

  const date = new Date(start);
  if (isNaN(date.getTime())) return null;

  date.setDate(date.getDate() + days);
  date.setHours(date.getHours() + hours);
  date.setMinutes(date.getMinutes() + minutes);
  date.setSeconds(date.getSeconds() + seconds);

  return date.toISOString();
}

export function findParticipantByEmail(
  event: Partial<CalendarEvent>,
  email: string
): { id: string; participant: CalendarParticipant } | null {
  if (!event.participants || !email) return null;

  const lowerEmail = email.toLowerCase();
  for (const [id, p] of Object.entries(event.participants)) {
    if (p.email?.toLowerCase() === lowerEmail) {
      return { id, participant: p };
    }
    if (p.sendTo) {
      for (const addr of Object.values(p.sendTo)) {
        if (addr.replace('mailto:', '').toLowerCase() === lowerEmail) {
          return { id, participant: p };
        }
      }
    }
  }
  return null;
}
