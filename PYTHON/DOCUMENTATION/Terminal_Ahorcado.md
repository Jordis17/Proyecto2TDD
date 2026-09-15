# Cómo funciona `ahorcado_terminal.py`

## Qué es y para qué sirve

Este programa es el lado **PC** del enlace serie; el lado **FPGA** es el periférico UART del proyecto. No implementa ninguna regla del juego: el banco de palabras, la lógica de aciertos/fallos y el límite de tiempo viven en la FPGA. Lo único que hace esta terminal es:

1. Traducir la letra que escribe la persona a un byte y mandarlo por el puerto serie.
2. Traducir las líneas de texto que manda la FPGA a algo legible en pantalla.

Vale la pena tener clara esta separación desde el inicio: la PC es solo el teclado y la pantalla que la FPGA no tiene, no toma ninguna decisión del juego. Si el juego corriera parcialmente en la PC no tendría sentido el proyecto, porque la idea es que la lógica esté en hardware.

## El protocolo de comunicación serie

**PC → FPGA:** un solo byte por turno, una letra ASCII de la `A` a la `Z`.

**FPGA → PC:** líneas de texto terminadas en `\n`, con campos de **ancho fijo**:

| Línea | Formato exacto | Largo total | Campos |
|---|---|---|---|
| `START` | `START:<M>:<LL>` | 10 | `M` = `F`/`D` (modo), `LL` = longitud en 2 dígitos |
| `PATT` | `PATT:<p>` | variable | `p` = patrón con `_` en lo oculto |
| `LET` | `LET:<X>:<R>` | 9 | `X` = letra jugada, `R` = `OK `/`NO `/`RPT` |
| `ERR` | `ERR:<n>` | 5 | `n` = un dígito, intentos restantes |
| `END` | `END:<E>:<W>` | variable, >8 | `E` = `WIN`/`LER`/`LTO`, `W` = palabra completa |

¿Por qué ancho fijo y no expresiones regulares? Porque la FPGA arma los mensajes con lógica de registros y temporizadores fijos, no con un motor de texto. Es mucho más barato, en lógica y en tiempo de diseño, generar campos de ancho constante que una gramática variable. Del lado de Python, `parsear()` aprovecha justo eso: primero valida el largo exacto de la línea y solo después corta por posición (`linea[6]`, `linea[8:10]`, etc.), sin necesitar nada más complicado.

## Arquitectura general

![Diagrama general de la terminal del jugador](FIGURAS/diagrama_general_terminal_ahorcado.png)

El diagrama general divide el programa en seis bloques. Así se relaciona cada uno con el código real:

| Bloque del diagrama | Función/objeto real | Qué hace |
|---|---|---|
| `main` | `main()` (líneas 362–429) | Lee opciones de línea de comandos, abre el puerto serie, crea la cola y el `Event`, arranca el hilo lector, llama a `jugar()` |
| `lector` | `lector()` (líneas 134–180) | Hilo aparte; lee bytes del puerto, arma líneas por posición del `\n` |
| `Cola` | `queue.Queue()` | Bandeja FIFO thread-safe entre `lector` y `jugar` |
| `Interpretar` | `parsear()` (líneas 75–128) | Convierte una línea de texto en `(tipo, datos)` o `None` |
| `Estado` | clase `Estado` (líneas 186–213) | Guarda el último patrón, intentos y última letra jugada |
| `jugar` | `jugar()` (líneas 267–358) | Ciclo principal: alterna entre vaciar la cola y pedir letra |
| `pedir_letra` | `pedir_letra()` (líneas 219–263) | Pregunta y valida la letra en un bucle |

Un aspecto importante del diseño es que el flujo de datos es unidireccional en cada sentido. Los bytes que llegan del puerto solo pueden entrar al programa por `lector`, y solo pueden salir hacia el puerto desde `jugar` (después de pasar por `pedir_letra`). No hay ningún otro punto de acceso al objeto `puerto`: un hilo solo lee (`puerto.read`) y el otro solo escribe (`puerto.write`), un hilo realiza únicamente lecturas y el otro únicamente escrituras, evitando accesos concurrentes sobre el puerto serie.

## Recorriendo el hilo lector (columna derecha del segundo diagrama)

![Diagrama de flujo del hilo principal y del hilo lector](FIGURAS/diagrama_flujol_terminal_ahorcado.png)

El recorrido del hilo lector es el siguiente:

1. **Leer los bytes que haya** → `puerto.read(puerto.in_waiting or 1)` (línea 152). El `or 1` evita un ciclo vacío cuando no hay nada esperando: siempre se intenta leer al menos un byte, y el `timeout=0.2` del puerto (línea 400) evita que esa lectura se quede bloqueada para siempre si no llega nada.
2. **¿Se desconectó?** → el `try/except` (líneas 149–157) captura cualquier excepción de `read` (cable desconectado, puerto cerrado) y mete `("desconectado", ...)` en la cola, terminando el hilo con `return`.
3. **¿Llegó un salto de línea (`0x0A`)?** → línea 160. Si no, el byte se acumula en `buffer` (línea 175), salvo que sea un retorno de carro `0x0D`, que se ignora (línea 172). Esto es lo que permite que el programa funcione igual si la FPGA manda `\r\n` o solo `\n`.
4. **Cerrar la línea armada** → `buffer.decode(...)` y `buffer.clear()` (líneas 163–164).
5. **¿Es `END` y el jugador está escribiendo?** → línea 165, usando `esperando_letra.is_set()`. Si es cierto, se imprime el aviso inmediato (líneas 169–170) **antes** de tocar la cola.
6. **Meter la línea en la cola** → línea 171. Esto pasa siempre, haya habido aviso inmediato o no.

