# Períferico LCD


## Diagrama de primer nivel

### Objetivo

Mostrar la relación general entre el sistema de control del juego y la pantalla LCD, sin entrar en detalles internos.

### Entradas

| Señal | Ancho | Descripción |
|---|---|---|
| `clk_i` | 1 | Reloj del sistema, 100 MHz |
| `rst_i` | 1 | Reinicio |
| `write_enable_i` | 1 | Habilita escritura en los registros |
| `addr_i` | 2 | Dirección del registro (`00` = CONTROL/ESTADO, `01` = DATOS) |
| `wdata_i` | 32 | Dato a escribir |

### Salidas

| Señal | Ancho | Descripción |
|---|---|---|
| `rdata_o` | 32 | Dato leído del registro seleccionado |
| `lcd_rs` | 1 | Selección comando (0) / dato (1) |
| `lcd_rw` | 1 | Atado a 0 permanentemente (solo escritura) |
| `lcd_e` | 1 | Pulso de habilitación del LCD |
| `lcd_data` | 8 | Bus de datos paralelo hacia el LCD |

### Explicación general

![LCD_primer_nivel](LCD_img/diagramas_lcd_page-0001.jpg)

El sistema principal no toca los pines del LCD directamente. En vez de eso, escribe en los registros de este periférico, y el periférico traduce eso a la secuencia de señales físicas que espera el HD44780, respetando sus tiempos de espera internos (que son de microsegundos a milisegundos, mucho más lentos que un ciclo de reloj de 100 MHz).

---

## Diagrama de segundo nivel

### Bloques generales

![LCD_segundo_nivel](LCD_img/diagramas_lcd_page-0002.jpg)

### Interfaz de Registros

- **Objetivo:** decodificar la dirección del bus y guardar lo que el sistema quiere hacer (escribir un carácter, borrar pantalla, etc.).
- **Entradas:** `clk_i`, `rst_i`, `write_enable_i`, `addr_i`, `wdata_i`, y las banderas `busy`/`done` que le manda la FSM.
- **Salidas:** `rdata_o`, y hacia la FSM: el byte a enviar, el valor de `rs`, y pulsos de un ciclo quue indican "hacé start/clear/home".
- **Explicación:** este bloque separa el protocolo del bus de 32 bits de la lógica interna del LCD. Los bits `start`, `clear` y `home` son de tipo "escribir un 1 para generar un pulso" (W1P): se ponen en 1 por un instante y se limpian solos.

### FSM de Control

- **Objetivo:** manejar toda la secuencia de arranque del LCD y la ejecución de cada comando (escritura de carácter, clear, home), respetando los tiempos de espera del HD44780.
- **Entradas:** los comandos de la Interfaz de Registros, y el aviso de "tiempo cumplido" del Temporizador.
- **Salidas:** `lcd_rs`, `lcd_e`, `lcd_data`, las banderas `busy`/`done`, y las señales de control hacia el Temporizador.
- **Explicación:** es el bloque que realmente "sabe" cómo hablarle al LCD. Al encender, hace la secuencia de arranque sin que nadie se lo pida. Después queda esperando comandos, y por cada uno que recibe repite el mismo patrón: preparar el dato, generar el pulso de `E`, y esperar el tiempo que corresponda antes de aceptar el siguiente.

### Temporizador

- **Objetivo:** generar las esperas que pide el HD44780 sin necesitar varios contadores separados.
- **Entradas:** orden de cargar un valor y cuál valor cargar, desde la FSM.
- **Salidas:** aviso de que el tiempo ya pasó.
- **Explicación:** en vez de un contador por cada tiempo distinto (lo cual gastaría más recursos de la FPGA), se usa un solo contador descendente que se puede cargar con distintos valores según lo que pida la FSM en cada momento.

### Explicación general del sistema

Cuando se enciende la FPGA, la FSM arranca sola la secuencia de inicialización del LCD usando el Temporizador para esperar los tiempos correctos. Una vez lista, queda en espera. El sistema del juego escribe un carácter o comando en la Interfaz de Registros, la FSM lo toma, genera la señal física correspondiente en el LCD, espera lo que haga falta, y avisa que terminó. Mientras tanto, el sistema del juego puede consultar el bit `busy` para saber si ya puede mandar la siguiente orden.

---

## Diagrama de tercer nivel

### Bloque: Decodificador de Direcciones y Registros

- **Objetivo:** guardar de forma segura el dato de configuración y responder las lecturas del bus.
- **Entradas:** `clk_i`, `rst_i`, `write_enable_i`, `addr_i`, `wdata_i`, `busy` y `done` de la FSM.
- **Salidas:** `rdata_o`, pulsos `start`/`clear`/`home` (W1P), y los registros `rs` y `data_byte` guardados.
- **Explicación:** solo se usan las direcciones `00` y `01`. Los bits W1P se implementan con un flip-flop que se pone en 1 el mismo ciclo en que se escribe, y se limpia automáticamente al ciclo siguiente (o cuando la FSM lo consume).

