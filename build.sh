#!/bin/bash

# Немедленно завершать работу при любой ошибке
set -e

# --- НАСТРОЙКА ---
OUTPUT_DIR="dist"
SOURCES_FILE="sources.list"
TEMP_DIR="temp_work"

# --- ОЧИСТКА И ПОДГОТОВКА ---
echo "--- Cleaning up old files ---"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# --- СБОРКА ---
echo "--- Starting build process ---"

if [ ! -f "$SOURCES_FILE" ]; then
    echo "Error: Sources file not found at '$SOURCES_FILE'!"
    exit 1
fi

while IFS= read -r line; do
    # Пропускаем пустые строки и строки, начинающиеся с #
    if [[ -z "$line" || "$line" == \#* ]]; then
        continue
    fi

    # Разбираем строку на части: ТИП,URL
    IFS=',' read -r ruletype url <<< "$line"

    # Получаем имя файла из URL
    source_filename=$(basename "$url")
    rule_name="${source_filename%.*}"

    echo "Processing rule: $rule_name"
    echo "Type: $ruletype, URL: $url"

    # Загружаем файл правил во временную директорию
    curl -L -s -o "$TEMP_DIR/$source_filename" "$url"

    # --- ЭТАП КОНВЕРТАЦИИ ---
    if [ "$ruletype" == "ipcidr" ]; then
        mihomo convert-ruleset ipcidr text "$TEMP_DIR/$source_filename" "$OUTPUT_DIR/$rule_name.mrs"
        echo "✅ Converted IP list to $OUTPUT_DIR/$rule_name.mrs"

    elif [ "$ruletype" == "domain" ]; then
        temp_yaml="$TEMP_DIR/$rule_name.yaml"
        echo "payload:" > "$temp_yaml"
        grep -v -E '^(#|$|!)' "$TEMP_DIR/$source_filename" | sed "s/.*/  - '&'/" >> "$temp_yaml"
        mihomo convert-ruleset domain yaml "$temp_yaml" "$OUTPUT_DIR/$rule_name.mrs"
        echo "✅ Converted domain list to $OUTPUT_DIR/$rule_name.mrs"

    else
        echo "⚠️ WARNING: Unknown rule type '$ruletype' for $url. Skipping."
    fi

    echo "-------------------------------------"

done < "$SOURCES_FILE"

# --- ФИНАЛЬНАЯ ОЧИСТКА ---
echo "--- Cleaning up temporary files ---"
rm -rf "$TEMP_DIR"

echo "🎉 Build process finished successfully."
