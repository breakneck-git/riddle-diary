-- Только для Mac: вендорный lua-ljsqlite3 рассчитан на KOReader (ffi.loadlib, ffi/posix_h).
local ffi = require("ffi")
if not ffi.loadlib then
  package.preload["ffi/posix_h"] = function()
    ffi.cdef("void free(void *ptr);")
    return true
  end
  local candidates = {
    "/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib",
    "libsqlite3.dylib",
    "libsqlite3.so.0",
  }
  local env = os.getenv("SQLITE_LIB")
  if env then table.insert(candidates, 1, env) end
  function ffi.loadlib()
    for _, p in ipairs(candidates) do
      local ok, lib = pcall(ffi.load, p)
      if ok then return lib end
    end
    error("libsqlite3 не найдена; задай SQLITE_LIB")
  end
end
