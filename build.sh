#!/usr/bin/env bash
# Build mihomo rule-sets into rules/ (see README.md).
#   sources.list : "category,url"                one upstream domain list -> rules/<name>_domain.mrs
#   merge.list   : "group,type,url[,exclude]"    N upstreams -> rules/<group>.mrs      (behavior domain)
#   ip.list      : "group,family,url[,min]"      IP lists    -> rules/<group>.mrs      (behavior ipcidr)
# Best-effort: a failing source or group keeps its previous .mrs and emits a
# warning (printed, annotated on GitHub Actions and appended to
# $BUILD_WARNINGS_FILE when set). The script exits non-zero only when the
# environment itself is broken (no mihomo / curl).
set -euo pipefail

# --- КОНФИГУРАЦИЯ ---
OUTPUT_DIR="rules"          # один каталог для рукописных .yaml И собранных .mrs
SOURCES_FILE="sources.list"
MERGE_FILE="merge.list"
IP_FILE="ip.list"
TEMP_DIR="temp_work"
BUILD_WARNINGS_FILE="${BUILD_WARNINGS_FILE:-}"

SOURCE_MIN_RATIO="${SOURCE_MIN_RATIO:-80}"   # % of the previous entry count (sources.list and merge groups)
SOURCE_MIN_COUNT="${SOURCE_MIN_COUNT:-10}"   # absolute floor for a sources.list output
MERGE_MIN_RATIO="${MERGE_MIN_RATIO:-80}"     # % of previous count, merge groups (raw input vs previous build)
DOMAIN_RE='^(\+\.)?[a-z0-9_-]+(\.[a-z0-9_-]+)+$'

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

# Log a warning; on GitHub Actions also annotate the run; collect for the final report.
warn() {
    echo "  ⚠ $*"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::warning title=build.sh::$*"; fi
    if [[ -n "$BUILD_WARNINGS_FILE" ]]; then echo "$*" >> "$BUILD_WARNINGS_FILE"; fi
    return 0
}

