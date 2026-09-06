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
