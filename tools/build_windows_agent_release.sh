#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-0.1.0}"
base_ref="${2:-origin/stable}"
source_version="${3:-stable}"
channel="${RELEASE_CHANNEL:-stable}"
out_dir="${OUT_DIR:-$repo_root/dist/releases}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/gse-windows-agent-release.XXXXXX")"
stage="$work_dir/payload"
patch_stage="$work_dir/patch"
source_file_list="$work_dir/source-files.list"
release_file_list="$work_dir/release-files.list"
changed_file_list="$work_dir/changed-files.list"
deleted_file_list="$work_dir/deleted-files.list"
untracked_file_list="$work_dir/untracked-files.list"

cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "release version must be semantic, for example 0.1.0" ;;
esac

command -v git >/dev/null 2>&1 || fail "git is required to enumerate release source files"
command -v zip >/dev/null 2>&1 || fail "zip is required to build release archives"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
command -v tar >/dev/null 2>&1 || fail "tar is required to stage release files efficiently"

mkdir -p "$stage" "$patch_stage/files" "$out_dir"

is_excluded() {
    local path="$1"
    case "$path" in
        .git|.git/*|.devplus|.devplus/*|dist|dist/*) return 0 ;;
        logs|logs/*|backups|backups/*|home|home/*) return 0 ;;
        AgentScripts/Cfg/Config.pm|AgentScripts/Cfg/Preferences.pm|AgentScripts/Cfg/bash_prefs.cfg) return 0 ;;
        AgentScripts/gsp_agent.log|AgentScripts/*.pid|AgentScripts/gsp_agent_update_request.json|AgentScripts/gsp_agent_update_state.json|AgentScripts/gsp_agent_update.log) return 0 ;;
        AgentScripts/screenlogs|AgentScripts/screenlogs/*|AgentScripts/startups|AgentScripts/startups/*|AgentScripts/runtime_status|AgentScripts/runtime_status/*) return 0 ;;
        AgentScripts/tmp|AgentScripts/tmp/*|AgentScripts/shared|AgentScripts/shared/*) return 0 ;;
        AgentScripts/steamcmd/linux32|AgentScripts/steamcmd/linux32/*|AgentScripts/steamcmd/steamapps|AgentScripts/steamcmd/steamapps/*) return 0 ;;
        var/run/*.pid|*.tmp|*.swp|*.swo|*~|Thumbs.db|.DS_Store) return 0 ;;
        .env|.env.*|*.pem|*.pfx|*.p12|*.key|id_rsa|id_dsa|id_ecdsa|id_ed25519|*/id_rsa|*/id_dsa|*/id_ecdsa|*/id_ed25519) return 0 ;;
    esac
    return 1
}

json_escape() {
    sed 's/\\/\\\\/g; s/"/\\"/g'
}

while IFS= read -r -d '' path; do
    [ -f "$repo_root/$path" ] || continue
    if is_excluded "$path"; then
        continue
    fi
    case "$path" in
        AgentScripts/release_version.json|AgentScripts/release_manifest.json) continue ;;
    esac
    printf '%s\n' "$path"
done < <(cd "$repo_root" && git ls-files -z --cached --others --exclude-standard) | LC_ALL=C sort > "$source_file_list"

cp "$source_file_list" "$release_file_list"
printf '%s\n' "AgentScripts/release_manifest.json" "AgentScripts/release_version.json" >> "$release_file_list"
LC_ALL=C sort -u "$release_file_list" -o "$release_file_list"

if [ -s "$source_file_list" ]; then
    (cd "$repo_root" && tar -cf - -T "$source_file_list") | (cd "$stage" && tar -xf -)
fi
mkdir -p "$stage/AgentScripts"

cat > "$stage/AgentScripts/release_version.json" <<EOF
{
  "component": "Agent-Windows",
  "release_version": "$version",
  "release_channel": "$channel",
  "manifest_path": "AgentScripts/release_manifest.json"
}
EOF

write_manifest() {
    local root="$1"
    local output="$2"
    local include_self="${3:-0}"
    local input_list="$work_dir/manifest-input-$(basename "$output").list"
    local hash_file="$work_dir/manifest-hashes-$(basename "$output").txt"
    if [ "$include_self" = "1" ]; then
        cp "$release_file_list" "$input_list"
    else
        grep -vx 'AgentScripts/release_manifest.json' "$release_file_list" > "$input_list"
    fi
    (cd "$root" && awk '{ printf "%s%c", $0, 0 }' "$input_list" | xargs -0 sha256sum) > "$hash_file"
    {
        printf '{\n'
        printf '  "component": "Agent-Windows",\n'
        printf '  "release_version": "%s",\n' "$version"
        printf '  "release_channel": "%s",\n' "$channel"
        printf '  "manifest_schema": 1,\n'
        printf '  "generated_at": "2000-01-01T00:00:00Z",\n'
        printf '  "files": [\n'
        local first=1
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            local sha="${line%% *}"
            local rel="${line#*  }"
            local escaped
            escaped="$(printf '%s' "$rel" | json_escape)"
            if [ "$first" = "1" ]; then
                first=0
            else
                printf ',\n'
            fi
            printf '    {"path":"%s","sha256":"%s"}' "$escaped" "$sha"
        done < "$hash_file"
        printf '\n  ]\n'
        printf '}\n'
    } > "$output"
}

