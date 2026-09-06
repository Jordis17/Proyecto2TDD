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

imagen 1

El sistema principal no toca los pines del LCD directamente. En vez de eso, escribe en los registros de este periférico, y el periférico traduce eso a la secuencia de señales físicas que espera el HD44780, respetando sus tiempos de espera internos (que son de microsegundos a milisegundos, mucho más lentos que un ciclo de reloj de 100 MHz).

---
