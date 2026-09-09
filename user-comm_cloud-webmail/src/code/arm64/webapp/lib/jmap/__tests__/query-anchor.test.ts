import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { JMAPClient } from '../client';
import { PageAnchors, emailQueryViewKey } from '../page-anchors';

// Pagination anchors (RFC 8620 5.5). `position` indexes a result list the
// server recomputes per request, so mail arriving or leaving between two pages
// slides the offset: the caller either sees rows twice (both list callers
// de-duplicate) or, when the list shrank, never sees the rows the offset
// skipped past. Anchoring the next page on the last id of the previous one is
// what makes consecutive pages meet.

type MethodCall = [string, Record<string, unknown>, string];

function makeSession() {
  return {
    capabilities: { 'urn:ietf:params:jmap:core': {} },
    accounts: { 'acct-1': { name: 'test', isPersonal: true, accountCapabilities: { 'urn:ietf:params:jmap:mail': {} } } },
    primaryAccounts: { 'urn:ietf:params:jmap:mail': 'acct-1' },
    apiUrl: 'https://mail.example.com/jmap/api',
    downloadUrl: 'https://mail.example.com/jmap/download/{accountId}/{blobId}/{name}',
    uploadUrl: 'https://mail.example.com/jmap/upload/{accountId}/',
    eventSourceUrl: 'https://mail.example.com/jmap/eventsource',
  };
}

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } });
}

/** An Email/query + Email/get pair answering with `ids` at `position` of `total`. */
function page(ids: string[], position: number, total: number) {
  return {
    methodResponses: [
      ['Email/query', { ids, position, total }, '0'],
      ['Email/get', {
        list: ids.map(id => ({
          id, threadId: `t-${id}`, mailboxIds: { inbox: true }, keywords: {},
          receivedAt: '2026-01-01T00:00:00Z', size: 1, hasAttachment: false,
        })),
      }, '1'],
    ],
  };
}

/** RFC 8620 5.5: the anchor id is no longer in the result list. */
const anchorNotFound = {
  methodResponses: [
    ['error', { type: 'anchorNotFound' }, '0'],
    ['error', { type: 'invalidResultReference' }, '1'],
  ],
};

describe('JMAPClient Email/query paging anchors', () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    fetchSpy = vi.spyOn(globalThis, 'fetch');
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  afterEach(() => {
    fetchSpy.mockRestore();
    vi.restoreAllMocks();
  });

  async function connectedClient(): Promise<JMAPClient> {
    fetchSpy.mockResolvedValueOnce(jsonResponse(makeSession()));
    const client = JMAPClient.withBearer('https://mail.example.com', 'token123', 'user@test.com');
    await client.connect();
    fetchSpy.mockReset();
    return client;
  }

  /** Records every request's method calls and replies with the queued responses in order. */
  function replyWith(...responses: unknown[]) {
    const sent: MethodCall[][] = [];
    let index = 0;
    fetchSpy.mockImplementation((async (_url: string, init: RequestInit) => {
      sent.push(JSON.parse(init.body as string).methodCalls);
      return jsonResponse(responses[Math.min(index++, responses.length - 1)]);
    }) as never);
    return sent;
  }

  const queryArgs = (sent: MethodCall[][]) => sent.map(calls => calls[0][1]);

  it('anchors the page that continues where the last one ended', async () => {
    const client = await connectedClient();
    const sent = replyWith(page(['a', 'b'], 0, 10), page(['c', 'd'], 2, 10));

    await client.getEmails('inbox', undefined, 2, 0);
    await client.getEmails('inbox', undefined, 2, 2);

    expect(queryArgs(sent)[0]).toMatchObject({ position: 0 });
    expect(queryArgs(sent)[0]).not.toHaveProperty('anchor');
    // 'b' ended the first page, so the second starts one past it - wherever
    // the server now holds it.
    expect(queryArgs(sent)[1]).toMatchObject({ anchor: 'b', anchorOffset: 1 });
    expect(queryArgs(sent)[1]).not.toHaveProperty('position');
  });

  it('falls back to the requested offset when the anchor has left the view', async () => {
    const client = await connectedClient();
    const sent = replyWith(page(['a', 'b'], 0, 10), anchorNotFound, page(['c', 'd'], 2, 10));

    await client.getEmails('inbox', undefined, 2, 0);
    const second = await client.getEmails('inbox', undefined, 2, 2);

    expect(sent).toHaveLength(3);
    expect(queryArgs(sent)[2]).toMatchObject({ position: 2 });
    expect(queryArgs(sent)[2]).not.toHaveProperty('anchor');
    expect(second.emails.map(e => e.id).sort()).toEqual(['c', 'd']);
  });

  it('forgets the anchor after it was refused, so the next page does not retry it', async () => {
    const client = await connectedClient();
    const sent = replyWith(page(['a', 'b'], 0, 10), anchorNotFound, page(['c', 'd'], 2, 10), page(['e', 'f'], 4, 10));

    await client.getEmails('inbox', undefined, 2, 0);
    await client.getEmails('inbox', undefined, 2, 2);
    await client.getEmails('inbox', undefined, 2, 4);

    // The offset-served page re-established an anchor of its own ('d').
    expect(queryArgs(sent)[3]).toMatchObject({ anchor: 'd', anchorOffset: 1 });
  });

  it('pages by offset when the request does not continue the last page', async () => {
    const client = await connectedClient();
    const sent = replyWith(page(['a', 'b'], 0, 10));

    await client.getEmails('inbox', undefined, 2, 0);
    await client.getEmails('inbox', undefined, 2, 6);

    expect(queryArgs(sent)[1]).toMatchObject({ position: 6 });
    expect(queryArgs(sent)[1]).not.toHaveProperty('anchor');
  });

  it('keeps each view on its own anchor', async () => {
    const client = await connectedClient();
    const sent = replyWith(page(['a', 'b'], 0, 10), page(['x', 'y'], 0, 10), page(['c', 'd'], 2, 10));

    await client.getEmails('inbox', undefined, 2, 0);
    await client.getEmails('archive', undefined, 2, 0);
    await client.getEmails('inbox', undefined, 2, 2);

    // The archive page must not lend its last id to the inbox's second page.
    expect(queryArgs(sent)[2]).toMatchObject({ anchor: 'b', anchorOffset: 1 });
  });

  it('anchors search paging the same way', async () => {
    const client = await connectedClient();
    const sent = replyWith(page(['a', 'b'], 0, 10), page(['c', 'd'], 2, 10));

    await client.searchEmails('report', 'inbox', undefined, 2, 0);
    await client.searchEmails('report', 'inbox', undefined, 2, 2);

    expect(queryArgs(sent)[1]).toMatchObject({ anchor: 'b', anchorOffset: 1 });
  });

  it('reports hasMore from the offset the server served, not the one asked for', async () => {
    const client = await connectedClient();
    // The anchored page really sits at 1 (a message above it was deleted), so
    // 1 + 2 < 4: there is still a page left, even though 2 + 2 == 4 suggests not.
    replyWith(page(['a', 'b'], 0, 4), page(['c', 'd'], 1, 4));

    await client.getEmails('inbox', undefined, 2, 0);
    const second = await client.getEmails('inbox', undefined, 2, 2);

    expect(second.hasMore).toBe(true);
  });
});