### FSM de Control (detallada)

- **Objetivo:** ejecutar paso a paso tanto el arranque como cada operación individual del LCD.
- **Entradas:** pulsos de comando, `rs`, `data_byte`, aviso de tiempo cumplido.
- **Salidas:** `lcd_rs`, `lcd_e`, `lcd_data`, `busy`, `done`, orden de carga del temporizador y qué valor cargar.

**Estados propuestos:**

![LCD_tercer_nivel](LCD_img/diagramas_lcd_page-0003.jpg)

### Explicando la imagen anterior para cada estado

**Bloque 1: la secuencia de arranque (se ejecuta una sola vez, al encender)**

Estos cinco estados corren automáticamente, sin que nadie les pida nada, apenas se enciende la FPGA:

- **POWER_ON_DELAY** — espera 50 ms antes de tocar el LCD. El HD44780 necesita tiempo para estabilizarse eléctricamente después de que le llega la alimentación; si le mandas comandos antes, no responde bien.
- **FUNCTION_SET** — manda el comando `0x38`, que le dice al LCD "vas a trabajar con bus de 8 bits, 2 líneas, letras de 5x8 puntos". Espera 60 µs después de mandarlo.
- **DISPLAY_ONOFF** — manda `0x0C`: enciende la pantalla y apaga el cursor visible. Otros 60 µs de espera.
- **INIT_CLEAR** — manda `0x01` (Clear Display), que borra toda la pantalla y regresa la posición de escritura al inicio. Este tarda más: 2 ms, porque internamente el controlador tiene que limpiar toda su memoria de caracteres.
- **ENTRY_MODE** — manda `0x06`: le dice al LCD que cada vez que reciba un carácter, avance el cursor automáticamente hacia la derecha (y no haga "shift" de toda la pantalla).

Al terminar `ENTRY_MODE`, el LCD ya quedó completamente configurado y listo para usarse.

**IDLE — el estado de reposo**

Aquí es donde la FSM se queda esperando. No hace nada hasta que el resto del sistema (la lógica del juego) le manda una orden escribiendo el bit `start` en el registro de control. Todo el tiempo que la FSM está aquí, el bit `busy` está en 0 — el sistema sabe que puede mandar una nueva operación.

**Bloque 2: escribir un carácter o comando (se repite cada vez que hay algo nuevo que mostrar)**

Cuando llega `start_pulso`, la FSM sale de IDLE y hace esta secuencia:

- **DATA_SETUP** — deja el byte a escribir y la señal `RS` (comando o dato) estables en las líneas antes de mover nada más. Espera 200 ns — es el tiempo de margen que ustedes mismos decidieron poner, porque ni el manual del PmodCLP ni el datasheet del controlador dan ese dato exacto.
- **E_HIGH** — sube el pin `E` (Enable) a 1 durante 1 µs. Mientras `E` está en alto, el dato ya tiene que estar estable en las líneas.
- **E_LOW** — baja `E` a 0, también por 1 µs. Este es el momento clave: el HD44780 captura el dato justo en el flanco de bajada de `E`, o sea, en la transición de este estado.
- **WAIT_POST** — espera el tiempo que el LCD necesita para procesar internamente lo que acaba de recibir: 60 µs si fue un carácter normal, o 2 ms si lo que se mandó fue un `clear` o un `home` (que son comandos más "pesados" para el controlador, igual que `INIT_CLEAR` arriba).

**DONE**

Cuando termina la espera, la FSM llega aquí y activa el bit `done` — le avisa al resto del sistema que la operación ya se completó y que puede revisar el resultado o pedir la siguiente.

**La flecha larga de la derecha**

Esa es la que vuelve de `DONE` a `IDLE`, con la etiqueta "se acepta el próximo start_pulso". No es una transición automática por tiempo (como las otras) — la FSM se queda en `DONE` hasta que el sistema externo manda la siguiente orden (`start_pulso`), y ahí recién regresa a `IDLE` para repetir el ciclo. Es literalmente el mismo camino que ya siguió una vez el flujo de `IDLE → DATA_SETUP → ... → DONE`, solo que dibujado como el retorno del lazo en vez de repetir todos los cuadros de nuevo.


**Pendiente de verificar en el RTL:** los comandos `clear` y `home` que llegan por el registro CONTROL/ESTADO ejecutan la misma instrucción del HD44780 que se usa durante el arranque (`Clear Display` y `Return Home`), así que deberían esperar también el tiempo largo (2 ms), no el corto de 60 µs que se usa para escribir un carácter normal. Hay que asegurarse de que el estado `WAIT_POST` seleccione el valor correcto del temporizador según qué comando se ejecutó.
Se encuentra bajo trabajo para la implementación final de los sistemas.