write_manifest "$stage" "$stage/AgentScripts/release_manifest.json" 0
find "$stage" -exec touch -h -t 200001010000.00 {} +

zip_file="$out_dir/gse-windows-agent-$version.zip"
checksum_file="$zip_file.sha256"
metadata_file="$out_dir/gse-windows-agent-$version.json"
manifest_file="$out_dir/gse-windows-agent-$version.manifest.json"
patch_file="$out_dir/gse-windows-agent-$version-from-stable.patch.zip"
patch_checksum_file="$patch_file.sha256"
patch_metadata_file="$patch_stage/patch_metadata.json"

rm -f "$zip_file" "$checksum_file" "$metadata_file" "$manifest_file" "$patch_file" "$patch_checksum_file"
(cd "$stage" && zip -X -0 -q "$zip_file" -@ < "$release_file_list")
zip_sha="$(sha256sum "$zip_file" | awk '{print $1}')"
printf '%s  %s\n' "$zip_sha" "$(basename "$zip_file")" > "$checksum_file"

write_manifest "$stage" "$manifest_file" 1
manifest_sha="$(sha256sum "$manifest_file" | awk '{print $1}')"

deletions_file="$patch_stage/deletions.txt"
: > "$deletions_file"
if git -C "$repo_root" rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    git -C "$repo_root" diff --name-only --diff-filter=ACMRT "$base_ref" -- > "$changed_file_list"
    git -C "$repo_root" diff --name-only --diff-filter=D "$base_ref" -- > "$deleted_file_list"
    git -C "$repo_root" ls-files --others --exclude-standard > "$untracked_file_list"
    cat "$changed_file_list" "$untracked_file_list" | LC_ALL=C sort -u |
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if is_excluded "$path"; then
            continue
        fi
        if [ -f "$stage/$path" ]; then
            mkdir -p "$patch_stage/files/$(dirname "$path")"
            cp -p "$stage/$path" "$patch_stage/files/$path"
        fi
    done
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        is_excluded "$path" && continue
        printf '%s\n' "$path" >> "$deletions_file"
    done < "$deleted_file_list"
else
    echo "WARN: base ref $base_ref not found; patch archive will contain only deletions.txt" >&2
fi

for identity_file in AgentScripts/release_version.json AgentScripts/release_manifest.json; do
    if [ -f "$stage/$identity_file" ]; then
        mkdir -p "$patch_stage/files/$(dirname "$identity_file")"
        cp -p "$stage/$identity_file" "$patch_stage/files/$identity_file"
    fi
done

cat > "$patch_metadata_file" <<EOF
{
  "component": "Agent-Windows",
  "patch_schema": 1,
  "source_version": "$source_version",
  "target_version": "$version",
  "target_manifest": "AgentScripts/release_manifest.json",
  "deletions": "deletions.txt",
  "files_root": "files",
  "validation": ["sha256", "perl -c AgentScripts/gse_agent.pl", "bash -n AgentScripts/agent_launch.sh", "release_manifest"],
  "rollback": "restore backed-up touched files and remove newly-created files on validation failure",
  "preserved_paths": [
    "AgentScripts/Cfg",
    "AgentScripts/ServerFiles",
    "AgentScripts/Schedule",
    "AgentScripts/screenlogs",
    "AgentScripts/startups",
    "AgentScripts/runtime_status",
    "AgentScripts/events",
    "AgentScripts/tmp",
    "AgentScripts/shared",
    "AgentScripts/steamcmd",
    "AgentScripts/logs",
    "home",
    "logs",
    "backups"
  ]
}
EOF

find "$patch_stage" -exec touch -h -t 200001010000.00 {} +
(cd "$patch_stage" && LC_ALL=C find . -type f -print | sort | zip -X -0 -q "$patch_file" -@)
patch_sha="$(sha256sum "$patch_file" | awk '{print $1}')"
printf '%s  %s\n' "$patch_sha" "$(basename "$patch_file")" > "$patch_checksum_file"

cat > "$metadata_file" <<EOF
{
  "component": "Agent-Windows",
  "version": "$version",
  "channel": "$channel",
  "zip_url": "$(basename "$zip_file")",
  "sha256": "$zip_sha",
  "checksum_url": "$(basename "$checksum_file")",
  "manifest_url": "$(basename "$manifest_file")",
  "manifest_sha256": "$manifest_sha",
  "patch_url": "$(basename "$patch_file")",
  "patch_sha256": "$patch_sha",
  "source_version": "$source_version",
  "target_version": "$version",
  "base_ref": "$base_ref"
}
EOF

cp "$metadata_file" "$out_dir/gse-windows-agent-latest.json"
cp "$checksum_file" "$out_dir/gse-windows-agent-latest.zip.sha256"

echo "Built $zip_file"
echo "Built $metadata_file"
echo "Built $manifest_file"
echo "Built $patch_file"
