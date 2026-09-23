#!/bin/bash
set -e

# --- КОНФИГУРАЦИЯ ---
OUTPUT_DIR="rules"          # один каталог для рукописных .yaml И собранных .mrs
SOURCES_FILE="sources.list"
TEMP_DIR="temp_work"

# --- ПОДГОТОВКА ---
# ВНИМАНИЕ: НЕ wipe'аем OUTPUT_DIR — там лежат рукописные .yaml (исходные правила).
# build только перезаписывает свои .mrs (mihomo convert-ruleset overwrites).
echo "--- Preparing ---"
mkdir -p "$OUTPUT_DIR"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

if [[ ! -f "$SOURCES_FILE" ]]; then
    echo "❌ Error: Sources file not found at '$SOURCES_FILE'!"
    exit 1
fi

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

is_ipcidr() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]
}

detect_mrs_type() {
    local file="$1"
    local has_domain=0 has_ipcidr=0 has_process=0

    grep -q "domain:" "$file" && has_domain=1
    grep -q "ipcidr:" "$file" && has_ipcidr=1
    grep -q '^[[:space:]]*- PROCESS-NAME,' "$file" && has_process=1
    grep -q '^[[:space:]]*-\ DOMAIN-' "$file" && has_domain=1

    local count=$((has_domain + has_ipcidr + has_process))

    if [ $count -gt 1 ]; then echo "mixed"
    elif [ $count -eq 1 ]; then
        [ $has_domain -eq 1 ] && echo "domain"
        [ $has_ipcidr -eq 1 ] && echo "ipcidr"
        [ $has_process -eq 1 ] && echo "process-name"
    else
        echo "domain"
    fi
}

# Обработка .conf файлов
process_conf_file() {
    local filepath="$1"
    local rule_name="$2"
    local outdir="$3"

    local yaml_file="$TEMP_DIR/${rule_name}_from_conf.yaml"
    echo "payload:" > "$yaml_file"

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        echo "  - DOMAIN-SUFFIX,${line#,}" >> "$yaml_file"
    done < "$filepath"

    mkdir -p "$outdir"
    mihomo convert-ruleset domain yaml "$yaml_file" "$outdir/${rule_name}_domain.mrs"
    echo "  ✅ $rule_name conf list converted."
}

