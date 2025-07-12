#!/bin/bash
set -e

# --- КОНФИГУРАЦИЯ ---
OUTPUT_DIR="dist"
SOURCES_FILE="sources.list"
TEMP_DIR="temp_work"

# --- ПОДГОТОВКА ---
echo "--- Cleaning up old files ---"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# Проверяем, что файл с источниками существует
if [[ ! -f "$SOURCES_FILE" ]]; then
    echo "❌ Error: Sources file not found at '$SOURCES_FILE'!"
    exit 1
fi

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

# Проверка, является ли строка IP/CIDR
is_ipcidr() {
    local line="$1"
    [[ $line =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]
}

# Определение типа .mrs или .yaml файла
detect_mrs_type() {
    local file_to_check="$1"
    local has_domain=0 has_ipcidr=0 has_process=0

    # Проверяем явные ключи
    grep -q "domain:" "$file_to_check" && has_domain=1
    grep -q "ipcidr:" "$file_to_check" && has_ipcidr=1
    grep -q '^[[:space:]]*- PROCESS-NAME,' "$file_to_check" && has_process=1

    # Дополнительно ищем строки с доменами в payload
    if grep -q '^[[:space:]]*-\ DOMAIN-' "$file_to_check"; then
        has_domain=1
    fi

    local count=$((has_domain + has_ipcidr + has_process))

    if [ $count -gt 1 ]; then
        echo "mixed"
    elif [ $count -eq 1 ]; then
        if [ $has_domain -eq 1 ]; then
            echo "domain"
        elif [ $has_ipcidr -eq 1 ]; then
            echo "ipcidr"
        else
            echo "process-name"
        fi
    else
        echo "unknown"
    fi
}

# Обработка "сырых" текстовых файлов
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
        echo "  -> Converting IP list for $rule_name..."
        mihomo convert-ruleset ipcidr text "$ip_file" "$OUTPUT_DIR/$subdir/${rule_name}_ip.mrs"
        echo "  ✅ $rule_name IP list converted."
    fi

    if [ -s "$domain_file" ]; then
        echo "  -> Converting domain list for $rule_name..."
        local temp_yaml="$TEMP_DIR/${rule_name}_domain.yaml"
        echo "payload:" > "$temp_yaml"
        sed "s/.*/  - '&'/" "$domain_file" >> "$temp_yaml"
        mihomo convert-ruleset domain yaml "$temp_yaml" "$OUTPUT_DIR/$subdir/${rule_name}_domain.mrs"
        echo "  ✅ $rule_name domain list converted."
    fi

    if [ -s "$process_file" ]; then
        echo "  -> Converting process-name list for $rule_name..."
        local temp_yaml="$TEMP_DIR/${rule_name}_process.yaml"
        echo "payload:" > "$temp_yaml"
        sed 's/^PROCESS-NAME,//' "$process_file" | sed "s/.*/  - PROCESS-NAME,&/" >> "$temp_yaml"
        mihomo convert-ruleset logical yaml "$temp_yaml" "$OUTPUT_DIR/$subdir/${rule_name}_process.mrs"
        echo "  ✅ $rule_name process-name list converted."
    fi
}

# --- ОСНОВНОЙ ЦИКЛ ---

echo "--- Starting build process ---"

while IFS= read -r url; do
    [[ -z "$url" || "$url" == \#* ]] && continue

    source_filename=$(basename "$url")
    rule_name="${source_filename%.*}"

    if [[ "$url" =~ github\.com/[^/]+/[^/]+/(raw|blob)/[^/]+/(.+) ]]; then
        path_part="${BASH_REMATCH[2]}"
        subdir=$(dirname "$path_part")
        [ "$subdir" == "." ] && subdir="general"
    else
        subdir="uncategorized"
    fi

    echo "Processing: $rule_name"
    echo "  -> Target subdirectory: $subdir"

    curl -L -s -o "$TEMP_DIR/$source_filename" "$url"

    ext="${source_filename##*.}"

    if [[ "$ext" == "mrs" || "$ext" == "yaml" ]]; then
        echo "  -> Pre-compiled file detected. Analyzing type..."
        mrs_type=$(detect_mrs_type "$TEMP_DIR/$source_filename")
        if [[ "$mrs_type" == "unknown" ]]; then
            mrs_type="domain"
        fi
        mkdir -p "$OUTPUT_DIR/$subdir"
        cp "$TEMP_DIR/$source_filename" "$OUTPUT_DIR/$subdir/${rule_name}_${mrs_type}.mrs"
        echo "  ✅ Saved as ${rule_name}_${mrs_type}.mrs"
    else
        process_plain_file "$TEMP_DIR/$source_filename" "$rule_name" "$subdir"
    fi

    echo "-------------------------------------"
done < "$SOURCES_FILE"

echo "--- Cleaning up temporary files ---"
rm -rf "$TEMP_DIR"

echo "🎉 Build process finished successfully."
