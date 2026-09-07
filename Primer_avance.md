# Ahorcado FPGA / PC — Primer avance

Proyecto 2 del curso Taller de Diseño Digital. Juego de ahorcado en el que toda la lógica de
control vive en una FPGA y la computadora actúa únicamente como terminal
conectada por enlace serie.

Este documento corresponde al primer avance: recoge el planteamiento del hardware en los niveles
1 y 2 del diseño modular, con el objetivo, las entradas, las salidas y la explicación de cada
bloque, y la forma en que se relacionan entre sí. 

**Equipo**

| Integrante | Responsabilidad |
|---|---|
| Mariana Fallas Fallas | Núcleo del juego |
| Abner López Méndez | Subsistema LCD |
| Justin Garita Serrano | Subsistema UART y aplicación de PC |
| Jordi | Periféricos locales e integración |

---

## 1. El problema y el reparto de responsabilidades

La inteligencia del juego está en la FPGA. La computadora no elige la palabra, no valida letras, no cuenta el
tiempo y no decide quién gana.

| En la FPGA | En la PC |
|---|---|
| Banco de palabras en ROM | Pedir una letra al jugador |
| Selección pseudoaleatoria con LFSR | Validar que sea A–Z antes de enviarla |
| Validación de la letra y revelado del patrón | Mostrar el patrón, los intentos y el resultado |
| Cuenta de errores y de tiempo | — |
| Determinación del desenlace | — |
| Presentación en LCD, displays, LEDs y sonido | — |

Reglas de la partida: seis errores como máximo; una letra ya jugada se ignora sin penalizar ni
reiniciar nada; todas las apariciones de una letra acertada se revelan a la vez; al terminar se
muestra el resultado durante tres segundos y el sistema vuelve solo a la pantalla de selección.

| | Fácil | Difícil |
|---|---|---|
| Palabras elegibles | cualquiera del banco | solo de 6 letras o más |
| Tiempo de partida | 60 s | 45 s |

---

## 2. Diagrama de primer nivel

![Diagrama de primer nivel](Diagramas/nivel1.png)

**Objetivo.** Realizar una partida completa de ahorcado: presentar la selección de dificultad,
elegir la palabra, recibir letras desde la PC, validarlas, llevar el tiempo y los intentos,
informar el estado por el enlace serie y mostrarlo localmente en la tarjeta.

**Entradas**

| Señal | Descripción |
|---|---|
| `clk_i` | Reloj único del sistema, 100 MHz. Pin E3 |
| `btn_rst_i` | Pulsador central (btnC). Reinicia el sistema y el contador de victorias |
| `btn_sel_i` | Pulsador izquierdo (btnL). Alterna la dificultad mostrada |
| `btn_ok_i` | Pulsador derecho (btnR). Confirma la dificultad e inicia la partida |
| `uart_rx_i` | Línea serie a 115200 baudios, 8N1. Transporta la letra que envía la PC, como un byte ASCII A–Z |

**Salidas**

| Señal | Descripción |
|---|---|
| `lcd_db_o[7:0]`, `lcd_rs_o`, `lcd_rw_o`, `lcd_e_o` | LCD PmodCLP 16x2. `lcd_rw_o` queda fijo a 0: el periférico solo escribe |
| `seg_o[6:0]`, `an_o[7:0]` | Displays de 7 segmentos multiplexados. Dos dígitos para el tiempo restante y dos para las victorias |
| `led_o` | LEDs de estado. LED0 a LED2 indican en qué fase está el juego y LED15 indica el modo difícil |
| `aud_pwm_o`, `aud_sd_o` | Salida de audio de la tarjeta hacia el jack de 3.5 mm |
| `uart_tx_o` | Tramas ASCII con el estado de la partida hacia la PC |

**Explicación general.** El sistema es completamente síncrono con un único reloj de 100 MHz. No
se generan relojes derivados: toda temporización menor —el milisegundo, los baudios, la
temporización del LCD, el multiplexado, los tonos— sale de contadores y señales de habilitación
derivadas de ese mismo reloj.

No existe una entrada de reset independiente de los pulsadores: `btn_rst_i` es la única fuente, y
el arranque tras programar la FPGA no depende de ella, porque los registros declaran su valor
inicial en la declaración y el controlador del LCD lanza su secuencia de inicialización por su
cuenta.

