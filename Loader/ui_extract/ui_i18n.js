(() => {
  'use strict';
  let lang = 'en';
  const en = {
    'Обновление лоадера':'Loader update', 'Перекачать':'Download again', 'Позже':'Later',
    'Администратор запросил повторную загрузку лоадера. После загрузки он перезапустится.':'The administrator requested a fresh copy of the loader. It will restart after downloading.',
    'Перезапуск лоадера…':'Restarting loader…', 'Не удалось обновить лоадер':'Could not update the loader',
    'Подпись лоадера недействительна или устарела':'The loader signature is invalid or expired',
    'Скачанный лоадер не совпал с подписанной сборкой':'The downloaded loader does not match the signed release',
    'Размер лоадера превышает подписанную сборку':'The loader exceeds the signed release size',
    'Запрос обновления больше не актуален':'The update request is no longer current',
    'Дождитесь окончания запуска или обновления':'Wait for launch or update to finish',
    'Дождитесь окончания обновления лоадера':'Wait for the loader update to finish',
    'Криминальная песочница: грабежи, клановые войны, захват территорий.':'Crime sandbox: robberies, clan wars, and territory control.',
    'Вход выполнен, но сохранить ключ на этом ПК не удалось':'Signed in, but your key could not be saved on this PC',
    'Авторизация':'Sign in', 'Введите ключ, чтобы продолжить':'Enter your key to continue',
    'Свернуть':'Minimize', 'Закрыть':'Close', 'Обновить':'Refresh', 'Проверить заново':'Check again',
    'Подключение…':'Connecting…', 'Сервер в сети':'Server online', 'Сервер недоступен':'Server offline',
    'Подключено':'Connected', 'Нет связи':'Disconnected', 'Ваши игры':'Your games',
    'Нет доступных игр':'No games available', 'Для этого ключа пока не открыто ни одной игры':'No games are available for this key yet',
    'Готовность ПК':'PC status', 'Проверка…':'Checking…', 'Выйти':'Sign out', 'Доступно':'Available',
    'Запустить':'Launch', 'Запущено':'Launched', 'Подготовка':'Preparing', 'Загрузка':'Downloading',
    'Проверка':'Verifying', 'Распаковка':'Extracting', 'Запуск':'Launching', 'Инициализация':'Initializing',
    'Ожидание игры':'Waiting for game', 'Готово':'Ready', 'Введите ключ':'Enter your key',
    'Навсегда':'Lifetime', 'Бессрочный доступ':'Lifetime access', 'Срок действия ключа истёк':'Your license has expired',
    'Меньше часа':'Less than an hour left', 'Запустите ROB RUN — окно можно оставить открытым':'Start ROB RUN — you can leave this window open',
    'Не удалось запустить':'Launch failed', 'Проверка не удалась':'Check failed', 'Данные обновлены':'Updated',
    'Дождитесь окончания запуска':'Wait for the launch to finish', 'ВКЛ':'ON', 'ВЫКЛ':'OFF',
    'Служба запущена':'Service running', 'Служба остановлена':'Service stopped', 'Не установлен':'Not installed',
    'Не удалось определить':'Unknown', 'Работает':'Running', 'Включена, не запущена':'Enabled, not running',
    'Выключена':'Disabled', 'Целостность памяти':'Memory integrity', 'Не работает':'Not running',
    'По реестру':'Registry status', 'Запущен':'Running', 'Не запущен':'Stopped',
    'Защита активна':'Protection active', 'Защита отключена':'Protection disabled',
    'Пассивный режим':'Passive mode', 'Реальная защита':'Real-time protection',
    'Реальная защита выкл.':'Real-time protection off', 'Отключён':'Disabled',
    'В пакете нет файла запуска':'Package executable not found',
    'Не удалось запустить RobRun':'Unable to start RobRun',
    'Отмена инициализации':'Initialization cancelled',
    'Сервер вернул недопустимую длину пакета':'The server returned an invalid packet length',
    'Сервер закрыл канал статуса RobRun':'The server closed the RobRun status pipe',
    'Канал с RobRun закрыт до готовности':'The RobRun pipe closed before becoming ready',
    'Сессия завершена':'Session ended', 'Ключ привязан к другому устройству':'This key is linked to another device',
    'Требуется авторизация':'Sign in required', 'Ключ не найден':'Key not found', 'Недействительный ключ':'Invalid key',
    'Ключ заблокирован':'Key banned', 'HWID не совпадает':'This key is linked to another device',
    'Срок действия ключа истёк':'Your license has expired', 'Ключ истёк':'Your license has expired',
    'Сессия истекла, войдите снова':'Your session expired. Sign in again',
    'Слишком много запросов':'Too many requests', 'Слишком часто, попробуйте позже':'Too many requests. Try again later',
    'Нет доступа к этой игре':'You do not have access to this game',
    'Файлы игры ещё не загружены на сервер':'Game files have not been uploaded yet',
    'Файлы игры ещё не загружены':'Game files have not been uploaded yet',
    'Файл пакета не найден на сервере':'Package not found on the server',
    'Подписанная сборка отсутствует':'Signed release not found', 'Подпись сборки отсутствует':'Release signature not found',
    'Сервер недоступен. Проверьте подключение к интернету':'Server unavailable. Check your internet connection',
    'Не удалось установить защищённое соединение. Проверьте дату и время на компьютере и обновите Windows':'Secure connection failed. Check the date and time on your computer and update Windows',
    'Сервер не отвечает. Возможно, соединение блокируется провайдером, VPN или антивирусом':'The server is not responding. A provider, VPN or antivirus may be blocking the connection',
    'Превышено время ожидания':'The request timed out', 'Игра уже запускается':'The game is already launching',
    'Обновите лоадер: протокол запуска не поддерживается':'Update the loader: unsupported launch protocol',
    'Файл повреждён при загрузке — контрольная сумма не совпала':'Download verification failed: checksum mismatch',
    'В пакете RobRun нет файла запуска':'The RobRun package has no executable',
    'Сервер вернул неподдерживаемый билет запуска':'The server returned an invalid launch ticket',
    'Размер пакета не совпал с подписанной сборкой':'Package size differs from the signed release',
    'Соединение прервано во время загрузки':'The connection was interrupted during download',
    'Пакет превышает подписанный размер':'Package exceeds its signed size',
    'Загрузка не завершена — соединение оборвалось':'Download incomplete: connection interrupted',
    'Архив содержит недопустимые пути':'The archive contains invalid paths', 'Некорректный путь файла запуска':'Invalid executable path',
    'Для RobRun нужен исполняемый EXE-файл':'RobRun requires an EXE file',
    'В лоадере отсутствует ключ проверки обновлений':'The loader has no release verification key',
    'Подпись сборки недействительна или устарела. Обновите лоадер или обратитесь в поддержку.':'The release signature is invalid or expired. Update the loader or contact support.',
    'Сервер не предоставил контрольную сумму сборки':'The server did not provide a release checksum',
    'Некорректная контрольная сумма сборки':'Invalid release checksum',
    'Не удалось определить пользователя Windows':'Unable to determine the Windows user',
    'Время ожидания игры истекло. Запустите игру и повторите запуск':'Timed out waiting for the game. Start the game and try again',
    'RobRun не подключился к лоадеру за отведённое время':'RobRun did not connect to the loader in time',
    'Проверка процесса RobRun не пройдена':'RobRun process verification failed',
    'Не удалось передать параметры запуска RobRun':'Unable to send RobRun launch parameters',
    'RobRun не подтвердил инициализацию за отведённое время':'RobRun did not confirm initialization in time',
    'RobRun прислал неизвестное состояние':'RobRun returned an unknown status',
    'RobRun прислал недопустимый пакет состояния':'RobRun returned an invalid status packet',
    'RobRun прислал некорректное состояние':'RobRun returned an invalid status',
    'Ошибка инициализации RobRun':'RobRun initialization failed',
    'RobRun завершился до готовности':'RobRun exited before becoming ready',
    'Не удалось получить процесс RobRun':'Unable to open the RobRun process',
    'Запускайте RobRun через Loader.':'Start RobRun through Loader.',
    'Разрешение на запуск недействительно. Запустите заново из лоадера.':'Launch permission is invalid. Launch again through Loader.',
    'Не удалось проверить запуск на сервере. Проверьте подключение.':'Unable to verify launch permission. Check your connection.',
    'Не удалось загрузить настройки с сервера. Повторите запуск.':'Unable to load server settings. Try launching again.',
    'МБ':'MB', 'МБ/с':'MB/s',
  };
  function t(value) {
    value = String(value ?? '');
    if (lang === 'ru' || !value) return value;
    if (Object.hasOwn(en, value)) return en[value];
    for (const [ru, english] of Object.entries(en)) {
      if (value.startsWith(ru + ': ') || value.startsWith(ru + ' (')) return english + value.slice(ru.length);
    }
    return value;
  }
  function apply(root = document) {
    root.querySelectorAll('[data-i18n]').forEach(el => { el.textContent = t(el.dataset.i18n); });
    root.querySelectorAll('[data-i18n-title]').forEach(el => {
      el.title = t(el.dataset.i18nTitle); el.setAttribute('aria-label', el.title);
    });
  }
  window.i18n = { t, apply, get lang() { return lang; }, setLanguage(next) {
    lang = next === 'ru' ? 'ru' : 'en';
    document.documentElement.lang = lang;
    apply(); document.querySelectorAll('template').forEach(el => apply(el.content));
    document.querySelectorAll('[data-language]').forEach(el => {
      el.textContent = lang.toUpperCase();
      el.title = el.ariaLabel = lang === 'en' ? 'Switch to Russian' : 'Переключить на английский';
    });
    window.dispatchEvent(new Event('languagechange'));
  }};
})();
