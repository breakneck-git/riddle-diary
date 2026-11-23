-- Запись файла целиком или никак — общая для писателей на FAT (карта, итог синхронизации). Без зависимостей.
local file = {}

-- path <- s whole; a failed open, write or close (a full FAT disk) -> nil, err.
-- open: io.open by default (tests and main.lua pass their own)
function file.write(path, s, open)
  local f, err = (open or io.open)(path, "wb")
  if not f then return nil, err end
  local ok, werr = f:write(s)
  local cok, cerr = f:close()
  if not ok then return nil, werr end
  if not cok then return nil, cerr end
  return true
end

-- path <- s through path..".tmp" and rename: a failed write leaves the old file untouched, the .tmp is not renamed.
-- o (optional): write(path, s) -> true | nil, err; open (for the default write); rename(a, b) -> true | nil, err
function file.write_atomic(path, s, o)
  o = o or {}
  local tmp = path .. ".tmp"
  local ok, err
  if o.write then
    ok, err = o.write(tmp, s)
  else
    ok, err = file.write(tmp, s, o.open)
  end
  if not ok then return nil, err end
  return (o.rename or os.rename)(tmp, path)
end

return file
