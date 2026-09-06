# Nait ZTR Installer

Нужно добавить VPS и домашние устройства в одну локалку? Этот инсталлер поможет развернуть свою ZeroTier-сеть и управлять ей через веб-интерфейс.

## Установка

```bash
cd ~ && curl -L \
-o nait-ztr-installer.tar.gz \
https://api.github.com/repos/NaitSide/Nait_ZTR_Installer/tarball/main \
&& rm -rf Nait_ZTR_Installer \
&& mkdir Nait_ZTR_Installer \
&& tar -xzf nait-ztr-installer.tar.gz -C Nait_ZTR_Installer --strip-components=1 \
&& cd Nait_ZTR_Installer \
&& chmod +x install.sh \
&& ./install.sh
```

> Сеть не создаётся автоматически. 
> После установки создай сеть через пункт 3 в меню
> или через вебморду ZTNCUI

## Что такое ZeroTier?

Это по сути самый дешманский свич TP-Link или D-Link - только виртуальный.
В обычный свич воткнули свои домашние железки с помощю пачкорда, задали ip и маску - готово, железки пингуются, видят дрг друга.
Когда нужно добавить vps сервера в одну локалку без танцев с бубном, тут поможет ZeroTier

## Nait ZTR Installer

Nait ZTR Installer - это интерактивный инсталлер который поможет поднять сеть ZeroTier.

## Как это работает

Один хост будет главный - Это контроллер (оф терминалогия ZeroTier)
там настраивается подсеть
Остальные узлы сети - клиенты

## ZTNCUI

Для простоты управления в инсталлер зашил web-интерфейс ZTNCUI
он как по мне самый адекватны (Я перепробовал все, это больше всего мне понравился)

> (Тут будет скрин интерфейса)

В инсталлере есть интерактивное меню авторизации клиентов в контроллере, если не хотите ставить ZTNCUI, но лучьше поставить, так проще понять что к чему



## Меню

![Меню Nait ZTR Installer](img/Nait-ZTR-Installer-menu.png)


## Доступ к ZTNCUI

Нужно прокинуть SSH тунель (Port Forwarding)
Через Termius это делается так:

![Настройка SSH Port Forwarding в Termius](img/SSH-port-forwarding.png)

и в браузере открой: `http://127.0.0.1:3000`

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
