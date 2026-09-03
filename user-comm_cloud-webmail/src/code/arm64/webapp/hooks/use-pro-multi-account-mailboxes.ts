"use client";

import { useEffect } from "react";
import { useAccountStore } from "@/stores/account-store";
import { useAuthStore } from "@/stores/auth-store";
import { useEmailStore } from "@/stores/email-store";
import { useSettingsStore } from "@/stores/settings-store";
import { useIsEmbedded } from "@/hooks/use-is-embedded";

/**
 * Keeps `useEmailStore.accountMailboxes` populated with one entry per
 * connected account while the Pro shell is the active interface. The Pro
 * sidebar reads this cache to render a Thunderbird-style per-account folder
 * tree (see [[project_pro_mode]]). Outside Pro the cache stays empty.
 *
 * Refetches whenever the set of connected accounts changes, so adding or
 * removing an account in another tab is reflected without a reload.
 */
export function useProMultiAccountMailboxes(): void {
  const isEmbedded = useIsEmbedded();
  const proInterface = useSettingsStore((s) => s.proInterface);
  const accounts = useAccountStore((s) => s.accounts);

  useEffect(() => {
    if (!proInterface && !isEmbedded) return;

    const connected = accounts.filter((a) => a.isConnected);
    if (connected.length === 0) return;

    const fetchAccountMailboxes = useEmailStore.getState().fetchAccountMailboxes;
    const getClientForAccount = useAuthStore.getState().getClientForAccount;

    for (const account of connected) {
      const client = getClientForAccount(account.id);
      if (!client) continue;
      void fetchAccountMailboxes(client, account.id);
    }
  }, [proInterface, isEmbedded, accounts]);
}
