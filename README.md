# wlp-brm

Script para Hyprland que cambia el wallpaper aleatoriamente desde varios repositorios públicos de GitHub. Pensado para Omarchy / Arch Linux con `swww`.

## Qué hace

Al apretar el atajo configurado, descarga un wallpaper aleatorio desde una de estas fuentes:

- [dharmx/walls](https://github.com/dharmx/walls) — 50 categorías (gruvbox, nord, anime, minimal, etc.)
- [DenverCoder1/minimalistic-wallpaper-collection](https://github.com/DenverCoder1/minimalistic-wallpaper-collection) — minimalista y flat art
- [makccr/wallpapers](https://github.com/makccr/wallpapers) — colección 4K curada
- [mylinuxforwork/wallpaper](https://github.com/mylinuxforwork/wallpaper) — wallpapers Linux-friendly

Si una fuente falla, automáticamente prueba con la siguiente.

## Requisitos

- Hyprland con [`swww`](https://github.com/LGFae/swww) corriendo
- `curl`, `jq`, `notify-send` (mako u otro daemon de notificaciones)

## Instalación

```bash
git clone https://github.com/TU-USUARIO/wlp-brm.git
cd wlp-brm
cp next-wallpaper.sh ~/.local/bin/
chmod +x ~/.local/bin/next-wallpaper.sh
```

Asegúrate de que `~/.local/bin` esté en tu `PATH`.

## Configurar atajo en Hyprland

Agregar a `~/.config/hypr/hyprland.conf`:

```
bind = SUPER, B, exec, ~/.local/bin/next-wallpaper.sh
```

Recargar Hyprland:

```bash
hyprctl reload
```

## Configuración

Las variables editables están al inicio del script:

| Variable | Por defecto | Qué hace |
|----------|-------------|----------|
| `WALLPAPER_DIR` | `~/.local/share/wallpapers/fetched` | Dónde se guardan los wallpapers descargados |
| `MAX_STORED` | `20` | Máximo de wallpapers a conservar (los más viejos se borran) |
| `TRANSITION_TYPE` | `grow` | Tipo de transición de swww |
| `TRANSITION_DURATION` | `2` | Duración de la transición en segundos |
| `SOURCES` | las 4 | Fuentes habilitadas (puedes comentar las que no quieras) |

## Estructura

```
wlp-brm/
├── next-wallpaper.sh    # Script principal
├── README.md            # Esto
├── LICENSE              # MIT
└── .gitignore
```

## Limitaciones conocidas

- Las APIs públicas de GitHub tienen un límite de 60 requests por hora sin autenticación. Si lo aprietas mucho, podrías toparte con ese límite temporalmente.
- Requiere conexión a internet en cada ejecución.

## Licencia

MIT. Las imágenes pertenecen a sus respectivos repositorios y autores originales.

## Autostart al iniciar sesión (opcional)

Por defecto el script solo se ejecuta cuando aprietas `Super + B`. Si quieres que al iniciar Hyprland cargue automáticamente el último wallpaper descargado (y solo descargue uno nuevo si la carpeta está vacía), agrega esta línea a `~/.config/hypr/autostart.conf`:

```
exec-once = sh -c 'sleep 2 && f=$(ls -t ~/.local/share/wallpapers/fetched/ 2>/dev/null | head -1); [ -n "$f" ] && swww img "$HOME/.local/share/wallpapers/fetched/$f" --transition-type none || ~/.local/bin/next-wallpaper.sh'
```

Esto evita el fondo negro al iniciar sesión, sin gastar datos descargando un wallpaper nuevo cada vez.