**Códigos de las instrucciones usadas en el arranque:**

| Instrucción | Código (hex) | Espera después |
|---|---|---|
| Function Set (8 bits, 2 líneas, 5x8) | `0x38` | 60 µs |
| Display On/Off (display on, cursor off) | `0x0C` | 60 µs |
| Clear Display | `0x01` | 2 ms |
| Entry Mode Set (incremento, sin shift) | `0x06` | — |

### Bloque: Temporizador Multiplexado

- **Objetivo:** dar los distintos tiempos de espera usando un solo contador.
- **Entradas:** orden de carga y selección del valor.
- **Salidas:** aviso de tiempo cumplido.
- **Explicación:** con reloj de 100 MHz (ciclos de 10 ns), un contador de 23 bits alcanza para el valor más grande que se necesita (50 ms). Los valores que puede cargar son:

| Selección | Tiempo | Ciclos de reloj |
|---|---|---|
| `00` | 50 ms | 5,000,000 |
| `01` | 2 ms | 200,000 |
| `10` | 60 µs | 6,000 |
| `11` | 1 µs (ancho del pulso E) | 100 |

### Explicación de funcionamiento en conjunto

Al encender, la FSM le pide al Temporizador cargar 50 ms y espera. Cuando el Temporizador avisa que el tiempo se cumplió, la FSM manda las instrucciones de arranque una por una, esperando el tiempo correcto después de cada una. Al terminar, pasa a `IDLE` y baja `busy`.

Cuando el sistema del juego quiere escribir algo, escribe el dato y después el comando `start`. La FSM sube `busy`, arma la señal en `lcd_data`, sube `rs` si corresponde, hace el pulso de `E` (200 ns de margen antes, 1 µs en alto, 1 µs en bajo — el dato se captura en el flanco de bajada), espera el tiempo posterior, y finalmente sube `done` y vuelve a `IDLE`.

---

## Pantallas del LCD

| Pantalla | Línea 0 | Línea 1 |
|---|---|---|
| Selección de modo | `AHORCADO   V:nn` | `MODO: FACIL` / `MODO: DIFICIL` |
| Partida en curso | patrón de la palabra (ej. `A______`) | `INTENTOS: 6   F` (intentos y modo) |
| Resultado | `GANASTE!` / `PERDISTE` | (según se defina) |

Direcciones DDRAM: fila 0 en `0x00` (comando `0x80` para posicionar), fila 1 en `0x40` (comando `0xC0`).

**Cuándo se redibuja la pantalla** (nunca en un lazo continuo, porque eso produciría parpadeo y dejaría `busy` activo casi todo el tiempo):

- Al entrar a la pantalla de selección
- Al cambiar de modo (FACIL/DIFICIL)
- Al iniciar la partida
- Al evaluar una letra que cambia el patrón o los intentos
- Al entrar a la pantalla de resultado
- Al actualizar el contador de partidas ganadas

Los 3 segundos que debe mostrarse el resultado se cuentan desde que termina el redibujado (no desde que se entra al estado), para asegurar que se vean los 3 segundos completos.

---

## Pendientes para la completar la sección

- [ ] Confirmar en el RTL que `clear` y `home` usan el temporizador de 2 ms, no el de 60 µs.
- [ ] Diseñar el banco de pruebas (testbench) autoverificable de este periférico.
- [ ] Simulación post-implementación temporizada, cubriendo al menos una escritura completa de carácter.
- [ ] Verificar con el linter de síntesis que no aparezcan latches no intencionados.

---

## Referencias

## Referencias

[1] Hitachi Ltd., *HD44780U (LCD-II): Dot Matrix Liquid Crystal Display Controller/Driver*, Rev. 0.0, Hitachi Semiconductor, Sep. 1999. [En línea]. Disponible: https://cdn.sparkfun.com/assets/9/5/f/7/b/HD44780.pdf

[2] Digilent Inc., *PmodCLP Reference Manual*, Digilent Inc. [En línea]. Disponible: https://digilent.com/reference/_media/pmod:pmod:pmodclp_rm.pdf

[3] J. González-Gómez y R. Coto Calderón, "Proyecto 2: Ahorcado — Juego electrónico FPGA/PC por enlace serial," EL3313 Taller de Diseño Digital, Escuela de Ingeniería Electrónica, Instituto Tecnológico de Costa Rica, II Semestre 2026.

[4] M. A. Hernández R., "Diseño Modular," Laboratorio de Diseño Lógico, Escuela de Ingeniería Electrónica, Instituto Tecnológico de Costa Rica.
