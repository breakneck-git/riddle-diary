-- riddle.file: запись файла целиком или никак (общая для карты и итога синхронизации).
local t = require("t")
local file = require("riddle.file")

local T = {}

local function open_with(f) return function() return f end end

function T.test_write_checks_open_write_and_close()
  local ok_file = { write = function(f) return f end, close = function() return true end }
  t.eq(file.write("/x", "s", open_with(ok_file)), true)
  t.eq(file.write("/x", "s", function() return nil, "EACCES" end), nil, "не открылся")
  local bad_write = { write = function() return nil, "ENOSPC" end, close = function() return true end }
  t.eq(file.write("/x", "s", open_with(bad_write)), nil, "write упал")
  local bad_close = { write = function(f) return f end, close = function() return nil, "ENOSPC" end }
  local r, err = file.write("/x", "s", open_with(bad_close))
  t.eq(r, nil, "close упал")
  t.eq(err, "ENOSPC")
end

local function fake()
  local d = { ops = {}, files = {} }
  d.write = function(path, s) d.ops[#d.ops + 1] = "write " .. path d.files[path] = s return true end
  d.rename = function(a, b)
    d.ops[#d.ops + 1] = "rename " .. a .. " " .. b
    d.files[b], d.files[a] = d.files[a], nil
    return true
  end
  return d
end

function T.test_write_atomic_goes_through_tmp_then_rename()
  local d = fake()
  d.files["/r/f"] = "old"
  t.eq(file.write_atomic("/r/f", "new", d), true)
  t.eq(table.concat(d.ops, "|"), "write /r/f.tmp|rename /r/f.tmp /r/f")
  t.eq(d.files["/r/f"], "new")
  t.eq(d.files["/r/f.tmp"], nil)
end

function T.test_write_atomic_failed_write_keeps_old_file_and_skips_rename()
  local d = fake()
  d.files["/r/f"] = "old"
  d.write = function(path) d.ops[#d.ops + 1] = "write " .. path return nil, "ENOSPC" end
  local ok, err = file.write_atomic("/r/f", "new", d)
  t.eq(ok, nil)
  t.eq(err, "ENOSPC")
  t.eq(table.concat(d.ops, "|"), "write /r/f.tmp")
  t.eq(d.files["/r/f"], "old")
end

function T.test_write_atomic_reports_rename_failure()
  local d = fake()
  d.rename = function() return nil, "EXDEV" end
  local ok, err = file.write_atomic("/r/f", "new", d)
  t.eq(ok, nil)
  t.eq(err, "EXDEV")
end

-- настоящая ФС: без своих open/rename писатель идёт через io.open и os.rename
function T.test_write_atomic_default_writes_a_real_file()
  local path = os.tmpname()
  t.eq(file.write_atomic(path, "abc"), true)
  local f = assert(io.open(path, "rb"))
  t.eq(f:read("*a"), "abc")
  f:close()
  t.ok(io.open(path .. ".tmp", "rb") == nil, "временного файла не остаётся")
  os.remove(path)
end

t.run(T)