# Strip leading/trailing whitespace (and a CR from CRLF files); no xargs: quotes must not break parsing.
trim() {
    local s="${1%$'\r'}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# fetch <url> <file>: fails on HTTP errors (-f), retries, never hangs.
fetch() {
    curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors --connect-timeout 20 --max-time 120 -o "$2" "$1"
}

# mrs_count <domain|ipcidr> <file.mrs> -> entries after decoding (0 = missing/unreadable)
mrs_count() {
    local out="$TEMP_DIR/mrs_count.txt"
    [[ -s "$2" ]] || { echo 0; return 0; }
    if mihomo convert-ruleset "$1" mrs "$2" "$out" >/dev/null 2>&1; then
        grep -c . "$out" || true
    else
        echo 0
    fi
}

# publish_mrs <domain|ipcidr> <sorted unique list> <dest.mrs> <min_count>
# Compiles into TEMP_DIR (mihomo truncates its output before converting, so a
# failed run must never touch rules/), rejects any mihomo warning (mihomo only
# WARNS on invalid lines and drops them), compares decoded counts with the
# previous build, then atomically replaces the destination.
publish_mrs() {
    local behavior="$1" list="$2" dest="$3" min="$4" tmp count prev built
    tmp="$TEMP_DIR/out_$(basename "$dest")"
    count=$(grep -c . "$list" || true)
    if (( count < min )); then warn "$dest: only $count entries (< $min), kept previous"; return 1; fi
    if [[ "$behavior" == domain ]]; then
        { echo "payload:"; sed "s/.*/  - '&'/" "$list"; } > "$tmp.yaml"
        mihomo convert-ruleset domain yaml "$tmp.yaml" "$tmp" > "$tmp.log" 2>&1 \
            || { warn "$dest: compile failed: $(tail -1 "$tmp.log")"; return 1; }
    else
        mihomo convert-ruleset ipcidr text "$list" "$tmp" > "$tmp.log" 2>&1 \
            || { warn "$dest: compile failed: $(tail -1 "$tmp.log")"; return 1; }
    fi
    if grep -q 'level=warning' "$tmp.log"; then
        warn "$dest: mihomo rejected entries: $(grep -m3 -o 'msg="[^"]*"' "$tmp.log" | tr '\n' ' ')"
        return 1
    fi
    # compare equally normalized sets: domain folds 'x' into '+.x', ipcidr merges
    # adjacent prefixes -> count the new AND the previous file after decoding
    built=$(mrs_count "$behavior" "$tmp")
    prev=$(mrs_count "$behavior" "$dest")
    if (( built == 0 )); then warn "$dest: compiled file is unreadable, kept previous"; return 1; fi
    if (( prev > 0 && built * 100 < prev * SOURCE_MIN_RATIO )); then
        warn "$dest: shrank $prev -> $built (< ${SOURCE_MIN_RATIO}%), kept previous"
        return 1
    fi
    mkdir -p "$(dirname "$dest")"
    mv -f "$tmp" "$dest"
    echo "  ✅ $dest: $built entries (prev $prev)"
}

# --- ПОДГОТОВКА ---
# ВНИМАНИЕ: НЕ wipe'аем OUTPUT_DIR — там лежат рукописные .yaml (исходные правила).
# build только перезаписывает свои .mrs, и только после всех проверок.
echo "--- Preparing ---"
command -v mihomo > /dev/null || { echo "❌ mihomo not found on PATH"; exit 1; }
command -v curl > /dev/null || { echo "❌ curl not found on PATH"; exit 1; }
mihomo -v | sed -n 1p   # sed reads everything: no SIGPIPE under pipefail
mkdir -p "$OUTPUT_DIR"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

# --- SOURCES (one upstream domain list -> rules/<name>_domain.mrs) ---
# Plain domain lists only (Clash domainset: "example.com" / "+.example.com").
# Output name = basename of the URL without extension; the first column is informational.
if [[ -f "$SOURCES_FILE" ]]; then
    echo "--- Processing sources ---"
    while IFS= read -r line || [[ -n "$line" ]]; do   # last line may lack a newline
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        url="$line"
        [[ "$line" == *,* ]] && url="$(trim "${line#*,}")"
        source_filename="$(basename "${url%%\?*}")"
        rule_name="${source_filename%.*}"
        ext="${source_filename##*.}"
        echo "Processing: $rule_name"
        if [[ "$ext" != txt && "$ext" != list ]]; then
            warn "$rule_name: unsupported source type .$ext ($url), skipped"
            echo "-------------------------------------"; continue
        fi
        src="$TEMP_DIR/src_$source_filename"
        if ! fetch "$url" "$src"; then
            warn "$rule_name: fetch failed: $url, kept previous"
            echo "-------------------------------------"; continue
        fi
        list="$TEMP_DIR/${rule_name}_domain.list"
        awk 'NF && $0 !~ /^[[:space:]]*[#!]/ { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); sub(/\r$/, ""); print tolower($0) }' "$src" \
            | LC_ALL=C sort -u > "$list"
        bad=$(grep -cvE "$DOMAIN_RE" "$list" || true)
        if (( bad > 0 )); then
            warn "$rule_name: $bad non-domain line(s) (HTML/error page?), kept previous; e.g. $(grep -m3 -vE "$DOMAIN_RE" "$list" | tr '\n' ' ')"
            echo "-------------------------------------"; continue
        fi
        publish_mrs domain "$list" "$OUTPUT_DIR/${rule_name}_domain.mrs" "$SOURCE_MIN_COUNT" || true
        echo "-------------------------------------"
    done < "$SOURCES_FILE"
fi

# --- MERGE GROUPS (consolidate N sources -> one .mrs) ---
# Config: merge.list, lines "group,type,url[,exclude_regex]"
#   type = list  (plain domain list, e.g. MetaCubeX *.list)
#        | yaml  (classical *.yaml, e.g. blackmatrix7: DOMAIN/DOMAIN-SUFFIX kept)
#        | local* (file inside this repo; locallist = plain list, localyaml = classical yaml)
#   exclude_regex = optional ERE; matching domains are dropped (e.g. typosquats)
# Output: rules/<group>.mrs. Best-effort: never breaks the build.
# Safety: a group is rebuilt only if
#   - EVERY source was fetched and parsed (no HTML/error pages, no empty sources),
#   - the new domain count is not below MERGE_MIN_RATIO of the previous build,
#   - no entry is a TLD or a public suffix (Public Suffix List, see below),
#   - mihomo compiled it without warnings and the result reads back (publish_mrs).
# Otherwise the previous rules/<group>.mrs is kept untouched.
# Public Suffix List guard. An entry equal to a TLD or a public suffix
# ("+.com", "+.co.uk", "+.akamaized.net", "+.github.io") would capture a whole
# namespace of unrelated sites.
#   - TLD-level and ICANN-section suffixes are rejected in every group;
#   - PRIVATE-section suffixes (hosting/CDN platforms) are rejected only in
#     PSL_STRICT_GROUPS and reported as a notice elsewhere (e.g. "+.hf.space"
#     in the ai group is intentional).
# If the list cannot be downloaded, no merge group is rebuilt.
PSL_URLS="${PSL_URLS:-https://publicsuffix.org/list/public_suffix_list.dat https://raw.githubusercontent.com/publicsuffix/list/main/public_suffix_list.dat}"
PSL_STRICT_GROUPS="${PSL_STRICT_GROUPS:-tiktok}"
PSL_FILE="$TEMP_DIR/public_suffix_list.dat"
# awk program: 1st file = PSL, 2nd file = sorted group entries.
# Prints "REJECT <entry> <tld|icann|private>" or "NOTICE <entry> private".
# shellcheck disable=SC2016  # awk program, $ is awk syntax
PSL_AWK='
FNR == NR {
    if ($0 ~ /===BEGIN ICANN DOMAINS===/) sec = "icann"
    if ($0 ~ /===BEGIN PRIVATE DOMAINS===/) sec = "private"
    r = $1
    if (r == "" || substr(r, 1, 2) == "//") next
    r = tolower(r)
    if (substr(r, 1, 1) == "!") { exc[substr(r, 2)] = 1; next }
    if (substr(r, 1, 2) == "*.") { wild[substr(r, 3)] = sec; next }
    rule[r] = sec
    next
}
{
    e = $0; d = e; sub(/^\+\./, "", d)
    if (index(d, ".") == 0) { print "REJECT " e " tld"; next }
    if (d in exc) next
    s = ""
    if (d in rule) s = rule[d]
    else { p = d; sub(/^[^.]*\./, "", p); if (p in wild) s = wild[p] }
    if (s == "") next
    if (s == "icann" || strict == 1) print "REJECT " e " " s
    else print "NOTICE " e " " s
}'

if [[ -f "$MERGE_FILE" ]]; then
    echo "--- Processing merge groups ---"
    psl_ok=0
    for psl_url in $PSL_URLS; do
        if fetch "$psl_url" "$PSL_FILE" \
            && grep -q '===BEGIN ICANN DOMAINS===' "$PSL_FILE" \
            && grep -q '===BEGIN PRIVATE DOMAINS===' "$PSL_FILE" \
            && [[ "$(grep -cvE '^[[:space:]]*(//|$)' "$PSL_FILE" || true)" -gt 5000 ]]; then
            psl_ok=1
            echo "  public suffix list: $psl_url"
            break
        fi
    done
    [[ "$psl_ok" -eq 1 ]] || warn "public suffix list unavailable, merge groups are not rebuilt"
    groups=$(grep -vE '^[[:space:]]*(#|$)' "$MERGE_FILE" | cut -d',' -f1 | tr -d ' \t\r' | sort -u || true)
    for grp in $groups; do
        echo "Merging group: $grp"
        combined="$TEMP_DIR/${grp}_combined.txt"; : > "$combined"
        grp_failed=0
        while IFS= read -r mline || [[ -n "$mline" ]]; do   # last line may lack a newline
            mline="${mline%$'\r'}"
            [[ -z "$(trim "$mline")" || "$mline" == \#* ]] && continue
            IFS=',' read -r g mtype murl mexclude <<< "$mline" || true
            g="$(trim "$g")"
            [[ "$g" != "$grp" ]] && continue
            mtype="$(trim "$mtype")"; murl="$(trim "$murl")"
            tmpf="$TEMP_DIR/merge_${grp}_$(basename "$murl")"
            if [[ "$mtype" == local* ]]; then
                cp "$murl" "$tmpf" 2>/dev/null || { warn "$grp: no local file: $murl"; grp_failed=1; continue; }
            else
                fetch "$murl" "$tmpf" || { warn "$grp: fetch failed: $murl"; grp_failed=1; continue; }
            fi
            [[ ! -s "$tmpf" ]] && { warn "$grp: empty source: $murl"; grp_failed=1; continue; }
            extracted="$TEMP_DIR/merge_extract.txt"
            if [[ "$mtype" == *yaml* ]]; then
                awk '
                  { line=$0; sub(/\r$/,"",line); sub(/^[[:space:]]*-?[[:space:]]*/,"",line) }
                  line ~ /^DOMAIN-SUFFIX,/ { split(line,a,","); d=a[2]; gsub(/[[:space:]]/,"",d); if(d!="") print "+." tolower(d); next }
                  line ~ /^DOMAIN,/        { split(line,a,","); d=a[2]; gsub(/[[:space:]]/,"",d); if(d!="") print tolower(d); next }
                ' "$tmpf" > "$extracted" || true
            else
                awk 'NF && $0 !~ /^[[:space:]]*#/ { gsub(/[[:space:]]/,""); if($0!="") print tolower($0) }' "$tmpf" > "$extracted" || true
            fi
            [[ ! -s "$extracted" ]] && { warn "$grp: no domains parsed from $murl"; grp_failed=1; continue; }
            bad=$(grep -cvE "$DOMAIN_RE" "$extracted" || true)
            if [[ "${bad:-0}" -gt 0 ]]; then
                warn "$grp: $bad non-domain line(s) in $murl (HTML/error page?)"; grp_failed=1; continue
            fi
            if [[ -n "$mexclude" ]]; then
                grep -vE "$mexclude" "$extracted" >> "$combined" || true
            else
                cat "$extracted" >> "$combined" || true
            fi
        done < "$MERGE_FILE"
        if [[ "$grp_failed" -ne 0 ]]; then
            warn "$grp: source failure, kept previous $OUTPUT_DIR/${grp}.mrs"
            echo "-------------------------------------"; continue
        fi
        sorted="$TEMP_DIR/${grp}_sorted.txt"
        LC_ALL=C sort -u "$combined" | grep -E '\.' > "$sorted" || true
        count=$(wc -l < "$sorted" | tr -d '[:space:]')
        if [[ "$psl_ok" -ne 1 ]]; then
            warn "$grp: no public suffix list, kept previous $OUTPUT_DIR/${grp}.mrs"
            echo "-------------------------------------"; continue
        fi
        strict=0
        case " $PSL_STRICT_GROUPS " in *" $grp "*) strict=1 ;; esac
        psl_hits="$TEMP_DIR/${grp}_psl.txt"
        awk -v strict="$strict" "$PSL_AWK" "$PSL_FILE" "$sorted" > "$psl_hits" || true
        if grep -q '^REJECT ' "$psl_hits"; then
            warn "$grp: TLD/public-suffix entries, kept previous $OUTPUT_DIR/${grp}.mrs: $(grep '^REJECT ' "$psl_hits" | cut -d' ' -f2- | tr '\n' ';')"
            echo "-------------------------------------"; continue
        fi
        if grep -q '^NOTICE ' "$psl_hits"; then
            echo "  ℹ private public-suffix entries allowed in $grp: $(grep '^NOTICE ' "$psl_hits" | cut -d' ' -f2 | tr '\n' ' ')"
        fi
        prev=0
        if [[ -s "$OUTPUT_DIR/${grp}.mrs" ]]; then
            mihomo convert-ruleset domain mrs "$OUTPUT_DIR/${grp}.mrs" "$TEMP_DIR/${grp}_prev.txt" >/dev/null 2>&1 \
                && prev=$(grep -c . "$TEMP_DIR/${grp}_prev.txt" || true)
        fi
        if [[ "${count:-0}" -eq 0 ]]; then
            warn "$grp produced 0 domains, kept previous $OUTPUT_DIR/${grp}.mrs"
        elif [[ "${prev:-0}" -gt 0 && $((count * 100)) -lt $((prev * MERGE_MIN_RATIO)) ]]; then
            warn "$grp shrank $prev -> $count (< ${MERGE_MIN_RATIO}%), kept previous $OUTPUT_DIR/${grp}.mrs"
        elif ! publish_mrs domain "$sorted" "$OUTPUT_DIR/${grp}.mrs" 1; then
            warn "$grp: kept previous $OUTPUT_DIR/${grp}.mrs"
        fi
        echo "-------------------------------------"
    done
fi

# --- IPCIDR GROUPS (IP lists -> one ipcidr .mrs) ---
# Config: ip.list, lines "group,family,url[,min_entries]"
#   family      = v4: IPv4 CIDRs kept, IPv6 lines dropped (only v4 is implemented)
#   url         = http(s) upstream (curl -f, retries) | local:<path inside this repo>
#   min_entries = optional absolute floor, protects the very first build
# Output: rules/<group>.mrs (behavior ipcidr). Best-effort: never breaks the build.
# A group is rebuilt only if
#   - every source was fetched and EVERY line is a strict CIDR: IPv4 dotted quad
#     0-255 without leading zeros, mask /IP_MIN_MASK../32 without leading zeros,
#     no host bits; or a well-formed IPv6 CIDR (dropped for v4). HTML/error pages,
#     bare IPs and garbage fail the group (mihomo itself only WARNS and drops them);
#   - no entry overlaps special-purpose ranges (IP_BOGONS);
#   - the count is >= min_entries, >= IP_MIN_RATIO % of the previous prefix count,
#     and the address count is within IP_MIN_ADDR_RATIO..IP_MAX_GROWTH % of the
#     previous build (previous = rules/<group>.mrs read back by mihomo);
#   - the compiled .mrs has the zstd magic, mihomo printed no "invalid Ipcidr",
#     and it reads back (convert-ruleset ipcidr mrs); counts above are taken from
#     that read-back (mihomo's canonical, merged set), not from the raw input.
# Otherwise the previous rules/<group>.mrs is kept untouched.
IP_MIN_MASK="${IP_MIN_MASK:-10}"              # upstream minimum is /13 (30 versions, 18.08-23.09.2026)
IP_MIN_ENTRIES="${IP_MIN_ENTRIES:-100}"
IP_MIN_RATIO="${IP_MIN_RATIO:-80}"            # % of previous prefix count
IP_MIN_ADDR_RATIO="${IP_MIN_ADDR_RATIO:-90}"  # % of previous address count
IP_MAX_GROWTH="${IP_MAX_GROWTH:-120}"         # % of previous address count
IP_FORCE_GROUPS="${IP_FORCE_GROUPS:-}"        # one-off: groups rebuilt WITHOUT ratio checks vs previous
# start/prefix of special-purpose IPv4 blocks (RFC 6890 + multicast/reserved);
# 198.18/15 also hosts mihomo's default fake-ip-range.
IP_BOGONS="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3"

# awk (POSIX/mawk-safe: no {n} intervals): stdout = valid IPv4 CIDRs,
# stats file: "v4 N / v6 N / bad N / skipped N", reject file: "<reason> <line>".
# shellcheck disable=SC2016  # awk program, $ is awk syntax
IP_V4_AWK='
function q2n(s,   o, k) {
    if (split(s, o, ".") != 4) return -1
    for (k = 1; k <= 4; k++) {
        if (o[k] !~ /^[0-9]+$/ || length(o[k]) > 3) return -1
        if (length(o[k]) > 1 && substr(o[k], 1, 1) == "0") return -1
        if (o[k] + 0 > 255) return -1
    }
    return ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
}
function rej(why) { bad++; if (bad <= 20) print why " " $0 > rejf }
BEGIN {
    nb = split(bogons, bl, " ")
    for (j = 1; j <= nb; j++) {
        split(bl[j], pp, "/"); bs[j] = q2n(pp[1]); be[j] = bs[j] + 2 ^ (32 - pp[2]) - 1
    }
}
{
    sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
    if ($0 == "" || substr($0, 1, 1) == "#") { skipped++; next }
    if (index($0, ":")) {
        if ($0 ~ /^[0-9A-Fa-f:.]+\/[0-9]+$/) { v6++; next }
        rej("garbage"); next
    }
    if (split($0, p, "/") != 2) { rej("no-mask"); next }
    ip = q2n(p[1])
    if (ip < 0) { rej("bad-address"); next }
    m = p[2]
    if (m !~ /^[0-9]+$/ || length(m) > 2 || (length(m) > 1 && substr(m, 1, 1) == "0") || m + 0 > 32) { rej("bad-mask"); next }
    if (m + 0 < minmask) { rej("too-broad"); next }
    size = 2 ^ (32 - m)
    if (ip % size != 0) { rej("host-bits"); next }
    for (j = 1; j <= nb; j++) if (ip <= be[j] && ip + size - 1 >= bs[j]) { rej("special-range"); next }
    v4++; print
}
END { printf "v4 %d\nv6 %d\nbad %d\nskipped %d\n", v4, v6, bad, skipped > statf }'

# number of IPv4 addresses covered by a CIDR list (IPv6 lines ignored)
ip_addr_sum() { awk -F/ 'NF == 2 && index($1, ":") == 0 { s += 2 ^ (32 - $2) } END { printf "%.0f\n", s + 0 }' "$1"; }
ip_stat() { awk -v k="$1" '$1 == k { print $2 }' "$2"; }

if [[ -f "$IP_FILE" ]]; then
    echo "--- Processing ipcidr groups ---"
    ip_groups=$(grep -vE '^[[:space:]]*(#|$)' "$IP_FILE" | cut -d',' -f1 | tr -d ' \t\r' | sort -u || true)
    for grp in $ip_groups; do
        echo "IP group: $grp"
        combined="$TEMP_DIR/ip_${grp}_combined.txt"; : > "$combined"
        grp_failed=0; floor="$IP_MIN_ENTRIES"
        n_src=0
        while IFS= read -r iline || [[ -n "$iline" ]]; do   # last line may lack a newline
            iline="${iline%$'\r'}"   # tolerate CRLF in ip.list
            [[ -z "${iline//[[:space:]]/}" || "$iline" =~ ^[[:space:]]*# ]] && continue
            # pure bash split, no xargs: a quote in the line must not abort build.sh (set -e)
            IFS=',' read -r g fam iurl imin _ <<< "$iline" || true
            g="${g//[[:space:]]/}"; fam="${fam//[[:space:]]/}"; iurl="${iurl//[[:space:]]/}"; imin="${imin//[[:space:]]/}"
            [[ "$g" != "$grp" ]] && continue
            n_src=$((n_src + 1))
            [[ "$imin" =~ ^[0-9]+$ && "$imin" -gt "$floor" ]] && floor="$imin"
            if [[ "$fam" != "v4" ]]; then warn "$grp: unsupported family '$fam'"; grp_failed=1; continue; fi
            raw="$TEMP_DIR/ip_${grp}_src${n_src}.txt"
            if [[ "$iurl" == local:* ]]; then
                cp "${iurl#local:}" "$raw" 2>/dev/null || { warn "$grp: no local file: ${iurl#local:}"; grp_failed=1; continue; }
            else
                fetch "$iurl" "$raw" || { warn "$grp: fetch failed: $iurl"; grp_failed=1; continue; }
            fi
            [[ -s "$raw" ]] || { warn "$grp: empty source: $iurl"; grp_failed=1; continue; }
            stats="$TEMP_DIR/ip_${grp}_stats.txt"; rejects="$TEMP_DIR/ip_${grp}_rejects.txt"; : > "$rejects"
            awk -v minmask="$IP_MIN_MASK" -v bogons="$IP_BOGONS" -v statf="$stats" -v rejf="$rejects" \
                "$IP_V4_AWK" "$raw" >> "$combined" || { warn "$grp: parser failed on $iurl"; grp_failed=1; continue; }
            nbad=$(ip_stat bad "$stats"); nv4=$(ip_stat v4 "$stats"); nv6=$(ip_stat v6 "$stats")
            echo "  $iurl: v4 ${nv4:-0}, v6 ${nv6:-0} (dropped), rejected ${nbad:-0}"
            if [[ "${nbad:-0}" -gt 0 ]]; then
                warn "$grp: ${nbad} invalid line(s) in $iurl, e.g.: $(head -3 "$rejects" | tr '\n' ';')"
                grp_failed=1; continue
            fi
            [[ "${nv4:-0}" -gt 0 ]] || { warn "$grp: no IPv4 CIDRs in $iurl"; grp_failed=1; continue; }
        done < "$IP_FILE"
        target="$OUTPUT_DIR/${grp}.mrs"
        [[ "$n_src" -gt 0 ]] || { warn "$grp: no source lines parsed from $IP_FILE"; grp_failed=1; }
        if [[ "$grp_failed" -ne 0 ]]; then
            warn "$grp: source failure, kept previous $target"; echo "-------------------------------------"; continue
        fi
        sorted="$TEMP_DIR/ip_${grp}_sorted.txt"
        LC_ALL=C sort -u "$combined" > "$sorted" || true
        naive_addrs=$(ip_addr_sum "$sorted")
        # compile, then read back: the read-back list is mihomo's canonical set
        # (overlaps/adjacent prefixes merged) and is what the guards compare.
        tmp_mrs="$TEMP_DIR/ip_${grp}.mrs"; back="$TEMP_DIR/ip_${grp}_back.txt"; clog="$TEMP_DIR/ip_${grp}_compile.log"
        if ! { mihomo convert-ruleset ipcidr text "$sorted" "$tmp_mrs" > "$clog" 2>&1 \
                && ! grep -q 'invalid Ipcidr' "$clog" \
                && [[ "$(head -c 4 "$tmp_mrs" | od -An -tx1 | tr -d ' \n')" == "28b52ffd" ]] \
                && mihomo convert-ruleset ipcidr mrs "$tmp_mrs" "$back" >/dev/null 2>&1; }; then
            warn "$grp: compile/read-back failed, kept previous $target: $(tail -2 "$clog" 2>/dev/null | tr '\n' ' ')"
            echo "-------------------------------------"; continue
        fi
        count=$(grep -c . "$back" || true); addrs=$(ip_addr_sum "$back")
        prev=0; prev_addrs=0
        if [[ -s "$target" ]]; then
            if mihomo convert-ruleset ipcidr mrs "$target" "$TEMP_DIR/ip_${grp}_prev.txt" >/dev/null 2>&1; then
                prev=$(grep -c . "$TEMP_DIR/ip_${grp}_prev.txt" || true)
                prev_addrs=$(ip_addr_sum "$TEMP_DIR/ip_${grp}_prev.txt")
            else
                warn "$grp: previous $target is unreadable, only min_entries guards this build"
            fi
        fi
        case " $IP_FORCE_GROUPS " in
            *" $grp "*) warn "$grp: IP_FORCE_GROUPS set, ratio checks vs previous ($prev / $prev_addrs) skipped"; prev=0; prev_addrs=0 ;;
        esac
        if [[ "${count:-0}" -lt "$floor" ]]; then
            warn "$grp: only ${count:-0} prefixes (< $floor), kept previous $target"
        elif [[ "$addrs" -gt "$naive_addrs" ]]; then
            warn "$grp: read-back covers more than the input ($addrs > $naive_addrs), kept previous $target"
        elif [[ "$prev" -gt 0 && $((count * 100)) -lt $((prev * IP_MIN_RATIO)) ]]; then
            warn "$grp shrank $prev -> $count prefixes (< ${IP_MIN_RATIO}%), kept previous $target"
        elif [[ "$prev_addrs" -gt 0 && $((addrs * 100)) -lt $((prev_addrs * IP_MIN_ADDR_RATIO)) ]]; then
            warn "$grp: addresses $prev_addrs -> $addrs (< ${IP_MIN_ADDR_RATIO}%), kept previous $target"
        elif [[ "$prev_addrs" -gt 0 && $((addrs * 100)) -gt $((prev_addrs * IP_MAX_GROWTH)) ]]; then
            warn "$grp: addresses $prev_addrs -> $addrs (> ${IP_MAX_GROWTH}%), kept previous $target"
        else
            mkdir -p "$OUTPUT_DIR"
            cp "$tmp_mrs" "$target"
            echo "  ✅ $grp: $count prefixes, $addrs addresses (prev $prev / $prev_addrs), $(wc -c < "$target" | tr -d ' ') bytes -> $target"
        fi
        echo "-------------------------------------"
    done
fi

echo "🎉 Build process finished."
