-- tools/kindle_log.sh с поддельным ssh: устройство не нужно, удалённая команда не уходит.
local t = require("t")

-- io.popen в LuaJIT не отдаёт код возврата: дописываем его в вывод
local function sh(cmd)
  local p = assert(io.popen("(" .. cmd .. ") 2>&1; echo __rc=$?", "r"))
  local out = p:read("*a")
  p:close()
  local rc = tonumber(out:match("__rc=(%d+)%s*$"))
  return (out:gsub("__rc=%d+%s*$", "")), rc
end

-- каталог с ssh-подделкой: отмечает вызов файлом и ничего не выполняет
local function sandbox()
  local dir = sh("mktemp -d"):gsub("%s+$", "")
  sh("mkdir -p " .. dir .. "/bin")
  local f = assert(io.open(dir .. "/bin/ssh", "w"))
  f:write("#!/bin/sh\ntouch " .. dir .. "/called\n")
  f:close()
  sh("chmod +x " .. dir .. "/bin/ssh")
  return dir
end

local function run_script(n)
  local dir = sandbox()
  local out, rc = sh("PATH=" .. dir .. "/bin:$PATH sh tools/kindle_log.sh " .. n)
  local called = io.open(dir .. "/called", "r")
  if called then called:close() end
  return out, rc, called ~= nil
end

local tests = {}

function tests.test_huge_n_rejected_before_ssh()
  local out, rc, called = run_script("99999999999999999999")
  t.eq(rc, 2, "код выхода: " .. out)
  t.ok(not called, "ssh вызван")
  t.ok(not out:find("integer expression", 1, true), "сравнение упало: " .. out)
end

function tests.test_five_digits_rejected()
  local out, rc, called = run_script("12345")
  t.eq(rc, 2, "код выхода: " .. out)
  t.ok(not called, "ssh вызван")
end

function tests.test_over_2000_rejected()
  local _, rc, called = run_script("2001")
  t.eq(rc, 2)
  t.ok(not called, "ssh вызван")
end

function tests.test_non_digits_rejected()
  local _, rc, called = run_script("'1;id'")
  t.eq(rc, 2)
  t.ok(not called, "ssh вызван")
end

function tests.test_valid_n_calls_ssh()
  local out, rc, called = run_script("120")
  t.eq(rc, 0, "код выхода: " .. out)
  t.ok(called, "ssh не вызван")
end

t.run(tests)
