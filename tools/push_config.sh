#!/bin/sh
# Пишет /mnt/us/riddle/config.lua на Kindle из ~/.envs. Значения не печатает.
# Читает: GEMINI_API_KEY, GEMINI_API_KEY_*, GEMINI_API_KEYS (через запятую), GROQ_API_KEY, BEATAPI_API_KEY,
# GEMINI_PROXY_URL и GEMINI_PROXY_AUTH_TOKEN (gemini-proxy — Cloudflare Worker rss_bot, первым в цепочке).
# Правила печати (таблица seal) — из файла печати RIDDLE_SEAL (по умолчанию ~/.config/riddle-diary/seal.lua):
# поля таблицы Lua как в config.example.lua; в конфиг уходит только seal, разобранный config.parse_seal плагина.
# Печать необязательна: нет файла или в нём нет seal — конфиг без печати («печать: нет»), дневник на устройстве
# открыт сразу. Файл есть, но битый (не Lua, seal нарушает правила, старое слово password_variants) — отказ,
# ничего не записывается.
# Цепочка модели: gemini-proxy → Gemini → Groq → BeatAPI (deepseek-v4.1-flash-free, max_tokens 400); OpenRouter убран (2026-10-25).
# GROQ_API_KEY, BEATAPI_API_KEY — запасные провайдеры: providers = { { name = "groq", …, after_legacy = true }, { name = "beatapi", … } }.
# NOTION_DIARY_API — токен Notion в notion_token (знание дневника; один, без ключа модели конфиг не пишется).
# RIDDLE_TASKS_SOURCE — название или id базы задач в tasks_source (необязательно; без него дневник ищет сам).
# RIDDLE_WHOSE — чей это дневник, в whose (необязательно; без него — «Том Реддл из «Методов рационального мышления»»).
# Ключи Gemini — списком gemini_keys (без дублей) и первым из них в gemini_key; печатается только их число.
# Не вызывать с set -x и не добавлять сюда echo значений.
set -e
ENVS="${RIDDLE_ENVS:-$HOME/.envs}"
[ -r "$ENVS" ] || { echo "нет файла $ENVS" >&2; exit 1; }
SEAL="${RIDDLE_SEAL:-$HOME/.config/riddle-diary/seal.lua}"

set -a
# shellcheck disable=SC1090
. "$ENVS"
set +a

# значение попадает в строку Lua в двойных кавычках — пускаем только безопасные символы. Пусто — ключа
# нет; другой формат — отказ всего скрипта: иначе провайдер молча выпал бы из цепочки
check() {
  case "$2" in
    "") return 1 ;;
    *[!A-Za-z0-9_.:/+=-]*)
      echo "$1: недопустимые символы (разрешены A-Za-z0-9_.:/+=-) — ничего не записано" >&2; exit 1 ;;
  esac
  return 0
}

count=0
body=""
add() { # имя поля Lua, имя переменной, значение
  if check "$2" "$3"; then
    body="$body  $1 = \"$3\",
"
    count=$((count + 1))
    echo "$1: есть"
  else
    echo "$1: нет"
  fi
}

# ключи Gemini: GEMINI_API_KEY, затем GEMINI_API_KEY_* по имени, затем GEMINI_API_KEYS через запятую
gem_list=""
gem_n=0
gem() { # имя переменной (для сообщения), значение
  check "$1" "$2" || return 0
  case ",$gem_list," in
    *",$2,"*) return 0 ;;
  esac
  gem_list="${gem_list:+$gem_list,}$2"
  gem_n=$((gem_n + 1))
}
gem GEMINI_API_KEY "${GEMINI_API_KEY:-}"
for name in $(env | sed -n 's/^\(GEMINI_API_KEY_[A-Za-z0-9_]*\)=.*/\1/p' | sort -u); do
  eval "gem $name \"\${$name:-}\""
done
set -f
old_ifs=$IFS
IFS=,
for v in ${GEMINI_API_KEYS:-}; do gem GEMINI_API_KEYS "$v"; done
IFS=$old_ifs
set +f
if [ "$gem_n" -gt 0 ]; then
  first=${gem_list%%,*}
  quoted=$(printf '%s' "$gem_list" | sed 's/[^,]*/"&"/g; s/,/, /g')
  body="$body  gemini_key = \"$first\",
  gemini_keys = { $quoted },
