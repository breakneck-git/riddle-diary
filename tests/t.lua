-- мини-раннер: t.eq / t.ok / t.run(tbl)
local t = {}

function t.eq(a, b, msg)
  if a ~= b then
    error((msg or "eq") .. ": ожидалось " .. tostring(b) .. ", получено " .. tostring(a), 2)
  end
end

function t.ok(v, msg)
  if not v then error(msg or "ok: ложь", 2) end
end

function t.run(tbl)
  local names = {}
  for name in pairs(tbl) do
    if name:match("^test_") then names[#names + 1] = name end
  end
  table.sort(names)
  local failed = 0
  for _, name in ipairs(names) do
    local ok, err = pcall(tbl[name])
    if ok then
      print("PASS " .. name)
    else
      failed = failed + 1
      print("FAIL " .. name .. ": " .. tostring(err))
    end
  end
  print(string.format("%d tests, %d failed", #names, failed))
  if failed > 0 then os.exit(1) end
end

return t
