-- devtest offline=tcp: кэш IP закрывается и у хостов своих providers из конфига, не только у app.HOSTS.
local t = require("t")

local function stub(name, mod) package.preload[name] = function() return mod end end
stub("device", { screen = {} })
stub("ui/uimanager", {})
stub("logger", { info = function() end, warn = function() end, err = function() end })
stub("ui/time", { monotonic = function() return 0 end })
stub("libs/libkoreader-lfs", {})

local http = { dns_cache = {}, dns_reset = function() end }
package.loaded["riddle.http"] = http
package.loaded["riddle.config"] = { load = function()
  return { providers = { { name = "own", url = "https://own.test/v1/chat/completions", model = "m" },
    { name = "beatapi", url = "https://api.beatapi.io/v1/chat/completions", model = "deepseek-v4.1-flash-free",
      key = "k", after_legacy = true } } }
end }

local app = require("riddle.app")
local devtest = require("riddle.devtest")

local T = {}

function T.test_offline_tcp_blackholes_default_and_own_provider_hosts()
  devtest.simulateOffline("cycles=1 offline=tcp")
  for _, h in ipairs(app.HOSTS) do t.ok(http.dns_cache[h], "хост по умолчанию закрыт: " .. h) end
  t.ok(http.dns_cache["own.test"], "хост своего провайдера закрыт")
  t.ok(http.dns_cache["api.beatapi.io"], "хост BeatAPI закрыт")
end

t.run(T)