Las tres entradas de pulsador son asíncronas al reloj y con rebotes mecánicos, así que ninguna
entra directamente a la lógica de control: todas pasan primero por sincronización y filtrado. La
línea `uart_rx_i` también se sincroniza antes de usarse.

La computadora queda fuera del sistema: es un periférico de entrada y salida conectado por las
dos líneas serie, y todo lo que hace es enviar una letra y mostrar lo que la FPGA le devuelve.

---

## 3. Diagrama de segundo nivel

![Diagrama de segundo nivel](Diagramas/nivel2.png)

El sistema se subdivide en cuatro bloques generales dentro de la FPGA, más dos elementos externos:
la aplicación de PC y el módulo LCD. Las etiquetas del diagrama agrupan las señales por familias;
el detalle señal a señal corresponde al tercer nivel.

### 3.1 Periféricos locales e integración

- **Objetivo:** conectar el sistema con las entradas y salidas físicas de la tarjeta, y sostener
  la integración de los demás bloques.
- **Entradas:** `clk_i`, `btn_rst_i`, `btn_sel_i`, `btn_ok_i`; del núcleo del juego, el tiempo
  restante, las victorias acumuladas, el estado del juego, el modo y los eventos de sonido.
- **Salidas:** hacia el núcleo, el reset y los eventos de botón —cambio de modo y confirmación—;
  hacia la tarjeta, `seg_o[6:0]`, `an_o[7:0]`, `led_o`, `aud_pwm_o` y `aud_sd_o`.

Es el bloque que recibe el reloj y lo distribuye, y el que genera la base de tiempo común: un
pulso de habilitación cada milisegundo, obtenido dividiendo los 100 MHz entre 100 000. Ese pulso
alimenta el filtro de rebotes, el temporizador de la partida, el multiplexado de los displays y la
espera de la pantalla de resultado.

Del lado de las entradas, cada pulsador atraviesa el mismo camino: sincronizador de dos etapas,
filtro de rebotes de 10 ms y detector de flanco. `btn_rst_i` se entrega como nivel de reset y los
otros dos como pulsos de un ciclo, que es la forma en que el núcleo los consume.

Del lado de las salidas, multiplexa cuatro dígitos a razón de uno por milisegundo, lo que da un
refresco completo cada 4 ms —250 Hz— sin necesidad de contadores adicionales; los cuatro dígitos
no utilizados se mantienen apagados explícitamente. Enciende un LED distinto para cada una de las
tres fases del juego, más el LED de modo, y genera la retroalimentación sonora de acierto, error y
fin de partida.


### 3.2 Núcleo del juego

- **Objetivo:** implementar todas las reglas del ahorcado. Es el bloque que hace que la
  inteligencia del juego resida en la FPGA y no en la PC.
- **Entradas:** el reset y los eventos de botón desde el bloque de periféricos locales; la letra
  recibida desde el subsistema UART; y la señal de ocupado de las dos capas de presentación.
- **Salidas:** hacia el subsistema LCD, el modo, la palabra, el patrón revelado, los intentos y
  el resultado; hacia el subsistema UART, el estado y los eventos de la partida; hacia los
  periféricos locales, el tiempo restante, las victorias, el estado del juego, el modo y los
  eventos de sonido.

Agrupa la máquina de estados de control, el banco de 64 palabras en ROM, el generador
pseudoaleatorio LFSR, el temporizador regresivo y la máscara de las letras ya jugadas.

Al confirmarse el modo captura el valor del LFSR —que corre libre desde el arranque— y con él
elige un índice dentro del rango de la ROM que corresponde a la dificultad. Arranca entonces la
cuenta regresiva. Con cada letra válida decide en un solo ciclo si es repetida, acertada o
fallada: compara en paralelo contra todas las posiciones de la palabra, revela todas las
coincidencias a la vez y, si no hay ninguna, incrementa el contador de errores. Evalúa el
desenlace en orden de prioridad: victoria, sexto error, agotamiento del tiempo.

El núcleo no maneja ningún bus de periférico. Pide pantallas y eventos a las dos capas de
presentación y espera a que queden libres antes de pedir nada nuevo; por eso su máquina de estados
tiene estados de espera y por eso necesita conocer si esas capas están ocupadas.

### 3.3 Subsistema UART