"
  count=$((count + gem_n))
fi
echo "gemini_keys: $gem_n"

# запасные провайдеры (модель читает рукопись, замер tools/bench_providers.py): после Gemini, сперва Groq,
# затем BeatAPI. Ключом цепочки сами по себе не считаются (count не растёт): конфиг только с ними не пишем.
# BeatAPI режет ответ на max_tokens 200 (finish_reason=length) — просим 400.
# Groq: ITPM 7000, полный запрос — 13–16 тыс. токенов (413); max_input_chars 10000 — ~5,5 тыс. токенов
# с картинкой, урезаются знание и лор (prompt.fit).
prov=""
prov_n=0
# gemini-proxy (Cloudflare Worker rss_bot, ключи Google с ротацией по 429): первым, до прямого Gemini; запрос
# нативный generateContent (format = "gemini"), токен — заголовком X-Proxy-Auth. Только при обеих переменных.
# Модель — как у прямого Gemini (llm.lua), fit-лимита нет — как у него. Считается ключом цепочки: ходит в ту же модель
if check GEMINI_PROXY_URL "${GEMINI_PROXY_URL:-}" && check GEMINI_PROXY_AUTH_TOKEN "${GEMINI_PROXY_AUTH_TOKEN:-}"; then
  case "$GEMINI_PROXY_URL" in
    https://?*) ;;
    *) echo "GEMINI_PROXY_URL: нужен адрес https:// — ничего не записано" >&2; exit 1 ;;
  esac
  proxy_url=$(printf '%s' "$GEMINI_PROXY_URL" | sed 's:/*$::')
  prov="$prov { name = \"gemini-proxy\", format = \"gemini\", url = \"$proxy_url\", model = \"gemini-3.5-flash-lite\", proxy_auth = \"$GEMINI_PROXY_AUTH_TOKEN\" },"
  prov_n=$((prov_n + 1))
  count=$((count + 1))
  echo "gemini-proxy: есть"
else
  echo "gemini-proxy: нет"
fi
if check GROQ_API_KEY "${GROQ_API_KEY:-}"; then
  prov="$prov { name = \"groq\", url = \"https://api.groq.com/openai/v1/chat/completions\", model = \"qwen/qwen3.8-27b\", key = \"$GROQ_API_KEY\", after_legacy = true, max_input_chars = 10000 },"
  prov_n=$((prov_n + 1))
fi
if check BEATAPI_API_KEY "${BEATAPI_API_KEY:-}"; then
  prov="$prov { name = \"beatapi\", url = \"https://api.beatapi.io/v1/chat/completions\", model = \"deepseek-v4.1-flash-free\", key = \"$BEATAPI_API_KEY\", after_legacy = true, max_tokens = 400 },"
  prov_n=$((prov_n + 1))
fi
[ "$prov_n" -eq 0 ] || body="$body  providers = {$prov },
"
echo "providers: $prov_n"

# токен Notion — знание дневника; как и Groq, ключом цепочки модели не считается (count не растёт)
if check NOTION_DIARY_API "${NOTION_DIARY_API:-}"; then
  body="$body  notion_token = \"$NOTION_DIARY_API\",
"
  echo "notion_token: есть"
else
  echo "notion_token: нет"
fi

# база задач (название или id) — RIDDLE_TASKS_SOURCE; пусто — дневник ищет сам. Значение встаёт в строку Lua
# в кавычках: кавычка, обратная косая и перевод строки — отказ всего скрипта; само значение не печатается
nl='
'
cr=$(printf '\r')
case "${RIDDLE_TASKS_SOURCE:-}" in
  "") echo "tasks_source: нет" ;;
  *\"*|*\\*|*"$nl"*|*"$cr"*)
    echo "RIDDLE_TASKS_SOURCE: недопустимые символы (кавычка, обратная косая, перевод строки) — ничего не записано" >&2
    exit 1 ;;
  *)
    body="$body  tasks_source = \"$RIDDLE_TASKS_SOURCE\",
"
    echo "tasks_source: есть" ;;
esac

