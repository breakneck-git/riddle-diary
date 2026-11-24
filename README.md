# riddle-diary

A KOReader plugin that turns a jailbroken Kindle into Tom Riddle's diary: you write on a blank page with
your finger, the ink sinks into the paper, and the diary answers in handwriting.

> **По-русски.** Плагин KOReader «дневник Тома Реддла» для Kindle: пишешь пальцем на пустой странице,
> чернила впитываются, дневник отвечает рукописным шрифтом. Интерфейс и тексты дневника — на русском,
> персонаж по умолчанию — Том Реддл из «Гарри Поттера и методов рационального мышления». Ниже — описание
> на английском; документация разработки в `docs/` — на русском.

The diary's own texts and the documentation in `docs/` are in Russian.

## What it does

- **Full-screen diary page.** The plugin opens a white page when KOReader starts (switch it off in the
  plugin menu or with a `/mnt/us/riddle/no_autostart` file) and hides the KOReader UI. A 3-second hold in the top-right corner leaves to the normal KOReader.
- **Handwriting in, handwriting out.** The page is sent as a PNG image to a vision-capable LLM, which reads
  the handwriting and writes the reply; the reply appears in the bundled Marck Script font.
- **Memory.** Conversations are kept in SQLite on the device (`/mnt/us/riddle/diary.sqlite3`): sessions
  (a new one after 4 hours of silence), entries and rolling summaries of earlier talk.
- **Lore.** `lore.md` describes the character; it is imported into the database and sent with every
  open-seal request (capped at 10,000 characters).
- **Whose diary.** The default persona is built in. Set `whose` in the config to another character and
  world, and the diary generates that persona once and then speaks in its voice.
- **Seal (optional).** A lock on your data, opened and closed by a drawn key — a sign you draw twice in
  the diary to set it; the Kindle compares the drawing itself, without the model or the network. Rules in
  the `seal` table of the config: `key`, close after `minutes` without an entry, close on sleep
  (`on_sleep`), remember the closed-seal talk (`remember`), `off`. Under a closed seal the diary still
  answers, but no memory, lore, Notion knowledge or tasks go to the model. Without a `seal` table the
  diary is open right away.
- **Notion knowledge (optional).** With a Notion integration token, a background process syncs your
  Notion pages and databases (read-only) into a local SQLite, and the diary can talk about them; it
  also finds a task database and occasionally reminds you of open tasks.
- **Marauder's map.** Draw a wind rose (a circle with a cross) to open a parchment map of the streets and
  buildings around you, with characters of the current persona walking on it. Opens only under an open
  seal; when the seal closes after `minutes` without an entry, the map (and the status page) closes too.
- **Status page.** Draw a triangle to see the Kindle's state: Wi-Fi network and IP, SSH, free memory and
  disk, uptime, build version, Notion sync result and a check of the LLM chain.
- **Corner icons.** Time, battery and Wi-Fi in a corner of the page, updated every minute.

## Requirements

- A jailbroken Kindle with KOReader. Developed and tested only on a **Kindle Paperwhite 2**
  (firmware 5.12.2.2, WinterBreak jailbreak, KUAL, **KOReader v2025.08**). Other models may need changes.
- SSH access to the Kindle with a host alias `kindle` in `~/.ssh/config` (all `tools/*.sh` scripts use
  `ssh kindle` / `scp kindle:`).
- On the computer: `luajit` (syntax check in `tools/deploy.sh`, test runner, seal-file check in
  `tools/push_config.sh`) and the SQLite library for the tests (`tests/run.sh` looks it up via
  `brew --prefix sqlite` on macOS).
- An API key for at least one LLM provider that accepts images.

## LLM providers

`riddle/llm.lua` builds a chain of providers sharing one time budget; when one fails, the next is tried:

1. custom providers from `providers` (without `after_legacy`), in list order;
2. Google Gemini (`gemini-3.5-flash-lite`, OpenAI-compatible endpoint) for each key in
   `gemini_key` / `gemini_keys` — several keys rotate;
3. custom providers with `after_legacy = true` (fallbacks).

A custom provider is any OpenAI-compatible `…/chat/completions` server over HTTPS (Groq, BeatAPI,
OpenAI, DeepSeek, Mistral, LiteLLM and so on): `name`, `url`, `model`, optional `key`, `max_tokens`,
`max_input_chars`. A provider with `format = "gemini"` speaks Gemini's native `generateContent` instead
(used for a self-hosted Gemini proxy with an `X-Proxy-Auth` header, `proxy_auth`). The model must
understand images. See `config.example.lua`.

## Install and configure

