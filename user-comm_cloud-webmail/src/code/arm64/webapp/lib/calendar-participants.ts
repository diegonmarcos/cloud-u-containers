import type { CalendarEvent, CalendarParticipant } from '@/lib/jmap/types';

export interface ParticipantInfo {
  id: string;
  name: string;
  email: string;
  status: CalendarParticipant['participationStatus'];
  isOrganizer: boolean;
}

export interface StatusCounts {
  accepted: number;
  declined: number;
  tentative: number;
  'needs-action': number;
}

function normalizeEmail(value: string | undefined | null): string {
  if (!value) return '';
  const trimmed = value.trim().toLowerCase();
  return trimmed.startsWith('mailto:') ? trimmed.slice(7) : trimmed;
}

function toCalendarAddress(email: string): string {
  const normalized = normalizeEmail(email);
  return normalized ? `mailto:${normalized}` : '';
}

function participantEmail(p: CalendarParticipant): string {
  if (p.calendarAddress) return normalizeEmail(p.calendarAddress);
  return normalizeEmail(p.email);
}

export function isOrganizer(event: CalendarEvent, userEmails: string[]): boolean {
  if (!event.participants) return false;
  const lower = userEmails.map(normalizeEmail);
  return Object.values(event.participants).some(p =>
    p.roles?.owner && lower.includes(normalizeEmail(participantEmail(p)))
  );
}

export function getUserParticipantId(event: CalendarEvent, userEmails: string[]): string | null {
  if (!event.participants) return null;
  const lower = userEmails.map(normalizeEmail);
  for (const [id, p] of Object.entries(event.participants)) {
    if (lower.includes(normalizeEmail(participantEmail(p)))) return id;
  }
  return null;
}

export function getUserStatus(
  event: CalendarEvent,
  userEmails: string[]
): CalendarParticipant['participationStatus'] | null {
  if (!event.participants) return null;
  const lower = userEmails.map(normalizeEmail);
  for (const p of Object.values(event.participants)) {
    if (lower.includes(normalizeEmail(participantEmail(p)))) return p.participationStatus;
  }
  return null;
}

export function getParticipantList(event: CalendarEvent): ParticipantInfo[] {
  if (!event.participants) return [];
  const deduped = new Map<string, ParticipantInfo>();
  for (const [id, p] of Object.entries(event.participants)) {
    const email = participantEmail(p);
    // Stalwart can return equivalent participant entries under different keys;
    // dedupe on normalized address so organizer/self isn't shown twice.
    const key = email || id.toLowerCase();
    const next: ParticipantInfo = {
      id,
      name: p.name || '',
      email,
      status: p.participationStatus || 'needs-action',
      isOrganizer: !!p.roles?.owner,
    };
    const existing = deduped.get(key);
    if (!existing || (!existing.isOrganizer && next.isOrganizer)) {
      deduped.set(key, next);
    }
  }
  return Array.from(deduped.values());
}

export function getStatusCounts(event: CalendarEvent): StatusCounts {
  const counts: StatusCounts = { accepted: 0, declined: 0, tentative: 0, 'needs-action': 0 };
  const participants = getParticipantList(event);
  for (const p of participants) {
    const s = p.status || 'needs-action';
    if (s in counts) counts[s as keyof StatusCounts]++;
  }
  return counts;
}

export function getParticipantCount(event: CalendarEvent): number {
  return getParticipantList(event).length;
}

export function buildParticipantMap(
  organizer: { name: string; email: string } | null,
  attendees: { name: string; email: string }[]
): Record<string, Partial<CalendarParticipant>> {
  const participants: Record<string, Partial<CalendarParticipant>> = {};

  // Only add organizer when we can map it to a valid calendar address.
  if (organizer?.email) {
    const organizerAddress = toCalendarAddress(organizer.email);
    participants[organizerAddress] = {
      '@type': 'Participant',
      name: organizer.name || organizer.email,
      calendarAddress: organizerAddress,
      roles: { owner: true },
      participationStatus: 'accepted',
      kind: 'individual',
    };
  }

  attendees.forEach((a) => {
    if (!a.email) return;
    const addr = toCalendarAddress(a.email);
    if (participants[addr]) return;

    participants[addr] = {
      '@type': 'Participant',
      name: a.name || a.email,
      calendarAddress: addr,
      roles: { attendee: true },
      participationStatus: 'needs-action',
      expectReply: true,
      kind: 'individual',
    };
  });

  return participants;
}
