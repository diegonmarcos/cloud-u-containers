#!/usr/bin/env bash
# Guard (#1064 follow-up): render-dist runs on the PUBLIC checkout, where the sops files are gone
# (they live in the private vault and only Ship overlays them). A render there strips every secret
# mount from the compose, because the engine gates the mounts on the file existing. This guard
# refuses a render that REMOVES secret mounts from the committed <service>/dist.
#
# Usage: render-dist-secret-mounts-guard.sh <repo_root> <service>   (run after the render, before commit)
# Compares each changed file under <service>/dist with HEAD: the count of secret-mount markers
# (/run/secrets, .secrets) must not drop. Exit 1 naming the path; never prints file content.
set -u
ROOT="${1:?repo root}"; SVC="${2:?service}"
PAT='/run/secrets|\.secrets'
bad=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  old=$(git -C "$ROOT" show "HEAD:$f" 2>/dev/null | grep -Eo "$PAT" | wc -l)
  new=0; [ -f "$ROOT/$f" ] && new=$(grep -Eo "$PAT" "$ROOT/$f" | wc -l)
  if [ "$new" -lt "$old" ]; then
    echo "SECRET-MOUNTS-STRIPPED: $f ($old -> $new markers)"; bad=$((bad+1))
  fi
done < <(git -C "$ROOT" status --porcelain --untracked-files=all -- "$SVC/dist" | cut -c4- | tr -d '"'; git -C "$ROOT" ls-files -d -- "$SVC/dist")
if [ "$bad" -gt 0 ]; then
  echo "render-dist-secret-mounts-guard: FAIL, the render dropped secret mounts in $bad file(s); the public checkout has no sops files. Render with the vault overlaid (Ship) or hand-edit the src-hash only."
  exit 1
fi
echo "render-dist-secret-mounts-guard: ok"
