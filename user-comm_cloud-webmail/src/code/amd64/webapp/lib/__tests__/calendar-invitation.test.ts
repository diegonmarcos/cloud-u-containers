import { describe, it, expect } from 'vitest';
import {
  findCalendarAttachment,
  getInvitationMethod,
  formatEventSummary,
  findParticipantByEmail,
} from '../calendar-invitation';
import type { Email, CalendarEvent, CalendarParticipant } from '@/lib/jmap/types';

function makeEmail(overrides: Partial<Email> = {}): Email {
  return {
    id: 'e1',
    threadId: 't1',
    mailboxIds: { inbox: true },
    keywords: {},
    size: 1024,
    receivedAt: '2026-02-17T10:00:00Z',
    hasAttachment: false,
    ...overrides,
  };
}

function makeParticipant(overrides: Partial<CalendarParticipant> = {}): CalendarParticipant {
  return {
    '@type': 'Participant',
    name: 'Test',
    email: 'test@example.com',
    description: null,
    sendTo: null,
    kind: 'individual',
    roles: { attendee: true },
    participationStatus: 'needs-action',
    participationComment: null,
    expectReply: false,
    scheduleAgent: 'server',
    scheduleForceSend: false,
    scheduleId: null,
    scheduleSequence: 0,
    scheduleStatus: null,
    scheduleUpdated: null,
    invitedBy: null,
    delegatedTo: null,
    delegatedFrom: null,
    memberOf: null,
    locationId: null,
    language: null,
    links: null,
    ...overrides,
  };
}

describe('findCalendarAttachment', () => {
  it('finds attachment by MIME type text/calendar', () => {
    const email = makeEmail({
      attachments: [
        { partId: '1', blobId: 'b1', size: 500, type: 'text/calendar', name: 'invite.ics' },
      ],
      hasAttachment: true,
    });
    const result = findCalendarAttachment(email);
    expect(result).toBeTruthy();
    expect(result!.blobId).toBe('b1');
  });

  it('finds attachment by application/ics type', () => {
    const email = makeEmail({
      attachments: [
        { partId: '1', blobId: 'b2', size: 500, type: 'application/ics', name: 'event.ics' },
      ],
      hasAttachment: true,
    });
    expect(findCalendarAttachment(email)?.blobId).toBe('b2');
  });

  it('finds attachment by .ics file extension', () => {
    const email = makeEmail({
      attachments: [
        { partId: '1', blobId: 'b3', size: 500, type: 'application/octet-stream', name: 'meeting.ics' },
      ],
      hasAttachment: true,
    });
    expect(findCalendarAttachment(email)?.blobId).toBe('b3');
  });

  it('finds attachment by .ical file extension', () => {
    const email = makeEmail({
      attachments: [
        { partId: '1', blobId: 'b4', size: 500, type: 'application/octet-stream', name: 'meeting.ical' },
      ],
      hasAttachment: true,
    });
    expect(findCalendarAttachment(email)?.blobId).toBe('b4');
  });

  it('returns null when no calendar attachment exists', () => {
    const email = makeEmail({
      attachments: [
        { partId: '1', blobId: 'b5', size: 500, type: 'application/pdf', name: 'doc.pdf' },
      ],
      hasAttachment: true,
    });
    expect(findCalendarAttachment(email)).toBeNull();
  });

  it('returns null when attachments is undefined', () => {
    const email = makeEmail();
    expect(findCalendarAttachment(email)).toBeNull();
  });

  it('detects text/calendar in textBody parts', () => {
    const email = makeEmail({
      textBody: [
        { partId: 'p1', blobId: 'tb1', size: 300, type: 'text/calendar' },
      ],
    });
    const result = findCalendarAttachment(email);
    expect(result).toBeTruthy();
    expect(result!.blobId).toBe('tb1');
  });

  it('prioritizes attachments over textBody', () => {
    const email = makeEmail({
      attachments: [
        { partId: '1', blobId: 'att1', size: 500, type: 'text/calendar', name: 'invite.ics' },
      ],
      textBody: [
        { partId: 'p1', blobId: 'tb1', size: 300, type: 'text/calendar' },
      ],
      hasAttachment: true,
    });
    expect(findCalendarAttachment(email)?.blobId).toBe('att1');
  });
});

