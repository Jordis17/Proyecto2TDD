## Subsistema UART

### Objetivo
Implementar la comunicación bidireccional entre la FPGA y la aplicación
de PC mediante UART a 115200 baudios.

El subsistema recibe desde la PC una letra ASCII entre A-Z y la entrega
al núcleo del juego. En sentido contrario, recibe información del estado
de la partida desde el núcleo del juego y la transmite hacia la PC.

### Entradas

- `clk_i`: reloj global del sistema de 100 MHz.
- `uart_rx_i`: señal serial proveniente de la PC.
- Información de estado proveniente del núcleo del juego:
  - inicio de partida;
  - resultado de la letra;
  - patrón actualizado de la palabra;
  - intentos restantes;
  - resultado final.

### Salidas

- `uart_tx_o`: señal serial hacia la PC.
- Letra recibida y validada hacia el núcleo del juego.
- Indicación de disponibilidad de una nueva letra válida.

### Explicación general

El subsistema UART actúa como interfaz de comunicación entre el núcleo
del juego y la aplicación ejecutada en la PC.

En recepción, el subsistema recibe por `uart_rx_i` un carácter enviado
desde la PC. Si el dato corresponde a una letra ASCII válida entre `A`
y `Z`, se entrega al núcleo del juego junto con una indicación de nueva
letra disponible.

En transmisión, el subsistema recibe desde el núcleo del juego la
información relevante de la partida y la envía hacia la PC mediante
`uart_tx_o`.

La aplicación de PC funciona únicamente como terminal de entrada y
visualización; no ejecuta la lógica del juego.