Hay una guarda extra que no aparece explícita en el diagrama: si el `buffer` supera 80 caracteres sin cerrar (línea 176), se descarta por completo. Es la protección contra ruido en la línea serie que nunca manda un `\n` — sin esta verificación, un byte perdido podría impedir el cierre de la línea y provocar que el búfer creciera indefinidamente.

## Recorriendo el hilo principal (columna izquierda del segundo diagrama)

1. **Leer opciones / abrir puerto / arrancar hilo lector** → `main()`, líneas 373–416.
2. **Sacar una línea de la cola y traducirla** → `tipo, datos = cola.get()` seguido de `parsear(datos["texto"])` (líneas 284–290).
3. **Actualizar y mostrar el estado** → el bloque `if/elif` por `clase` (líneas 298–338) actualiza los campos de `estado`; pero el llamado real a `estado.mostrar()` solo pasa para los eventos `"letra"` con resultado `RPT` (línea 318) y para `"intentos"` (línea 327), que es el último dato de una jugada normal. Los eventos `"inicio"` y `"fin"` imprimen su propio mensaje aparte, no usan `estado.mostrar()`.
4. **¿Sigue habiendo líneas en la cola, o aún no es turno?** → condición del `while` externo, `while not turno or not cola.empty()` (línea 283).
5. **Preguntar la letra** → `pedir_letra(esperando_letra)` (línea 341).
6. **¿Escribió "salir"?** → en el diagrama esta pregunta agrupa dos caminos del código: escribir literalmente `salir` (línea 244) y presionar `Ctrl+D`/`Ctrl+C` durante el `input()` (líneas 232–234, `EOFError`/`KeyboardInterrupt`). Ambos casos devuelven `None` desde `pedir_letra`, y `jugar()` los trata exactamente igual (línea 342).
7. **¿Llegó un fin de partida mientras escribía?** → esta es la condición `if not cola.empty() or not en_partida` (línea 349). Ojo con esto, lo explico mejor abajo porque el diagrama lo simplifica un poco.
8. **Enviar la letra** → `puerto.write(letra.encode("ascii"))` (línea 354), dentro de su propio `try/except` por si el puerto se cae justo en ese instante.
9. **Volver al inicio del ciclo** → `turno = False` (líneas 350 y 358) antes de volver a evaluar la cola.

## Decisiones de diseño y su justificación

Estas son las decisiones de diseño más importantes y la razón de cada una.

- **Un hilo aparte para leer (`threading.Thread`, líneas 413–416):** el límite de tiempo corre en la FPGA, no en la PC. Si la lectura fuera síncrona (leer solo entre pregunta y pregunta), un `END` por tiempo agotado no se vería hasta que el jugador terminara de escribir, el aviso llegaría demasiado tarde. Por eso el hilo lector permanece escuchando continuamente el puerto serie.
- **`queue.Queue` como frontera entre hilos:** es la estructura estándar de Python para comunicación productor-consumidor thread-safe. Usarla evita tener que programar candados (`locks`) a mano y arriesgarse a un error de sincronización.
- **`threading.Event` (`esperando_letra`):** es la señal mínima que necesita el hilo lector para saber si vale la pena avisar de inmediato. Se marca justo antes del `input()` (línea 229) y se limpia en un `finally` (líneas 236–238), para que quede en `False` sin importar por qué camino se salió de la espera (letra válida, `salir`, o `Ctrl+C`).
- **Descartar en vez de fallar ante una línea rara (`parsear()` devuelve `None`):** el enlace serie puede tener ruido o desincronizarse un byte durante la comunicación serie. Es preferible perder una línea y avisar en pantalla (línea 293) que dejar que todo el programa termine de forma inesperada por un mensaje inválido.
- **`daemon=True` en el hilo lector (línea 415):** así, si el hilo principal termina, el proceso completo puede cerrar sin quedar colgado esperando a que el hilo lector también termine por su cuenta.
- **`timeout=0.2` al abrir el puerto (línea 400):** sin esto, `puerto.read()` podría bloquear indefinidamente si la FPGA deja de mandar datos, y el hilo lector nunca podría revisar si el puerto sigue vivo.
- **Descartar la letra si ya no hay partida activa (línea 349):** enviar un byte cuando la partida ya terminó (o cuando ni siquiera ha empezado) no sirve de nada del lado FPGA; es más limpio no mandarlo que confiar en que el hardware lo ignore solo.
- **Validación estricta A–Z sin tildes ni Ñ (líneas 253–261):** el banco de palabras de la FPGA solo usa ese alfabeto (esto se ve también en `gen_word_rom.py`). Mandar un byte fuera de rango se descartaría en silencio del lado hardware, así que es mejor detectarlo en la PC y pedirle al jugador que corrija ahí mismo.

## En resumen

`ahorcado_terminal.py` es intencionalmente delgado: no toma ninguna decisión de juego, solo traduce en los dos sentidos aprovechando que el protocolo es de ancho fijo, y usa un hilo separado exclusivamente para no perder avisos de tiempo agotado mientras el jugador está escribiendo.
