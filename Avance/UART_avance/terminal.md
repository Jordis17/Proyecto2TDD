## Aplicación de PC

### Objetivo

Proporcionar una interfaz simple para que el jugador pueda enviar letras
a la FPGA y visualizar la información recibida durante la partida.

### Funciones principales

- Solicitar al usuario una letra.
- Validar que la entrada sea un único carácter entre `A` y `Z`.
- Enviar la letra a la FPGA mediante UART.
- Recibir mensajes enviados por la FPGA.
- Mostrar:
  - inicio de partida;
  - estado actualizado de la palabra;
  - resultado de la letra enviada;
  - intentos restantes;
  - resultado final de la partida.

La aplicación no implementa lógica de control del juego.

## Protocolo de comunicación UART

La comunicación operará a 115200 baudios.

### PC → FPGA

La PC enviará un único byte ASCII correspondiente a una letra mayúscula
entre `A` y `Z`.

Ejemplo:

`A` → `0x41`

Cualquier byte que no corresponda a una letra mayúscula será descartado
por la FPGA.

### FPGA → PC

La FPGA enviará mensajes ASCII terminados con salto de línea (`\n`).

Se proponen inicialmente los siguientes tipos de mensaje:

- `START`: inicio de una nueva partida.
- `GUESS`: resultado de una letra recibida.
- `END`: resultado final de la partida.

#### Mensaje `START`

Formato:

`START,<modo>,<longitud>\n`

Donde:

- `<modo>` puede ser `F` para fácil o `D` para difícil.
- `<longitud>` indica la cantidad de caracteres de la palabra secreta.

Ejemplo:

`START,F,7\n`

#### Mensaje `GUESS`

Formato:

`GUESS,<letra>,<resultado>,<patron>,<intentos>\n`

Donde:

- `<letra>`: letra recibida desde la PC.
- `<resultado>`: `HIT` si hubo acierto o `MISS` si fue incorrecta.
- `<patron>`: estado actual de la palabra.
- `<intentos>`: cantidad de intentos fallidos restantes.

Ejemplo:

`GUESS,A,HIT,_A_A__,6\n`

#### Mensaje `END`

Formato:

`END,<resultado>,<causa>\n`

Donde:

- `<resultado>` puede ser `WIN` o `LOSE`.
- `<causa>` puede ser:
  - `NONE` si la partida fue ganada;
  - `TIME` si se agotó el tiempo;
  - `ATTEMPTS` si se alcanzó el máximo de letras incorrectas.

Ejemplos:

`END,WIN,NONE\n`

`END,LOSE,TIME\n`

`END,LOSE,ATTEMPTS\n`

### Resumen del protocolo UART

| Dirección | Mensaje | Formato | Descripción |
|---|---|---|---|
| PC → FPGA | Letra | `<letra>` | Un byte ASCII entre `A` y `Z`. |
| FPGA → PC | `START` | `START,<modo>,<longitud>\n` | Indica el inicio de una nueva partida. |
| FPGA → PC | `GUESS` | `GUESS,<letra>,<resultado>,<patron>,<intentos>\n` | Informa el resultado de una letra y el estado actualizado. |
| FPGA → PC | `END` | `END,<resultado>,<causa>\n` | Informa el resultado final de la partida. |

