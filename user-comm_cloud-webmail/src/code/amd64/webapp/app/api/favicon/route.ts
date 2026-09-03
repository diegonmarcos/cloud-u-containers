import { NextResponse } from 'next/server';

/**
 * Favicon proxy. The page-side Avatar component uses this to look up
 * a sender-domain favicon without exposing the user's IP to the favicon
 * host, and — critically — to get a real 404 status code when the
 * upstream provider doesn't have a favicon for the domain.
 *
 * DuckDuckGo returns 404 with a placeholder image body for unknown
 * domains, and the <img> element treats any 2xx/4xx response with an
 * image body as a successful load (it ignores the status code). So the
 * placeholder leaks into the UI. By proxying here we can check the
 * status and pass through the upstream 404 with no body, which makes
 * the browser fire the error event and lets us fall back to initials.
 */

const DOMAIN_RE = /^(?!-)([a-z0-9-]{1,63}\.)+[a-z]{2,63}$/i;

export const runtime = 'edge';

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const domain = (searchParams.get('domain') || '').trim().toLowerCase();

  if (!domain || !DOMAIN_RE.test(domain) || domain.length > 253) {
    return new NextResponse(null, { status: 400 });
  }

  try {
    const upstream = await fetch(`https://icons.duckduckgo.com/ip3/${encodeURIComponent(domain)}.ico`, {
      cache: 'force-cache',
    });

    if (!upstream.ok) {
      return new NextResponse(null, { status: 404 });
    }

    const body = await upstream.arrayBuffer();
    return new NextResponse(body, {
      status: 200,
      headers: {
        'content-type': upstream.headers.get('content-type') || 'image/x-icon',
        // Long-lived client cache — favicons barely change and the
        // response is keyed by domain. Re-lookup after a week.
        'cache-control': 'public, max-age=604800, immutable',
      },
    });
  } catch {
    return new NextResponse(null, { status: 502 });
  }
}