# чей это дневник — RIDDLE_WHOSE; нет — Kindle владельца: Волдеморт из «Методов» (спека 2026-10-31, пункт 10:
# после обновления дневник не спрашивает «Чей это дневник?»). Проверка значения — как у RIDDLE_TASKS_SOURCE; не печатается
whose="${RIDDLE_WHOSE:-Том Реддл из «Методов рационального мышления»}"
case "$whose" in
  *\"*|*\\*|*"$nl"*|*"$cr"*)
    echo "RIDDLE_WHOSE: недопустимые символы (кавычка, обратная косая, перевод строки) — ничего не записано" >&2
    exit 1 ;;
esac
body="$body  whose = \"$whose\",
"
echo "whose: есть"

# значения свойства знания, при которых документ пройден (сверка советов дневника, Notion 8152): слова данных живут
# в конфиге на устройстве, не в плагине. «Брошено» — не советовать (владелец 2026-10-27); знание со статусами уходит
# модели как есть, о брошенном можно спросить
body="$body  watched_values = { \"Просмотрено\", \"Прочитано\", \"Брошено\" },
"
echo "watched_values: Просмотрено, Прочитано, Брошено"

[ "$count" -gt 0 ] || { echo "ни одного ключа — ничего не записано" >&2; exit 1; }

# правила печати живут только в конфиге на устройстве (образец ключа пишет дневник, не скрипт).
# Нет файла печати — печати нет. Файл есть: до отправки проверяем (luajit читает stdin, его ошибки
# с текстом файла не печатаются) правилами плагина — config.parse_seal, не копией: таблица Lua; seal нет —
# печати нет; seal битый — отказ (на устройстве печать была бы закрыта без выхода). В конфиг уходит seal,
# собранный заново config.seal_lua (поля — config.SEAL_FIELDS, своего списка здесь нет). Старое слово
# (password_variants) без seal — отказ: иначе после деплоя печать молча пропала бы
seal_body=""
# есть, но не читается — отказ: иначе печать молча пропала бы («печать: нет»)
if [ -e "$SEAL" ] && [ ! -r "$SEAL" ]; then
  echo "файл печати $SEAL не читается — ничего не записано" >&2; exit 1
fi
seal_state="нет"
if [ -r "$SEAL" ]; then
  command -v luajit >/dev/null || { echo "нет luajit: файл печати не проверить — ничего не записано" >&2; exit 1; }
  plugin="$(cd "$(dirname "$0")/.." && pwd)/plugin/riddlediary.koplugin"
  rc=0
  seal_body=$({ printf 'return {\n'; cat "$SEAL"; printf '\n}\n'; } | RIDDLE_PLUGIN="$plugin" luajit -e '
package.path = os.getenv("RIDDLE_PLUGIN") .. "/?.lua;" .. package.path
local config = require("riddle.config")
local f = loadstring(io.read("*a"))
local ok, t = pcall(f or error)
if not (ok and type(t) == "table") then os.exit(1) end
if t.seal == nil then os.exit(t.password_variants ~= nil and 5 or 2) end
local line = config.seal_lua(t.seal)
if not line then os.exit(1) end
io.write("  ", line, "\n")
local s = config.parse_seal(t.seal)
os.exit(s.off and 3 or (s.on and 0 or 4))' 2>/dev/null) || rc=$?
  case $rc in
    0) seal_state="есть" ;;
    3) seal_state="снята (off)" ;;
    4) ;;
    2) seal_body="" ;;
    5) echo "файл печати $SEAL: старое слово (password_variants) больше не читается — перенесите печать в таблицу seal (config.example.lua); ничего не записано" >&2
       exit 1 ;;
    *) echo "файл печати $SEAL битый — ничего не записано" >&2; exit 1 ;;
  esac
fi
echo "печать: $seal_state"
cfg=$(printf 'return {\n%s' "$body"; [ -z "$seal_body" ] || printf '%s' "$seal_body"; printf '\n}\n')
printf '%s\n' "$cfg" |
  ssh kindle 'umask 077; mkdir -p /mnt/us/riddle; cat > /mnt/us/riddle/config.lua; chmod 600 /mnt/us/riddle/config.lua'
echo "config.lua записан ($count ключ.)"
