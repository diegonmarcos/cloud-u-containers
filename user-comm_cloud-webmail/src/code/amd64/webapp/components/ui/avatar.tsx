"use client";

import { useEffect, useState } from "react";
import { cn } from "@/lib/utils";
import { useSettingsStore } from "@/stores/settings-store";

interface AvatarProps {
  name?: string;
  email?: string;
  size?: "sm" | "md" | "lg";
  className?: string;
}

// Freemail / webmail providers where the sender's domain is a generic
// mailbox host rather than an identifying brand. Showing Google's logo
// for every gmail.com sender is misleading — the domain belongs to the
// provider, not to the individual. Fall back to initials for these.
const FREEMAIL_DOMAINS = new Set([
  "gmail.com",
  "googlemail.com",
  "yahoo.com",
  "yahoo.co.uk",
  "yahoo.fr",
  "ymail.com",
  "outlook.com",
  "outlook.fr",
  "hotmail.com",
  "hotmail.fr",
  "live.com",
  "live.fr",
  "msn.com",
  "icloud.com",
  "me.com",
  "mac.com",
  "aol.com",
  "proton.me",
  "protonmail.com",
  "pm.me",
  "tutanota.com",
  "tuta.io",
  "gmx.com",
  "gmx.de",
  "gmx.fr",
  "gmx.net",
  "web.de",
  "mail.ru",
  "yandex.ru",
  "yandex.com",
  "fastmail.com",
  "fastmail.fm",
  "zoho.com",
  "orange.fr",
  "wanadoo.fr",
  "free.fr",
  "laposte.net",
  "sfr.fr",
  "bbox.fr",
  "hey.com",
  "duck.com",
]);

function extractDomain(email?: string): string | null {
  if (!email) return null;
  const at = email.lastIndexOf("@");
  if (at < 0 || at === email.length - 1) return null;
  const domain = email.slice(at + 1).trim().toLowerCase();
  if (!domain.includes(".") || domain === "localhost") return null;
  if (FREEMAIL_DOMAINS.has(domain)) return null;
  return domain;
}

/**
 * Routed through our own /api/favicon endpoint rather than hitting
 * DuckDuckGo directly. DDG replies with an image body (HTTP 404 or a
 * 200 with a placeholder) for unknown domains, and the browser treats
 * anything with an image body as a successful load — so without the
 * proxy every domain would get DDG's "no favicon" placeholder rendered
 * as if it were real. The proxy passes the upstream status through so
 * onError fires when the domain actually has no favicon, and the
 * avatar falls back to initials.
 */
function faviconUrlFor(domain: string): string {
  return `/api/favicon?domain=${encodeURIComponent(domain)}`;
}

export function Avatar({ name, email, size = "md", className }: AvatarProps) {
  const domainFaviconAvatars = useSettingsStore((s) => s.domainFaviconAvatars);
  const [faviconOk, setFaviconOk] = useState(false);
  const domain = domainFaviconAvatars ? extractDomain(email) : null;

  useEffect(() => {
    // Reset load state when the domain changes so we retry for a new sender.
    setFaviconOk(false);
  }, [domain]);

  const getInitials = () => {
    if (name) {
      const parts = name.trim().split(/\s+/);
      if (parts.length >= 2) {
        return `${parts[0][0]}${parts[parts.length - 1][0]}`.toUpperCase();
      }
      return name.slice(0, 2).toUpperCase();
    }
    if (email) {
      return email[0].toUpperCase();
    }
    return "?";
  };

  const getBackgroundColor = () => {
    const str = name || email || "";
    let hash = 0;
    for (let i = 0; i < str.length; i++) {
      hash = str.charCodeAt(i) + ((hash << 5) - hash);
    }
    const hue = Math.abs(hash) % 360;
    return `hsl(${hue}, 70%, 50%)`;
  };

  const sizeClasses = {
    sm: "w-8 h-8 text-xs",
    md: "w-10 h-10 text-sm",
    lg: "w-12 h-12 text-base",
  };

  // When a favicon has loaded, swap to a neutral backdrop so transparent
  // regions of the icon don't bleed the initials-derived hue through.
  const showFavicon = !!domain && faviconOk;
  const backdrop = showFavicon ? "#fff" : getBackgroundColor();

  return (
    <div
      className={cn(
        "rounded-full flex items-center justify-center font-semibold text-white overflow-hidden relative ring-1 ring-black/5 dark:ring-white/10",
        sizeClasses[size],
        className
      )}
      style={{ backgroundColor: backdrop }}
      title={name || email}
    >
      {/* Initials render behind so there's no flash if the favicon loads late or fails */}
      <span aria-hidden={faviconOk}>{getInitials()}</span>
      {domain && (
        <img
          src={faviconUrlFor(domain)}
          alt=""
          aria-hidden="true"
          loading="lazy"
          referrerPolicy="no-referrer"
          onLoad={() => setFaviconOk(true)}
          onError={() => setFaviconOk(false)}
          className={cn(
            // contain (not cover) keeps the favicon fully visible with a
            // small white margin, which reads better than a cropped logo
            // when the source icon isn't square.
            "absolute inset-[15%] w-[70%] h-[70%] object-contain transition-opacity duration-150",
            faviconOk ? "opacity-100" : "opacity-0"
          )}
        />
      )}
    </div>
  );
}
