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

Каталог конфигурации по умолчанию: `$HOME/.config/clash`

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

## 📄 Лицензия

[AGPL-3.0](LICENSE)

## 🙏 Благодарности

- [mihomo](https://github.com/MetaCubeX/mihomo) — ядро прокси-движка
- [ClashX](https://github.com/bannedbook/ClashX) — оригинальный клиент для macOS
- [Yacd-meta](https://github.com/MetaCubeX/Yacd-meta) — панель управления
