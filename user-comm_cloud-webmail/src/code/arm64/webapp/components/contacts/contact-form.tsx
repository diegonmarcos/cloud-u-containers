"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { X, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";
import type { ContactCard } from "@/lib/jmap/types";

interface EmailEntry {
  address: string;
  context: "work" | "private" | "";
}

interface PhoneEntry {
  number: string;
  context: "work" | "private" | "";
}

interface ContactFormProps {
  contact?: ContactCard | null;
  onSave: (data: Partial<ContactCard>) => Promise<void>;
  onCancel: () => void;
}

export function ContactForm({ contact, onSave, onCancel }: ContactFormProps) {
  const t = useTranslations("contacts.form");
  const isEditing = !!contact;

  const givenInit = contact?.name?.components?.find(c => c.kind === "given")?.value || "";
  const surnameInit = contact?.name?.components?.find(c => c.kind === "surname")?.value || "";

  const [givenName, setGivenName] = useState(givenInit);
  const [surname, setSurname] = useState(surnameInit);

  const [emails, setEmails] = useState<EmailEntry[]>(() => {
    if (contact?.emails) {
      return Object.values(contact.emails).map(e => ({
        address: e.address,
        context: e.contexts?.work ? "work" : e.contexts?.private ? "private" : "",
      }));
    }
    return [{ address: "", context: "" }];
  });

  const [phones, setPhones] = useState<PhoneEntry[]>(() => {
    if (contact?.phones) {
      return Object.values(contact.phones).map(p => ({
        number: p.number,
        context: p.contexts?.work ? "work" : p.contexts?.private ? "private" : "",
      }));
    }
    return [];
  });

  const [organization, setOrganization] = useState(
    contact?.organizations ? Object.values(contact.organizations)[0]?.name || "" : ""
  );

  const [note, setNote] = useState(
    contact?.notes ? Object.values(contact.notes)[0]?.note || "" : ""
  );

  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [emailErrors, setEmailErrors] = useState<Record<number, string>>({});

  const validateEmail = (address: string): boolean => {
    if (!address.trim()) return true;
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address.trim());
  };

  const handleEmailBlur = (index: number, address: string) => {
    if (address.trim() && !validateEmail(address)) {
      setEmailErrors(prev => ({ ...prev, [index]: t("email_error_inline") }));
    } else {
      setEmailErrors(prev => {
        const next = { ...prev };
        delete next[index];
        return next;
      });
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    if (!givenName.trim() && !surname.trim()) {
      setError(t("name_required"));
      return;
    }

    const validEmails = emails.filter(e => e.address.trim());
    for (const entry of validEmails) {
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(entry.address.trim())) {
        setError(t("email_invalid"));
        return;
      }
    }

    const emailsMap: Record<string, { address: string; contexts?: Record<string, boolean> }> = {};
    validEmails.forEach((entry, i) => {
      const obj: { address: string; contexts?: Record<string, boolean> } = { address: entry.address.trim() };
      if (entry.context) {
        obj.contexts = { [entry.context]: true };
      }
      emailsMap[`e${i}`] = obj;
    });

    const validPhones = phones.filter(p => p.number.trim());
    const phonesMap: Record<string, { number: string; contexts?: Record<string, boolean> }> = {};
    validPhones.forEach((entry, i) => {
      const obj: { number: string; contexts?: Record<string, boolean> } = { number: entry.number.trim() };
      if (entry.context) {
        obj.contexts = { [entry.context]: true };
      }
      phonesMap[`p${i}`] = obj;
    });

    const nameComponents = [];
    if (givenName.trim()) {
      nameComponents.push({ kind: "given" as const, value: givenName.trim() });
    }
    if (surname.trim()) {
      nameComponents.push({ kind: "surname" as const, value: surname.trim() });
    }

    const data: Partial<ContactCard> = {
      name: { components: nameComponents, isOrdered: true },
      emails: Object.keys(emailsMap).length > 0 ? emailsMap : undefined,
      phones: Object.keys(phonesMap).length > 0 ? phonesMap : undefined,
      organizations: organization.trim()
        ? { o0: { name: organization.trim() } }
        : undefined,
      notes: note.trim()
        ? { n0: { note: note.trim() } }
        : undefined,
    };

    setIsSaving(true);
    try {
      await onSave(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : t("save_failed"));
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <form onSubmit={handleSubmit} className="flex flex-col h-full">
      <div className="px-6 py-4 border-b border-border">
        <h2 className="text-lg font-semibold">
          {isEditing ? t("edit_title") : t("create_title")}
        </h2>
      </div>

      <div className="flex-1 overflow-y-auto px-6 py-4 space-y-4">
        {error && (
          <div className="text-sm text-red-600 dark:text-red-400 bg-red-50 dark:bg-red-950 px-3 py-2 rounded">
            {error}
          </div>
        )}

        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          <div>
            <label className="text-sm text-muted-foreground mb-1 block">
              {t("given_name")} <span className="text-red-500">*</span>
            </label>
            <Input
              value={givenName}
              onChange={(e) => setGivenName(e.target.value)}
              placeholder={t("given_name")}
              autoFocus
            />
          </div>
          <div>
            <label className="text-sm text-muted-foreground mb-1 block">
              {t("surname")} <span className="text-red-500">*</span>
            </label>
            <Input
              value={surname}
              onChange={(e) => setSurname(e.target.value)}
              placeholder={t("surname")}
            />
          </div>
        </div>

        <div>
          <label className="text-sm text-muted-foreground mb-1 block">{t("email")}</label>
          <div className="space-y-2">
            {emails.map((entry, i) => (
              <div key={i}>
                <div className="flex items-center gap-2">
                <Input
                  type="email"
                  inputMode="email"
                  value={entry.address}
                  onChange={(e) => {
                    const next = [...emails];
                    next[i] = { ...next[i], address: e.target.value };
                    setEmails(next);
                    if (emailErrors[i]) {
                      setEmailErrors(prev => {
                        const n = { ...prev };
                        delete n[i];
                        return n;
                      });
                    }
                  }}
                  onBlur={() => handleEmailBlur(i, entry.address)}
                  placeholder={t("email_placeholder")}
                  className={cn("flex-1", emailErrors[i] && "border-red-500 focus:ring-red-500")}
                />
                <select
                  value={entry.context}
                  onChange={(e) => {
                    const next = [...emails];
                    next[i] = { ...next[i], context: e.target.value as EmailEntry["context"] };
                    setEmails(next);
                  }}
                  className="text-sm bg-transparent border rounded px-2 py-2 text-foreground"
                >
                  <option value="">—</option>
                  <option value="work">{t("context_work")}</option>
                  <option value="private">{t("context_private")}</option>
                </select>
                {emails.length > 1 && (
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    onClick={() => setEmails(emails.filter((_, j) => j !== i))}
                    className="h-8 w-8"
                  >
                    <X className="w-3 h-3" />
                  </Button>
                )}
                </div>
                {emailErrors[i] && (
                  <p className="text-xs text-red-600 dark:text-red-400 mt-1">{emailErrors[i]}</p>
                )}
              </div>
            ))}
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => setEmails([...emails, { address: "", context: "" }])}
            >
              <Plus className="w-3 h-3 mr-1" />
              {t("add_email")}
            </Button>
          </div>
        </div>

        <div>
          <label className="text-sm text-muted-foreground mb-1 block">{t("phone")}</label>
          <div className="space-y-2">
            {phones.map((entry, i) => (
              <div key={i} className="flex items-center gap-2">
                <Input
                  type="tel"
                  inputMode="tel"
                  value={entry.number}
                  onChange={(e) => {
                    const next = [...phones];
                    next[i] = { ...next[i], number: e.target.value };
                    setPhones(next);
                  }}
                  placeholder={t("phone_placeholder")}
                  className="flex-1"
                />
                <select
                  value={entry.context}
                  onChange={(e) => {
                    const next = [...phones];
                    next[i] = { ...next[i], context: e.target.value as PhoneEntry["context"] };
                    setPhones(next);
                  }}
                  className="text-sm bg-transparent border rounded px-2 py-2 text-foreground"
                >
                  <option value="">—</option>
                  <option value="work">{t("context_work")}</option>
                  <option value="private">{t("context_private")}</option>
                </select>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  onClick={() => setPhones(phones.filter((_, j) => j !== i))}
                  className="h-8 w-8"
                >
                  <X className="w-3 h-3" />
                </Button>
              </div>
            ))}
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => setPhones([...phones, { number: "", context: "" }])}
            >
              <Plus className="w-3 h-3 mr-1" />
              {t("add_phone")}
            </Button>
          </div>
        </div>

        <div>
          <label className="text-sm text-muted-foreground mb-1 block">{t("organization")}</label>
          <Input
            value={organization}
            onChange={(e) => setOrganization(e.target.value)}
            placeholder={t("organization_placeholder")}
          />
        </div>

        <div>
          <label className="text-sm text-muted-foreground mb-1 block">{t("note")}</label>
          <textarea
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder={t("note_placeholder")}
            className="w-full min-h-[80px] rounded border bg-transparent px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground resize-y outline-none focus:ring-2 focus:ring-ring"
          />
        </div>
      </div>

      <div className="flex items-center justify-end gap-2 px-6 py-4 border-t border-border">
        <Button type="button" variant="outline" onClick={onCancel} disabled={isSaving}>
          {t("cancel")}
        </Button>
        <Button type="submit" disabled={isSaving}>
          {isSaving ? (isEditing ? t("updating") : t("creating")) : t("save")}
        </Button>
      </div>
    </form>
  );
}