- **Objetivo:** ser el único maestro del enlace serie, en los dos sentidos.
- **Entradas:** `uart_rx_i` desde la PC; el estado y los eventos desde el núcleo del juego.
- **Salidas:** `uart_tx_o` hacia la PC; la letra recibida y la señal de ocupado hacia el núcleo.

Contiene el formateador del protocolo de aplicación, el periférico UART con su interfaz estándar
de registros de 32 bits, y el núcleo de transmisión y recepción. En transmisión convierte un
evento del juego en una trama ASCII de ancho fijo y la envía byte a byte, esperando entre cada
uno. En recepción consulta el aviso de byte nuevo, lee el registro de datos, limpia el aviso y
descarta cualquier byte que no sea una letra mayúscula.

Transmisión y recepción están en el mismo bloque a propósito: comparten el mismo bus de registros,
y dos maestros sobre el mismo periférico —uno enviando una trama y otro leyendo una letra— sería
una carrera. Que el filtrado de bytes no válidos viva aquí y no en el núcleo también es
deliberado: descartar un byte que no es una letra es una cuestión de protocolo, no una regla del
juego. Para una letra que llegue mientras se muestra la pantalla de selección o el resultado se ignora, pero el aviso se limpia, de
modo que no se cuela como primera letra de la partida siguiente.

### 3.4 Subsistema LCD

- **Objetivo:** presentar el estado del juego en el módulo PmodCLP.
- **Entradas:** el modo, la palabra, los intentos y el resultado desde el núcleo del juego.
- **Salidas:** `lcd_db_o[7:0]`, `lcd_rs_o`, `lcd_rw_o`, `lcd_e_o` hacia el módulo; la señal de
  ocupado hacia el núcleo.

Contiene el generador de pantallas, el periférico LCD con su interfaz de registros de 32 bits y el
controlador que respeta la temporización real del dispositivo. Traduce una orden como "muestra la
pantalla de selección" en la treintena de transacciones que eso significa, cada una con su inicio,
su espera y su fin.

Las líneas se escriben completas, rellenando con espacios hasta los 16 caracteres, de modo que no
quedan restos de la pantalla anterior y no hace falta limpiar la pantalla antes de cada
redibujado, que es lo que produce parpadeo. Se redibuja solo cuando cambia algo visible: al entrar
a la selección, al cambiar de modo, al empezar la partida, al evaluar una letra que mueve el
patrón o los intentos, y al entrar al resultado. Nunca en bucle.

### 3.5 Elementos externos

**PC / Python.** Terminal del jugador. Pide una letra, valida que sea un solo carácter de la A a
la Z, la pasa a mayúscula y la envía como un byte. Recibe las tramas de estado y muestra el patrón
actual, los intentos que quedan, cómo fue la última letra y el resultado final. No guarda la
palabra secreta, no elige la palabra, no decide quién gana y no lleva el tiempo.

**LCD PmodCLP.** Módulo de 16x2 con controlador KS0066, compatible HD44780, conectado por
interfaz paralela de 8 bits a los conectores JA y JB.

### 3.6 Funcionamiento del sistema en conjunto

Al configurar la FPGA los registros toman su valor inicial y el subsistema LCD arranca solo su
secuencia de inicialización, sin esperar ninguna pulsación. El núcleo pide la pantalla de
selección y queda a la espera. Una pulsación de `btn_sel_i` llega al núcleo como un pulso limpio,
alterna el modo y provoca un redibujado; `btn_ok_i` captura el valor del LFSR y con él se elige la
palabra dentro del rango de la ROM que corresponde al modo confirmado.

Empezada la partida, el núcleo arranca el temporizador, pide la pantalla de juego al subsistema
LCD y el mensaje de inicio al subsistema UART, y espera a que ambos queden libres. A partir de ahí
el ciclo es siempre el mismo: el subsistema UART entrega una letra ya filtrada, el núcleo la
evalúa en un ciclo, pide el redibujado del LCD y la notificación a la PC, espera a que ambas
terminen, y vuelve a esperar letra. Mientras tanto el bloque de periféricos locales refresca los
displays con el tiempo que va quedando y las victorias acumuladas, mantiene encendido el LED de la
fase actual y produce el tono que corresponda a cada evento.

El temporizador no se detiene durante la publicación de una jugada: pararlo en cada letra le
regalaría tiempo al jugador y el límite dejaría de ser el que anuncia el modo.

