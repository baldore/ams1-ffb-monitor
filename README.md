# AMS 1 FFB monitor

Overlay para Automobilista 1 que lee la consola del plugin RealFeel y muestra
sus valores con etiquetas, siempre la ultima linea, con MAX GAIN (pico
retenido) y botones para mandar los atajos de RealFeel sin teclado numerico
ni Right Ctrl.

Base: MOZA R5. Juego en ventana sin bordes (Config.ini: WindowedMode=1,
WindowBorders=0). RealFeelPlugin.ini con ConsoleEnabled=True.

## Ficheros

| Fichero | Que hace |
|---|---|
| `realfeel-overlay.ps1` | El monitor. Compila `realfeel-overlay.exe` al lado y lo lanza. |
| `pin-realfeel-console.ps1` | Alternativa cruda: fija la consola de RealFeel encima del juego. |
| `tools/fake-realfeel.ps1` | Consola falsa que imprime lineas como RealFeel, para probar sin el juego. |
| `tools/shoot-running.ps1` | Captura el overlay en marcha a PNG, para revisar el layout. |

El `.exe` no se versiona: se reconstruye solo cuando el `.ps1` es mas nuevo.

## Uso

    powershell -NoProfile -ExecutionPolicy Bypass -File realfeel-overlay.ps1

Parametros: `-Corner TopRight|TopLeft|BottomRight|BottomLeft`, `-StartExpanded`,
`-ClipThreshold 100`, `-ClipHoldSeconds 4`, `-PollMs 100`, `-HoldMs 150`,
`-IniPath <RealFeelPlugin.ini>`.

Hay un acceso directo en el escritorio ("AMS 1 FFB monitor") que apunta aqui.

Arrastrar mueve la ventana. Doble clic o `R` resetea el pico. `Esc` cierra.
`FFB controls [+]` despliega los botones.

## Por que un exe

Leer la consola de otro proceso exige `AttachConsole`, y antes `FreeConsole`.
`powershell.exe` muere en cuanto pierde su consola, asi que el overlay se
compila como aplicacion Windows (sin consola). No es por rendimiento.

## Que mide MAX GAIN

`Force (output) / MaxForceAtSteeringRack`, verificado con la aritmetica de la
propia consola. Es la saturacion de la etapa RealFeel, ANTES de `output max`,
`FFB Gain` y Pit House. Un 78% no dice que la base tenga margen; un cambio de
Pit House no mueve este numero. Es la unica etapa que se puede medir desde
fuera; ninguna API de MOZA expone el par real.

Al llegar al umbral (`-ClipThreshold`, 100 por defecto) el pico se congela en
pantalla `-ClipHoldSeconds` segundos y luego se borra, para poder barrer una
vuelta entera y ver todos los puntos donde clipea, no solo el primero. El
contador `clip events` sube en el flanco de subida: un derrape largo cuenta
una vez aunque el hold expire y se rearme por el camino. `samples` es el
numero bruto de muestras en el umbral.

## Botones (mapa de atajos de RealFeel)

    Ctrl + Num 7/8/9   Max force   bajar / invertir / subir
    Ctrl + Num 4/5/6   Damper      bajar / reset / subir
    Ctrl + Num 1/2/3   Mix         -10% / on-off / +10%
    RCtrl + Num 0/.    Smoothing   bajar / subir

Right Ctrl = paso fino, Left Ctrl = paso grueso. Las fuentes se contradicen
en los tamanos de paso del damper, asi que cada boton informa del delta real
que produjo. Invertir, reset y on-off no tienen boton a proposito.

Se inyecta con `SendInput` (RealFeel solo usa `GetKeyState`; `PostMessage`
no sirve). El overlay tiene `WS_EX_NOACTIVATE`, por eso pulsar sus botones no
le quita el foco al juego. Solo envia si AMS esta en primer plano y hay
telemetria (los atajos solo funcionan en pista).

**Sin verificar en el juego real**: que `GetKeyState` dentro del plugin vea la
entrada inyectada. Todo lo demas esta probado contra `tools/fake-realfeel.ps1`.

## Probar sin el juego

    powershell -NoProfile -ExecutionPolicy Bypass -File tools\fake-realfeel.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File realfeel-overlay.ps1 -SelfTest -TestPid <pid del fake>

`-SelfTest` lee cinco muestras, las parsea e imprime, sin construir el exe.

## rotation-watcher.ps1 (rotacion automatica de la MOZA)

Pone el rango de giro de la base al del coche. El valor sale de
`Steering Wheel Range` del `Controller.ini` del PERFIL: es el numero que
calcula el propio juego para el coche actual, ya en grados tope a tope, y lo
reescribe en vivo al cambiar de coche (visto 540 -> 450). El fichero se
reescribe cada pocos segundos con el mismo contenido, asi que se dispara por
CAMBIO DE VALOR, nunca por fecha de modificacion.

Necesita las DLL del SDK de MOZA en `lib\moza\` (no se versionan, sin licencia
en el zip): `MOZA_API_CSharp.dll`, `MOZA_API_C.dll`, `MOZA_SDK.dll`, de
`SDK_CSharp\x64\` dentro de `MOZA_SDK.zip`
(mozaracing.com/pages/sdk -> cdn.gudsen.vip, 54,5 MB).

    setMotorLimitAngle(limitAngle, gameMaximumAngle)
      limitAngle        limite de la base,  90-2000
      gameMaximumAngle  rango del juego,    90-limitAngle

Solo se toca `gameMaximumAngle`; `limitAngle` se deja como este. El ejemplo
oficial de MOZA llama a `setMotorLimitAngle(150,200)`, que viola su propia
restriccion documentada, asi que siempre se relee despues de escribir.

    -Probe     solo lee y muestra los angulos de la base, no escribe
    -DryRun    vigila y registra, sin escribir nunca

    -Restore   devuelve la base a lo que habia antes

El original se guarda una sola vez en `rotation-watcher-state.json` (no se
versiona). `limitAngle` se sube a 2000 al arrancar para que ningun coche se
quede recortado: con la base en 450, un coche de 540 se habria aplicado como
450 sin avisar.

La base pasa por tres estados al conectar: `NODEVICES`, luego `NORMAL` con
ceros, y por fin `NORMAL` con el valor bueno. El estado intermedio miente, asi
que solo se acepta una lectura de 90 grados o mas (el minimo que documenta el
SDK). Tarda unos 3 segundos.
