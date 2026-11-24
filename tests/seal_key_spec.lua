-- Режим «задать ключ» (план 2026-11-20-seal-key, задача 5; спека §5 «Как задаётся ключ», §9 флаг off): ключ задаётся
-- в самом дневнике — два рисунка, второй сверяется с первым, образец пишется на устройство. Пока стоит off, образец
-- удаляется; флаг снят — режим начинается с нуля.
-- Контроллер — настоящий: на поддельной файловой системе (files) и, в конце, через app.new_controller на настоящих
-- файлах во временном каталоге.
require("sqlite_shim") -- riddle.app тянет хранилище
local t = require("t")
local stand = require("seal_stand")
local texts = require("riddle.texts")
local seal = require("riddle.seal")
local controller = require("riddle.controller")
local app = require("riddle.app")
local TR = require("fixtures.triangle_strokes")
local O = require("fixtures.rose_owner")
local R = require("fixtures.rose_strokes")

local T = {}

local KEY = seal.KEY_PATH

-- знак владельца для тестов: квадрат и тот же квадрат, нарисованный рукой ещё раз (углы гуляют); розы и треугольник
-- в знак не годятся (glyph.fits — "taken")
local SQUARE = TR.square
local SQUARE_AGAIN = { { p = { 230, 320, 560, 310, 545, 660, 215, 640, 230, 320 } } }
-- другая фигура в те же один штрих: годится в знак, с квадратом не совпадает
local ZIGZAG = TR.zigzag

local function flat(list) return table.concat(list, ",") end

local function logged(env, needle)
  for _, l in ipairs(env.logs) do
    if l:find(needle, 1, true) then return l end
  end
end

