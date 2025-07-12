#!/bin/bash
set -e

OUTPUT_DIR="dist"
SOURCES_FILE="sources.list"
TEMP_DIR="temp_work"

echo "--- Cleaning up old files ---"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

if [ ! -f "$SOURCES_FILE" ]; then
    echo "Error: Sources file not found at '$SOURCES_FILE'!"
    exit 1
fi

# Проверка, является ли строка IP/CIDR
is_ipcidr() {
    local line="$1"
    [[ $line =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]
}

# Определение типа внутри .mrs или .yaml файла с учетом PROCESS-NAME
detect_mrs_type() {
    local mrs_file="$1"

    local has_domain=0
    local has_ipcidr=0
    local has_process=0

    if grep -q "domain:" "$mrs_file"; then
        has_domain=1
    fi

    if grep -q "ipcidr:" "$mrs_file"; then
        has_ipcidr=1
    fi

    if grep -q '^  - PROCESS-NAME,' "$mrs_file"; then
        has_process=1
    fi

    local count=$((has_domain + has_ipcidr + has_process))

    if [ $count -eq 1 ]; then
        if [ $has_domain -eq 1 ]; then
            echo "domain"
            return
        elif [ $has_ipcidr -eq 1 ]; then
            echo "ipcidr"
            return
        else
            echo "process-name"
            return
        fi
    fi

    if [ $count -gt 1 ]; then
        echo "mixed"
        return
    fi

    echo ""
}

# Обработка обычных текстовых файлов с разделением на IP, domain и process-name
process_plain_file() {
    local filepath="$1"
    local rule_name="$2"
    local subdir="$3"

    local ip_file="$TEMP_DIR/${rule_name}_ip.txt"
    local domain_file="$TEMP_DIR/${rule_name}_domain.txt"
    local process_file="$TEMP_DIR/${rule_name}_process.txt"

    > "$ip_file"
    > "$domain_file"
    > "$process_file"

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

    mkdir -p "$OUTPUT_DIR/$subdir"

    if [ -s "$ip_file" ]; then
        echo "Converting IP list for $rule_name"
        mihomo convert-ruleset ipcidr text "$ip_file" "$OUTPUT_DIR/$subdir/${rule_name}_ip.mrs"
        echo "✅ $rule_name IP converted."
    fi

    if [ -s "$domain_file" ]; then
        echo "Converting domain list for $rule_name"
        local temp_yaml="$TEMP_DIR/${rule_name}_domain.yaml"
        echo "payload:" > "$temp_yaml"
        grep -v -E '^(#|$|!)' "$domain_file" | sed "s/.*/  - '&'/" >> "$temp_yaml"
        mihomo convert-ruleset domain yaml "$temp_yaml" "$OUTPUT_DIR/$subdir/${rule_name}_domain.mrs"
        echo "✅ $rule_name domain converted."
    fi

    if [ -s "$process_file" ]; then
        echo "Converting process-name list for $rule_name"
        local temp_yaml="$TEMP_DIR/${rule_name}_process.yaml"
        echo "payload:" > "$temp_yaml"
        grep -v -E '^(#|$|!)' "$process_file" | sed "s/.*/  - '&'/" >> "$temp_yaml"
        mihomo convert-ruleset process-name yaml "$temp_yaml" "$OUTPUT_DIR/$subdir/${rule_name}_process.mrs"
        echo "✅ $rule_name process-name converted."
    fi
}

# Сохранение .mrs или .yaml файла с типом и подпапкой
save_mrs_with_type() {
    local src="$1"
    local base_name="$2"
    local type="$3"
    local subdir="$4"
    local ext="$5"

    if [[ -z "$type" ]]; then
        echo "⚠️ Type unknown, skipping saving $base_name.$ext"
        return
    fi

    mkdir -p "$OUTPUT_DIR/$subdir"
    cp "$src" "$OUTPUT_DIR/$subdir/${base_name}_${type}.mrs"
    echo "Saved $base_name as ${base_name}_${type}.mrs in $subdir"
}

echo "--- Starting build process ---"

while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue

    url="$line"

    # Выделяем путь после raw/ или main/ для подпапок
    if [[ "$url" =~ github.com/.+/.+/(raw|blob)/.+/(.+) ]]; then
        path_part="${BASH_REMATCH[2]}"
    else
        path_part=""
    fi

    source_filename=$(basename "$url")
    rule_name="${source_filename%.*}"
    subdir=$(dirname "$path_part")

    echo "Processing: $rule_name from $url"
    echo "Target subdirectory: $subdir"

    curl -L -s -o "$TEMP_DIR/$source_filename" "$url"

    ext="${source_filename##*.}"

    if [[ "$ext" == "mrs" || "$ext" == "yaml" ]]; then
        mrs_type=$(detect_mrs_type "$TEMP_DIR/$source_filename")
        echo "Detected type: $mrs_type"

        if [[ "$mrs_type" == "mixed" ]]; then
            mkdir -p "$OUTPUT_DIR/$subdir"
            cp "$TEMP_DIR/$source_filename" "$OUTPUT_DIR/$subdir/${rule_name}_mixed.mrs"
            echo "Saved mixed type file"
        elif [[ -n "$mrs_type" ]]; then
            save_mrs_with_type "$TEMP_DIR/$source_filename" "$rule_name" "$mrs_type" "$subdir" "$ext"
        else
            echo "⚠️ Unknown file type for $rule_name, skipping save"
        fi
    else
        process_plain_file "$TEMP_DIR/$source_filename" "$rule_name" "$subdir"
    fi

    echo "-------------------------------------"
done < "$SOURCES_FILE"

echo "--- Cleaning up temporary files ---"
rm -rf "$TEMP_DIR"

echo "🎉 Build process finished successfully."
