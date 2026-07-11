#!/bin/sh
# Download Grafana dashboards from each exporter's authoritative GitHub repo into
# $OUT/<exporter>/, one flat folder per exporter. Reads $MANIFEST. Warns and
# continues on per-item failure; exits non-zero only if NOTHING was fetched.
#
# Dir paths (trailing "/") are matched RECURSIVELY via the git trees API, so nested
# dashboard subdirectories (e.g. pstore block/file/...) are included. Destination
# filenames are flattened (repo path under "grafana/", "/" -> "__") so files from
# different subdirectories never collide (e.g. pflex gen1 vs gen2 share basenames).
set -u

MANIFEST="${MANIFEST:-/manifest/dashboards.manifest.txt}"
OUT="${OUT:-/dashboards}"
API="https://api.github.com"
RAW="https://raw.githubusercontent.com"
GCOM="https://grafana.com/api/dashboards"
GLOBAL_REF="${DASHBOARD_REF:-default}"

gh_get() { # url -> body on stdout
  curl -fsSL -H "Accept: application/vnd.github+json" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "$1"
}

resolve_ref() { # repo ref -> concrete ref
  _repo="$1"; _ref="$2"
  if [ "$_ref" = "default" ] || [ -z "$_ref" ] || [ "$_ref" = "-" ]; then
    _db=$(gh_get "$API/repos/$_repo" | jq -r '.default_branch // empty' 2>/dev/null)
    [ -n "$_db" ] && echo "$_db" || echo "main"
  else
    echo "$_ref"
  fi
}

list_dir() { # repo ref prefix/ -> repo-relative .json paths at or below prefix (recursive)
  _repo="$1"; _ref="$2"; _prefix="$3"
  gh_get "$API/repos/$_repo/git/trees/$_ref?recursive=1" \
    | jq -r --arg p "$_prefix" '.tree[]
        | select(.type=="blob") | .path
        | select(startswith($p)) | select(endswith(".json"))' 2>/dev/null
}

flatname() { # repo-path -> filename: strip leading grafana/, replace "/" with "__"
  printf '%s' "${1#grafana/}" | sed 's#/#__#g'
}

fetch_gcom() { # id destfile -> 0 on success, writes normalised dashboard JSON
  _id="$1"; _out="$2"
  _rev=$(curl -fsSL "$GCOM/$_id" | jq -r '.revision // empty' 2>/dev/null)
  [ -n "$_rev" ] || return 1
  _raw=$(curl -fsSL "$GCOM/$_id/revisions/$_rev/download") || return 1
  [ -n "$_raw" ] || return 1
  _dsvar=$(printf '%s' "$_raw" \
    | jq -r '(.__inputs // [])[] | select(.pluginId=="prometheus") | .name' 2>/dev/null \
    | head -n1)
  [ -n "$_dsvar" ] || _dsvar="DS_PROMETHEUS"
  printf '%s' "$_raw" \
    | jq 'del(.__inputs, .__requires)' \
    | sed "s/\${$_dsvar}/prometheus/g" > "$_out" 2>/dev/null || return 1
  [ -s "$_out" ] || return 1
  return 0
}

total=0; ok=0
rm -rf "${OUT:?}/"* 2>/dev/null || true

while read -r name repo ref paths || [ -n "${name:-}" ]; do
  case "$name" in ""|\#*) continue ;; esac
  [ "$GLOBAL_REF" != "default" ] && ref="$GLOBAL_REF"
  rref=$(resolve_ref "$repo" "$ref")
  dest="$OUT/$name"; mkdir -p "$dest"
  for path in $paths; do
    case "$path" in
      gcom:*)
        total=$((total + 1))
        _gid=${path#gcom:}
        if fetch_gcom "$_gid" "$dest/$_gid.json"; then
          ok=$((ok + 1)); echo "ok   $name  grafana.com/$_gid"
        else
          echo "WARN failed: $name  grafana.com/$_gid" >&2
        fi
        continue ;;
      */) files=$(list_dir "$repo" "$rref" "$path") ;;
      *)  files="$path" ;;
    esac
    for f in $files; do
      [ -z "$f" ] && continue
      total=$((total + 1))
      if curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
           "$RAW/$repo/$rref/$f" -o "$dest/$(flatname "$f")"; then
        ok=$((ok + 1)); echo "ok   $name  $repo@$rref  $f"
      else
        echo "WARN failed: $name  $repo@$rref  $f" >&2
      fi
    done
  done
done < "$MANIFEST"

echo "fetched $ok/$total dashboards"
[ "$ok" -gt 0 ] || { echo "ERROR: no dashboards fetched" >&2; exit 1; }
