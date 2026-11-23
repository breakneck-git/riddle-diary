-- Путь в интернет без обращений к сети (riddle.net): каналы — списком, у каждого «включён» и «есть связь»
-- через NetworkMgr KOReader (на Kindle: isWifiOn — есть /sys/class/net/wlan0, isConnected — у wlan0 адрес).
local t = require("t")

local function install(mgr)
  package.loaded["ui/network/manager"] = nil
  package.preload["ui/network/manager"] = function() return mgr end
  package.loaded["riddle.net"] = nil
  return require("riddle.net")
end

local T = {}

function T.test_wifi_off_is_off()
  local net = install({ isWifiOn = function() return false end, isConnected = function() return false end })
  t.eq(net.state(), "off")
  -- KOReader на устройстве с выключателем Wi‑Fi без своего isWifiOn отдаёт nil — тоже «не включено»
  net = install({ isWifiOn = function() end, isConnected = function() end })
  t.eq(net.state(), "off")
end

function T.test_wifi_on_without_address_is_down()
  local net = install({ isWifiOn = function() return true end, isConnected = function() return nil end })
  t.eq(net.state(), "down")
end

function T.test_wifi_on_with_address_is_up()
  local net = install({
    isWifiOn = function(self) t.ok(self, "метод, не функция") return true end,
    isConnected = function(self) t.ok(self, "метод, не функция") return true end,
  })
  t.eq(net.state(), "up")
end

-- узнать не удалось — не мешаем запросу: http сам скажет "offline"
function T.test_unusable_networkmgr_is_up()
  local net = install({ isWifiOn = function() error("boom") end, isConnected = function() return false end })
  t.eq(net.state(), "up", "isWifiOn упал")
  net = install({ isWifiOn = function() return true end, isConnected = function() error("boom") end })
  t.eq(net.state(), "up", "isConnected упал")
  net = install({})
  t.eq(net.state(), "up", "методов нет")
  package.loaded["ui/network/manager"] = nil
  package.preload["ui/network/manager"] = function() error("no module") end
  package.loaded["riddle.net"] = nil
  t.eq(require("riddle.net").state(), "up", "модуля нет")
end

-- канал добавляется одной записью: связь по любому — "up", включён хоть один — "down"
function T.test_second_channel_counts()
  local wifi_on, wan_on, wan_up = false, true, false
  local net = install({
    isWifiOn = function() return wifi_on end, isConnected = function() return false end,
    isWanOn = function() return wan_on end, isWanConnected = function() return wan_up end,
  })
  net.CHANNELS[#net.CHANNELS + 1] = { on = "isWanOn", up = "isWanConnected" }
  t.eq(net.state(), "down", "Wi‑Fi выключен, другой канал включён")
  wan_up = true
  t.eq(net.state(), "up")
  wan_on, wan_up = false, false
  t.eq(net.state(), "off", "ни одного включённого")
end

t.run(T)
