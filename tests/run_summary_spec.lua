-- tests/run.sh: итоговая строка называет упавшие spec (иначе при сбое одного из 60 имя теряется в выводе),
-- exit-код прежний. Гоняем копию run.sh над временным деревом со своими spec — настоящие тесты не трогаем.
local t = require("t")

local T = {}

-- files: имя → тело spec; возвращает вывод и код возврата (io.popen в LuaJIT кода не отдаёт — дописываем в вывод)
local function run_tree(files)
  local dir = io.popen("mktemp -d"):read("*l")
  os.execute(string.format("mkdir -p %s/tests && cp tests/run.sh %s/tests/run.sh", dir, dir))
  for name, body in pairs(files) do
    local f = assert(io.open(dir .. "/tests/" .. name, "w"))
    f:write(body)
    f:close()
  end
  local p = assert(io.popen(string.format("(sh %s/tests/run.sh) 2>&1; echo __rc=$?", dir), "r"))
  local out = p:read("*a")
  p:close()
  os.execute("rm -rf " .. dir)
  return out:gsub("__rc=%d+%s*$", ""), tonumber(out:match("__rc=(%d+)"))
end

local function last_line(out) return out:gsub("%s+$", ""):match("([^\n]*)$") end

function T.test_summary_names_failed_specs()
  local out, rc = run_tree({
    ["a_spec.lua"] = "print('ok')\n",
    ["b_spec.lua"] = "os.exit(1)\n",
    ["c_spec.lua"] = "print('ok')\n",
    ["d_spec.lua"] = "error('boom')\n",
  })
  t.eq(rc, 1, "упавший spec — exit 1")
  t.eq(last_line(out), "4 specs, 2 FAILED: tests/b_spec.lua tests/d_spec.lua")
end

function T.test_summary_single_failure()
  local out, rc = run_tree({ ["a_spec.lua"] = "print('ok')\n", ["x_spec.lua"] = "os.exit(3)\n" })
  t.eq(rc, 1)
  t.eq(last_line(out), "2 specs, 1 FAILED: tests/x_spec.lua")
end

function T.test_summary_when_green_is_unchanged()
  local out, rc = run_tree({ ["a_spec.lua"] = "print('ok')\n", ["b_spec.lua"] = "print('ok')\n" })
  t.eq(rc, 0)
  t.eq(last_line(out), "2 specs, OK")
end

t.run(T)
