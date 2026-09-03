"use client";

import { useMemo } from "react";
import { useTranslations } from "next-intl";
import { Search, Plus, BookUser, Info, Check, X, UserPlus, Upload } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ContactListItem } from "./contact-list-item";
import { ContactBulkActionsMenu } from "./contact-bulk-actions-menu";
import { cn } from "@/lib/utils";
import type { ContactCard } from "@/lib/jmap/types";
import { getContactDisplayName } from "@/stores/contact-store";

interface ContactListProps {
  contacts: ContactCard[];
  selectedContactId: string | null;
  searchQuery: string;
  onSearchChange: (query: string) => void;
  onSelectContact: (id: string) => void;
  onCreateNew: () => void;
  onImport?: () => void;
  supportsSync: boolean;
  className?: string;
  selectedContactIds: Set<string>;
  onToggleSelection: (id: string) => void;
  onSelectAll: (ids: string[]) => void;
  onClearSelection: () => void;
  onBulkDelete: () => void;
  onBulkAddToGroup: () => void;
  onBulkExport: () => void;
}

export function ContactList({
  contacts,
  selectedContactId,
  searchQuery,
  onSearchChange,
  onSelectContact,
  onCreateNew,
  onImport,
  supportsSync,
  className,
  selectedContactIds,
  onToggleSelection,
  onSelectAll,
  onClearSelection,
  onBulkDelete,
  onBulkAddToGroup,
  onBulkExport,
}: ContactListProps) {
  const t = useTranslations("contacts");

  const filtered = useMemo(() => {
    const individuals = contacts.filter(c => c.kind !== "group");
    if (!searchQuery) return individuals;
    const lower = searchQuery.toLowerCase();
    return individuals.filter((c) => {
      const name = getContactDisplayName(c).toLowerCase();
      const emails = c.emails
        ? Object.values(c.emails).map((e) => e.address.toLowerCase())
        : [];
      return (
        name.includes(lower) || emails.some((e) => e.includes(lower))
      );
    });
  }, [contacts, searchQuery]);

  const sorted = useMemo(() => {
    return [...filtered].sort((a, b) => {
      const nameA = getContactDisplayName(a).toLowerCase();
      const nameB = getContactDisplayName(b).toLowerCase();
      return nameA.localeCompare(nameB);
    });
  }, [filtered]);

  const hasSelection = selectedContactIds.size > 0;
  const allSelected = sorted.length > 0 && sorted.every(c => selectedContactIds.has(c.id));

  return (
    <div className={cn("flex flex-col h-full", className)}>
      <div className="px-4 py-3 border-b border-border space-y-3">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold">{t("title")}</h2>
          <Button size="sm" onClick={onCreateNew}>
            <Plus className="w-4 h-4 mr-1" />
            {t("create_new")}
          </Button>
        </div>

        <div className="relative">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-muted-foreground" />
          <Input
            placeholder={t("search_placeholder")}
            value={searchQuery}
            onChange={(e) => onSearchChange(e.target.value)}
            className="pl-9"
          />
        </div>

        {!supportsSync && (
          <div className="flex items-start gap-2 text-xs text-muted-foreground bg-muted rounded px-3 py-2">
            <Info className="w-3.5 h-3.5 mt-0.5 flex-shrink-0" />
            <span>{t("local_mode")}</span>
          </div>
        )}
      </div>

      {hasSelection && (
        <div className="px-3 py-2 border-b border-border bg-muted/50 flex items-center gap-2">
          <span className="text-xs font-medium text-muted-foreground">
            {t("bulk.selected", { count: selectedContactIds.size })}
          </span>
          <div className="flex-1" />
          <ContactBulkActionsMenu
            onBulkAddToGroup={onBulkAddToGroup}
            onBulkExport={onBulkExport}
            onBulkDelete={onBulkDelete}
          />
          <Button variant="ghost" size="icon" onClick={onClearSelection} className="h-7 w-7">
            <X className="w-3.5 h-3.5" />
          </Button>
        </div>
      )}

      {sorted.length > 0 && (
        <div className="px-4 py-1.5 border-b border-border flex items-center">
          <button
            onClick={() => {
              if (allSelected) {
                onClearSelection();
              } else {
                onSelectAll(sorted.map(c => c.id));
              }
            }}
            className="flex items-center gap-2 text-xs text-muted-foreground hover:text-foreground transition-colors"
          >
            <div className={cn(
              "w-4 h-4 rounded border flex items-center justify-center transition-colors",
              allSelected
                ? "bg-primary border-primary text-primary-foreground"
                : "border-border"
            )}>
              {allSelected && <Check className="w-2.5 h-2.5" />}
            </div>
            {t("bulk.select_all")}
          </button>
        </div>
      )}

      <div className="flex-1 overflow-y-auto">
        {sorted.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full px-6 text-center">
            {searchQuery ? (
              <>
                <Search className="w-12 h-12 mb-3 text-muted-foreground/30" />
                <p className="text-sm font-medium text-foreground">{t("empty_search")}</p>
                <p className="text-xs text-muted-foreground mt-1">{t("empty_search_hint")}</p>
                <Button
                  variant="outline"
                  size="sm"
                  className="mt-4"
                  onClick={() => onSearchChange("")}
                >
                  {t("clear_search")}
                </Button>
              </>
            ) : (
              <>
                <BookUser className="w-12 h-12 mb-3 text-muted-foreground/30" />
                <p className="text-sm font-medium text-foreground">{t("empty_state_title")}</p>
                <p className="text-xs text-muted-foreground mt-1">{t("empty_state_subtitle")}</p>
                <div className="flex flex-wrap gap-2 mt-4 justify-center">
                  <Button size="sm" onClick={onCreateNew} className="min-w-0 whitespace-nowrap overflow-hidden text-ellipsis">
                    <UserPlus className="w-4 h-4 mr-1.5 shrink-0" />
                    {t("create_new")}
                  </Button>
                  {onImport && (
                    <Button variant="outline" size="sm" onClick={onImport} className="min-w-0 whitespace-nowrap overflow-hidden text-ellipsis">
                      <Upload className="w-4 h-4 mr-1.5 shrink-0" />
                      {t("import_vcard")}
                    </Button>
                  )}
                </div>
              </>
            )}
          </div>
        ) : (
          <div className="divide-y divide-border">
            {sorted.map((contact) => (
              <div key={contact.id} className="flex items-center">
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    onToggleSelection(contact.id);
                  }}
                  className="pl-4 pr-1 py-3 flex-shrink-0"
                >
                  <div className={cn(
                    "w-4 h-4 rounded border flex items-center justify-center transition-colors",
                    selectedContactIds.has(contact.id)
                      ? "bg-primary border-primary text-primary-foreground"
                      : "border-border hover:border-muted-foreground"
                  )}>
                    {selectedContactIds.has(contact.id) && <Check className="w-2.5 h-2.5" />}
                  </div>
                </button>
                <div className="flex-1 min-w-0">
                  <ContactListItem
                    contact={contact}
                    isSelected={contact.id === selectedContactId}
                    onClick={() => onSelectContact(contact.id)}
                  />
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
