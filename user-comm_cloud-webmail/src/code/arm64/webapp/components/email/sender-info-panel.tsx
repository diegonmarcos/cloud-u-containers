"use client";

import { useMemo } from "react";
import type { EmailAddress } from "@/lib/jmap/types";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { useContactStore, getContactDisplayName } from "@/stores/contact-store";
import { useTranslations } from "next-intl";
import { UserPlus, Search } from "lucide-react";

interface SenderInfoPanelProps {
  sender: EmailAddress;
  onSearch: (email: string) => void;
  onAddContact: (name: string, email: string) => void;
}

export function SenderInfoPanel({ sender, onSearch, onAddContact }: SenderInfoPanelProps) {
  const t = useTranslations("email_viewer.sender_info");
  const contacts = useContactStore((state) => state.contacts);

  const matchedContact = useMemo(() => {
    const lowerEmail = sender.email.toLowerCase();
    return contacts.find((c) => {
      if (c.kind === "group" || !c.emails) return false;
      return Object.values(c.emails).some(
        (e) => e.address?.toLowerCase() === lowerEmail
      );
    });
  }, [contacts, sender.email]);

  const orgName = useMemo(() => {
    if (!matchedContact?.organizations) return null;
    const org = Object.values(matchedContact.organizations)[0];
    return org?.name || null;
  }, [matchedContact]);

  return (
    <div className="animate-in slide-in-from-top-2 duration-200 border-t border-border bg-muted/30 px-6 py-4">
      <div className="flex items-start gap-4">
        <Avatar
          name={sender.name}
          email={sender.email}
          size="lg"
          className="w-14 h-14 text-base shadow-md"
        />
        <div className="flex-1 min-w-0 space-y-2">
          <div>
            <div className="font-semibold text-foreground text-base">
              {sender.name || sender.email}
            </div>
            {sender.name && (
              <div className="text-sm text-muted-foreground truncate">
                {sender.email}
              </div>
            )}
          </div>

          {matchedContact ? (
            <div className="text-sm text-muted-foreground">
              {orgName && (
                <span>{orgName}</span>
              )}
              {!orgName && (
                <span>{getContactDisplayName(matchedContact)}</span>
              )}
            </div>
          ) : (
            <div className="text-sm text-muted-foreground italic">
              {t("no_contact")}
            </div>
          )}

          <div className="flex items-center gap-2 flex-wrap pt-1">
            {!matchedContact && (
              <Button
                variant="outline"
                size="sm"
                className="h-8 text-xs"
                onClick={() => onAddContact(sender.name || "", sender.email)}
              >
                <UserPlus className="w-3.5 h-3.5 mr-1.5" />
                {t("add_to_contacts")}
              </Button>
            )}
            <Button
              variant="outline"
              size="sm"
              className="h-8 text-xs"
              onClick={() => onSearch(sender.email)}
            >
              <Search className="w-3.5 h-3.5 mr-1.5" />
              {t("view_all_emails")}
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}
