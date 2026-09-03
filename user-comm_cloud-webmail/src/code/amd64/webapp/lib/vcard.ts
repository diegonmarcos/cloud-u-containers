import type { ContactCard, NameComponent } from "@/lib/jmap/types";

function unfoldLines(vcf: string): string {
  return vcf.replace(/\r\n[ \t]/g, "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

function decodeValue(raw: string): string {
  return raw
    .replace(/\\n/gi, "\n")
    .replace(/\\,/g, ",")
    .replace(/\\;/g, ";")
    .replace(/\\\\/g, "\\");
}

function encodeValue(val: string): string {
  return val
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\n/g, "\\n");
}

function parseParams(paramStr: string): Record<string, string> {
  const params: Record<string, string> = {};
  if (!paramStr) return params;
  const parts = paramStr.split(";");
  for (const part of parts) {
    const eq = part.indexOf("=");
    if (eq > 0) {
      params[part.substring(0, eq).toUpperCase()] = part.substring(eq + 1).replace(/"/g, "");
    } else {
      const upper = part.toUpperCase();
      if (["WORK", "HOME", "CELL", "FAX", "VOICE", "PREF"].includes(upper)) {
        params.TYPE = params.TYPE ? `${params.TYPE},${upper}` : upper;
      }
    }
  }
  return params;
}

function typeToContext(typeStr: string | undefined): Record<string, boolean> | undefined {
  if (!typeStr) return undefined;
  const types = typeStr.toUpperCase().split(",");
  const ctx: Record<string, boolean> = {};
  if (types.includes("WORK")) ctx.work = true;
  if (types.includes("HOME")) ctx.private = true;
  if (!ctx.work && !ctx.private) return undefined;
  return ctx;
}

function contextToType(contexts: Record<string, boolean> | undefined): string {
  if (!contexts) return "";
  if (contexts.work) return "WORK";
  if (contexts.private) return "HOME";
  return "";
}

export function parseVCard(vcfString: string): ContactCard[] {
  const text = unfoldLines(vcfString);
  const lines = text.split("\n");
  const contacts: ContactCard[] = [];
  let current: Record<string, string[]> | null = null;

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    if (trimmed.toUpperCase() === "BEGIN:VCARD") {
      current = {};
      continue;
    }

    if (trimmed.toUpperCase() === "END:VCARD") {
      if (current) {
        const card = buildContact(current);
        if (card) contacts.push(card);
      }
      current = null;
      continue;
    }

    if (current) {
      const colonIdx = trimmed.indexOf(":");
      if (colonIdx < 1) continue;
      const keyPart = trimmed.substring(0, colonIdx);
      const value = trimmed.substring(colonIdx + 1);
      if (!current[keyPart]) current[keyPart] = [];
      current[keyPart].push(value);
    }
  }

  return contacts;
}

function buildContact(raw: Record<string, string[]>): ContactCard | null {
  const id = `import-${crypto.randomUUID()}`;
  const card: ContactCard = { id, addressBookIds: {} };

  for (const [fullKey, values] of Object.entries(raw)) {
    const semiIdx = fullKey.indexOf(";");
    const propName = (semiIdx > 0 ? fullKey.substring(0, semiIdx) : fullKey).toUpperCase();
    const paramStr = semiIdx > 0 ? fullKey.substring(semiIdx + 1) : "";
    const params = parseParams(paramStr);

    for (const rawValue of values) {
      const val = decodeValue(rawValue);

      switch (propName) {
        case "FN":
          if (!card.name) {
            const parts = val.split(" ");
            const components: NameComponent[] = [];
            if (parts.length >= 2) {
              components.push({ kind: "given", value: parts[0] });
              components.push({ kind: "surname", value: parts.slice(1).join(" ") });
            } else if (parts.length === 1) {
              components.push({ kind: "given", value: parts[0] });
            }
            card.name = { components, isOrdered: true };
          }
          break;

        case "N": {
          const nParts = val.split(";");
          const components: NameComponent[] = [];
          if (nParts[3]) components.push({ kind: "prefix", value: nParts[3] });
          if (nParts[1]) components.push({ kind: "given", value: nParts[1] });
          if (nParts[2]) components.push({ kind: "additional", value: nParts[2] });
          if (nParts[0]) components.push({ kind: "surname", value: nParts[0] });
          if (nParts[4]) components.push({ kind: "suffix", value: nParts[4] });
          if (components.length > 0) {
            card.name = { components, isOrdered: true };
          }
          break;
        }

        case "EMAIL": {
          if (!card.emails) card.emails = {};
          const idx = Object.keys(card.emails).length;
          card.emails[`e${idx}`] = {
            address: val,
            contexts: typeToContext(params.TYPE),
          };
          break;
        }

        case "TEL": {
          if (!card.phones) card.phones = {};
          const idx = Object.keys(card.phones).length;
          card.phones[`p${idx}`] = {
            number: val,
            contexts: typeToContext(params.TYPE),
          };
          break;
        }

        case "ORG": {
          if (!card.organizations) card.organizations = {};
          const orgParts = val.split(";").filter(Boolean);
          const idx = Object.keys(card.organizations).length;
          card.organizations[`o${idx}`] = {
            name: orgParts[0],
            units: orgParts.slice(1).map(u => ({ name: u })),
          };
          break;
        }

        case "ADR": {
          if (!card.addresses) card.addresses = {};
          const adrParts = val.split(";");
          const idx = Object.keys(card.addresses).length;
          card.addresses[`a${idx}`] = {
            street: adrParts[2] || undefined,
            locality: adrParts[3] || undefined,
            region: adrParts[4] || undefined,
            postcode: adrParts[5] || undefined,
            country: adrParts[6] || undefined,
            contexts: typeToContext(params.TYPE),
          };
          break;
        }

        case "NOTE": {
          if (!card.notes) card.notes = {};
          const idx = Object.keys(card.notes).length;
          card.notes[`n${idx}`] = { note: val };
          break;
        }

        case "NICKNAME": {
          if (!card.nicknames) card.nicknames = {};
          card.nicknames.n0 = { name: val };
          break;
        }

        case "UID":
          card.uid = val;
          break;

        case "KIND": {
          const k = val.toLowerCase();
          if (k === "group" || k === "individual" || k === "org") {
            card.kind = k;
          }
          break;
        }

        case "MEMBER": {
          if (!card.members) card.members = {};
          const memberUri = val.startsWith("urn:uuid:") ? val.substring(9) : val;
          card.members[memberUri] = true;
          break;
        }
      }
    }
  }

  const hasName = card.name && card.name.components.length > 0;
  const hasEmail = card.emails && Object.keys(card.emails).length > 0;
  if (!hasName && !hasEmail && card.kind !== "group") return null;

  return card;
}

export function generateVCard(contacts: ContactCard[]): string {
  return contacts.map(generateSingleVCard).join("\r\n");
}

function generateSingleVCard(contact: ContactCard): string {
  const lines: string[] = ["BEGIN:VCARD", "VERSION:3.0"];

  if (contact.uid) {
    lines.push(`UID:${contact.uid}`);
  }

  if (contact.kind) {
    lines.push(`KIND:${contact.kind}`);
  }

  const components = contact.name?.components || [];
  const given = components.find(c => c.kind === "given")?.value || "";
  const surname = components.find(c => c.kind === "surname")?.value || "";
  const prefix = components.find(c => c.kind === "prefix")?.value || "";
  const suffix = components.find(c => c.kind === "suffix")?.value || "";
  const additional = components.find(c => c.kind === "additional")?.value || "";

  const fn = [given, surname].filter(Boolean).join(" ");
  if (fn) {
    lines.push(`FN:${encodeValue(fn)}`);
    lines.push(`N:${encodeValue(surname)};${encodeValue(given)};${encodeValue(additional)};${encodeValue(prefix)};${encodeValue(suffix)}`);
  }

  if (contact.nicknames) {
    for (const nick of Object.values(contact.nicknames)) {
      lines.push(`NICKNAME:${encodeValue(nick.name)}`);
    }
  }

  if (contact.emails) {
    for (const email of Object.values(contact.emails)) {
      const type = contextToType(email.contexts);
      const typeParam = type ? `;TYPE=${type}` : "";
      lines.push(`EMAIL${typeParam}:${email.address}`);
    }
  }

  if (contact.phones) {
    for (const phone of Object.values(contact.phones)) {
      const type = contextToType(phone.contexts);
      const typeParam = type ? `;TYPE=${type}` : "";
      lines.push(`TEL${typeParam}:${phone.number}`);
    }
  }

  if (contact.organizations) {
    for (const org of Object.values(contact.organizations)) {
      const parts = [org.name || ""];
      if (org.units) parts.push(...org.units.map(u => u.name));
      lines.push(`ORG:${parts.map(encodeValue).join(";")}`);
    }
  }

  if (contact.addresses) {
    for (const addr of Object.values(contact.addresses)) {
      const type = contextToType(addr.contexts);
      const typeParam = type ? `;TYPE=${type}` : "";
      const parts = [
        "",
        "",
        addr.street || "",
        addr.locality || "",
        addr.region || "",
        addr.postcode || "",
        addr.country || "",
      ];
      lines.push(`ADR${typeParam}:${parts.map(encodeValue).join(";")}`);
    }
  }

  if (contact.notes) {
    for (const n of Object.values(contact.notes)) {
      lines.push(`NOTE:${encodeValue(n.note)}`);
    }
  }

  if (contact.members) {
    for (const memberId of Object.keys(contact.members)) {
      if (contact.members[memberId]) {
        lines.push(`MEMBER:urn:uuid:${memberId}`);
      }
    }
  }

  lines.push("END:VCARD");
  return lines.join("\r\n");
}

export function detectDuplicates(
  existing: ContactCard[],
  incoming: ContactCard[]
): Map<number, string> {
  const dupes = new Map<number, string>();
  const existingEmails = new Map<string, string>();

  for (const c of existing) {
    if (c.emails) {
      for (const e of Object.values(c.emails)) {
        existingEmails.set(e.address.toLowerCase(), c.id);
      }
    }
  }

  incoming.forEach((card, idx) => {
    if (card.emails) {
      for (const e of Object.values(card.emails)) {
        const match = existingEmails.get(e.address.toLowerCase());
        if (match) {
          dupes.set(idx, match);
          return;
        }
      }
    }
  });

  return dupes;
}
