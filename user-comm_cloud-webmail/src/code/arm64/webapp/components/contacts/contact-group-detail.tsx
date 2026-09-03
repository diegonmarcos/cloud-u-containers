"use client";

import { useTranslations } from "next-intl";
import { Users, Pencil, Trash2, UserMinus } from "lucide-react";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import type { ContactCard } from "@/lib/jmap/types";
import { getContactDisplayName, getContactPrimaryEmail } from "@/stores/contact-store";

interface ContactGroupDetailProps {
  group: ContactCard;
  members: ContactCard[];
  onEdit: () => void;
  onDelete: () => void;
  onRemoveMember: (memberId: string) => void;
  onSelectMember: (id: string) => void;
  className?: string;
}

export function ContactGroupDetail({
  group,
  members,
  onEdit,
  onDelete,
  onRemoveMember,
  onSelectMember,
  className,
}: ContactGroupDetailProps) {
  const t = useTranslations("contacts");
  const groupName = getContactDisplayName(group);

  return (
    <div className={cn("flex flex-col h-full overflow-y-auto", className)}>
      <div className="px-6 py-6 border-b border-border">
        <div className="flex items-start justify-between">
          <div className="flex items-center gap-4">
            <div className="w-14 h-14 rounded-full bg-primary/10 flex items-center justify-center">
              <Users className="w-7 h-7 text-primary" />
            </div>
            <div>
              <h2 className="text-xl font-semibold">{groupName}</h2>
              <p className="text-sm text-muted-foreground">
                {t("groups.member_count", { count: members.length })}
              </p>
            </div>
          </div>
          <div className="flex gap-2">
            <Button variant="outline" size="sm" onClick={onEdit}>
              <Pencil className="w-4 h-4 mr-1" />
              {t("form.edit_title")}
            </Button>
            <Button
              variant="outline"
              size="sm"
              onClick={onDelete}
              className="text-red-600 dark:text-red-400 hover:text-red-700 dark:hover:text-red-300 hover:bg-red-50 dark:hover:bg-red-950"
            >
              <Trash2 className="w-4 h-4" />
            </Button>
          </div>
        </div>
      </div>

      <div className="px-6 py-4">
        <h3 className="text-sm font-medium text-muted-foreground mb-3">
          {t("groups.members_label")}
        </h3>
        {members.length === 0 ? (
          <p className="text-sm text-muted-foreground py-4 text-center">
            {t("groups.no_members")}
          </p>
        ) : (
          <div className="space-y-1">
            {members.map((member) => {
              const mName = getContactDisplayName(member);
              const mEmail = getContactPrimaryEmail(member);
              return (
                <div
                  key={member.id}
                  className="flex items-center gap-3 px-3 py-2.5 rounded-md hover:bg-muted group transition-colors"
                >
                  <button
                    className="flex items-center gap-3 flex-1 min-w-0 text-left"
                    onClick={() => onSelectMember(member.id)}
                  >
                    <Avatar name={mName} email={mEmail} size="sm" />
                    <div className="flex-1 min-w-0">
                      <div className="text-sm font-medium truncate">{mName}</div>
                      {mEmail && (
                        <div className="text-xs text-muted-foreground truncate">{mEmail}</div>
                      )}
                    </div>
                  </button>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-8 w-8 opacity-0 group-hover:opacity-100 transition-opacity"
                    onClick={() => onRemoveMember(member.id)}
                  >
                    <UserMinus className="w-4 h-4 text-muted-foreground" />
                  </Button>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
