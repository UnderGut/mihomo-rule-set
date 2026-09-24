#!/usr/bin/env bash
# Gate before publishing rules/*.mrs (run after build.sh, before commit).
# For every rules/*.mrs that differs from HEAD (or is new):
#   - it must decode with `mihomo convert-ruleset <domain|ipcidr> mrs`;
#   - its behavior must match the committed version (or, for a new file, the
#     name: *_ip.mrs, *-v4.mrs, *-v6.mrs, geoip-*.mrs -> ipcidr, else domain),
#     because clients declare `behavior:` per URL and reject a mismatch;
#   - it must hold >= MIN_ENTRIES entries; a domain set must contain only
#     domain-like lines (mihomo compiles an HTML error page with exit 0);
#     a *-v4.mrs set must not contain IPv6 prefixes;
#   - it must not shrink below MIN_RATIO % of the committed version.
# A failing file is restored from HEAD (the previous version stays published)
# and listed in the step output `held`. A table goes to $GITHUB_STEP_SUMMARY.
set -euo pipefail

MIN_RATIO="${MIN_RATIO:-80}"
MIN_ENTRIES="${MIN_ENTRIES:-1}"
DOMAIN_RE='^(\+\.|\*\.)?[a-z0-9_-]+(\.[a-z0-9_*-]+)+$'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
SUMMARY="${GITHUB_STEP_SUMMARY:-$tmp/summary.md}"

# inspect <file.mrs> <published name> -> "<behavior> <count> <bad>", rc=1 if undecodable
inspect() {
    local f="$1" name="$2" b n bad
    for b in domain ipcidr; do
        if mihomo convert-ruleset "$b" mrs "$f" "$tmp/list.txt" >/dev/null 2>&1; then
            n=$(grep -c . "$tmp/list.txt" || true)
            bad=0
            if [[ "$b" == domain ]]; then
                bad=$(grep -cvE "$DOMAIN_RE" "$tmp/list.txt" || true)
            elif [[ "$name" == *-v4.mrs ]]; then
                bad=$(grep -c ':' "$tmp/list.txt" || true)
            fi
            echo "$b ${n:-0} ${bad:-0}"
            return 0
        fi
    done
    return 1
}

# behavior expected for a file that has no committed version yet
expected_behavior() {
    case "$1" in
        *_ip.mrs | *-v4.mrs | *-v6.mrs | rules/geoip-*.mrs) echo ipcidr ;;
        *) echo domain ;;
    esac
}

held=()
{
    echo "### rules/*.mrs"
    echo "| file | type | before | after | result |"
    echo "|---|---|---:|---:|---|"
} >> "$SUMMARY"

for f in rules/*.mrs; do
    [[ -e "$f" ]] || continue
    prev="-"
    want="$(expected_behavior "$f")"
    if git cat-file -e "HEAD:$f" 2>/dev/null; then
        git show "HEAD:$f" > "$tmp/prev.mrs"
        if cmp -s "$f" "$tmp/prev.mrs"; then
            read -r b n _ < <(inspect "$f" "$f" || echo "? ? ?")
            echo "| \`$f\` | $b | $n | $n | unchanged |" >> "$SUMMARY"
            continue
        fi
        if prev_info=$(inspect "$tmp/prev.mrs" "$f"); then
            read -r want prev _ <<< "$prev_info"
        fi
    fi
    reason="" b="?" n=0 bad=0
    if ! info=$(inspect "$f" "$f"); then
        reason="does not decode"
    else
        read -r b n bad <<< "$info"
        if [[ "$b" != "$want" ]]; then
            reason="behavior $b, expected $want"
        elif (( n < MIN_ENTRIES )); then
            reason="only $n entries"
        elif (( bad > 0 )); then
            reason="$bad invalid line(s)"
        elif [[ "$prev" =~ ^[0-9]+$ ]] && (( prev > 0 && n * 100 < prev * MIN_RATIO )); then
            reason="shrank $prev -> $n (< ${MIN_RATIO}%)"
        fi
    fi
    if [[ -n "$reason" ]]; then
        echo "::error file=$f::$reason, previous version kept"
        if git cat-file -e "HEAD:$f" 2>/dev/null; then
            git checkout HEAD -- "$f"
        else
            rm -f -- "$f"
        fi
        held+=("$f")
        echo "| \`$f\` | $b | $prev | $n | **held**: $reason |" >> "$SUMMARY"
    else
        echo "| \`$f\` | $b | $prev | $n | updated |" >> "$SUMMARY"
    fi
done

[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || cat "$SUMMARY"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "held=${held[*]:-}" >> "$GITHUB_OUTPUT"
fi
exit 0