La partida termina por victoria, por sexto error o por agotamiento del tiempo. Los tres casos
recorren el mismo estado final y se diferencian solo en un código de dos bits, que es justamente el
dato que reciben las dos capas de presentación: el LCD muestra un texto distinto, la PC recibe un
código distinto y el sonido de victoria no es el de derrota. Tras tres segundos de resultado
—contados desde que termina el dibujado, no desde que se entra al estado— el sistema regresa solo
a la pantalla de selección. Si el tiempo se agota mientras hay una transacción del LCD o una trama
serie a medias, el evento se captura en un indicador y se atiende cuando ambas capas quedan
libres, para no dejar media pantalla escrita ni una trama truncada.

`btn_rst_i` interrumpe todo esto en cualquier momento: devuelve el sistema a la pantalla de
selección y pone el contador de victorias en cero.

---

## 4. Interfaces principales

### Interfaz estándar de periféricos

Los dos periféricos, LCD y UART, exponen la misma interfaz de 32 bits:
`clk_i`, `rst_i`, `write_enable_i`, `addr_i[1:0]`, `wdata_i[31:0]` y `rdata_o[31:0]`. La lectura
es combinacional, un multiplexor sobre `addr_i` con rama por defecto explícita para no inferir
latches, de modo que el maestro puede consultar el estado en el mismo ciclo en que presenta la
dirección. 

**Periférico LCD**

| `addr_i` | Registro | Campos |
|---|---|---|
| `2'b00` | CONTROL/ESTADO (offset 0x00) | 0 `start`, 1 `rs`, 2 `clear`, 3 `home`, 8 `busy` (RO), 9 `done` (RO) |
| `2'b01` | DATOS (offset 0x04) | `[7:0]` byte a enviar, ASCII o código de instrucción |

`done` es un indicador que se mantiene hasta que se acepta una nueva operación, no un pulso de un
ciclo: con un pulso, un maestro que consulta el registro podría no verlo nunca y quedarse esperando
indefinidamente. Si una escritura activa varias solicitudes a la vez, la prioridad es `clear`,
`home`, `start`; lo que llegue con `busy` en 1 se descarta.

**Periférico UART**

| `addr_i` | Registro |
|---|---|
| `2'b00` | Datos de transmisión |
| `2'b01` | Datos de recepción |
| `2'b10` | Control |

En el registro de control, `send` solo puede ponerse a 1 y el hardware lo baja al terminar la
transferencia; `new_rx` se limpia escribiendo un 1 sobre él. Con esa semántica los dos campos son
independientes y una escritura nunca destruye el estado del otro, que es el fallo intermitente que
aparecería si el registro fuera plano.

### Protocolo de aplicación

Texto ASCII terminado en salto de línea, con campos de ancho fijo.

**PC → FPGA:** un byte, de la `A` a la `Z`. Cualquier otra cosa se descarta.

**FPGA → PC:**

| Mensaje | Formato | Cuándo |
|---|---|---|
| Inicio | `START:<M>:<LL>` | al empezar la partida |
| Patrón | `PATT:<p>` | al empezar y tras cada letra |
| Letra | `LET:<X>:<R>` | al evaluar una letra |
| Intentos | `ERR:<n>` | al empezar y tras cada letra |
| Fin | `END:<E>:<W>` | al terminar |

`<M>` es `F` o `D`; `<LL>` la longitud en dos dígitos; `<p>` el patrón con guiones bajos en lo
oculto; `<R>` es `OK `, `NO ` o `RPT`, siempre tres caracteres; `<n>` los intentos que quedan;
`<E>` es `WIN`, `LER` por errores o `LTO` por tiempo; `<W>` la palabra completa.

```
al empezar     START:F:07    PATT:_______    ERR:6
letra buena    LET:A:OK      PATT:A______    ERR:6
letra mala     LET:Z:NO      PATT:A______    ERR:5
repetida       LET:A:RPT
al terminar    END:WIN:ARBOLES
```

El ancho fijo simplifica las dos puntas: en RTL solo el patrón y la palabra tienen longitud
variable, y en Python el troceo es por posición, sin expresiones regulares. La secuencia más larga
son unos 34 bytes.

---

## 5. Temporización

Un solo reloj de 100 MHz. Ningún módulo lleva números de ciclos escritos por dentro: todas las
constantes bajan como parámetros desde el nivel superior, lo que además permite generar una
variante con tiempos reducidos para las simulaciones.

