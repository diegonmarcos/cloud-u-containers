import { describe, it, expect, afterEach, vi } from 'vitest';
import { gateCredentials, gateInit } from '../client';

// The edge gate reads the domain-wide Authelia cookie; a cross-origin fetch only carries it with
// credentials: 'include'. Foreign JMAP servers answer CORS with `*` and must stay credential-free.
describe('gateCredentials', () => {
  afterEach(() => vi.unstubAllGlobals());

  const at = (href: string) => {
    const u = new URL(href);
    vi.stubGlobal('window', { location: { href: u.href, origin: u.origin, hostname: u.hostname } });
  };

  it('includes the cookie for a sibling subdomain of the page', () => {
    at('https://webmail.diegonmarcos.com/en/mail');
    expect(gateCredentials('https://jmap.diegonmarcos.com/jmap/session')).toBe('include');
    expect(gateInit('https://jmap.diegonmarcos.com/jmap/session')).toEqual({ credentials: 'include' });
  });

  it('keeps the default for the same origin and for another site', () => {
    at('https://webmail.diegonmarcos.com/en/mail');
    expect(gateCredentials('https://webmail.diegonmarcos.com/api/health')).toBe('same-origin');
    expect(gateCredentials('https://mail.fastmail.com/jmap/session')).toBe('same-origin');
    expect(gateInit('https://mail.fastmail.com/jmap/session')).toEqual({});
  });

  it('is inert without a window (server side) or with a bad URL', () => {
    vi.stubGlobal('window', undefined);
    expect(gateCredentials('https://jmap.diegonmarcos.com/')).toBe('same-origin');
  });
});
