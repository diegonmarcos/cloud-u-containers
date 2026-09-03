export interface OAuthMetadata {
  issuer: string;
  authorization_endpoint: string;
  token_endpoint: string;
  revocation_endpoint?: string;
  end_session_endpoint?: string;
}

const CACHE_TTL_MS = 10 * 60 * 1000;
const metadataCache = new Map<string, { metadata: OAuthMetadata; expiresAt: number }>();

export async function discoverOAuth(serverUrl: string): Promise<OAuthMetadata | null> {
  const cached = metadataCache.get(serverUrl);
  if (cached && cached.expiresAt > Date.now()) return cached.metadata;
  if (cached) metadataCache.delete(serverUrl);

  const urls = [
    `${serverUrl}/.well-known/oauth-authorization-server`,
    `${serverUrl}/.well-known/openid-configuration`,
  ];

  const errors: string[] = [];

  for (const url of urls) {
    try {
      const response = await fetch(url);
      if (!response.ok) {
        errors.push(`${url} returned HTTP ${response.status}`);
        continue;
      }

      const data = await response.json();
      if (data.authorization_endpoint && data.token_endpoint) {
        const metadata: OAuthMetadata = {
          issuer: data.issuer,
          authorization_endpoint: data.authorization_endpoint,
          token_endpoint: data.token_endpoint,
          revocation_endpoint: data.revocation_endpoint,
          end_session_endpoint: data.end_session_endpoint,
        };
        metadataCache.set(serverUrl, { metadata, expiresAt: Date.now() + CACHE_TTL_MS });
        return metadata;
      }
      errors.push(`${url} response missing required endpoints`);
    } catch (err) {
      errors.push(`${url}: ${err instanceof Error ? err.message : String(err)}`);
      continue;
    }
  }

  return null;
}
