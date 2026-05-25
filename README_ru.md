<h1 align="center">
  ClashFX
  <br>
</h1>

<h4 align="center">Клиент прокси для macOS на основе правил с расширенным режимом (TUN) — на базе ядра mihomo</h4>

<div align="center">

[English](README.md) | [简体中文](README_zh-CN.md) | [繁體中文](README_zh-TW.md) | [日本語](README_ja.md) | [Русский](README_ru.md)

</div>

---

## ✨ Возможности

- **Расширенный режим (TUN)** — глобальный перехват трафика через TUN-устройство, настройка в один клик
- Поддержка протоколов HTTP/HTTPS и SOCKS
- Маршрутизация на основе правил (домен, IP-CIDR, GeoIP, процесс)
- Поддержка протоколов VMess/VLESS/Trojan/Shadowsocks/Hysteria2
- Безопасность DNS с режимом Fake-IP
- Сетевой стек пользовательского пространства gVisor
- Нативная поддержка Apple Silicon
- Совместимость с macOS 10.14+ (включая macOS 15 Sequoia)

## 📥 Установка

Скачайте со страницы [Releases](https://github.com/Clash-FX/ClashFX/releases).

### 🧪 Канал Lab (опционально)

Хотите получать исправления и экспериментальные функции первыми?
Откройте **Настройки → Debug → Update Channel → Lab (Experimental)**, чтобы подписаться на более частые и ранние релизы.
Сборки Lab менее стабильны, чем обычные релизы — сообщайте о проблемах на GitHub. Можно вернуться к Стабильному в любой момент.

Пользователи Стабильного канала: ничего делать не нужно, вы уже на правильном пути.

## 🔨 Сборка из исходного кода

### Требования

- macOS 10.14 или новее
- Xcode 15.0+
- Python 3
- Golang 1.21+

### Шаги сборки

1. **Установите Golang**
   ```bash
   brew install golang
   ```

2. **Установите зависимости**
   ```bash
   bash install_dependency.sh
   ```

3. **Откройте и соберите**
   ```bash
   open ClashFX.xcworkspace
   # Соберите в Xcode (Cmd+R)
   ```

## ⚙️ Настройка

### Пути по умолчанию

Каталог конфигурации по умолчанию: `$HOME/.config/clashfx`

Имя файла конфигурации по умолчанию: `config.yaml`. Вы можете использовать пользовательские имена конфигураций и переключаться между ними в меню «Конфигурация».

### Расширенный режим

Основная функция ClashFX — глобальный прокси на базе TUN, который перехватывает весь TCP/UDP трафик от всех приложений, а не только от браузеров.

**Как включить:**
1. Строка меню → Расширенный режим → Включить
2. При первом использовании предоставьте права администратора
3. Весь трафик теперь маршрутизируется через ClashFX

### URL-схемы

- **Импорт удалённой конфигурации:**
  ```
  clashfx://install-config?url=http%3A%2F%2Fexample.com&name=example
  clash://install-config?url=http%3A%2F%2Fexample.com&name=example
  ```

- **Перезагрузка текущей конфигурации:**
  ```
  clash://update-config
  ```

## 🤝 Сопутствующий репозиторий: cn-apps-direct

Переключатель **«Bypass Common Chinese Apps» (Расширенный режим → Прямое подключение для китайских приложений)**, добавленный в v1.0.38, загружает список правил `PROCESS-NAME` из **[Clash-FX/cn-apps-direct](https://github.com/Clash-FX/cn-apps-direct)** — небольшого репозитория, поддерживаемого сообществом, со списком имён исполняемых файлов macOS для часто используемых китайских приложений (WeChat, QQ, DingTalk, Feishu, Bilibili и др.). Список автоматически обновляется каждые 24 часа через `rule-provider` и не зависит от цикла релизов ClashFX.

**Хотите добавить приложение или исправить неверное имя процесса?** PR приветствуются — см. [CONTRIBUTING.md](https://github.com/Clash-FX/cn-apps-direct/blob/main/CONTRIBUTING.md). Добавление записи занимает около минуты:

```bash
ls /Applications/<App>.app/Contents/MacOS/   # проверьте реальное имя исполняемого файла
# добавьте проверенное имя в формате: PROCESS-NAME,<name>,DIRECT
# откройте PR
```

## 📄 Лицензия

[AGPL-3.0](LICENSE)

## 🙏 Благодарности

- [mihomo](https://github.com/MetaCubeX/mihomo) — ядро прокси-движка
- [ClashX](https://github.com/bannedbook/ClashX) — оригинальный клиент для macOS
- [Yacd-meta](https://github.com/MetaCubeX/Yacd-meta) — панель управления
