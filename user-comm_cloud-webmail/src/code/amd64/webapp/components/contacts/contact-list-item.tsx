"use client";

import { Avatar } from "@/components/ui/avatar";
import { cn } from "@/lib/utils";
import type { ContactCard } from "@/lib/jmap/types";
import { getContactDisplayName, getContactPrimaryEmail } from "@/stores/contact-store";

interface ContactListItemProps {
  contact: ContactCard;
  isSelected: boolean;
  onClick: () => void;
}

export function ContactListItem({ contact, isSelected, onClick }: ContactListItemProps) {
  const name = getContactDisplayName(contact);
  const email = getContactPrimaryEmail(contact);
  const org = contact.organizations
    ? Object.values(contact.organizations)[0]?.name
    : undefined;

  return (
    <button
      onClick={onClick}
      className={cn(
        "w-full flex items-center gap-3 px-4 py-3 text-left transition-colors",
        "hover:bg-muted",
        isSelected && "bg-accent text-accent-foreground"
      )}
    >
      <Avatar name={name} email={email} size="sm" />
      <div className="flex-1 min-w-0">
        <div className="text-sm font-medium truncate">
          {name || email || "—"}
        </div>
        {email && name && (
          <div className="text-xs text-muted-foreground truncate">{email}</div>
        )}
        {org && (
          <div className="text-xs text-muted-foreground truncate">{org}</div>
        )}
      </div>
    </button>
  );
}
