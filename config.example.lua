-- Образец /mnt/us/riddle/config.lua. Настоящий файл в git не кладём:
-- его на устройство пишет tools/push_config.sh: ключи — из ~/.envs, слово и подсказки печати —
-- из файла печати (RIDDLE_SEAL, по умолчанию ~/.config/riddle-diary/seal.lua: поля password_variants
-- и hints, как ниже).
return {
  gemini_key = "your_token_here",

  -- свои провайдеры: любой OpenAI-совместимый сервер (BeatAPI, Groq, LiteLLM, OpenAI, DeepSeek, Mistral
  -- и т. п.) строкой, без отдельной логики. Идут первыми, по порядку списка, затем
  -- gemini_key / gemini_keys; с after_legacy = true — после них (запасные). url — полный адрес …/chat/completions, только https.
  -- key можно не задавать (сервер без ключа) — тогда без заголовка Authorization. Запись без url
  -- или model, с пустым ключом или заглушкой пропускается. Дневник шлёт в модель картинку рукописи:
  -- модель обязана понимать изображения. tools/push_config.sh это поле не пишет — править
  -- /mnt/us/riddle/config.lua на устройстве.
  providers = {
    { name = "groq", url = "https://api.groq.com/openai/v1/chat/completions", model = "qwen/qwen3.8-27b",
      key = "your_token_here", after_legacy = true,
      max_input_chars = 10000 }, -- лимит знаков запроса: срезаются знание, затем лор; по умолчанию — полный
    { name = "beatapi", url = "https://api.beatapi.io/v1/chat/completions",
      model = "deepseek-v4.1-flash-free", key = "your_token_here", after_legacy = true,
      max_tokens = 400 }, -- потолок ответа; по умолчанию 200
  },

  -- заветное слово и его допустимые написания (регистр не важен)
  password_variants = { "your_word_here" },

  -- подсказки печати: по кругу, в порядке списка; строки стиха — через \n; пусто — без подсказок
  hints = {
    "Первая строка подсказки,\nвторая строка подсказки.",
  },

  -- каждая N-я неудачная разобранная попытка получает подсказку
  hint_every = 3,

  -- название или id базы задач; по умолчанию дневник ищет сам. tools/push_config.sh пишет его из
  -- RIDDLE_TASKS_SOURCE.
  -- tasks_source = "Мои задачи",

  -- чей это дневник — персонаж и, лучше, его мир; по строке дневник один раз генерирует персону и дальше говорит
  -- её голосом. Строка «Методов» — встроенная персона без генерации. tools/push_config.sh пишет его из RIDDLE_WHOSE
  -- (по умолчанию — строка «Методов»).
  -- whose = "Гермиона Грейнджер из «Гарри Поттера»",

  -- значения свойства знания, при которых документ пройден (фильм просмотрен, книга прочитана): совет такого
  -- вызывает один повтор запроса. Нет или пусто — сверка выключена. tools/push_config.sh пишет «Просмотрено»,
  -- «Прочитано».
  -- watched_values = { "Просмотрено", "Прочитано" },
}