1. **Deploy the plugin:** `tools/deploy.sh`. It checks syntax locally, copies
   `plugin/riddlediary.koplugin` to `/mnt/us/koreader/plugins/` on the Kindle, writes the build version,
   re-checks syntax with the device's LuaJIT and restarts KOReader (through the plugin's restart watcher;
   if KOReader is not running, it starts it with `--framework_stop`). If the watcher is off — the first
   deploy — restart KOReader by hand once. `--dev` (or a test-mode string) enables the developer harness;
   don't use it for normal use.
2. **Write the device config:** `tools/push_config.sh` reads environment variables from `~/.envs` (or the
   file in `RIDDLE_ENVS`) and writes `/mnt/us/riddle/config.lua` over SSH with mode 600. It never prints
   key values. Variables:
   - `GEMINI_API_KEY`, `GEMINI_API_KEY_*`, `GEMINI_API_KEYS` (comma-separated) — Gemini keys;
   - `GROQ_API_KEY`, `BEATAPI_API_KEY` — fallback providers (with fixed models, see the script);
   - `GEMINI_PROXY_URL` + `GEMINI_PROXY_AUTH_TOKEN` — optional Gemini proxy, first in the chain;
   - `NOTION_DIARY_API` — Notion integration token (optional);
   - `RIDDLE_TASKS_SOURCE` — name or id of the Notion task database (optional);
   - `RIDDLE_WHOSE` — whose diary it is (optional; default — the built-in persona).

   The seal rules are read from a separate Lua file, `RIDDLE_SEAL`
   (default `~/.config/riddle-diary/seal.lua`) with a `seal` table as in `config.example.lua`
   (for example `seal = { key = true, }`); a file with only the old `password_variants` (no `seal`) is refused. No file —
   no seal. The key's sample is not in this file: the diary writes it on the device. Without any LLM key the script writes nothing.
   Fields the script doesn't write (for example your own `providers`) can be edited directly in
   `/mnt/us/riddle/config.lua` on the device; `config.example.lua` documents them all.
3. **Upload the lore:** edit `lore.md` and run `tools/lore_push.sh [path]`. It copies the file to
   `/mnt/us/riddle/lore.md`; the plugin re-imports it when the file's mtime changes.
4. Optional: `assets/img/cover_sleep.png` (758×1024) can be set as KOReader's sleep screen image.

`tools/kindle_log.sh [lines]` shows the tail of the device log (`riddle:` lines), read-only.

## Tests

```sh
sh tests/run.sh
```

Runs every `tests/*_spec.lua` with `luajit` on the computer, without a device; the last line is
`N specs, OK` or the list of failed specs.

## Privacy: what leaves the device

- **LLM provider(s) you configure:** the image of the handwritten page, the recent conversation and
  summaries, the lore and persona texts, and — if Notion is configured — relevant Notion excerpts and open
  tasks. To classify Notion databases, the model gets only their schema (database and property names,
  option values, row counts), not rows. Persona and map generation send the persona line.
- **Notion API** (`api.notion.com`), only with a token: read-only search, database queries and page
  blocks. Nothing is written to Notion.
- **Marauder's map only** (when you open it):
  - **BeaconDB** (`api.beacondb.net`): MAC addresses (BSSID) and signal strength of nearby Wi-Fi networks
    from a fresh scan, `considerIp = false`; network names (SSID) are not sent;
  - **ipinfo.io**: if Wi-Fi location fails, an IP lookup (the service sees your IP address);
  - **Overpass API / OpenStreetMap** (`overpass-api.de`): a bounding box around the found point to fetch
    streets and buildings.
- Logs on the device contain provider host, status and timing — no keys, coordinates, BSSIDs or network
  names.

Everything else (memory, knowledge, map point and terrain) stays in `/mnt/us/riddle/` on the Kindle.

## Credits

- Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright), available under the
  Open Database License (ODbL), fetched through the Overpass API.
- Font: [Marck Script](https://fonts.google.com/specimen/Marck+Script) by Denis Masharov, SIL Open Font
  License 1.1 (`assets/fonts/OFL.txt`).
- Sleep cover: derived from "Tom Riddle's diary and the basilisk's fang" by Ruth Hartnup,
  [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/), modified — see `assets/img/CREDITS.md`.
- Tests vendor [dkjson](http://dkolf.de/dkjson-lua/) (MIT, David Heiko Kolf) and LJSQLite3 (MIT,
  Stefano Peluchetti).

## Disclaimer

This is an unofficial fan project. It is not affiliated with, endorsed or sponsored by Warner Bros.,
J.K. Rowling, or the author of *Harry Potter and the Methods of Rationality*. All characters, names and
related marks belong to their respective owners.

## License

[MIT](LICENSE) © 2026 breakneck-git
