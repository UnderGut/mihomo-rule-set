#!/bin/bash

# Немедленно завершать работу при любой ошибке
set -e

# --- НАСТРОЙКА ---
# Директория для сохранения финальных.mrs файлов
OUTPUT_DIR="dist"
# Файл со списком URL-адресов исходных правил
SOURCES_FILE="sources.list"
# Временная рабочая директория
TEMP_DIR="temp_work"

# --- ОЧИСТКА И ПОДГОТОВКА ---
echo "--- Cleaning up old files ---"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# --- СБОРКА ---
echo "--- Starting build process ---"

# Проверяем, существует ли файл с источниками
if; then
    echo "Error: Sources file not found at '$SOURCES_FILE'!"
    exit 1
fi

# Читаем файл с источниками построчно
while IFS= read -r url |

| [[ -n "$url" ]]; do
    # Пропускаем пустые строки и строки, начинающиеся с #
    if [[ -z "$url" |

| "$url" == \#* ]]; then
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
    # Для.txt или.lst файлов, которые являются простыми списками доменов
    if [ "$extension" == "txt" ] |

| [ "$extension" == "lst" ]; then
        # Удаляем комментарии и пустые строки из исходного файла
        grep -v -E '^(#|$)' "$TEMP_DIR/$source_filename" | sed "s/.*/  - '&'/" >> "$temp_yaml"
    else
        echo "Unsupported file type: $extension for rule $rule_name. Skipping."
        continue
    fi

    echo "Generated temporary YAML at $temp_yaml"

    # Выполняем конвертацию с помощью mihomo
    mihomo convert-ruleset domain yaml "$temp_yaml" "$OUTPUT_DIR/$rule_name.mrs"
    
    echo "Successfully converted to $OUTPUT_DIR/$rule_name.mrs"
    echo "-------------------------------------"

done < "$SOURCES_FILE"

# --- ФИНАЛЬНАЯ ОЧИСТКА ---
echo "--- Cleaning up temporary files ---"
rm -rf "$TEMP_DIR"

echo "Build process finished successfully."