-- Есть ли путь в интернет, без обращений к сети: NetworkMgr KOReader. Каналы — списком: у каждого
-- метод «включён» и метод «есть связь». На Kindle PW2 канал один — Wi‑Fi: isWifiOn (есть
-- /sys/class/net/wlan0, модуль загружен) и isConnected (wlan0 поднят и у него есть адрес).
local net = {}

-- новый канал (мобильная сеть, Bluetooth) — одной записью: имена методов NetworkMgr
net.CHANNELS = {
  { on = "isWifiOn", up = "isConnected" },
}

-- -> "up" (связь есть хоть по одному каналу), "down" (канал включён, связи нет), "off" (ни один канал
-- не включён). NetworkMgr недоступен или упал — "up": запросу не мешаем, http сам скажет "offline"
function net.state()
  local ok, mgr = pcall(require, "ui/network/manager")
  if not ok or type(mgr) ~= "table" then return "up" end
  local any_on = false
  for _, ch in ipairs(net.CHANNELS) do
    if type(mgr[ch.on]) ~= "function" or type(mgr[ch.up]) ~= "function" then return "up" end
    local ok_on, on = pcall(mgr[ch.on], mgr)
    if not ok_on then return "up" end
    if on then
      any_on = true
      local ok_up, up = pcall(mgr[ch.up], mgr)
      if not ok_up or up then return "up" end
    end
  end
  return any_on and "down" or "off"
end

-- Класс сбоя запроса по тексту его ошибки (http.lua, luasocket и клиенты поверх, у llm — «имя: причина»; регистр не
-- важен): "offline" — нет сети или DNS, "slow" — вышло время (и потолок синхронизации main.lua — «deadline»),
-- "limit" — 429. Иное — nil. Одно правило для фраз дневника (controller) и страницы состояния (status.sync_reason)
local NO_NET = { "offline", "dns:", "network is unreachable", "no route to host" }

function net.fail_kind(err)
  local e = tostring(err):lower()
  for _, s in ipairs(NO_NET) do
    if e:find(s, 1, true) then return "offline" end
  end
  if e:find("timeout$") or e:find("deadline$") then return "slow" end
  if e:find("http 429", 1, true) then return "limit" end
  return nil
end

return net