| Parámetro | Valor | Ciclos o ticks | Cálculo |
|---|---:|---:|---|
| `TICK_1MS_CYCLES` | 1 ms | 100 000 | 100e6 / 1000 |
| `DEBOUNCE_MS` | 10 ms | 10 ticks | |
| `T_EASY_S` | 60 s | 60 000 ticks | |
| `T_HARD_S` | 45 s | 45 000 ticks | |
| `RESULT_MS` | 3 s | 3 000 ticks | |
| `MUX_DIGIT_MS` | 1 ms | 1 tick | 4 dígitos, refresco completo a 250 Hz |
| `BAUD_DIV` | 115 200 baud | 868 | 100e6 / 115200 = 868.06, error 0.006 % |
| `LCD_POWERON_MS` | 50 ms | 50 ticks | el manual del PmodCLP pide 20 |
| `LCD_SHORT_US` | 60 µs | 6 000 | el manual pide 37 |
| `LCD_LONG_US` | 2 ms | 200 000 | el manual pide 1.52 |

---

## 6. Decisiones implementadas en el proyecto

| Decisión | Por qué |
|---|---|
| Dos subsistemas de presentación entre el núcleo y los periféricos | Una pantalla del LCD son unas 34 transacciones y un mensaje serie unos 34 bytes. Si esa secuenciación viviera en la máquina de estados del juego, pasaría de una decena de estados a varias decenas y mezclaría las reglas con el armado de texto |
| Cada periférico con un solo maestro | Evita que dos módulos manejen el mismo bus de registros a la vez, que es lo que ocurriría si el núcleo leyera la letra por su cuenta mientras sale una trama |
| ROM de 64 palabras ordenada por dificultad, índice por truncamiento del LFSR | En modo difícil una palabra corta es imposible por construcción, no por una regla de la máquina de estados. Un ciclo, sin operación de módulo, sin rechazo y sin bucles |
| LFSR de corrida libre, capturado al confirmar el modo | Si solo avanzara al iniciar la partida, la secuencia de palabras sería idéntica tras cada encendido. La variedad sale del instante de la pulsación; en simulación sigue siendo determinista porque el testbench fija el ciclo exacto |
| Un solo estado de fin de partida, con un código de dos bits | Los tres desenlaces hacen lo mismo: pintar, notificar, sonar y esperar. Tres estados que se diferencian en un dato pertenecen al camino de datos, no al control |
| `lcd_rw_o` atado a 0 | Leer el indicador de ocupado del LCD obligaría a declarar los datos como `inout` con buffers triestado sobre pines Pmod, con riesgo de contención, para ahorrar microsegundos irrelevantes aquí |
| Constantes de tiempo como parámetros desde el primer módulo | La simulación post-implementación temporizada es obligatoria y con los valores reales sería impracticable. Añadir los parámetros después obligaría a tocar todos los módulos y todos los testbenches |

---

## 7. Estado del avance y pendientes

**Cerrado.** Arquitectura por niveles, interfaces de los dos periféricos, protocolo de aplicación,
distribución de las tres pantallas del LCD, banco de palabras y mapeo de pines. Los módulos
escritos tienen testbench propio con resumen de aciertos y fallos, y la aplicación de PC tiene su
prueba contra un puerto serie simulado.

**Pendiente.**

| Tema | Cómo se cierra |
|---|---|
| Integración con el núcleo UART en VHDL provisto por el curso | Correr la regresión en Vivado en lenguaje mixto. Hasta entonces lo verificado es la lógica del sistema, no la integración |
| Ancho del pulso de `lcd_e_o` y setup y hold de RS y datos | El manual del PmodCLP no los especifica. Los valores actuales son elección del equipo con margen amplio y se validan en la tarjeta |
| Polaridad de `aud_sd_o` y naturaleza de la entrada del filtro de audio | Verificar en el esquemático de la tarjeta antes de cerrar la generación de sonido. Alternativa prevista: Pmod buzzer en JB7 a JB10 |
| Conexión física del PmodCLP a JA y JB | Comprobar antes de la primera prueba en tarjeta |
| Simulación post-implementación temporizada | Escalar únicamente las constantes que la hacen inviable, manteniendo el divisor de baudios real para que la recepción de la letra se valide a la velocidad verdadera |

La FPGA no tiene buzzer: la retroalimentación sonora sale por el jack de 3.5 mm, así que para la
demostración hacen falta un parlante.

---
