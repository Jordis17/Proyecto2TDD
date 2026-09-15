<h1 align="center">
  Proyecto 2 <br>
  EL-3313 Taller de Digitales <br>
  Ahorcado: juego electrónico FPGA / PC por enlace serial
</h1>

<h3 align="center" style="color: #0366d6; letter-spacing: 1px;">
  Equipo de trabajo
</h3>

<p align="center">
  <b>Fallas Fallas Mariana | 2022080686 | mfallas@estudiantec.cr </b>
  <br>
  <b>Garita Serrano Justin | 2022437433 | jugarita@estudiantec.cr </b>
  <br>
  <b>López Méndez Abner | 2022273075 | ablopez@estudiantec.cr </b>
  <br>
  <b>Segura Chinchilla Jordi | 2022240646 | jorsegura@estudiantec.cr </b>
</p>

---

Vídeo para la defensa: https://youtu.be/WKnffdmOIWA

---

# Informe técnico

## Contenido

1. [Introducción](#1-introducción)
2. [Investigación previa](#2-investigación-previa)
3. [Enfoque de la solución](#3-enfoque-de-la-solución)
4. [Interfaces de los módulos](#4-interfaces-de-los-módulos)
5. [Periférico LCD y protocolo UART](#5-periférico-lcd-y-protocolo-uart)
6. [Diagramas de estado](#6-diagramas-de-estado)
7. [Estrategia de validación](#7-estrategia-de-validación)
8. [Resultados de simulación](#8-resultados-de-simulación)
9. [Resultados de síntesis e implementación](#9-resultados-de-síntesis-e-implementación)
10. [Resultados en la tarjeta](#10-resultados-en-la-tarjeta)
11. [Análisis de resultados](#11-análisis-de-resultados)
12. [Problemas encontrados y soluciones](#12-problemas-encontrados-y-soluciones)
13. [Análisis crítico](#13-análisis-crítico)
14. [Conclusiones](#14-conclusiones)
15. [Referencias](#referencias)

---

## 1. Introducción

En este proyecto se implementó el juego del ahorcado en una FPGA Digilent Nexys 4, con una aplicación de Python en la computadora que funciona como terminal del jugador. La FPGA hace todo el trabajo del juego: elige la palabra de un banco guardado en ROM con un LFSR, valida cada letra, lleva el tiempo y los errores y decide el resultado. La PC solo envía la letra por el puerto serie y muestra lo que la FPGA le responde.

El estado del juego se ve también en la tarjeta: la palabra y los intentos en un LCD PmodCLP de 16x2, el tiempo y las victorias en los displays de 7 segmentos, la etapa en los LEDs y cada evento con un tono por la salida de audio.

Para lograrlo se diseñaron dos periféricos con registros de 32 bits (LCD y UART), dos capas de presentación que arman las pantallas y los mensajes, el núcleo del juego y los módulos de entradas y salidas locales. Todo está descrito en SystemVerilog, funciona con un solo reloj de 100 MHz y se sintetizó e implementó en Vivado.

El diseño completo, nivel por nivel, está en [`Docs/Diseño/Diseño.md`](../Diseño/Diseño.md). Este informe resume la teoría que lo sustenta, las decisiones principales, los resultados obtenidos y lo que aprendimos.

---

## 2. Investigación previa

En esta sección se resume lo que investigamos antes de diseñar y cómo cada tema se aplicó en la arquitectura del sistema.

### 2.1 Módulos LCD con controlador HD44780 y su inicialización

El HD44780 recibe los datos en paralelo y usa tres líneas de control: `RS` elige entre instrucción y carácter, `R/W` entre escritura y lectura, y `E` habilita la operación. El dato se captura en el flanco de bajada de `E` [3]. Antes de usar el LCD hay que esperar a que se estabilice la alimentación y enviar la secuencia de inicialización: *Function Set* (bus y número de líneas), *Display On/Off*, *Clear Display* y *Entry Mode Set*. Cada instrucción tarda un tiempo en procesarse, y *Clear Display* y *Return Home* tardan bastante más que las demás. Para escribir en una fila se posiciona el cursor con *Set DDRAM Address* (`0x80` para la fila 0 y `0xC0` para la fila 1).

El controlador tiene una bandera de ocupado que se puede leer, pero para leerla el bus de datos tiene que ser bidireccional. La otra opción es esperar siempre el tiempo del peor caso.

**En nuestra arquitectura.** `lcd_controller` hace la inicialización sola al encender (`0x38`, `0x0C`, `0x01`, `0x06`) y genera cada escritura en cuatro fases: datos estables, `E` en alto, `E` en bajo y espera. Elegimos no leer la bandera de ocupado y dejar `R/W` fijo en 0. Así todas las señales son salidas y no hay que manejar un bus triestado sobre los pines del Pmod. La espera se decide dentro del controlador: la larga para `clear` y `home` y la corta para lo demás. `lcd_screen_ctrl` usa `0x80` y `0xC0` para escribir cada fila completa.

### 2.2 PmodCLP

El PmodCLP es un LCD de 16x2 con un controlador Samsung KS0066, compatible con el HD44780, que se conecta en paralelo por dos conectores: J1 lleva los ocho bits de datos y J2 las señales `RS`, `R/W` y `E` [4]. Su manual indica esperar 20 ms después de encender, 37 µs entre instrucciones normales y 1,52 ms después de *Clear Display*. No especifica el ancho del pulso `E` ni los tiempos de establecimiento de `RS` y de los datos.

**En nuestra arquitectura.** Usamos 50 ms, 60 µs y 2 ms, todos por encima de los mínimos del manual. Los tiempos que el manual no da los fijamos nosotros con margen amplio: 200 ns de establecimiento y 1 µs para `E` en alto y en bajo. Todos son parámetros de `top`. J1 va al conector JA y J2 a la fila inferior del JB, porque al montarlo vimos que J2 no alcanza la fila superior.

### 2.3 Protocolo UART

Una UART envía cada byte de forma asíncrona. En reposo la línea está en alto; un bit de arranque en bajo marca el inicio, siguen los bits de datos empezando por el menos significativo, un bit de paridad opcional y uno o más bits de parada en alto [2]. En el formato 8N1 cada byte ocupa 10 bits.

Como el reloj no se transmite, los dos lados tienen que usar la misma velocidad. En una FPGA se obtiene dividiendo el reloj del sistema. Para ubicar el centro de cada bit, el receptor suele sobremuestrear, por ejemplo 16 veces por bit, a partir del flanco del bit de arranque [2]. El error del divisor se acumula a lo largo de la trama, así que hay que comprobar que en el último bit el punto de muestreo siga dentro del bit.

**En nuestra arquitectura.** A 100 MHz y 115 200 baudios el divisor ideal es 868,06. El transmisor usa 868 y el receptor, que sobremuestrea por 16, usa 54. `uart_core` le pasa esos valores al núcleo VHDL del curso. Calculamos que en el peor caso el muestreo del último bit se corre un 10,2 % de un bit, frente al 50 % disponible. `uart_msg` envía líneas de texto con campos de ancho fijo para que la PC pueda cortarlas por posición.

### 2.4 Periféricos mapeados a memoria con buses de 32 bits

Un periférico mapeado a memoria se controla leyendo y escribiendo registros en direcciones fijas [1]. Cada registro se divide en campos con un tipo de acceso: lectura y escritura (RW), solo lectura (RO), escribir 1 para generar un pulso (W1P) o escribir 1 para limpiar (W1C). Los dos últimos permiten cambiar un campo sin tocar los demás, lo que importa cuando un mismo registro mezcla bits que maneja el hardware con bits que maneja el maestro. La lectura puede ser combinacional o registrada; si es combinacional, el maestro ve el estado en el mismo ciclo en que pone la dirección.

**En nuestra arquitectura.** Los periféricos LCD y UART usan la misma interfaz de 32 bits, con lectura combinacional y reinicio síncrono. En el LCD, `start`, `clear` y `home` son W1P, y `busy` y `done` son RO. `done` queda como bandera hasta la siguiente operación, para que el maestro no se lo pierda. En el UART, `send` solo se puede poner en 1 y `new_rx` se limpia escribiendo 1; así transmitir y recibir no se estorban. Cada periférico tiene un solo maestro, que es su capa de presentación.

### 2.5 ROM sintetizable para bancos de cadenas

Una ROM en HDL se describe como una tabla: un `case` o un arreglo constante indexado por la dirección [2]. Cuando la tabla es pequeña, la herramienta la implementa con LUTs (memoria distribuida). Para guardar cadenas de largo variable en palabras de ancho fijo, cada cadena se rellena hasta el largo máximo y su longitud real se guarda aparte.

**En nuestra arquitectura.** `word_rom` guarda 64 palabras como 12 caracteres ASCII (96 bits) rellenos con espacios, más un campo de 4 bits con la longitud. La tabla está ordenada por dificultad: los índices 0–31 tienen palabras de 6 letras o más y los 32–63 palabras de 4 o 5. Como ese orden es frágil, la ROM se genera con `gen_word_rom.py`, que lo comprueba cada vez. `game_controller` usa la longitud para armar una máscara que ignora las posiciones de relleno.

### 2.6 LFSR para seleccionar un índice

Un LFSR desplaza su contenido y mete por un extremo el XOR de algunos de sus bits (*taps*). Si los taps corresponden a un polinomio primitivo de grado *n*, el registro recorre los 2ⁿ − 1 estados distintos de cero antes de repetirse [1]. La secuencia es determinista, pero se ve aleatoria, y solo cuesta *n* flip-flops y una compuerta XOR. Para usarlo como índice de una tabla se pueden tomar algunos de sus bits.

**En nuestra arquitectura.** `lfsr` es de 8 bits con el polinomio `x^8 + x^6 + x^5 + x^4 + 1` (255 estados) y corre libre desde el arranque. `game_controller` captura su valor al presionar el botón de confirmación, así que la palabra depende del instante de la pulsación. El índice se saca truncando: 5 bits en modo difícil (0–31) y 6 en fácil (0–63). Con la ROM ordenada, el modo difícil nunca puede elegir una palabra corta y no hace falta división ni reintentos.

### 2.7 Temporizadores regresivos y displays multiplexados

Un temporizador regresivo es un contador descendente que avanza con una habilitación periódica y se detiene en cero. En un diseño síncrono, la forma recomendada de ir más lento que el reloj es generar un pulso de habilitación (*tick*) de un ciclo, no dividir el reloj [2]. Un reloj hecho con lógica común no viaja por la red dedicada de distribución y llega a cada registro con retardos distintos.

Para mostrar el tiempo, el valor se separa en dígitos decimales y cada dígito se convierte a segmentos [1]. En la Nexys 4 los dígitos comparten las líneas de segmento [5], así que se encienden de uno en uno. Si el barrido es lo bastante rápido, por encima de unos 60 Hz, el ojo los ve encendidos todo el tiempo [2].

**En nuestra arquitectura.** `clk_tick_gen` genera un tick cada 100 000 ciclos (1 ms) y es la única base de tiempo lenta del sistema. `round_timer` acumula 1000 ticks por segundo y baja desde 60 o 45. Su aviso de fin es un nivel, para que el control lo atienda cuando termine de publicar. `display_controller` cambia de dígito en cada tick: cuatro dígitos dan 250 Hz. Las victorias se guardan en BCD para no tener que dividir.

### 2.8 Debouncing de pulsadores

Una señal que cambia sin relación con el reloj puede violar el tiempo de establecimiento de un flip-flop y dejarlo metaestable. Un sincronizador de dos flip-flops no elimina ese riesgo, pero hace que el tiempo medio entre fallos sea muy grande [1]. Además, los contactos de un pulsador rebotan durante algunos milisegundos. Un filtro de rebotes solo acepta un nivel nuevo si se mantiene estable un tiempo mínimo, y un detector de flanco convierte ese nivel en un pulso de un ciclo [2].

**En nuestra arquitectura.** Cada botón pasa por `button_input`: sincronizador de dos etapas, filtro de 10 ms contado con el tick y detector de flanco. Los botones de selección y confirmación se usan como pulso, para que el modo no cambie sin parar mientras el dedo sigue encima. El de reinicio se usa como nivel, para que el sistema se mantenga reiniciado mientras está presionado.

### 2.9 Conceptos complementarios

- **FSM y FSMD.** Una FSMD es una ruta de datos controlada por una máquina de estados [2]. `game_controller` es una FSMD: la FSM lleva la secuencia de la partida y la ruta de datos guarda la palabra, las posiciones reveladas, las letras usadas, los errores y las victorias. Para no inferir latches, la lógica secuencial (`always_ff`) va separada de la combinacional (`always_comb`) y todos los `case` tienen `default` [1], [2].
- **Salida de audio de la Nexys 4.** La tarjeta no tiene zumbador. Tiene una salida `AUD_PWM` que pasa por un filtro y un amplificador hacia el jack de 3,5 mm, más una señal `AUD_SD` [5]. `buzzer_controller` genera ondas cuadradas invirtiendo la salida cada `CLK_HZ / (2f)` ciclos y deja `AUD_SD` en alto.

---

## 3. Enfoque de la solución

### 3.1 Arquitectura


```
top
├── clk_tick_gen            tick de 1 ms
├── button_input ×3         sincronizador, filtro de rebotes, detector de flanco
├── game_controller         FSM y ruta de datos del juego
│   ├── word_rom            64 palabras
│   ├── lfsr                generador de 8 bits
│   └── round_timer         cuenta regresiva
├── lcd_screen_ctrl  → lcd_peripheral  → lcd_controller  → PmodCLP
├── uart_msg         → uart_peripheral → uart_core       → PC
├── uart_test_block         bloque de pruebas del UART (por parámetro)
├── display_controller
├── led_controller
└── buzzer_controller
```

(En `top` todos los módulos se instancian al mismo nivel; la sangría solo muestra con quién habla cada uno.)

### 3.2 Decisiones de diseño y su justificación

| Decisión | Justificación |
|---|---|
| Un solo reloj y un tick de 1 ms | Todo queda en un dominio y la herramienta analiza todos los caminos. No hacen falta sincronizadores internos. |
| Capas de presentación (`lcd_screen_ctrl`, `uart_msg`) entre el juego y los periféricos | Una pantalla son 34 transacciones y un mensaje hasta 34 bytes. Si eso estuviera en `game_controller`, su FSM tendría varias decenas de estados y mezclaría reglas con texto. Así cada capa se prueba por separado. |
| Un solo maestro por periférico | Evita que dos módulos usen el mismo bus de registros a la vez. Por eso la recepción de letras también está en `uart_msg`. |
| ROM de 64 palabras ordenada por dificultad; índice por truncamiento del LFSR | El modo difícil usa 5 bits (índices 0–31, solo palabras largas) y el fácil 6 bits. Un ciclo, sin división ni reintentos, y el modo difícil nunca puede elegir una palabra corta. |
| LFSR de 8 bits en corrida libre, capturado al confirmar | La palabra depende del instante de la pulsación. Si solo avanzara al empezar la partida, la secuencia de palabras sería igual después de cada encendido. |
| Comparación de la letra contra las 12 posiciones en paralelo | Revela todas las apariciones en un ciclo, sin contador de recorrido. |
| Registro de 26 bits de letras usadas | Detecta repetidas en un ciclo; una repetida no toca errores ni tiempo. |
| Un solo estado de fin con código de dos bits | Los tres desenlaces hacen lo mismo; la diferencia es un dato, no un camino de control. |
| `timeout` como nivel, atendido cuando las capas terminan | No quedan pantallas ni tramas a medias. |
| El temporizador no se detiene al publicar | Detenerlo le regalaría unos milisegundos al jugador en cada letra. |
| Resultado visible 3 s contados desde que termina el dibujado | Así el jugador ve los 3 s completos. |
| `R/W` del LCD fijo en 0 | Leer la bandera de ocupado requiere un bus bidireccional con triestado; esperar por contador es suficiente. |
| `done` del LCD como bandera y no como pulso | Un maestro que consulta el registro podría no ver un pulso de un ciclo. |
| `send` solo se pone en 1 y `new_rx` se limpia escribiendo 1 | Ninguna escritura sobre un bit afecta al otro; transmitir y recibir no se estorban. |
| Envoltura `uart_core` sobre el núcleo VHDL | Las diferencias del núcleo real se resolvieron en un solo módulo. |
| Protocolo de texto con campos de ancho fijo | En RTL solo el patrón y la palabra cambian de largo; en Python se corta por posición. |
| Líneas del LCD escritas completas | No hace falta borrar la pantalla antes de redibujar, así que no hay parpadeo. |
| Redibujar solo cuando algo cambia | Un refresco continuo parpadea y deja el periférico ocupado casi siempre. |
| Un LED por etapa y otro para el modo | Se distingue de un vistazo, sin patrones de parpadeo. |
| Victorias en BCD con saturación en 99 | El display no necesita dividir y el marcador no vuelve a 00. |
| Tiempos como parámetros desde `top` | Los testbenches y la simulación post-implementación usan valores reducidos sin tocar el RTL. |
| Polaridades como parámetros | La lógica interna usa 1 = activo y la polaridad de la tarjeta se aplica en la salida. |
| 60 s en fácil y 45 s en difícil | El modo difícil tiene menos tiempo y los dos valores caben en dos dígitos. |

---

## 4. Interfaces de los módulos

La descripción formal de las entradas y salidas de cada módulo está en el documento de diseño, en los puntos d) y e) de cada módulo del [cuarto nivel](../Diseño/Diseño.md#8-diagrama-de-cuarto-nivel), y la integración en `top` está en el [quinto nivel](../Diseño/Diseño.md#9-quinto-nivel-integración-y-conexiones).

En resumen, todos los módulos trabajan con el reloj de 100 MHz y un reinicio síncrono activo en alto. Los que miden tiempo reciben el tick de 1 ms. `game_controller` se comunica con las capas de presentación mediante un código (`screen_o` o `uart_event_o`), un pulso de disparo y los datos de la partida, y recibe de vuelta su señal de ocupado. Las capas de presentación hablan con sus periféricos por la interfaz estándar de 32 bits (`write_enable`, `addr[1:0]`, `wdata[31:0]`, `rdata[31:0]`).

---

## 5. Periférico LCD y protocolo UART

La definición completa (mapa de registros, bits, tipo de acceso, tramas y semántica) está en la [sección 10 del documento de diseño](../Diseño/Diseño.md#10-interfaces-de-los-periféricos-y-protocolo). Aquí va un resumen.

- **Periférico LCD** ([detalle](../Diseño/Diseño.md#102-periférico-lcd)). Tiene CONTROL/ESTADO en 0x00 (`start`, `rs`, `clear`, `home`, `busy`, `done`) y DATOS en 0x04 (byte en `[7:0]`). Si se piden varias operaciones a la vez, la prioridad es `clear` > `home` > `start`, y lo que llegue con `busy` en 1 se descarta. Una pantalla completa son 34 transacciones.
- **Periférico UART** ([detalle](../Diseño/Diseño.md#103-periférico-uart)). Tiene TX en `00`, RX en `01` y CONTROL en `10`. `send` inicia la transmisión y baja solo al terminar; `new_rx` indica que hay un byte sin leer y se limpia escribiendo 1. Funciona a 115 200 baudios, 8N1.
- **Protocolo** ([detalle](../Diseño/Diseño.md#104-protocolo-de-aplicación)). La PC envía un byte `A`–`Z` y la FPGA descarta cualquier otro valor. La FPGA responde con líneas de ancho fijo terminadas en `\n`: `START:<M>:<LL>`, `PATT:<p>`, `LET:<X>:<R>`, `ERR:<n>` y `END:<E>:<W>`.

---

## 6. Diagramas de estado

La tabla completa de estados y transiciones de cada máquina está en el documento de diseño: [control principal](../Diseño/Diseño.md#86-game_controller), [controlador del LCD](../Diseño/Diseño.md#89-lcd_controller) y [capa de pantallas](../Diseño/Diseño.md#87-lcd_screen_ctrl).

### 6.1 Control principal

![Máquina de estados del control](../Diseño/FIGURAS/Maquina_estados_control.png)

La partida recorre doce estados: selección, carga de la palabra, inicio, juego, evaluación de la letra, publicación, resultado y regreso a la selección. Los estados de espera existen porque las capas de presentación tardan unos milisegundos. Los tres desenlaces comparten un solo estado de fin y se diferencian por un código de dos bits.

### 6.2 Controlador del LCD

La propuesta inicial tenía un estado por cada instrucción de arranque:

![FSM propuesta originalmente para el LCD](../Diseño/FIGURAS/diagramas_lcd_page-0003.jpg)

En la versión final un contador indica qué instrucción de inicialización toca, así que la máquina quedó en siete estados:

```
          50 ms
S_POWERON ─────► S_CARGA ──► S_SETUP ──► S_E_ALTO ──► S_E_BAJO ──► S_ESPERA
                    ▲          200 ns       1 µs         1 µs          │
                    │                                                  │
                    ├──────────── faltan instrucciones de inicio ◄─────┤
                    │                                                  │
                    │  start_i                                         │
                 S_IDLE ◄──────────── inicio terminado ◄───────────────┘
```

---

## 7. Estrategia de validación

La validación se hizo en cuatro etapas:

1. **Simulación funcional por módulo.** Cada módulo con lógica propia tiene un testbench autoverificable: estímulos deterministas, comparación automática con el valor esperado, contador de errores y resumen final de pase o fallo. No se depende de revisar formas de onda a mano.
2. **Simulación de integración.** `tb_top` instancia el sistema completo y solo mira los pines: reconstruye las dos filas del LCD siguiendo el cursor y decodifica la línea serie bit a bit, como lo haría la PC.
3. **Síntesis e implementación en Vivado.** Se revisa que no haya latches, que no haya avisos críticos y que el timing cierre a 100 MHz.
4. **Prueba en la tarjeta,** en un orden que permite ubicar el bloque que falla (LCD primero, luego botones y displays, luego el enlace serie y al final una partida completa).

Los tiempos se reducen por parámetro en simulación (por ejemplo, en `tb_top` el tick es de 20 ciclos en vez de 100 000 y el bit dura 16 ciclos en vez de 868), porque con los valores reales una sola pantalla son millones de ciclos. Los valores reales se comprueban en los testbenches de cada módulo, como `tb_clk_tick_gen` (100 000 ciclos entre pulsos) y `tb_round_timer` (vencimientos de 60 s y 45 s).

`uart_core` instancia las entidades VHDL del curso, así que se valida en Vivado con simulación de lenguaje mixto y en la tarjeta. Para probar las capas de arriba sin el VHDL, los testbenches del UART usan un modelo de comportamiento con la misma interfaz.

La aplicación de PC se prueba con `test_terminal.py`, que juega contra un puerto serie falso.

---

## 8. Resultados de simulación

### 8.1 Pruebas autoverificables

| Testbench | Casos principales | Criterio de pase | Resultado |
|---|---|---|---|
| `tb_clk_tick_gen` | periodo, ancho del pulso, reinicio, primer pulso sin pulsar nada | 100 000 ciclos exactos entre pulsos | PASS |
| `tb_button_input` | pulsación limpia, rebotes al cerrar y abrir, pulsación corta, dos polaridades, tiempo de filtro | 4 pulsaciones = 4 pulsos, adopción entre 9 y 10 ms | PASS |
| `tb_lfsr` | recorrido completo | 255 estados distintos, sin 0x00, vuelve a la semilla | PASS |
| `tb_word_rom` | las 64 entradas | longitudes 4–12, 0–31 con ≥ 6, 32–63 con 4–5, solo A–Z, relleno con espacio | PASS |
| `tb_round_timer` | carga, pausa, recarga, cero, vencimiento | segundos exactos, sin vuelta, `timeout` solo con `run` | PASS |
| `tb_game_controller` | correcta, incorrecta, repetida, victoria, seis errores, vencimiento, vencimiento durante publicación, prioridad, retorno, saturación | cero comprobaciones fallidas | PASS |
| `tb_lcd_controller` | inicialización, tiempos, fases, espera larga/corta, `done`, reinicio, `lcd_rw_o` | cero fallos | PASS |
| `tb_lcd_peripheral` | registros, `start`, `rs`, descarte con `busy`, prioridad, `done`, lecturas en 0 | cero fallos | PASS |
| `tb_lcd_screen_ctrl` | todas las pantallas carácter por carácter, orden ignorada con `busy_o`, datos que cambian a mitad | byte y `rs` correctos en cada paso | PASS |
| `tb_lcd_screen_snapshot` | captura y retención de datos | cero fallos | PASS |
| `tb_lcd_step_decoder` | paso → comando, fila y columna | cero fallos | PASS |
| `tb_lcd_text_gen` | carácter por posición | cero fallos | PASS |
| `tb_uart_peripheral` | registros, independencia de `send` y `new_rx`, llegada simultánea a la limpieza | cero fallos | PASS |
| `tb_uart_msg` | texto exacto de cada evento, orden durante envío, datos que cambian a mitad, filtrado | cero fallos | PASS |
| `tb_uart_test_block` | secuencia A–Z, eco, último byte | cero fallos | PASS |
| `tb_display_controller` | diez dígitos, 10–15, barrido, ánodos, fuera de rango, polaridades | cero fallos | PASS |
| `tb_led_controller` | cuatro estados, exclusión mutua, modo, polaridades | cero fallos | PASS |
| `tb_buzzer_controller` | frecuencias y duraciones, secuencias, solapamiento | cero fallos | PASS |
| `tb_top` | arranque, cambio de modo, inicio, letra correcta, letra incorrecta, seis fallos, retorno, LEDs | cero fallos | PASS |

Mensajes finales de algunos testbenches:

```
tb_lfsr               PASS  255 estados distintos, sin el 0x00, vuelve a la semilla
tb_word_rom           PASS  64 palabras: longitudes, orden por dificultad y relleno correctos
tb_round_timer        PASS  carga, habilitacion, segundo exacto, vencimiento de 60 s y 45 s, sin vuelta
tb_game_controller    PASS  reglas, prioridades, vencimiento diferido y contador correctos
tb_top                PASS  el sistema completo juega, pinta y conversa con la PC
```

> **Evidencia pendiente de agregar:** capturas de la consola de Vivado con el resumen de cada testbench y, al menos, una forma de onda de `tb_top` durante la recepción de una letra.

La aplicación de PC pasa `test_terminal.py`: juega una partida completa contra el puerto falso, trocea correctamente las cinco líneas del protocolo, descarta líneas rotas sin detenerse y nunca envía algo que no sea una letra A–Z.

### 8.2 Simulación post-implementación temporizada

La simulación post-implementación usa el netlist con los retardos de la implementación. Para que sea viable se reducen por parámetro las constantes que la harían demasiado larga (tick, esperas del LCD y duración del resultado) y se cubre, como mínimo, la recepción y validación de una letra: el byte entra por `uart_rx_i`, `uart_msg` lo entrega, `game_controller` lo evalúa y la respuesta sale por `uart_tx_o` y por las patas del LCD.

> **Evidencia pendiente de agregar:** captura de la simulación post-implementación temporizada (*Post-Implementation Timing Simulation*) mostrando la llegada de la letra por `uart_rx_i` y la respuesta `LET:` en `uart_tx_o`, con los parámetros que se usaron.

---

## 9. Resultados de síntesis e implementación

Vivado, dispositivo `xc7a100t` de la Nexys 4, reloj declarado con `create_clock -period 10.000`.

### 9.1 Síntesis

| Métrica | Valor |
|---|---|
| LUTs | 902 de 63 400 (1,42 %) |
| Registros | 632 de 126 800 (0,50 %) |
| Registros inferidos como latch | **0** |
| Errores | 0 |
| Avisos críticos | 0 |
| Avisos | 143 |

Los avisos corresponden a situaciones esperadas:

| Cantidad | Aviso | Motivo |
|---|---|---|
| 100 | `Synth 8-7129` | bits del bus de 32 bits que los periféricos no usan |
| 12 | `Synth 8-3917` | LED3 a LED14 fijos en cero |
| 3 | `Synth 8-3332` | la lógica de `uart_test_block` se elimina con `MODO_PRUEBA_UART = 0` |

### 9.2 Implementación

| Métrica | Valor |
|---|---|
| LUTs después de colocar | 887 (1,40 %) |
| Registros | 632 (0,50 %) |
| Pines | 50 de 210 (23,81 %) |
| WNS (holgura de establecimiento) | **+1,813 ns**, 0 caminos fallando de 1430 |
| WHS (holgura de mantenimiento) | **+0,134 ns**, 0 caminos fallando de 1430 |
| WPWS (ancho de pulso) | +4,500 ns, 0 fallando de 633 |
| Ruteo | 1417 de 1417 conexiones, 0 errores |
| DRC y metodología | sin violaciones |
| Bitstream | 0 errores, 0 avisos |

### 9.3 Recursos por módulo (estimados en el diseño)

| Módulo | Registros |
|---|---:|
| `game_controller` | 185 |
| `uart_msg` (con snapshot) | 149 |
| `buzzer_controller` | 64 |
| `uart_peripheral` | 20 |
| `round_timer` | 17 |
| `clk_tick_gen` | 17 |
| `button_input` (cada uno) | 8 |
| `lfsr` | 8 |
| `display_controller` | 2 |
| `word_rom`, `led_controller` | 0 |

> **Evidencia pendiente de agregar:** capturas del *Utilization Report* y del *Timing Summary* de Vivado.

---

## 10. Resultados en la tarjeta

El sistema completo funciona en la Nexys 4: se juega desde la terminal de Python y el LCD, los displays, los LEDs y el sonido acompañan la partida. Esto comprueba en hardware la integración con el núcleo UART en VHDL, que la simulación con el modelo no puede cubrir.

| Prueba | Resultado observado |
|---|---|
| Arranque sin pulsar nada | aparece la pantalla de selección |
| BTNL | alterna `MODO: FACIL` / `MODO: DIFICIL`; LED15 sigue al modo |
| BTNR | inicia la partida; LED1 se enciende; displays empiezan en 60 o 45 |
| Letra correcta | el LCD revela todas las posiciones; la terminal muestra `OK`; suena el tono agudo |
| Letra incorrecta | bajan los intentos en LCD y terminal; suena el tono grave |
| Letra repetida | la terminal avisa, el LCD no cambia, no se pierde intento |
| Seis errores | `PERDISTE: FALLOS` durante 3 s y regreso a selección |
| Tiempo agotado | `PERDISTE: TIEMPO` durante 3 s y regreso a selección |
| Victoria | `GANASTE!`, sube el contador de victorias en los displays |
| BTNC | vuelve a la selección y las victorias quedan en 00 |
| Entrada inválida en la terminal | se rechaza en la PC sin enviar nada |
| Audio | los tonos se escuchan por el jack de 3,5 mm |

> **Evidencia pendiente de agregar:** fotografías de las pantallas de selección, partida y resultado; foto del montaje del PmodCLP; captura de la terminal durante una partida en cada modo; enlace o fotogramas del vídeo mostrando el límite de tiempo y el de intentos.

---

## 11. Análisis de resultados

### 11.1 Timing

El camino más lento tarda 10 − 1,813 = 8,187 ns, así que el diseño aguantaría un reloj de unos 122 MHz. El margen viene de que casi todo es control sencillo; los caminos más largos son razonablemente los de `game_controller` (doce comparadores de 8 bits, la comparación de máscaras y la suma de errores en un mismo ciclo) y la división entre 10 del display. La holgura de mantenimiento es positiva, que es la que no se arregla bajando la frecuencia. La decisión de comparar las doce posiciones en paralelo, que era la que más preocupaba en cuanto a retardo, cabe con holgura en el ciclo de 10 ns.

### 11.2 Recursos

El diseño usa menos del 1,5 % de las LUTs y 0,5 % de los registros. Los dos bloques más grandes son `game_controller` (la copia de la palabra de 96 bits más los registros de reveladas, usadas y victorias) y `uart_msg`, cuyo snapshot también guarda la palabra. Es decir, la palabra está copiada dos veces (tres, contando el snapshot del LCD). Se aceptó ese costo porque cada capa necesita datos estables mientras trabaja, y en esta FPGA sobra espacio.

La ROM de 64 × 100 bits se implementó en LUTs y no ocupó bloques de memoria, como se esperaba para una tabla de este tamaño.

Que haya 0 latches confirma que todos los `always_comb` asignan todas las salidas en todas las ramas. Los avisos de síntesis se explican por la interfaz de 32 bits (la mayoría de sus bits no se usan) y no indican errores.

### 11.3 Comparación entre valores teóricos, simulados y medidos

| Magnitud | Teórico | Simulado | En tarjeta |
|---|---|---|---|
| Periodo del tick | 100 000 ciclos = 1 ms | 100 000 ciclos exactos | — |
| Tiempo de partida | 60 s / 45 s | vencimiento a los 60 000 y 45 000 ticks | los displays cuentan desde 60 y 45 |
| Filtro de rebotes | 10 ms | adopción entre 9 y 10 ms | botones sin rebotes perceptibles |
| Refresco de displays | 250 Hz | vuelta de 4 ticks | dígitos sin parpadeo visible |
| Velocidad TX | 115 207 baud (−0,006 %) | — | la terminal recibe sin errores |
| Velocidad RX | 115 741 baud (−0,47 %), peor caso 10,2 % de bit | — | las letras llegan sin errores |
| Tonos | 2000 / 2500 / 2999,94 / 800 / 500 Hz | periodo medido en el testbench | tonos distinguibles por el jack |
| Duración del resultado | ≥ 3 s | 3000 ticks después del dibujado | se ve completo |

Las diferencias entre lo teórico y lo implementado vienen de redondear divisores. El único caso que vale la pena mirar es el receptor UART: redondear 54,25 a 54 da un error que se acumula en la trama. El cálculo del peor caso (10,2 % de un bit contra 50 % disponible) explica por qué en la tarjeta no hubo errores de recepción.

En la tarjeta no se midieron frecuencias ni tiempos con instrumentos; la comprobación fue visual y auditiva. Una medición con osciloscopio de `aud_pwm_o` y de `lcd_e_o` sería la forma de confirmar esos valores con números.

### 11.4 Comportamiento del juego

Los resultados muestran que las reglas se cumplen tanto en simulación como en la tarjeta. Las decisiones que más ayudaron fueron:

- **Garantías por construcción.** El modo difícil no puede elegir una palabra corta porque el índice no tiene el bit 5. No hubo que probar un caso de "rechazar palabra corta" porque ese caso no existe; bastó revisar el orden de la ROM.
- **Probar desde los pines.** `tb_top` compara el texto que vería el jugador y la trama que recibiría la PC, así que un error en cualquier nivel de la cadena aparece como un fallo.
- **Vencimiento diferido.** En la prueba de `game_controller` un vencimiento en medio de una publicación termina la trama completa y después resuelve la derrota por tiempo, que es lo que se buscaba.

Sobre el LFSR: como nunca vale cero, el índice 0 sale un poco menos que los demás (1,18 % de las partidas en fácil en vez de 1,56 %). La diferencia no se nota al jugar.

---

## 12. Problemas encontrados y soluciones

| # | Problema | Causa | Solución |
|---|---|---|---|
| 1 | El núcleo UART del curso no expone los parámetros de velocidad en `UART.vhd` | ese archivo solo cablea TX y RX con valores por omisión para 16 MHz | se instanciaron `UART_tx` y `UART_rx` por separado con divisores para 100 MHz |
| 2 | `tx_rdy` no indicaba "libre" | es un pulso de un ciclo al terminar cada byte | la envoltura arma un nivel de ocupado con un biestable |
| 3 | Algunas peticiones de transmisión se perdían y el sistema se quedaba esperando | el núcleo ignora `tx_start` casi un tiempo de bit después de cada byte | la petición se sostiene hasta que el núcleo confirma; el mensaje más largo pasa de ~3 ms a ~4 ms |
| 4 | Riesgo de perder letras o cancelar envíos | una escritura de 32 bits toca `send` y `new_rx` a la vez | `send` solo se pone en 1 y `new_rx` se limpia escribiendo 1 |
| 5 | Riesgo de dar un envío por terminado antes de empezar | el núcleo tarda en levantar su señal de ocupado | estado intermedio `TX_ARRANQUE` en `uart_peripheral` |
| 6 | El aviso de recepción llegaba antes del fin real de la transmisión en la prueba con TX y RX unidos | el receptor muestrea el bit de parada antes de que el transmisor suelte la línea | el fin de cada byte se detecta con `send` |
| 7 | Un maestro podía no ver el fin de una operación del LCD | `done` del controlador es un pulso | el periférico lo guarda como bandera hasta la siguiente operación |
| 8 | La primera pantalla de la partida podía mostrar la palabra anterior | las capas copian los datos en el mismo flanco en que aceptan la orden | `S_CARGA` registra y `S_INICIO` dispara, un ciclo después |
| 9 | Un vencimiento a mitad de una publicación dejaría pantallas o tramas cortadas | el tiempo corre mientras se publica | `timeout` es un nivel y se atiende cuando las capas terminan |
| 10 | El reinicio del botón dependía del tick y el tick del reinicio | dependencia circular | `clk_tick_gen` y `filtro_rst` reciben un 0 fijo y arrancan con valores iniciales del bitstream |
| 11 | El conector J2 del PmodCLP no alcanzaba la fila superior del JB | geometría del Pmod con J1 en el JA | el control del LCD se movió a JB7–JB9 (K16, R16, T9) |
| 12 | No estaba claro cómo manejar la salida de audio | la tarjeta no tiene zumbador, el manual no documenta `AUD_SD` y había duda de si la entrada del filtro era de colector abierto | se probó en la tarjeta: `aud_sd_o` en alto y `aud_pwm_o` como salida normal suenan bien; no hizo falta el Pmod de reserva |
| 13 | Victorias y segundos se leían como un solo número de cuatro cifras | los cuatro dígitos estaban juntos | victorias en AN0–AN1 y segundos en AN4–AN5, uno a cada lado del hueco de la tarjeta |
| 14 | `lcd_screen_ctrl` era difícil de seguir | mezclaba captura de datos, cuenta de pasos, textos y diálogo con el periférico | se separó en `lcd_screen_snapshot`, `lcd_step_decoder`, `lcd_text_gen` y `lcd_screen_pkg`, sin cambiar sus puertos; `uart_msg` se separó igual |
| 15 | El paquete `lcd_screen_pkg` debe compilarse antes que los módulos que lo usan | dependencia de compilación | el paquete se agrega al proyecto de Vivado junto con los demás fuentes |
| 16 | La terminal fallaba con `Access is denied` | otro programa tenía abierto el puerto COM | cerrar el otro programa; el Hardware Manager de Vivado no interfiere |
| 17 | El resultado podía verse menos de 3 s | la cuenta empezaba al entrar al estado, antes de terminar de dibujar | la cuenta empieza en `S_RESULTADO`, después de que las capas terminan |

---

## 13. Análisis crítico

### 13.1 Logros

- Toda la lógica del juego está en la FPGA y la PC es solo terminal.
- El sistema funciona completo en la tarjeta con los dos modos.
- Los dos periféricos tienen interfaz de registros de 32 bits y cada uno tiene un solo maestro.
- El diseño cierra timing con 1,8 ns de margen, sin latches y usando menos del 1,5 % de la FPGA.
- Todos los módulos con lógica tienen testbench autoverificable, y hay una prueba del sistema completo que observa solo los pines.
- Las diferencias del núcleo UART del curso se resolvieron en un solo módulo sin tocar el resto.

### 13.2 Limitaciones

- **Sin FIFO de recepción.** Si el jugador enviara dos letras seguidas sin esperar la respuesta, la segunda podría perderse. La terminal lo evita, pero la FPGA depende de ese control de flujo.
- **Tiempos de `E` del LCD elegidos por el equipo.** El manual del PmodCLP no los especifica; los valores funcionaron, pero no se contrastaron con la hoja de datos del KS0066.
- **No se lee la bandera de ocupado del LCD,** así que cada operación espera el peor caso.
- **Leve sesgo del índice 0** por la ausencia del estado cero en el LFSR.
- **`uart_core` no tiene testbench propio en SystemVerilog puro**; se verifica en Vivado y en la tarjeta. Falta comparar lado a lado, con los mismos estímulos, el modelo de comportamiento y el núcleo real.
- **La simulación post-implementación usa constantes reducidas**, así que no ejercita los tiempos reales del LCD ni del temporizador.
- **Las frecuencias y tiempos en la tarjeta no se midieron con instrumentos.**
- **El marcador satura en 99.**

### 13.3 Mejoras posibles

- Agregar una FIFO pequeña en recepción para no depender de la terminal.
- Medir con osciloscopio `lcd_e_o`, la línea serie y `aud_pwm_o`.
- Correr la misma regresión en Vivado con el núcleo VHDL y con el modelo, y comparar resultados.
- Mostrar también el tiempo restante en el LCD, o una barra de intentos.
- Permitir cargar otro banco de palabras sin regenerar el RTL, por ejemplo con una BRAM inicializada desde archivo.
- Reducir las copias de la palabra compartiendo un solo snapshot entre las dos capas, si en otro diseño los recursos fueran limitados.

---

## 14. Conclusiones

1. Separar las reglas del juego de la presentación fue la decisión que más simplificó el proyecto. `game_controller` quedó en doce estados y las dos capas (`lcd_screen_ctrl` y `uart_msg`) se pudieron probar y modificar sin tocarlo, como se vio al dividirlas en piezas más pequeñas sin cambiar sus puertos.
2. Trabajar con un solo reloj y un tick de 1 ms permitió que Vivado analizara todo el diseño en un dominio; el timing cerró con 1,813 ns de holgura de establecimiento y 0,134 ns de mantenimiento, sin caminos fallando.
3. Resolver requisitos por construcción es más fácil de defender y de probar que resolverlos con lógica de control. Ordenar la ROM y truncar el LFSR hace imposible que el modo difícil elija una palabra corta.
4. Definir con cuidado la semántica de cada bit de un registro evita errores intermitentes. Los bits `send`/`new_rx` independientes y la bandera `done` resolvieron casos que solo aparecen cuando dos eventos coinciden.
5. Aislar un bloque externo detrás de una envoltura contuvo sus sorpresas: las dos diferencias del núcleo UART del curso se resolvieron en `uart_core` sin modificar nada más.
6. Las pruebas autoverificables, sobre todo la del sistema completo que mira solo los pines, dieron confianza antes de programar la tarjeta. Aun así, la integración con el núcleo VHDL y detalles como la geometría del Pmod o la salida de audio solo se pudieron confirmar en el hardware.
7. Hacer las constantes de tiempo parámetros desde el inicio fue lo que volvió viable la simulación de integración y la post-implementación; agregarlas después habría obligado a modificar todos los módulos y testbenches.

---

## Referencias

[1] D. M. Harris y S. L. Harris, *Digital Design and Computer Architecture: RISC-V Edition*. Morgan Kaufmann, 2022.

[2] P. P. Chu, *FPGA Prototyping by SystemVerilog Examples*. Wiley, 2018.

[3] Hitachi Ltd., *HD44780U (LCD-II): Dot Matrix Liquid Crystal Display Controller/Driver*, Rev. 0.0, Hitachi Semiconductor, sep. 1999. [En línea]. Disponible: https://cdn.sparkfun.com/assets/9/5/f/7/b/HD44780.pdf

[4] Digilent Inc., *PmodCLP Reference Manual*. [En línea]. Disponible: https://digilent.com/reference/_media/pmod:pmod:pmodclp_rm.pdf

[5] Digilent Inc., *Nexys 4 Reference Manual*. [En línea]. Disponible: https://digilent.com/reference/programmable-logic/nexys-4/reference-manual

[6] J. González-Gómez y R. Coto Calderón, "Proyecto 2: Ahorcado — Juego electrónico FPGA/PC por enlace serial," EL3313 Taller de Diseño Digital, Escuela de Ingeniería Electrónica, Instituto Tecnológico de Costa Rica, II Semestre 2026.

[7] M. A. Hernández R., "Diseño Modular," Laboratorio de Diseño Lógico, Escuela de Ingeniería Electrónica, Instituto Tecnológico de Costa Rica.
