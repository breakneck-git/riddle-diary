-- Клиент отпечатков (OpenAI-совместимый /embeddings, Cloudflare Workers AI): тело запроса, пакеты по
-- embed.BATCH, порядок по index, нормировка L2, ошибки без ключа. Поддельный request с журналом.
local t = require("t")
local json = require("dkjson")
local embed = require("riddle.embed")

local URL = "https://api.cloudflare.com/client/v4/accounts/acc123/ai/v1/embeddings"
local MODEL = "@cf/baai/bge-m3"
local KEY = "cfut_secret_KEY_987654"

-- route(body_tbl, n) -> status, body_tbl_or_string | nil, err
local function fake(route)
  local env = { calls = {} }
  env.request = function(method, url, headers, body, timeout_s)
    local call = { method = method, url = url, headers = headers, timeout_s = timeout_s, raw = body,
      body = body and json.decode(body) or nil }
    env.calls[#env.calls + 1] = call
    local status, resp = route(call.body, #env.calls)
    if status == nil then return nil, resp end
    if type(resp) == "table" then resp = json.encode(resp) end
    return status, resp, {}
  end
  env.E = embed.new({ url = URL, model = MODEL, key = KEY, request = env.request })
  return env
end

-- ответ в формате OpenAI: вектор i-го входа — { i, 1 } (до нормировки), usage — по 2 токена на вход
local function ok_reply(body)
  local data = {}
  for i = 1, #body.input do
    data[#data + 1] = { object = "embedding", index = i - 1, embedding = { i, 1 } }
  end
  return 200, { object = "list", data = data, model = body.model,
    usage = { prompt_tokens = 2 * #body.input, total_tokens = 2 * #body.input } }
end

local function near(a, b) return math.abs(a - b) < 1e-9 end

local tests = {}

function tests.test_body_model_and_input()
  local env = fake(ok_reply)
  local vecs, tokens = env.E:vectors({ "первый кусок", "второй" })
  t.ok(vecs, "векторы есть")
  t.eq(#env.calls, 1, "один вызов")
  local c = env.calls[1]
  t.eq(c.method, "POST", "метод")
  t.eq(c.url, URL, "url как в конфиге")
  t.eq(c.headers.Authorization, "Bearer " .. KEY, "ключ в Authorization")
  t.eq(c.headers["Content-Type"], "application/json", "JSON")
  t.eq(c.timeout_s, 20, "таймаут по умолчанию")
  t.eq(c.body.model, MODEL, "model")
  t.eq(type(c.body.input), "table", "input — массив")
  t.eq(#c.body.input, 2, "оба текста")
  t.eq(c.body.input[1], "первый кусок", "порядок входа 1")
  t.eq(c.body.input[2], "второй", "порядок входа 2")
  t.eq(tokens, 4, "токены из usage")
  -- один текст — всё равно массив
  env.E:vectors({ "один" })
  t.ok(env.calls[2].raw:find('"input":%["один"%]'), "один текст — массив из одного")
  -- пустой список — без запроса
  local none, zero = env.E:vectors({})
  t.eq(#none, 0, "пустой список — пустой результат")
  t.eq(zero, 0, "без токенов")
  t.eq(#env.calls, 2, "без вызова API")
end

function tests.test_450_texts_three_calls()
  t.eq(embed.BATCH, 200, "BATCH")
  local env = fake(ok_reply)
  local texts = {}
  for i = 1, 450 do texts[i] = "кусок " .. i end
  local vecs, tokens = env.E:vectors(texts)
  t.ok(vecs, "векторы есть")
  t.eq(#env.calls, 3, "три вызова")
  t.eq(#env.calls[1].body.input, 200, "пакет 1")
  t.eq(#env.calls[2].body.input, 200, "пакет 2")
  t.eq(#env.calls[3].body.input, 50, "пакет 3")
  t.eq(env.calls[2].body.input[1], "кусок 201", "пакет 2 с 201-го")
  t.eq(env.calls[3].body.input[50], "кусок 450", "последний")
  t.eq(#vecs, 450, "450 векторов")
  t.eq(tokens, 900, "токены сложены по пакетам")
  -- вектор j-го входа пакета — { j, 1 } до нормировки: проверяем, что векторы не перепутаны между пакетами
  local v = vecs[201]
  t.ok(near(v[1] / v[2], 1), "201-й — первый во втором пакете")
  v = vecs[450]
  t.ok(near(v[1] / v[2], 50), "450-й — 50-й в третьем пакете")
end

function tests.test_vectors_sorted_by_index_and_normalized()
  local env = fake(function(body)
    return 200, { object = "list", model = MODEL, usage = { prompt_tokens = 7 }, data = {
      { object = "embedding", index = 2, embedding = { 0, 0, 5 } },
      { object = "embedding", index = 0, embedding = { 3, 4, 0 } },
      { object = "embedding", index = 1, embedding = { 0, -2, 0 } },
    } }
  end)
  local vecs, tokens = env.E:vectors({ "а", "б", "в" })
  t.ok(vecs, "векторы есть")
  t.eq(tokens, 7, "токены")
  t.ok(near(vecs[1][1], 0.6) and near(vecs[1][2], 0.8) and near(vecs[1][3], 0), "index 0 первым, норма 1")
  t.ok(near(vecs[2][2], -1), "index 1 вторым")
  t.ok(near(vecs[3][3], 1), "index 2 третьим")
  for k, v in ipairs(vecs) do
    local s = 0
    for _, x in ipairs(v) do s = s + x * x end
    t.ok(near(s, 1), "вектор " .. k .. " нормирован")
  end
end

local function no_key(err, what)
  t.ok(err, what .. ": есть ошибка")
  t.ok(not tostring(err):find(KEY, 1, true), what .. ": ключа нет в err: " .. tostring(err))
  t.ok(not tostring(err):find("secret_KEY", 1, true), what .. ": и куска ключа нет")
end

function tests.test_error_masks_key()
  -- 401 с телом, где эхом ключ
  local env = fake(function() return 401, { success = false,
    errors = { { code = 10000, message = "Authentication error for Bearer " .. KEY } } } end)
  local vecs, err = env.E:vectors({ "а" })
  t.eq(vecs, nil, "401 — nil")
  no_key(err, "401")
  t.ok(err:find("401"), "статус в err: " .. err)
  -- 429 на втором пакете: ошибка, а не неполный результат
  env = fake(function(body, n)
    if n == 2 then return 429, { errors = { { code = 3036, message = "quota " .. KEY } } } end
    return ok_reply(body)
  end)
  local texts = {}
  for i = 1, 250 do texts[i] = "к" .. i end
  vecs, err = env.E:vectors(texts)
  t.eq(vecs, nil, "429 — nil")
  no_key(err, "429")
  t.ok(err:find("429"), "статус в err: " .. err)
  -- ошибка транспорта с ключом в тексте
  env = fake(function() return nil, "connect failed: Authorization: Bearer " .. KEY end)
  vecs, err = env.E:vectors({ "а" })
  t.eq(vecs, nil, "транспорт — nil")
  no_key(err, "транспорт")
  -- 200 с мусором и с неполным data
  env = fake(function() return 200, "<html>" .. KEY end)
  vecs, err = env.E:vectors({ "а" })
  t.eq(vecs, nil, "мусор — nil")
  no_key(err, "мусор")
  env = fake(function() return 200, { data = { { index = 0, embedding = { 1, 0 } } } } end)
  vecs, err = env.E:vectors({ "а", "б" })
  t.eq(vecs, nil, "векторов меньше, чем входов — nil")
  t.ok(err, "ошибка неполного ответа")
end

-- живая форма Cloudflare (замер оркестратора 2026-10-25): usage в ответе нет -> векторы есть, tokens = nil
function tests.test_reply_without_usage_tokens_nil()
  local env = fake(function(body)
    local data = {}
    for i = 1, #body.input do data[i] = { object = "embedding", embedding = { 1, i }, index = i - 1 } end
    return 200, { data = data }
  end)
  local texts = {}
  for i = 1, 201 do texts[i] = "к" .. i end
  local vecs, tokens = env.E:vectors(texts)
  t.ok(vecs, "векторы есть")
  t.eq(#vecs, 201, "все векторы")
  t.eq(tokens, nil, "токенов не знаем — nil, не 0")
  -- usage только у одного пакета из двух — сумма неизвестна
  env = fake(function(body, n)
    local code, reply = ok_reply(body)
    if n == 2 then reply.usage = nil end
    return code, reply
  end)
  vecs, tokens = env.E:vectors(texts)
  t.ok(vecs, "векторы есть")
  t.eq(tokens, nil, "частичный usage — nil")
end

local function reply_with(data)
  return fake(function() return 200, { data = data } end)
end

function tests.test_zero_vector_is_bad()
  local env = reply_with({ { index = 0, embedding = { 0, 0, 0 } } })
  local vecs, err = env.E:vectors({ "а" })
  t.eq(vecs, nil, "нулевой вектор — nil")
  t.eq(err, "bad vector", "err")
end

function tests.test_duplicate_index_is_bad()
  local env = reply_with({ { index = 0, embedding = { 1, 0 } }, { index = 0, embedding = { 0, 1 } } })
  local vecs, err = env.E:vectors({ "а", "б" })
  t.eq(vecs, nil, "дубль index — nil")
  t.eq(err, "bad index", "err")
end

function tests.test_mixed_dimensions_is_bad()
  local env = reply_with({ { index = 0, embedding = { 1, 0 } }, { index = 1, embedding = { 0, 1, 0 } } })
  local vecs, err = env.E:vectors({ "а", "б" })
  t.eq(vecs, nil, "разная размерность — nil")
  t.eq(err, "mixed dimensions", "err")
end

function tests.test_index_out_of_range_is_bad()
  -- index = n сдвинул бы векторы следующих пакетов
  local env = reply_with({ { index = 0, embedding = { 1, 0 } }, { index = 2, embedding = { 0, 1 } } })
  local vecs, err = env.E:vectors({ "а", "б" })
  t.eq(vecs, nil, "index вне диапазона — nil")
  t.eq(err, "bad index", "err")
  env = reply_with({ { index = -1, embedding = { 1, 0 } } })
  vecs, err = env.E:vectors({ "а" })
  t.eq(vecs, nil, "отрицательный index — nil")
  t.eq(err, "bad index", "err")
end

function tests.test_non200_body_text_not_in_err()
  local env = fake(function() return 500, { success = false,
    errors = { { code = 7003, message = "internal detail account acc123" } } } end)
  local vecs, err = env.E:vectors({ "а" })
  t.eq(vecs, nil, "500 — nil")
  t.eq(err, "http 500 cf 7003", "только статус и код")
  env = fake(function() return 502, "<html>Bad gateway detail</html>" end)
  vecs, err = env.E:vectors({ "а" })
  t.eq(err, "http 502", "не-JSON тело — только статус")
end

function tests.test_transport_err_masks_key_literal()
  local env = fake(function() return nil, "ssl failed near " .. KEY .. " end" end)
  local _, err = env.E:vectors({ "а" })
  no_key(err, "ключ без Bearer")
  t.ok(err:find("ssl failed near *** end", 1, true), "остальной текст цел: " .. err)
end

function tests.test_transport_err_masks_bearer_token()
  local env = fake(function() return nil, "proxy said Bearer other_token_123 rejected" end)
  local _, err = env.E:vectors({ "а" })
  t.ok(not err:find("other_token_123", 1, true), "чужой Bearer-токен скрыт: " .. err)
  t.ok(err:find("rejected", 1, true), "остальной текст цел")
end

t.run(tests)
