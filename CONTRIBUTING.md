# Contributing

## Tests

```sh
sh tests/run.sh
```

Every `tests/*_spec.lua` runs with `luajit` on the computer, no Kindle needed. The run must end with
`N specs, OK`. Needs `luajit` and the SQLite library (`brew install luajit sqlite` on macOS).

Write the test before the code: a spec that fails on the old code and passes on the new one. Test through
the module's public entry points and check what the user would see. Some specs (for example
`tests/no_event_spec.lua`, `tests/require_style_spec.lua`) read the plugin sources as text — run the full
suite, not only the spec you touched.

## Commits

One logical change per commit, message in the form `type(scope): what changed`, for example
`fix(answer): …`, `feat(status): …`, `test(tray): …`. Types in use: `feat`, `fix`, `test`, `refactor`,
`docs`, `refactor`, `perf`, `chore`. Never commit keys, tokens or `config.lua` with real values; `config.example.lua` holds
placeholders only.

## Running it on your own Kindle

1. Jailbreak the Kindle, install KOReader and enable SSH; add a host alias `kindle` to `~/.ssh/config`.
2. `tools/deploy.sh` — copies the plugin and restarts KOReader (restart it by hand after the very first
   deploy).
3. `tools/push_config.sh` — writes `/mnt/us/riddle/config.lua` from `~/.envs` (see the README for the
   variables).
4. `tools/lore_push.sh` — uploads `lore.md`.
5. `tools/kindle_log.sh` — read the `riddle:` lines of the device log.

Design notes and implementation plans live in `docs/superpowers/` (in Russian).