describe('getInvitationMethod', () => {
  it('detects cancel when status is cancelled', () => {
    expect(getInvitationMethod({ status: 'cancelled' })).toBe('cancel');
  });

  it('detects request when participants have organizer role', () => {
    const event: Partial<CalendarEvent> = {
      participants: {
        org: makeParticipant({ roles: { owner: true }, name: 'Organizer' }),
        att: makeParticipant({ roles: { attendee: true }, name: 'Attendee' }),
      },
    };
    expect(getInvitationMethod(event)).toBe('request');
  });

  it('detects request with chair role', () => {
    const event: Partial<CalendarEvent> = {
      participants: {
        org: makeParticipant({ roles: { chair: true }, name: 'Chair' }),
      },
    };
    expect(getInvitationMethod(event)).toBe('request');
  });

  it('returns unknown when no participants', () => {
    expect(getInvitationMethod({})).toBe('unknown');
  });

  it('returns unknown when participants have no organizer', () => {
    const event: Partial<CalendarEvent> = {
      participants: {
        att: makeParticipant({ roles: { attendee: true } }),
      },
    };
    expect(getInvitationMethod(event)).toBe('unknown');
  });
});

describe('formatEventSummary', () => {
  it('extracts title from event', () => {
    const summary = formatEventSummary({ title: 'Team Sync' });
    expect(summary.title).toBe('Team Sync');
  });

  it('extracts location from event', () => {
    const summary = formatEventSummary({
      locations: { loc1: { '@type': 'Location', name: 'Room A', description: null, locationTypes: null, coordinates: null, timeZone: null, links: null, relativeTo: null } },
    });
    expect(summary.location).toBe('Room A');
  });

  it('extracts organizer info', () => {
    const summary = formatEventSummary({
      participants: {
        org: makeParticipant({ roles: { owner: true }, name: 'Alice', email: 'alice@example.com' }),
        att: makeParticipant({ roles: { attendee: true }, name: 'Bob' }),
      },
    });
    expect(summary.organizer).toBe('Alice');
    expect(summary.organizerEmail).toBe('alice@example.com');
    expect(summary.attendeeCount).toBe(1);
  });

  it('handles missing data gracefully', () => {
    const summary = formatEventSummary({});
    expect(summary.title).toBe('');
    expect(summary.start).toBeNull();
    expect(summary.end).toBeNull();
    expect(summary.location).toBeNull();
    expect(summary.organizer).toBeNull();
    expect(summary.attendeeCount).toBe(0);
  });

  it('computes end from start + duration', () => {
    const summary = formatEventSummary({
      start: '2026-02-17T10:00:00',
      duration: 'PT1H30M',
    });
    expect(summary.start).toBe('2026-02-17T10:00:00');
    expect(summary.end).toBeTruthy();
    const endDate = new Date(summary.end!);
    expect(endDate.getHours()).toBe(new Date('2026-02-17T10:00:00').getHours() + 1);
    expect(endDate.getMinutes()).toBe(new Date('2026-02-17T10:00:00').getMinutes() + 30);
  });

  it('uses utcStart and utcEnd when available', () => {
    const summary = formatEventSummary({
      utcStart: '2026-02-17T15:00:00Z',
      utcEnd: '2026-02-17T16:00:00Z',
      start: '2026-02-17T10:00:00',
    });
    expect(summary.start).toBe('2026-02-17T15:00:00Z');
    expect(summary.end).toBe('2026-02-17T16:00:00Z');
  });
});

describe('findParticipantByEmail', () => {
  it('finds participant by direct email match', () => {
    const event: Partial<CalendarEvent> = {
      participants: {
        p1: makeParticipant({ email: 'alice@example.com', name: 'Alice' }),
      },
    };
    const result = findParticipantByEmail(event, 'alice@example.com');
    expect(result).toBeTruthy();
    expect(result!.id).toBe('p1');
    expect(result!.participant.name).toBe('Alice');
  });

  it('matches case-insensitively', () => {
    const event: Partial<CalendarEvent> = {
      participants: {
        p1: makeParticipant({ email: 'Alice@Example.COM' }),
      },
    };
    expect(findParticipantByEmail(event, 'alice@example.com')).toBeTruthy();
  });

  it('finds participant by sendTo mailto', () => {
    const event: Partial<CalendarEvent> = {
      participants: {
        p1: makeParticipant({ email: '', sendTo: { imip: 'mailto:bob@example.com' } }),
      },
    };
    const result = findParticipantByEmail(event, 'bob@example.com');
    expect(result).toBeTruthy();
    expect(result!.id).toBe('p1');
  });

  it('returns null when no match', () => {
    const event: Partial<CalendarEvent> = {
      participants: {
        p1: makeParticipant({ email: 'alice@example.com' }),
      },
    };
    expect(findParticipantByEmail(event, 'unknown@example.com')).toBeNull();
  });

  it('returns null with no participants', () => {
    expect(findParticipantByEmail({}, 'test@example.com')).toBeNull();
  });

  it('returns null with empty email', () => {
    const event: Partial<CalendarEvent> = {
      participants: {
        p1: makeParticipant({ email: 'alice@example.com' }),
      },
    };
    expect(findParticipantByEmail(event, '')).toBeNull();
  });
});
