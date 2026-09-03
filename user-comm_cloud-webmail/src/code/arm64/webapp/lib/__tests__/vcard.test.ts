import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { parseVCard, generateVCard, detectDuplicates } from "../vcard";
import type { ContactCard } from "@/lib/jmap/types";

beforeEach(() => {
  vi.stubGlobal("crypto", { randomUUID: () => "test-uuid" });
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("parseVCard", () => {
  it("parses single vCard with FN (full name)", () => {
    const vcf = `BEGIN:VCARD\r\nVERSION:3.0\r\nFN:John Doe\r\nEMAIL:john@example.com\r\nEND:VCARD`;
    const result = parseVCard(vcf);

    expect(result).toHaveLength(1);
    const card = result[0];
    expect(card.id).toBe("import-test-uuid");
    expect(card.name?.components).toEqual(
      expect.arrayContaining([
        { kind: "given", value: "John" },
        { kind: "surname", value: "Doe" },
      ])
    );
    expect(card.emails?.e0?.address).toBe("john@example.com");
  });

  it("parses vCard with N field (structured name with all components)", () => {
    const vcf = `BEGIN:VCARD\r\nVERSION:3.0\r\nN:Doe;John;Michael;Mr.;Jr.\r\nEMAIL:john@example.com\r\nEND:VCARD`;
    const result = parseVCard(vcf);

    expect(result).toHaveLength(1);
    const components = result[0].name?.components || [];
    expect(components).toEqual([
      { kind: "prefix", value: "Mr." },
      { kind: "given", value: "John" },
      { kind: "additional", value: "Michael" },
      { kind: "surname", value: "Doe" },
      { kind: "suffix", value: "Jr." },
    ]);
  });

  it("N field overrides FN when both present", () => {
    const vcf = `BEGIN:VCARD\r\nVERSION:3.0\r\nFN:John Doe\r\nN:Doe;John;;;\r\nEMAIL:john@example.com\r\nEND:VCARD`;
    const result = parseVCard(vcf);

    // N comes after FN in raw lines, and N always sets card.name (overwrites FN)
    const components = result[0].name?.components || [];
    expect(components.find((c) => c.kind === "given")?.value).toBe("John");
    expect(components.find((c) => c.kind === "surname")?.value).toBe("Doe");
  });

  it("parses vCard with phone, org, and address", () => {
    const vcf = [
      "BEGIN:VCARD",
      "VERSION:3.0",
      "FN:Jane Smith",
      "EMAIL;TYPE=WORK:jane@work.com",
      "TEL;TYPE=CELL:+1234567890",
      "ORG:Acme Corp;Engineering",
      "ADR;TYPE=WORK:;;123 Main St;City;State;12345;US",
      "END:VCARD",
    ].join("\r\n");

    const result = parseVCard(vcf);
    expect(result).toHaveLength(1);
    const card = result[0];

    expect(card.emails?.e0?.address).toBe("jane@work.com");
    expect(card.emails?.e0?.contexts).toEqual({ work: true });

    expect(card.phones?.p0?.number).toBe("+1234567890");

    expect(card.organizations?.o0?.name).toBe("Acme Corp");
    expect(card.organizations?.o0?.units).toEqual([{ name: "Engineering" }]);

    expect(card.addresses?.a0).toMatchObject({
      street: "123 Main St",
      locality: "City",
      region: "State",
      postcode: "12345",
      country: "US",
      contexts: { work: true },
    });
  });

  it("parses vCard with nickname, notes, and UID", () => {
    const vcf = [
      "BEGIN:VCARD",
      "VERSION:3.0",
      "FN:Bob Builder",
      "NICKNAME:Bobby",
      "NOTE:Important person",
      "UID:abc-123",
      "EMAIL:bob@example.com",
      "END:VCARD",
    ].join("\r\n");

    const result = parseVCard(vcf);
    const card = result[0];

    expect(card.nicknames?.n0?.name).toBe("Bobby");
    expect(card.notes?.n0?.note).toBe("Important person");
    expect(card.uid).toBe("abc-123");
  });

  it("parses multi-contact vCard file", () => {
    const vcf = [
      "BEGIN:VCARD",
      "VERSION:3.0",
      "FN:Alice",
      "EMAIL:alice@example.com",
      "END:VCARD",
      "BEGIN:VCARD",
      "VERSION:3.0",
      "FN:Bob",
      "EMAIL:bob@example.com",
      "END:VCARD",
    ].join("\r\n");

    const result = parseVCard(vcf);
    expect(result).toHaveLength(2);
    expect(result[0].emails?.e0?.address).toBe("alice@example.com");
    expect(result[1].emails?.e0?.address).toBe("bob@example.com");
  });

  it("skips malformed vCards without name or email", () => {
    const vcf = [
      "BEGIN:VCARD",
      "VERSION:3.0",
      "NOTE:Just a note",
      "END:VCARD",
      "BEGIN:VCARD",
      "VERSION:3.0",
      "FN:Valid Contact",
      "EMAIL:valid@example.com",
      "END:VCARD",
    ].join("\r\n");

    const result = parseVCard(vcf);
    expect(result).toHaveLength(1);
    expect(result[0].emails?.e0?.address).toBe("valid@example.com");
  });

  it("parses vCard with group kind and members", () => {
    const vcf = [
      "BEGIN:VCARD",
      "VERSION:3.0",
      "FN:Team Alpha",
      "KIND:group",
      "MEMBER:urn:uuid:member-1",
      "MEMBER:urn:uuid:member-2",
      "END:VCARD",
    ].join("\r\n");

    const result = parseVCard(vcf);
    expect(result).toHaveLength(1);
    const card = result[0];

    expect(card.kind).toBe("group");
    expect(card.members).toEqual({ "member-1": true, "member-2": true });
  });

  it("handles folded lines (continuation with leading space)", () => {
    const vcf =
      "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:John\r\n Doe\r\nEMAIL:john@example.com\r\nEND:VCARD";
    const result = parseVCard(vcf);

    expect(result).toHaveLength(1);
    expect(result[0].name?.components).toEqual(
      expect.arrayContaining([{ kind: "given", value: "JohnDoe" }])
    );
  });

  it("handles escaped characters", () => {
    const vcf = [
      "BEGIN:VCARD",
      "VERSION:3.0",
      "FN:Test User",
      "NOTE:Line one\\nLine two\\, with comma\\; and semicolon\\\\backslash",
      "EMAIL:test@example.com",
      "END:VCARD",
    ].join("\r\n");

    const result = parseVCard(vcf);
    expect(result[0].notes?.n0?.note).toBe(
      "Line one\nLine two, with comma; and semicolon\\backslash"
    );
  });

  it("allows group kind without name or email", () => {
    const vcf = [
      "BEGIN:VCARD",
      "VERSION:3.0",
      "KIND:group",
      "MEMBER:urn:uuid:m1",
      "END:VCARD",
    ].join("\r\n");

    const result = parseVCard(vcf);
    expect(result).toHaveLength(1);
    expect(result[0].kind).toBe("group");
  });
});

describe("generateVCard", () => {
  it("exports single contact with all fields", () => {
    const contact: ContactCard = {
      id: "c1",
      uid: "uid-1",
      addressBookIds: { ab1: true },
      kind: "individual",
      name: {
        components: [
          { kind: "prefix", value: "Dr." },
          { kind: "given", value: "Jane" },
          { kind: "additional", value: "Marie" },
          { kind: "surname", value: "Smith" },
          { kind: "suffix", value: "PhD" },
        ],
        isOrdered: true,
      },
      emails: {
        e0: { address: "jane@work.com", contexts: { work: true } },
        e1: { address: "jane@home.com", contexts: { private: true } },
      },
      phones: { p0: { number: "+1234567890", contexts: { work: true } } },
      organizations: {
        o0: { name: "Acme Corp", units: [{ name: "Engineering" }] },
      },
      addresses: {
        a0: {
          street: "123 Main St",
          locality: "City",
          region: "State",
          postcode: "12345",
          country: "US",
          contexts: { work: true },
        },
      },
      nicknames: { n0: { name: "JJ" } },
      notes: { n0: { note: "VIP client" } },
    };

    const vcf = generateVCard([contact]);

    expect(vcf).toContain("BEGIN:VCARD");
    expect(vcf).toContain("END:VCARD");
    expect(vcf).toContain("VERSION:3.0");
    expect(vcf).toContain("UID:uid-1");
    expect(vcf).toContain("KIND:individual");
    expect(vcf).toContain("FN:Jane Smith");
    expect(vcf).toContain("N:Smith;Jane;Marie;Dr.;PhD");
    expect(vcf).toContain("NICKNAME:JJ");
    expect(vcf).toContain("EMAIL;TYPE=WORK:jane@work.com");
    expect(vcf).toContain("EMAIL;TYPE=HOME:jane@home.com");
    expect(vcf).toContain("TEL;TYPE=WORK:+1234567890");
    expect(vcf).toContain("ORG:Acme Corp;Engineering");
    expect(vcf).toContain("ADR;TYPE=WORK:;;123 Main St;City;State;12345;US");
    expect(vcf).toContain("NOTE:VIP client");
  });

  it("produces valid structure for minimal contact", () => {
    const contact: ContactCard = {
      id: "c2",
      addressBookIds: {},
      name: {
        components: [{ kind: "given", value: "Solo" }],
        isOrdered: true,
      },
    };

    const vcf = generateVCard([contact]);
    const lines = vcf.split("\r\n");

    expect(lines[0]).toBe("BEGIN:VCARD");
    expect(lines[1]).toBe("VERSION:3.0");
    expect(lines).toContain("FN:Solo");
    expect(lines).toContain("N:;Solo;;;");
    expect(lines[lines.length - 1]).toBe("END:VCARD");
  });

  it("encodes special characters in values", () => {
    const contact: ContactCard = {
      id: "c3",
      addressBookIds: {},
      name: {
        components: [{ kind: "given", value: "Test" }],
        isOrdered: true,
      },
      notes: { n0: { note: "Has comma, semicolon; and newline\nhere" } },
    };

    const vcf = generateVCard([contact]);
    expect(vcf).toContain("NOTE:Has comma\\, semicolon\\; and newline\\nhere");
  });
});

describe("round-trip: parse → generate → parse", () => {
  it("produces structurally equivalent data", () => {
    const original = [
      "BEGIN:VCARD",
      "VERSION:3.0",
      "FN:John Doe",
      "N:Doe;John;;;",
      "EMAIL;TYPE=WORK:john@work.com",
      "TEL:+1234567890",
      "ORG:Acme Corp",
      "NICKNAME:JD",
      "NOTE:A note",
      "UID:round-trip-1",
      "END:VCARD",
    ].join("\r\n");

    const parsed = parseVCard(original);
    const exported = generateVCard(parsed);
    const reparsed = parseVCard(exported);

    expect(reparsed).toHaveLength(1);
    const a = parsed[0];
    const b = reparsed[0];

    expect(b.name?.components).toEqual(a.name?.components);
    expect(b.emails?.e0?.address).toBe(a.emails?.e0?.address);
    expect(b.phones?.p0?.number).toBe(a.phones?.p0?.number);
    expect(b.organizations?.o0?.name).toBe(a.organizations?.o0?.name);
    expect(b.nicknames?.n0?.name).toBe(a.nicknames?.n0?.name);
    expect(b.notes?.n0?.note).toBe(a.notes?.n0?.note);
    expect(b.uid).toBe(a.uid);
  });
});

describe("detectDuplicates", () => {
  it("detects duplicates by matching email (case-insensitive)", () => {
    const existing: ContactCard[] = [
      {
        id: "existing-1",
        addressBookIds: {},
        emails: { e0: { address: "Alice@Example.com" } },
      },
    ];
    const incoming: ContactCard[] = [
      {
        id: "new-1",
        addressBookIds: {},
        emails: { e0: { address: "alice@example.com" } },
      },
    ];

    const dupes = detectDuplicates(existing, incoming);
    expect(dupes.size).toBe(1);
    expect(dupes.get(0)).toBe("existing-1");
  });

  it("returns empty map when no duplicates", () => {
    const existing: ContactCard[] = [
      {
        id: "existing-1",
        addressBookIds: {},
        emails: { e0: { address: "alice@example.com" } },
      },
    ];
    const incoming: ContactCard[] = [
      {
        id: "new-1",
        addressBookIds: {},
        emails: { e0: { address: "bob@example.com" } },
      },
    ];

    const dupes = detectDuplicates(existing, incoming);
    expect(dupes.size).toBe(0);
  });

  it("handles contacts without emails", () => {
    const existing: ContactCard[] = [
      { id: "existing-1", addressBookIds: {} },
    ];
    const incoming: ContactCard[] = [
      { id: "new-1", addressBookIds: {} },
      {
        id: "new-2",
        addressBookIds: {},
        emails: { e0: { address: "a@b.com" } },
      },
    ];

    const dupes = detectDuplicates(existing, incoming);
    expect(dupes.size).toBe(0);
  });
});
