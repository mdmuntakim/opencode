#!/usr/bin/env bash
# ============================================================================
# agent-checkpoint.sh -- keep the agent's work across runs
# ----------------------------------------------------------------------------
# A free-tier model can run for an hour and then hit its usage limit, and the
# runner throws the whole workspace away.  This script snapshots the
# directories the agent works in and restores the newest snapshot before the
# next run, so a failed attempt continues where it stopped instead of starting
# over.
#
#   agent-checkpoint.sh save      tar the work directories into $CHECKPOINT_FILE
#   agent-checkpoint.sh restore   download the newest artifact and unpack it
#
# Environment:
#   GH_REPO / GITHUB_REPOSITORY   repository holding the artifacts
#   ISSUE_NUMBER                  issue the checkpoint belongs to (0 = dispatch)
#   CHECKPOINT_FILE               tarball path (default $RUNNER_TEMP/...)
#   GH_TOKEN                      token with actions:read (restore) and the
#                                 default token (save needs nothing)
# ============================================================================
set -uo pipefail

repo="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
issue="${ISSUE_NUMBER:-0}"
[[ "$issue" =~ ^[0-9]+$ ]] || issue=0
name="agent-checkpoint-${issue}"
checkpoint_file="${CHECKPOINT_FILE:-${RUNNER_TEMP:-/tmp}/opencode-checkpoint.tgz}"

# Everything the agent is known to work in.  The repository checkout itself is
# deliberately not included: `opencode-triage` restores it after every run, and
# project source belongs in the project repository.
work_dirs=("/tmp/opencode" "/tmp/scratchpad" "${OPENCODE_WORK:-}")

save() {
  local dirs=() dir
  for dir in "${work_dirs[@]}"; do
    [ -n "$dir" ] && [ -d "$dir" ] && dirs+=("$dir")
  done
  if [ "${#dirs[@]}" -eq 0 ]; then
    echo "nothing to checkpoint"
    return 0
  fi
  # Absolute paths on purpose: `-P` keeps them, so the archive unpacks over the
  # original locations without needing to change into / first.
  tar -czf "$checkpoint_file" -P "${dirs[@]}" 2>/dev/null
  if [ -f "$checkpoint_file" ]; then
    echo "checkpoint written: $checkpoint_file ($(du -h "$checkpoint_file" | cut -f1))"
  else
    echo "no checkpoint could be written"
  fi
}

restore() {
  local id url tmp
  if [ -z "$repo" ]; then
    echo "no repository, skipping restore"
    return 0
  fi
  id="$(gh api "repos/${repo}/actions/artifacts?per_page=100&name=${name}" \
        --jq '[.artifacts[] | select(.expired == false)] | sort_by(.created_at) | last | .id // empty' 2>/dev/null)"
  if [ -z "$id" ]; then
    echo "no checkpoint to restore for ${name}"
    return 0
  fi
  url="$(gh api "repos/${repo}/actions/artifacts/${id}" --jq .archive_download_url 2>/dev/null)"
  if [ -z "$url" ]; then
    echo "checkpoint ${id} has no download url"
    return 0
  fi
  tmp="$(mktemp -d)"
  if ! curl -fsSL -H "Authorization: token ${GH_TOKEN:-}" "$url" -o "$tmp/artifact.zip"; then
    echo "could not download checkpoint ${id}"
    rm -rf "$tmp"
    return 0
  fi
  if ! unzip -oq "$tmp/artifact.zip" -d "$tmp/out" 2>/dev/null; then
    echo "checkpoint ${id} is not a readable archive"
    rm -rf "$tmp"
    return 0
  fi
  local archive
  archive="$(find "$tmp/out" -name '*.tgz' -type f | head -n 1)"
  if [ -z "$archive" ]; then
    echo "checkpoint ${id} contains no tarball"
    rm -rf "$tmp"
    return 0
  fi
  tar -xzf "$archive" -P && echo "checkpoint ${id} restored into place"
  rm -rf "$tmp"
}

case "${1:-}" in
save) save ;;
restore) restore ;;
*)
  echo "usage: $0 save|restore" >&2
  exit 2
  ;;
esac