-- env.files — файловая система образца: путь -> содержимое; writes — вызовы write_key; llm_calls — вызовы модели
local function make(rules, files)
  local env = { files = files or {}, writes = {}, llm_calls = {}, logs = {} }
  env.deps = {
    cfg = { seal = rules or stand.key() },
    memory = nil,
    read_file = function() return "PNG" end,
    b64 = function(s) return "B64" .. s end,
    remove = function() end,
    now = function() return 1000 end,
    random = function() return 1 end,
    log = function(msg) env.logs[#env.logs + 1] = msg end,
    llm_call = function(...)
      env.llm_calls[#env.llm_calls + 1] = { ... }
      return { read = "x", reply = "y" }
    end,
    load_key = function(path)
      local s = env.files[path]
      if s == nil then return nil, "absent" end
      local drawings = seal.decode(s)
      if not drawings then return nil, "broken" end
      return drawings
    end,
    write_key = function(path, s)
      env.writes[#env.writes + 1] = { path = path, s = s }
      env.files[path] = s
      return true
    end,
    forget_key = function(path)
      env.files[path] = nil
      return true
    end,
  }
  env.ctl = controller.new(env.deps)
  return env
end

function T.test_setting_mode_when_no_key_file()
  local env = make()
  t.eq(env.ctl.seal.setting, true, "ключ в правилах, образца нет — режим «задать ключ»")
  t.eq(env.ctl:opening_text(), texts.key_draw)
  t.eq(env.ctl.seal_open, false, "печать закрыта, пока ключ не задан")
end

function T.test_set_key_two_matching()
  local env = make()
  t.eq(env.ctl:key_page(SQUARE), texts.key_again)
  t.eq(#env.writes, 0, "после первого рисунка ничего не записано")
  t.eq(env.ctl:key_page(SQUARE_AGAIN), texts.key_saved)
  t.eq(#env.writes, 1, "образец записан один раз")
  t.eq(env.writes[1].path, KEY)
  local drawings = seal.decode(env.writes[1].s)
  t.eq(#drawings, 2, "образец — два рисунка")
  t.eq(flat(drawings[1][1].p), flat(SQUARE[1].p))
  t.eq(flat(drawings[2][1].p), flat(SQUARE_AGAIN[1].p))
  t.eq(env.ctl.seal_open, true, "ключ задан — печать открыта")
  t.eq(env.ctl.seal.setting, false)
  t.eq(#env.llm_calls, 0, "модель не звали")
  t.ok(env.ctl:opening_text() ~= texts.key_draw, "режим кончился")
end

function T.test_set_key_mismatch_restarts()
  local env = make()
  t.eq(env.ctl:key_page(SQUARE), texts.key_again)
  -- второй рисунок — треугольник: в знак не годится, первый рисунок остаётся
  t.eq(env.ctl:key_page(TR.equilateral), texts.key_taken)
  t.eq(env.ctl:key_page(SQUARE_AGAIN), texts.key_saved, "после отказа второй рисунок сверяется с тем же первым")
  env = make()
  t.eq(env.ctl:key_page(SQUARE), texts.key_again)
  t.eq(env.ctl:key_page(ZIGZAG), texts.key_retry, "другая фигура — не совпало")
  t.eq(#env.writes, 0)
  t.eq(env.ctl.seal_open, false)
  -- режим заново: следующий рисунок снова первый, без блокировки и счётчика
  t.eq(env.ctl:key_page(ZIGZAG), texts.key_again)
  t.eq(env.ctl:key_page(SQUARE), texts.key_retry)
  t.eq(env.ctl:key_page(SQUARE), texts.key_again)
  t.eq(env.ctl:key_page(SQUARE_AGAIN), texts.key_saved)
  t.eq(#seal.decode(env.files[KEY]), 2)
end

function T.test_set_key_rejects_triangle_first()
  local env = make()
  t.eq(env.ctl:key_page(TR.equilateral), texts.key_taken)
  t.eq(env.ctl:key_page(O.owner_01), texts.key_taken, "роза тоже занята")
  t.eq(env.ctl:key_page(SQUARE), texts.key_again, "отказ не считается первым рисунком")
end

function T.test_set_key_rejects_small_first()
  local env = make()
  t.eq(env.ctl:key_page(TR.triangle_120), texts.key_bigger)
  t.eq(env.ctl:key_page(SQUARE), texts.key_again)
end

function T.test_setting_interrupted_by_sleep()
  local env = make(stand.rules({ key = true, on_sleep = true }))
  t.eq(env.ctl:key_page(SQUARE), texts.key_again)
  env.ctl:on_sleep()
  t.eq(env.ctl:key_page(SQUARE_AGAIN), texts.key_again, "после сна рисунок снова первый")
  t.eq(#env.writes, 0, "полуобразец нигде не записан")
end

function T.test_setting_interrupted_by_close()
  local env = make()
  t.eq(env.ctl:key_page(SQUARE), texts.key_again)
  env.ctl:on_close()
  t.eq(env.ctl:key_page(SQUARE_AGAIN), texts.key_again, "дневник закрыли — рисунок снова первый")
  t.eq(#env.writes, 0)
end

-- перезапуск KOReader — новый контроллер: первый рисунок жил только в памяти
function T.test_setting_interrupted_by_restart()
  local env = make()
  t.eq(env.ctl:key_page(SQUARE), texts.key_again)
  local again = controller.new(env.deps)
  t.eq(again:key_page(SQUARE_AGAIN), texts.key_again)
  t.eq(#env.writes, 0)
end

-- Review Focus 2: битый или недописанный образец не сбрасывает ключ
function T.test_broken_key_file_stays_closed()
  local env = make(nil, { [KEY] = "return { {{p={1,2," })
  t.eq(env.ctl.seal.setting, false, "битый образец — не режим задания")
  t.eq(env.ctl.seal_open, false, "печать закрыта")
  t.ok(logged(env, "riddle: seal key unreadable"), "лог о битом образце")
  t.ok(env.ctl:opening_text() ~= texts.key_draw)
  t.eq(env.ctl:key_page(SQUARE), nil, "рисунок — не задание ключа")
  t.eq(#env.writes, 0)
end

function T.test_key_file_present_no_setting()
  local env = make(nil, { [KEY] = seal.encode({ SQUARE, SQUARE_AGAIN }) })
  t.eq(env.ctl.seal.setting, false)
  t.eq(#env.ctl.seal.drawings, 2, "образец загружен")
  t.eq(env.ctl.seal_open, false)
  t.ok(env.ctl:opening_text() ~= texts.key_draw)
end

function T.test_invalid_config_no_setting()
  local env = make(stand.rules({ key = "yes" }))
  t.eq(env.ctl.seal.setting, false, "битый конфиг ключом не открывается — и задать ключ нельзя")
  t.eq(env.ctl:key_page(SQUARE), nil)
end

function T.test_many_strokes_in_setting_goes_to_model()
  local env = make()
  local six = {}
  for i = 1, 6 do six[i] = SQUARE[1] end
  t.eq(env.ctl:key_page(six), nil, "страница со словами — разговор, не попытка знака")
  t.eq(env.ctl:key_page(R.word_salandusa), nil)
  t.eq(env.ctl:key_page({}), nil, "пустая страница — не попытка знака")
end

function T.test_encode_decode_round_trip_and_stable()
  local drawings = { SQUARE, TR.letter_de }
  local s = seal.encode(drawings)
  t.eq(seal.encode(seal.decode(s)), s, "повтор записи даёт тот же файл")
  t.eq(flat(seal.decode(s)[2][2].p), flat(TR.letter_de[2].p))
  for _, bad in ipairs({ "", "return 1", "return {}", "return { {} }", "return { { {p={1,2,3}} } }",
                         "return { { {p={1,'x'}} } }", "os.exit(1)", "return {", "\0\1" }) do
    t.eq(seal.decode(bad), nil, "битый образец: " .. bad)
  end
end

-- образец не исполняет чужой код: окружение пустое
function T.test_decode_has_no_globals()
  t.eq(seal.decode("return { { {p={1,2,3,4}} }, x = os.time() }"), nil)
end

-- B1: методы строк доступны и в пустом окружении (метатаблица строк) — файл с кодом не исполняется вовсе: до
-- loadstring пропускаются только знаки формата образца
function T.test_decode_rejects_code()
  t.eq(seal.decode('return { { {p={1,2,3,#("x"):rep(10)}} } }'), nil, "вызов метода строки")
  t.eq(seal.decode("return { { {p={1,2,3,4}} } } --[[ x ]]"), nil, "чужие знаки")
  t.eq(seal.decode("return { { {p={1,2,3,0x10}} } }"), nil, "чужие знаки: x")
  local s = seal.encode({ SQUARE, TR.letter_de, { { p = { -1.5, 2.25, 300, 400 } } } })
  t.eq(seal.encode(seal.decode(s)), s, "образец в своём формате читается, как прежде")
end

-- M7: образец не записался (FAT, нет места) — «не совпало», печать закрыта, режим задания остаётся
function T.test_write_failure_keeps_setting()
  local env = make()
  env.deps.write_key = function() return nil, "No space left on device" end
  t.eq(env.ctl:key_page(SQUARE), texts.key_again)
  t.eq(env.ctl:key_page(SQUARE_AGAIN), texts.key_retry)
  t.eq(env.ctl.seal_open, false, "печать закрыта")
  t.eq(env.ctl.seal.setting, true, "режим задания остаётся")
  t.ok(logged(env, "riddle: seal key write failed"), table.concat(env.logs, "\n"))
  t.eq(env.ctl:key_page(SQUARE), texts.key_again, "режим заново: следующий рисунок — первый")
end

-- рисунок, который формат образца не прочтёт обратно (координата 1e-07 -> "1e-07"), не пишется: иначе записанный
-- образец на перезапуске оказался бы «битым» и печать не открылась бы ничем
function T.test_unreadable_encoding_not_written()
  local env = make()
  local first = { { p = { 1e-07, 0, 350, 0, 350, 350, 0, 350, 0, 0 } } }
  local second = { { p = { 0, 0, 350, 0, 350, 350, 0, 350, 0, 0 } } }
  t.eq(env.ctl:key_page(first), texts.key_again)
  t.eq(env.ctl:key_page(second), texts.key_retry)
  t.eq(#env.writes, 0, "образец не записан")
  t.eq(env.ctl.seal.setting, true, "режим задания остаётся")
  t.eq(env.ctl.seal_open, false)
  t.ok(logged(env, "riddle: seal key write failed: encode"), table.concat(env.logs, "\n"))
end

-- §9, решение владельца «А»: пока стоит off, образец удаляется; печати нет
function T.test_off_deletes_key_file_fake()
  local env = make(stand.rules({ key = true, off = true }), { [KEY] = seal.encode({ SQUARE, SQUARE_AGAIN }) })
  t.eq(env.files[KEY], nil, "образец удалён")
  t.eq(env.ctl.seal_open, true, "печать не действует")
  t.eq(env.ctl.seal.setting, false)
  t.eq(env.ctl:key_page(SQUARE), nil)
end

-- через app.new_controller — на настоящих файлах во временном каталоге ----------------------------------------------

local function tmpdir()
  local h = io.popen("mktemp -d")
  local dir = h:read("*l")
  h:close()
  return dir
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

local function put(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

local function slurp(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function real(rules, key_path)
  local logs = {}
  local ctl = app.new_controller{
    cfg = { seal = rules },
    memory = nil,
    http = { post = function() error("сеть не нужна") end },
    clock = function() return 0 end,
    wall = function() return 1000 end,
    log = function(msg) logs[#logs + 1] = msg end,
    read_file = function() return "PNG" end,
    remove = function() end,
    file_mtime = function() return nil end,
    random = function() return 1 end,
    key_path = key_path,
  }
  return ctl, logs
end

function T.test_off_deletes_key_file()
  local path = tmpdir() .. "/seal_key.lua"
  put(path, seal.encode({ SQUARE, SQUARE_AGAIN }))
  local ctl = real(stand.rules({ key = true, off = true }), path)
  t.eq(exists(path), false, "off — образец удалён")
  t.eq(ctl.seal_open, true, "печать не действует")
  t.eq(ctl:key_page(SQUARE), nil)
  -- повтор: файла уже нет — не ошибка
  ctl = real(stand.rules({ key = true, off = true }), path)
  t.eq(exists(path), false)
  t.eq(ctl.seal_open, true)
end

function T.test_off_removed_starts_setting()
  local path = tmpdir() .. "/seal_key.lua"
  put(path, seal.encode({ SQUARE, SQUARE_AGAIN }))
  real(stand.rules({ key = true, off = true }), path)
  local ctl = real(stand.key(), path)
  t.eq(ctl:opening_text(), texts.key_draw, "флаг снят, образца нет — режим «задать ключ» с нуля")
  t.eq(ctl.seal_open, false)
end

function T.test_real_key_written_and_loaded()
  local path = tmpdir() .. "/seal_key.lua"
  local ctl = real(stand.key(), path)
  t.eq(ctl:key_page(SQUARE), texts.key_again)
  t.eq(ctl:key_page(SQUARE_AGAIN), texts.key_saved)
  t.eq(exists(path .. ".tmp"), false, "запись атомарна: .tmp переименован")
  local first = slurp(path)
  -- перезапуск: образец читается, режима задания нет, печать на старте закрыта
  local again = real(stand.key(), path)
  t.eq(again.seal.setting, false)
  t.eq(#again.seal.drawings, 2)
  t.eq(again.seal_open, false)
  t.ok(again:opening_text() ~= texts.key_draw)
  t.eq(seal.encode(again.seal.drawings), first, "повтор записи образца дал бы тот же файл")
end

function T.test_real_broken_key_file()
  local path = tmpdir() .. "/seal_key.lua"
  put(path, "return { {{p={1,2,")
  local ctl, logs = real(stand.key(), path)
  t.eq(ctl.seal.setting, false)
  t.eq(ctl.seal_open, false)
  local hit = false
  for _, l in ipairs(logs) do hit = hit or l:find("riddle: seal key unreadable", 1, true) ~= nil end
  t.ok(hit, "лог о битом образце")
  t.eq(slurp(path), "return { {{p={1,2,", "битый образец не перезаписан")
end

-- M11: файл не открылся не потому, что его нет (здесь ENOTDIR; на Kindle — EIO, EACCES): «битый», не режим задания
function T.test_real_open_error_not_absent()
  local dir = tmpdir()
  put(dir .. "/file", "x")
  local path = dir .. "/file/seal_key.lua"
  local drawings, err = seal.load_key(path)
  t.eq(drawings, nil)
  t.eq(err, "broken")
  local ctl, logs = real(stand.key(), path)
  t.eq(ctl.seal.setting, false, "режим задания не включается")
  t.eq(ctl.seal_open, false)
  t.ok(ctl:opening_text() ~= texts.key_draw)
  local hit = false
  for _, l in ipairs(logs) do hit = hit or l:find("riddle: seal key unreadable", 1, true) ~= nil end
  t.ok(hit, "лог о битом образце")
end

t.run(T)
