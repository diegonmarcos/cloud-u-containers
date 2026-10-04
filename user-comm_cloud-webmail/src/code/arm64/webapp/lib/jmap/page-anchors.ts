/**
 * Pagination anchors for Email/query (RFC 8620 5.5).
 *
 * `position` indexes a result list the server recomputes for every request, so
 * whatever lands above the offset between two pages slides it. An arrival
 * repeats rows the caller already holds (both list callers carry a client-side
 * de-duplication for exactly that); a deletion, a move out of the view or a
 * keyword change shifts the other way, and the next page then starts *past*
 * messages that were never shown - they stay invisible until the whole list is
 * reloaded.
 *
 * `anchor` closes that seam: name the last id of the previous page and the
 * server counts from wherever that message now sits, so consecutive pages meet
 * exactly. This module holds the bookkeeping that makes it possible - which id
 * ended which view's last page, and at what offset.
 */

/** How many distinct list views keep an anchor. */
const MAX_ANCHORED_VIEWS = 32;

/** The paging argument of an Email/query: a raw offset, or an anchor. */
export type QueryPage = { position: number } | { anchor: string; anchorOffset: number };

/** The part of an Email/query response this module reads. */
export interface QueryPageResult {
  ids?: string[];
  position?: number;
}

/**
 * Identity of a paginated list view: same account, same filter, same sort,
 * same page size. An anchor is only meaningful inside one such view - under a
 * different filter or sort the anchored message sits at a different index, or
 * is not in the list at all.
 */
export function emailQueryViewKey(accountId: string, filter: unknown, sort: unknown, limit: number): string {
  return JSON.stringify([accountId, filter ?? null, sort ?? null, limit]);
}

export class PageAnchors {
  private ends = new Map<string, { id: string; nextPosition: number }>();

  /**
   * The paging argument for the next query on a view: an anchor when the
   * request continues where the last served page ended, an offset otherwise -
   * a first page, a jump to an arbitrary offset, or a caller whose local list
   * no longer lines up with what was served.
   */
  pageFor(viewKey: string, position: number): QueryPage {
    const end = this.ends.get(viewKey);
    return end && position > 0 && end.nextPosition === position
      ? { anchor: end.id, anchorOffset: 1 }
      : { position };
  }

  /** Drop an anchor the server refused with anchorNotFound and page by offset instead. */
  forget(viewKey: string, position: number): QueryPage {
    this.ends.delete(viewKey);
    return { position };
  }

  /**
   * Record where the served page ended so the next one can anchor on it, and
   * report the offset the server actually served from - the honest input for
   * "is there more", because an anchored page ignores the requested position
   * and lands wherever the anchor now is.
   */
  remember(viewKey: string, result: QueryPageResult | undefined, requestedPosition: number): number {
    const servedPosition = typeof result?.position === 'number' ? result.position : requestedPosition;
    const ids = result?.ids ?? [];
    const lastId = ids[ids.length - 1];
    // Deleting first also refreshes insertion order, which is the eviction order.
    this.ends.delete(viewKey);
    if (!lastId) return servedPosition;
    this.ends.set(viewKey, { id: lastId, nextPosition: servedPosition + ids.length });
    if (this.ends.size > MAX_ANCHORED_VIEWS) {
      // Map iterates in insertion order, so the least recently served view goes.
      this.ends.delete(this.ends.keys().next().value as string);
    }
    return servedPosition;
  }
}
