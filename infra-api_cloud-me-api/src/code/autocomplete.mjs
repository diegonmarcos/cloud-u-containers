// autocomplete.mjs — the Autocomplete document Cloud Account syncs into Cloud Keyboard (#1103).
//
// The owner's personal rows (IDs, addresses, URLs, secrets) live in ONE JSON file of a declared PRIVATE repo
// (runtime.autocomplete.{repo,path}). This route is the one deliberate exception to the "secret-looking files
// are never served" gate: the file is secrets by nature, so it is served only here, only to an authenticated
// caller, only in the fixed shape below, never through /me/config or /me/repos/:repo/file.
//
// Pure: no I/O. The wire shape is what libs:autofill AutocompleteContract parses on the phone:
//   {"v":1,"ids":[{"label","value"}],"addresses":[...],"urls":[...],"secrets":[...]}

export const PAGES = ['ids', 'addresses', 'urls', 'secrets'];
export const MAX_PER_PAGE = 500;
const MAX_FIELD = 4096;

/** The served document for a repo file's text: only the four pages, only string label/value, blanks dropped, capped. */
export function normalize(text) {
  let src;
  try { src = JSON.parse(text); } catch { return null; }
  if (src === null || typeof src !== 'object' || Array.isArray(src)) return null;
  const out = { v: 1 };
  for (const page of PAGES) {
    const rows = Array.isArray(src[page]) ? src[page] : [];
    out[page] = rows.slice(0, MAX_PER_PAGE)
      .filter((r) => r && typeof r === 'object' && typeof r.value === 'string' && r.value.trim() !== '')
      .map((r) => ({
        label: typeof r.label === 'string' ? r.label.trim().slice(0, 200) : '',
        value: r.value.slice(0, MAX_FIELD),
      }));
  }
  return out;
}

/** No file yet is a legitimate state (nothing entered): the same shape, empty. */
export const empty = () => Object.fromEntries([['v', 1], ...PAGES.map((p) => [p, []])]);
