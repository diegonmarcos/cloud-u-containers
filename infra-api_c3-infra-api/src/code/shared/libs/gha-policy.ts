// Input/size policy for the GitHub Actions artifact + single-job re-run tools.
// Pure functions so test-gha-policy.mjs exercises exactly what the tools use.

export const ARTIFACT_MAX_BYTES = 4 * 1024 * 1024;        // refuse artifacts larger than this (zip size)
export const ARTIFACT_INLINE_MAX_BYTES = 512 * 1024;      // total bytes returned inline
export const ARTIFACT_FILE_MAX_BYTES = 256 * 1024;        // per-file inline cap

/** owner/repo — GitHub's allowed charset only. */
export function validRepo(repo: string): boolean {
  return /^[A-Za-z0-9-]{1,39}\/[A-Za-z0-9._-]{1,100}$/.test(repo) && !repo.includes("..");
}

/** Run / job / artifact database ids are positive integers. */
export function validId(id: string): boolean {
  return /^[1-9][0-9]{0,19}$/.test(id);
}

/** Artifact names: no path separators, no control chars, no leading dash (gh flag injection). */
export function validArtifactName(name: string): boolean {
  return name.length > 0 && name.length <= 200 && !/[\/\\\x00-\x1f]/.test(name) && !name.startsWith("-") && name !== "." && name !== "..";
}

/** Path of a file extracted from an artifact, made relative and checked against escape. */
export function safeRelPath(p: string): string | null {
  if (!p || p.startsWith("/") || /[\x00]/.test(p)) return null;
  const parts = p.split("/").filter((s) => s && s !== ".");
  if (parts.some((s) => s === "..")) return null;
  return parts.join("/") || null;
}

export interface ArtifactFile { path: string; size: number }
/** Choose which files fit inline: in order, per-file and total caps. */
export function planInline(files: ArtifactFile[], total = ARTIFACT_INLINE_MAX_BYTES, perFile = ARTIFACT_FILE_MAX_BYTES): { inline: string[]; skipped: string[] } {
  const inline: string[] = []; const skipped: string[] = [];
  let used = 0;
  for (const f of files) {
    if (f.size <= perFile && used + f.size <= total) { inline.push(f.path); used += f.size; }
    else skipped.push(f.path);
  }
  return { inline, skipped };
}

/** A job can be re-run only once its run has finished. */
export function rerunnable(runStatus: string | undefined): boolean {
  return runStatus === "completed";
}