# Обработка обычных текстовых файлов
process_plain_file() {
    local filepath="$1"
    local rule_name="$2"
    local outdir="$3"

    local ip_file="$TEMP_DIR/${rule_name}_ip.txt"
    local domain_file="$TEMP_DIR/${rule_name}_domain.txt"
    local process_file="$TEMP_DIR/${rule_name}_process.txt"

    > "$ip_file"; > "$domain_file"; > "$process_file"

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[#\!].* ]] && continue
        if [[ "$line" =~ ^PROCESS-NAME, ]]; then
            echo "$line" >> "$process_file"
        elif is_ipcidr "$line"; then
            echo "$line" >> "$ip_file"
        else
            echo "$line" >> "$domain_file"
        fi
    done < "$filepath"

    mkdir -p "$outdir"

    if [ -s "$ip_file" ]; then
        mihomo convert-ruleset ipcidr text "$ip_file" "$outdir/${rule_name}_ip.mrs"
        echo "  ✅ $rule_name IP list converted."
    fi

    if [ -s "$domain_file" ]; then
        local temp_yaml="$TEMP_DIR/${rule_name}_domain.yaml"
        echo "payload:" > "$temp_yaml"
        sed "s/.*/  - '&'/" "$domain_file" >> "$temp_yaml"
        mihomo convert-ruleset domain yaml "$temp_yaml" "$outdir/${rule_name}_domain.mrs"
        echo "  ✅ $rule_name domain list converted."
    fi

    if [ -s "$process_file" ]; then
        local temp_yaml="$TEMP_DIR/${rule_name}_process.yaml"
        echo "payload:" > "$temp_yaml"
        sed 's/^PROCESS-NAME,//' "$process_file" | sed "s/.*/  - PROCESS-NAME,&/" >> "$temp_yaml"
        mihomo convert-ruleset logical yaml "$temp_yaml" "$outdir/${rule_name}_process.mrs"
        echo "  ✅ $rule_name process-name list converted."
    fi
}

# --- ОСНОВНОЙ ЦИКЛ ---

echo "--- Starting build process ---"

while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue

    folder=""
    url="$line"

    if [[ "$line" == *,* ]]; then
        folder="$(echo "$line" | cut -d',' -f1 | xargs)"
        url="$(echo "$line" | cut -d',' -f2- | xargs)"
    fi

    source_filename=$(basename "$url")
    rule_name="${source_filename%.*}"
    outdir="$OUTPUT_DIR"        # плоско: всё в rules/, без подпапок категорий

    echo "Processing: $rule_name"
    echo "  -> Saving to: $outdir"

    curl -L -s -o "$TEMP_DIR/$source_filename" "$url"
    ext="${source_filename##*.}"

    if [[ "$ext" == "conf" ]]; then
        process_conf_file "$TEMP_DIR/$source_filename" "$rule_name" "$outdir"
    elif [[ "$ext" == "mrs" || "$ext" == "yaml" ]]; then
        mrs_type=$(detect_mrs_type "$TEMP_DIR/$source_filename")
        mkdir -p "$outdir"
        cp "$TEMP_DIR/$source_filename" "$outdir/${rule_name}_${mrs_type}.mrs"
        echo "  ✅ Saved as ${rule_name}_${mrs_type}.mrs"
    else
        process_plain_file "$TEMP_DIR/$source_filename" "$rule_name" "$outdir"
    fi

    echo "-------------------------------------"
done < "$SOURCES_FILE"

# --- MERGE GROUPS (consolidate N sources -> one .mrs) ---
# Config: merge.list, lines "group,type,url[,exclude_regex]"
#   type = list  (plain domain list, e.g. MetaCubeX *.list)
#        | yaml  (classical *.yaml, e.g. blackmatrix7: DOMAIN/DOMAIN-SUFFIX kept)
#        | local* (file inside this repo; locallist = plain list, localyaml = classical yaml)
#   exclude_regex = optional ERE; matching domains are dropped (e.g. typosquats)
# Output: rules/<group>.mrs. Best-effort: never breaks the core build above.
# Safety: a group is rebuilt only if
#   - EVERY source was fetched and parsed (no HTML/error pages, no empty sources),
#   - the new domain count is not below MERGE_MIN_RATIO of the previous build,
#   - no entry is a TLD or a public suffix (Public Suffix List, see below).
# Otherwise the previous rules/<group>.mrs is kept untouched.
MERGE_FILE="merge.list"
MERGE_MIN_RATIO="${MERGE_MIN_RATIO:-80}"   # percent of previous count
DOMAIN_RE='^(\+\.)?[a-z0-9_-]+(\.[a-z0-9_-]+)+$'
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

# Log a warning; on GitHub Actions also emit an annotation on the run summary.
warn() {
    echo "  ⚠ $*"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::warning title=build.sh merge::$*"; fi
    return 0
}

if [[ -f "$MERGE_FILE" ]]; then
    echo "--- Processing merge groups ---"
    psl_ok=0
    for psl_url in $PSL_URLS; do
        if curl -fsSL --retry 3 --max-time 60 -o "$PSL_FILE" "$psl_url" \
            && grep -q '===BEGIN ICANN DOMAINS===' "$PSL_FILE" \
            && grep -q '===BEGIN PRIVATE DOMAINS===' "$PSL_FILE" \
            && [[ "$(grep -cvE '^[[:space:]]*(//|$)' "$PSL_FILE" || true)" -gt 5000 ]]; then
            psl_ok=1
            echo "  public suffix list: $psl_url"
            break
        fi
    done
    [[ "$psl_ok" -eq 1 ]] || warn "public suffix list unavailable, merge groups are not rebuilt"
    groups=$(grep -vE '^[[:space:]]*(#|$)' "$MERGE_FILE" | cut -d',' -f1 | sort -u || true)
    for grp in $groups; do
        echo "Merging group: $grp"
        combined="$TEMP_DIR/${grp}_combined.txt"; > "$combined"
        grp_failed=0
        while IFS= read -r mline; do
            [[ -z "$mline" || "$mline" == \#* ]] && continue
            g="$(echo "$mline" | cut -d',' -f1 | xargs)"
            [[ "$g" != "$grp" ]] && continue
            mtype="$(echo "$mline" | cut -d',' -f2 | xargs)"
            murl="$(echo "$mline" | cut -d',' -f3 | xargs)"
            mexclude="$(echo "$mline" | cut -d',' -f4-)"
            tmpf="$TEMP_DIR/merge_${grp}_$(basename "$murl")"
            if [[ "$mtype" == local* ]]; then
                cp "$murl" "$tmpf" 2>/dev/null || { warn "$grp: no local file: $murl"; grp_failed=1; continue; }
            else
                curl -fsSL --retry 3 --max-time 60 -o "$tmpf" "$murl" || { warn "$grp: fetch failed: $murl"; grp_failed=1; continue; }
            fi
            [[ ! -s "$tmpf" ]] && { warn "$grp: empty source: $murl"; grp_failed=1; continue; }
            extracted="$TEMP_DIR/merge_extract.txt"
            if [[ "$mtype" == *yaml* ]]; then
                awk '
                  { line=$0; sub(/^[[:space:]]*-?[[:space:]]*/,"",line) }
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
        sort -u "$combined" | grep -E '\.' > "$sorted" || true
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
            warn "$grp produced 0 domains, skipped"
        elif [[ "${prev:-0}" -gt 0 && $((count * 100)) -lt $((prev * MERGE_MIN_RATIO)) ]]; then
            warn "$grp shrank $prev -> $count (< ${MERGE_MIN_RATIO}%), kept previous .mrs"
        else
            yaml="$TEMP_DIR/${grp}_payload.yaml"
            echo "payload:" > "$yaml"
            sed "s/.*/  - '&'/" "$sorted" >> "$yaml"
            mkdir -p "$OUTPUT_DIR"
            if mihomo convert-ruleset domain yaml "$yaml" "$TEMP_DIR/${grp}.mrs" && [[ -s "$TEMP_DIR/${grp}.mrs" ]]; then
                cp "$TEMP_DIR/${grp}.mrs" "$OUTPUT_DIR/${grp}.mrs"
                echo "  ✅ $grp merged: $count domains (prev $prev) -> $OUTPUT_DIR/${grp}.mrs"
            else
                warn "$grp compile failed (kept previous .mrs)"
            fi
        fi
        echo "-------------------------------------"
    done
fi

echo "--- Cleaning up temporary files ---"
rm -rf "$TEMP_DIR"
echo "🎉 Build process finished successfully."
