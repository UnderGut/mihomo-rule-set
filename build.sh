#!/bin/bash

# Немедленно завершать работу при любой ошибке
set -e

# --- НАСТРОЙКА ---
OUTPUT_DIR="dist"
SOURCES_FILE="sources.list"
TEMP_DIR="temp_work"
PROCESSED_COUNT=0 # Счетчик обработанных правил

# --- ОЧИСТКА И ПОДГОТОВКА ---
echo "--- Cleaning up old files ---"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# --- СБОРКА ---
echo "--- Starting build process ---"

# Проверяем, существует ли файл с источниками
if [ ! -f "$SOURCES_FILE" ]; then
    echo "Error: Sources file not found at '$SOURCES_FILE'!"
    exit 1
fi

# --- ОТЛАДКА ---
# Показываем содержимое файла, чтобы убедиться, что он не пуст
echo "--- Debug: Content of '$SOURCES_FILE' ---"
cat "$SOURCES_FILE"
echo "--- End of content ---"
# Показываем содержимое в виде, удобном для поиска невидимых символов (CR, BOM и т.д.)
echo "--- Debug: Hexdump of '$SOURCES_FILE' ---"
od -c "$SOURCES_FILE" || echo "od command failed, continuing..."
echo "--- End of hexdump ---"


# Читаем файл с источниками построчно
# Эта конструкция надежно читает файл, даже если в конце нет символа новой строки
while IFS= read -r url || [[ -n "$url" ]]; do
    # Принудительно удаляем символ возврата каретки (CR), который может появиться из-за Windows-окончаний строк
    url=$(echo "$url" | tr -d '\r')

    # Пропускаем пустые строки и строки, начинающиеся с #
    if [[ -z "$url" || "$url" == \#* ]]; then
        continue
    fi

    # Получаем имя файла из URL (например, 'adguard.txt' -> 'adguard')
    source_filename=$(basename "$url")
    rule_name="${source_filename%.*}"

    echo "Processing rule: $rule_name from $url"

    # Загружаем файл правил во временную директорию
    curl -L -s -o "$TEMP_DIR/$source_filename" "$url"
    echo "Downloaded to $TEMP_DIR/$source_filename"

    # Определяем тип файла по расширению
    extension="${source_filename##*.}"

    # Создаем временный YAML для конвертации
    temp_yaml="$TEMP_DIR/$rule_name.yaml"

    # --- ЭТАП КОНВЕРТАЦИИ ---
    # Преобразуем исходный список в YAML, понятный для mihomo
    echo "payload:" > "$temp_yaml"

    # Для .txt или .lst файлов
    if [[ "$extension" == "txt" || "$extension" == "lst" ]]; then
        # Удаляем комментарии и пустые строки из исходного файла и форматируем для YAML
        grep -v -E '^(#|$|!)' "$TEMP_DIR/$source_filename" | sed "s/.*/  - '&'/" >> "$temp_yaml"
    else
        echo "Unsupported file type: $extension for rule $rule_name. Skipping."
        continue
    fi

    echo "Generated temporary YAML at $temp_yaml"

    # Выполняем конвертацию с помощью mihomo
    mihomo convert-ruleset domain yaml "$temp_yaml" "$OUTPUT_DIR/$rule_name.mrs"

    echo "Successfully converted to $OUTPUT_DIR/$rule_name.mrs"
    echo "-------------------------------------"
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))

done < "$SOURCES_FILE"

# --- ФИНАЛЬНАЯ ПРОВЕРКА ---
echo "--- Validating build results ---"
if [ "$PROCESSED_COUNT" -eq 0 ]; then
    echo "Error: No rules were processed. Check if '$SOURCES_FILE' is empty or contains only comments/invalid characters."
    exit 1
fi

# --- ФИНАЛЬНАЯ ОЧИСТКА ---
echo "--- Cleaning up temporary files ---"
rm -rf "$TEMP_DIR"

echo "Build process finished successfully. Total rules processed: $PROCESSED_COUNT."