describe('PageAnchors bookkeeping', () => {
  const inbox = emailQueryViewKey('acct-1', { inMailbox: 'inbox' }, [{ property: 'receivedAt' }], 50);
  const archive = emailQueryViewKey('acct-1', { inMailbox: 'archive' }, [{ property: 'receivedAt' }], 50);

  it('anchors only a page that continues the last one, within the same view', () => {
    const anchors = new PageAnchors();

    expect(anchors.pageFor(inbox, 0)).toEqual({ position: 0 });
    expect(anchors.remember(inbox, { ids: ['a', 'b'], position: 0 }, 0)).toBe(0);

    expect(anchors.pageFor(inbox, 2)).toEqual({ anchor: 'b', anchorOffset: 1 });
    expect(anchors.pageFor(archive, 2)).toEqual({ position: 2 });
    expect(anchors.pageFor(inbox, 7)).toEqual({ position: 7 });
  });

  it('reports the offset the server served, not the one requested', () => {
    const anchors = new PageAnchors();
    anchors.remember(inbox, { ids: ['a', 'b'], position: 0 }, 0);

    // Asked for 2, but a message above the page was deleted meanwhile, so the
    // anchored page really landed at 1 - and the next one starts at 3.
    expect(anchors.remember(inbox, { ids: ['c', 'd'], position: 1 }, 2)).toBe(1);
    expect(anchors.pageFor(inbox, 3)).toEqual({ anchor: 'd', anchorOffset: 1 });
  });

  it('keeps the caller accounting when the server omits position', () => {
    const anchors = new PageAnchors();
    expect(anchors.remember(inbox, { ids: ['a', 'b'] }, 10)).toBe(10);
    expect(anchors.pageFor(inbox, 12)).toEqual({ anchor: 'b', anchorOffset: 1 });
  });

  it('ends the chain on an empty page instead of anchoring on a stale id', () => {
    const anchors = new PageAnchors();
    anchors.remember(inbox, { ids: ['a', 'b'], position: 0 }, 0);
    anchors.remember(inbox, { ids: [], position: 2 }, 2);
    expect(anchors.pageFor(inbox, 2)).toEqual({ position: 2 });
  });

  it('forgets a refused anchor', () => {
    const anchors = new PageAnchors();
    anchors.remember(inbox, { ids: ['a', 'b'], position: 0 }, 0);
    expect(anchors.forget(inbox, 2)).toEqual({ position: 2 });
    expect(anchors.pageFor(inbox, 2)).toEqual({ position: 2 });
  });

  it('bounds the table at 32 views, evicting the least recently served', () => {
    const anchors = new PageAnchors();
    for (let i = 0; i < 40; i++) anchors.remember(`view-${i}`, { ids: [`id-${i}`], position: 0 }, 0);

    expect(anchors.pageFor('view-7', 1)).toEqual({ position: 1 });
    expect(anchors.pageFor('view-8', 1)).toEqual({ anchor: 'id-8', anchorOffset: 1 });
    expect(anchors.pageFor('view-39', 1)).toEqual({ anchor: 'id-39', anchorOffset: 1 });
  });
});
