# Nait ZTR Installer

## Что такое ZeroTier?

Это по сути самый дешманский свич TP-Link или D-Link - только виртуальный
В обычный свич воткнули свои домашние железки с помощю пачкорда, задали ip и маску - готово, железки пингуются, видят дрг друга
Когда нужно добавить vps сервера в одну локалку без танцев с бубном, тут поможет ZeroTier

## Nait ZTR Installer

Nait ZTR Installer - это интерактивный инсталлер который поможет поднять сеть ZeroTier

## Как это работает

Один хост будет главный - Это контроллер (оф терминалогия ZeroTier)
там настраивается подсеть
Остальные узлы сети - клиенты

## ZTNCUI

Для простоты управления в инсталлер зашил web-интерфейс ZTNCUI
он как по мне самый адекватны (Я перепробовал все, это больше всего мне понравился)

> (Тут будет скрин интерфейса)

В инсталлере есть интерактивное меню авторизации клиентов в контроллере, если не хотите ставить ZTNCUI, но лучьше поставить, так проще понять что к чему

## Что внутри

Инсталлер self-hosted ZeroTier: Controller, подключение узлов и ZTNCUI (веб-интерфейс).


## Меню

```text
1) Развернуть self-hosted ZeroTier Controller + ZTNCUI (веб-интерфейс)
2) Установить клиент ZeroTier
3) Мастер создания сети ZeroTier (CLI)
4) Подключить узел к сети ZeroTier (CLI)
5) Одобрить узел в сети ZeroTier (CLI)
6) Установить ZTNCUI
7) Статус
8) Выход
```


> Controller не создаёт сеть автоматически. После установки создай сеть через пункт 3 меню или через ZTNCUI.



## Установка

```bash
curl -fL https://github.com/NaitSide/Nait_ZTR_Installer/archive/refs/heads/main.tar.gz -o nait-ztr-installer.tar.gz
tar -xzf nait-ztr-installer.tar.gz
cd Nait_ZTR_Installer-main
chmod +x install.sh
./install.sh
```

Если на урезанном образе Ubuntu нет `curl`, установи его одной командой: `sudo apt-get install -y curl`.



`CLI` означает Command-Line Interface: действие выполняется в SSH-терминале, без веб-панели.

Обычный сценарий: разверни Controller, создай сеть в ZTNCUI, установи ZeroTier на нужном сервере, подключи его по Network ID и одобри в веб-панели.

## Доступ к ZTNCUI

прокинуть SSH тунель (Port Forwarding)

```bash
ssh -p <SSH_PORT> -L 3000:127.0.0.1:3000 <user>@<server>
```

Я юзаю Termius

Забей настройки как на скрине

и в браузере открой 

`http://127.0.0.1:3000`.

Дефолтный логин и пароль: `admin` / `password`.

Сразу измени пароль

Там есть пункт - создать юзера - он неочевидный, лучше создать своего и удалить админа.

> (скрин)

## Обновление ZTNCUI

Для Debian/Ubuntu ZTNCUI распространяется как отдельный DEB-пакет, а не через обычный APT-репозиторий. Открой [официальную страницу ZTNCUI](https://key-networks.com/ztncui/), скачай актуальный DEB-пакет на Controller и установи его:

```bash
sudo apt install ./ztncui_<версия>_amd64.deb
sudo systemctl restart ztncui
```

Перед обновлением сделай backup `/opt/key-networks/ztncui/.env` и `/var/lib/zerotier-one/controller.d`. Не меняй файлы в `controller.d` вручную при запущенном `zerotier-one`.

## Проверка перед запуском

```bash
bash -n install.sh
for file in lib/*.sh; do bash -n "$file"; done
./install.sh help
```

## Используемые проекты

- [ZeroTier One](https://github.com/zerotier/ZeroTierOne)
- [ZTNCUI](https://github.com/key-networks/ztncui)
