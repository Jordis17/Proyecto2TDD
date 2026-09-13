# Subsistema UART — Ahorcado FPGA/PC


## 1. Introducción

Este documento describe el subsistema UART del proyecto de Ahorcado FPGA/PC. Este
subsistema es el que permite que la FPGA y la aplicación de la computadora se comuniquen
entre sí durante la partida: por un lado recibe la letra que el jugador escribe en la
computadora, y por otro lado envía hacia la computadora todo lo que hay que mostrar en
pantalla (inicio de partida, resultado de cada letra, patrón de la palabra, intentos
restantes y el desenlace final).

El subsistema está dividido en tres módulos, que se explican en el orden en que aparecen
en el diagrama modular general: `uart_msg`, `uart_peripheral` y `uart_core`. Cada uno se
encarga de una parte distinta del problema, y juntos arman una cadena que va desde el
evento del juego hasta los bits que salen por el cable serie, y de regreso.

## 2. Descripción general del sistema

El objetivo del subsistema es implementar la comunicación bidireccional entre la FPGA y
la aplicación de PC mediante UART, a 115200 baudios.

En un sentido, el subsistema recibe por la línea serie un carácter que envía la
computadora. Si ese carácter es una letra ASCII válida entre `A` y `Z`, se entrega al
núcleo del juego junto con un aviso de que hay una letra nueva disponible. En el otro
sentido, el subsistema recibe del núcleo del juego la información de la partida (inicio,
resultado de la letra, patrón actualizado, intentos restantes, resultado final) y la
transmite hacia la PC.

La aplicación de PC funciona únicamente como terminal de entrada y visualización: no ejecuta
ninguna lógica del juego, esa lógica vive en la FPGA. Por eso todo lo que la PC necesita
para mostrar la partida tiene que salir por la UART en el formato correcto, y todo lo que
el jugador escribe tiene que entrar validado.

### Entradas del subsistema

- `clk_i`: reloj global del sistema, 100 MHz.
- `rst_i`: reinicio síncrono, activo en alto.
- `uart_rx_i`: línea serie proveniente de la PC.
- Información de estado que entrega el núcleo del juego: inicio de partida, resultado de
  la letra evaluada, patrón actualizado de la palabra, intentos restantes, resultado
  final.

### Salidas del subsistema

- `uart_tx_o`: línea serie hacia la PC.
- La letra recibida y ya validada, hacia el núcleo del juego.
- Un aviso de que hay una letra nueva disponible.

## 3. Diagrama modular general

La siguiente figura muestra los tres módulos del subsistema y cómo se conectan entre sí,
desde el núcleo del juego hasta los pines físicos de la tarjeta.

![Diagrama general del subsistema UART](FIGURAS/uart_subsistema_nivel3.png)

De izquierda a derecha: `uart_msg` es la capa de protocolo, que traduce los eventos del
juego a texto y viceversa; `uart_peripheral` es el banco de registros de 32 bits que
expone el enlace serie como un periférico direccionable; y `uart_core` es la envoltura
sobre el núcleo UART en VHDL que entregó el curso, que finalmente maneja los pines físicos
del puerto USB-serie.

Hay un detalle importante: `uart_peripheral` tiene un solo maestro a la vez. En el sistema final ese
maestro es `uart_msg`, pero en modo de prueba puede ser `uart_test_block` en su lugar. Cuál
de los dos se usa se decide con el parámetro `MODO_PRUEBA_UART` de `top`, y esa decisión se
resuelve en tiempo de síntesis, así que en el hardware final solo queda un camino y no hay
ningún multiplexor de por medio.

## 4. Descripción de los módulos

### 4.1. `uart_msg`

**Archivo:** `uart_msg.sv`, con dos módulos internos que no se instancian aparte en `top`:
`uart_msg_snapshot.sv` (copia registrada de los datos de la jugada) y
`uart_msg_char_gen.sv` (genera el carácter que corresponde a cada posición del mensaje).

**Función principal.** Traducir un evento del juego en las líneas de texto del protocolo
de aplicación y entregarlas byte a byte al periférico, y en el sentido contrario, recoger
y validar la letra que envía la computadora.

**Entradas.** Recibe del núcleo del juego el tipo de evento (`event_i`: 0 inicio, 1 letra,
2 repetida, 3 fin), un pulso que ordena notificarlo (`send_i`), la letra evaluada
(`letter_i`), si acertó (`hit_i`), la causa de fin (`end_code_i`: victoria, derrota por
fallos o derrota por tiempo), la palabra completa (`word_data_i`) con su longitud
(`word_len_i`), el patrón de posiciones descubiertas (`revealed_i`), los errores cometidos
(`errors_i`) y el modo de dificultad (`mode_i`). De `uart_peripheral` recibe `rdata_i`, del
que solo usa los bits de `send` y `new_rx`.

**Salidas.** Hacia el núcleo del juego entrega `busy_o` (hay un envío en curso o anotado),
`rx_letter_o` y `rx_valid_o` (la letra recibida ya validada). Hacia `uart_peripheral`
entrega `write_enable_o`, `addr_o` y `wdata_o`, es decir, la misma interfaz de registros
que después se describe en el módulo siguiente.

**Con quién se comunica.** Por arriba, con `game_controller` (recibe el evento y los
datos, devuelve `busy_o` y las letras validadas). Por abajo, con `uart_peripheral`, del
cual es maestro cuando el sistema se sintetiza para jugar.

**Funcionamiento interno.** El módulo arma cinco tipos de línea de texto, cada una con un
formato de ancho fijo para que la computadora pueda leerlas por posición sin tener que
buscar delimitadores:

| Evento | Líneas que emite |
|---|---|
| inicio | `START:<M>:<LL>` · `PATT:<p>` · `ERR:<n>` |
| letra | `LET:<X>:<R>` · `PATT:<p>` · `ERR:<n>` |
| repetida | `LET:<X>:RPT` |
| fin | `END:<E>:<W>` |

Donde `<M>` es el modo (`F` o `D`), `<LL>` la longitud de la palabra con cero a la
izquierda, `<p>` el patrón con `_` en lo oculto, `<X>` la letra evaluada, `<R>` el
resultado (`OK `, `NO ` o `RPT`, siempre de tres caracteres), `<n>` los intentos que
quedan, `<E>` la causa de fin (`WIN`, `LER` o `LTO`) y `<W>` la palabra completa. Todas las
líneas terminan en salto de línea.

Al llegar el pulso `send_i` estando el módulo libre, se anota la orden y el
`uart_msg_snapshot` copia los nueve datos de la jugada en el mismo flanco. Esta copia es
necesaria porque emitir la secuencia completa tarda unos 3 ms (el mensaje más largo, el de
inicio con una palabra de once letras, ocupa 34 bytes), y en ese tiempo el
`game_controller` podría entregar otra letra. Sin la copia, la trama podría salir mezclando
datos de dos jugadas distintas.

Para cada byte de la línea, el módulo sigue esta secuencia sobre el registro de control de
`uart_peripheral`: espera a que `send` esté en cero, escribe el byte en el registro de
datos de transmisión, escribe el registro de control con `send` en uno, y vuelve a esperar
a que `send` baje antes de pasar al siguiente byte. El carácter concreto que corresponde a
cada posición no lo decide la máquina de estados de `uart_msg`, sino el
`uart_msg_char_gen`, que además le indica cuántas líneas tiene el evento y cuál es el
último índice de la línea actual; con esas dos señales la FSM ya sabe todo lo que necesita
del formato sin tener que conocerlo en detalle.

En recepción, el módulo sondea el aviso de byte nuevo del periférico. Si hay uno, lee el
registro de recepción, limpia el aviso, y si el byte está entre `A` y `Z` emite el pulso
`rx_valid_o`; cualquier otro byte se descarta en silencio, pero el aviso igual se limpia.
Una orden de envío que llegue mientras el módulo está sondeando la recepción no se pierde,
queda anotada y se atiende al volver a reposo.

**Papel en el sistema.** Es la capa que le da sentido al enlace serie: sin ella,
`uart_peripheral` solo sabría mover bytes sueltos, y la computadora tendría que interpretar
tramas sin ningún formato. `uart_msg` es lo que convierte el estado de la partida en algo
que la aplicación de PC puede mostrar, y lo que convierte una tecla presionada en una letra
validada para el juego.

![Diagrama modular de uart_msg](FIGURAS/uart_msg_modular.png)

La figura anterior muestra la relación entre la FSM del bus, el snapshot y el generador de
carácter: el snapshot alimenta al generador con los datos congelados de la jugada, y el
generador le devuelve a la FSM el carácter de cada posición.

**Diseño interno.** El módulo se dividió en tres piezas (la FSM, el snapshot y el
generador de carácter) porque, si se hiciera todo en un solo bloque, ese bloque terminaría
haciendo tres cosas distintas a la vez. Con la separación, el formato del protocolo queda
completo en un archivo y el recorrido de líneas en otro, de modo que cambiar una línea del
protocolo no obliga a tocar la máquina de estados. Los puertos externos del módulo no
cambiaron al hacer esta partición, así que `top` lo sigue instanciando igual.

La detección de fin de transmisión se hace mirando el bit `send` del periférico, y no
alguna otra señal disponible. La razón es que, con transmisión y recepción conectadas
entre sí como transmisión y recepción están conectadas entre sí (loopback interno durante la prueba), 
el receptor muestrea el bit de parada un poco antes de
que el transmisor suelte la línea, así que cualquier aviso de recepción llegaría antes de
que la transmisión haya terminado de verdad.

También se decidió que la recepción viviera en este módulo y no en `game_controller`.
Si el control del juego leyera directamente el registro de recepción, habría dos maestros
distintos escribiendo sobre el mismo periférico al mismo tiempo (una trama saliendo y una
letra entrando), lo cual rompe la regla de un solo maestro por periférico. Al mantener la
recepción acá, sigue habiendo un único maestro, y el control del juego recibe letras que
ya llegaron validadas.

Sobre la validación: solo se aceptan los códigos ASCII de `A` a `Z` (`8'h41` a `8'h5A`).
El resto se descarta sin avisar a nadie, porque es un filtro de protocolo y no una regla
del juego. El pulso `rx_valid_o` dura un solo ciclo y se puede perder si el control no está
listo para atenderlo, lo cual es intencional: una letra que llegue fuera de la partida (en
selección de modo o mostrando el resultado) se ignora, pero el aviso queda limpio y no se
arrastra como si fuera la primera letra de la siguiente partida.

**Verificación.** El testbench `tb_uart_msg` se engancha directamente a la línea serie y
decodifica la trama bit a bit, igual que lo haría la computadora, así que compara
directamente el texto que sale por el cable. Los casos que cubre incluyen: el evento de
inicio con sus tres líneas y separadores, la longitud de la palabra en dos dígitos, los
resultados de letra acertada y fallada, la letra repetida, los tres desenlaces con la
palabra completa, la longitud del patrón según el largo de la palabra, los intentos
informados, el fin de línea correcto, que una orden durante un envío se ignore hasta
terminar, que cambiar los datos a mitad de un envío no altere la trama en curso, la
recepción de una letra válida, el descarte de un byte que no es letra, y que un byte
recibido durante una transmisión se atienda al terminar. Los dos módulos internos
(`uart_msg_snapshot` y `uart_msg_char_gen`) no tienen testbench propio porque quedan
cubiertos por este mismo testbench.

En cuanto a recursos, el conjunto usa 149 registros en total, de los cuales 129
corresponden al snapshot (96 solo para la palabra). La FSM tiene 7 estados en un registro
de 3 bits, hay un contador de línea de 2 bits y uno de posición de 5 bits, dos
comparadores de rango para validar entre `A` y `Z`, y los multiplexores de carácter del
generador, que son combinacionales.

![Diagrama estructural RTL de uart_msg](FIGURAS/uart_msg_rtl.png)

### 4.2. `uart_peripheral`

**Archivo:** `uart_peripheral.sv`.

**Función principal.** Exponer el enlace serie como un periférico de registros de 32
bits, para que quien lo use (en este caso `uart_msg`) escriba y lea direcciones en lugar
de manejar directamente el núcleo UART, y resolver la interacción entre transmitir
(`send`) y recibir (`new_rx`) sin que una operación estorbe a la otra.

**Entradas.** `write_enable_i` y `addr_i` para escribir un registro, `wdata_i` con el dato
a escribir (los bits 31 a 8 están reservados, porque la carga útil real es de un byte).
De `uart_core` recibe `tx_busy_i`, `rx_data_i` y `rx_valid_i`.

**Salidas.** `rdata_o`, la lectura combinacional del registro que indica `addr_i`. Hacia
`uart_core`: `tx_data_o` y `tx_start_o`.

El mapa de registros es el siguiente:

| `addr_i` | Registro | Contenido |
|---|---|---|
| `00` | DATOS TX | byte a transmitir, en los bits 7 a 0 |
| `01` | DATOS RX | último byte recibido, en los bits 7 a 0 |
| `10` | CONTROL | `send` en el bit 0, `new_rx` en el bit 1 |
| `11` | reservado | lee cero |

**Con quién se comunica.** Tiene un solo maestro a la vez, `uart_msg` en el sistema final o
`uart_test_block` en modo de prueba (según ya se explicó en la sección 3). Hacia abajo, se
comunica con `uart_core`, del que recibe el estado de la línea y al que le pide
transmisiones. Usa la misma interfaz de registros de 32 bits que `lcd_peripheral`, aunque
el hardware de cada uno no tenga nada en común.

**Lófica interna.** El registro de control no es un registro plano de dos bits
cualquiera; esa es la decisión más importante del módulo. El problema es que limpiar
`new_rx` requiere escribir el registro de control, pero una escritura de 32 bits toca los
dos bits a la vez. Si el registro fuera plano, limpiar `new_rx` podría cancelar por
accidente una transmisión en curso, o arrancar una transmisión podría borrar un `new_rx`
recién llegado y perder la letra. Es un problema intermitente, porque solo pasa si las dos
operaciones coinciden en el tiempo, lo cual en una partida ocurre cuando el jugador escribe
una letra justo mientras sale una trama.

La solución fue darle a cada bit su propia semántica:

| Bit | Nombre | Escribir 1 | Escribir 0 | Leer |
|---:|---|---|---|---|
| 0 | `send` | arranca la transmisión si no hay otra en curso | ningún efecto | 1 mientras transmite |
| 1 | `new_rx` | limpia el aviso | ningún efecto | 1 si hay un byte sin leer |

Con esto, ninguna escritura sobre uno de los bits afecta al otro.

La transmisión internamente pasa por tres estados: `TX_LIBRE` (no hay transmisión),
`TX_ARRANQUE` (la petición ya salió, se espera que `uart_core` la confirme) y `TX_CURSO`
(el núcleo está transmitiendo). El estado intermedio es necesario porque el núcleo tarda
en levantar su señal de ocupado; sin él, el periférico podría ver el núcleo todavía libre
justo después de pedir la transmisión y dar el envío por terminado antes de que
empezara. El bit `send` que se lee hacia afuera es simplemente la condición de que el
estado no sea `TX_LIBRE`.

En recepción, cuando llega un byte se guarda en el registro correspondiente y se levanta
`new_rx`; el maestro lo lee y limpia el aviso escribiendo un uno en ese bit. Si llega un
byte justo en el mismo ciclo en que se está limpiando el aviso, gana la llegada: el aviso
queda activo y el byte nuevo se guarda, porque perder un byte (la letra que escribió el
jugador) es peor que hacer que el maestro lea dos veces el mismo aviso.

La lectura es combinacional, un multiplexor de 4 entradas sobre `addr_i`, con un caso por
omisión explícito para la dirección `11` (que lee cero), necesario para que la
herramienta de síntesis no infiera un latch por dejar una combinación sin asignar.

**Función dentro del sistema.** Es la capa que traduce entre "escribir y leer una
dirección" y "manejar directamente los pines y tiempos del núcleo UART". Gracias a esta
capa, `uart_msg` no necesita saber nada de baudios ni de VHDL, solo tiene que escribir y
leer registros.

![Diagrama modular de uart_peripheral](FIGURAS/uart_peripheral_modular.png)

**Frontera con el núcleo.** Este módulo se diseñó antes de tener listo el núcleo UART del
curso, contra una interfaz supuesta de cinco señales (`tx_data_o`, `tx_start_o`,
`tx_busy_i`, `rx_data_i`, `rx_valid_i`). La idea era que, si el núcleo real resultaba
distinto, el cambio quedara contenido en esa frontera sin tocar los registros. Eso fue lo
que pasó: el núcleo real tenía dos particularidades (descritas en la sección de
`uart_core`), y las dos se resolvieron ahí, sin modificar nada de este módulo.

![Diagrama estructural RTL de uart_peripheral](FIGURAS/uart_peripheral_rtl.png)

**Verificación.** El testbench comprueba la escritura y lectura de los tres registros, que
una transmisión completa mantenga `send` en uno y lo baje solo al terminar, que escribir
cero en `send` no cancele una transmisión en curso, que escribir `send` durante una
transmisión no arranque una segunda, que la recepción guarde el byte y levante el aviso,
que limpiar `new_rx` con un uno funcione y con un cero no tenga efecto, que esa limpieza
no afecte una transmisión en curso, que una llegada simultánea a la limpieza no pierda el
byte, y que la dirección reservada lea cero.

En recursos, el módulo usa 20 registros en total (8 de transmisión y 8 de recepción, más
la FSM de 3 estados en 2 bits y los biestables de `new_rx` y de la petición), un
decodificador de 2 a 4 y un multiplexor de lectura de 4 entradas de 32 bits.

### 4.3. `uart_core`

**Archivo:** `uart_core.sv`. Instancia dos entidades en VHDL entregadas por el curso,
`UART_tx.vhd` y `UART_rx.vhd`, sin modificarlas. El curso también entregó un tercer
archivo, `UART.vhd`, que cablea las dos entidades entre sí, pero que no se instancia
porque no expone los parámetros de velocidad y se quedaría con valores por omisión
pensados para un reloj de 16 MHz. Al instanciar `UART_tx` y `UART_rx` por separado, sí se
les pueden pasar los divisores calculados para el reloj de 100 MHz de la tarjeta.

**Función principal.** Adaptar el núcleo UART en VHDL del curso a la interfaz que espera
`uart_peripheral`, resolviendo en un solo lugar las diferencias entre lo que el núcleo
realmente hace y lo que el periférico necesita.

**Entradas.** `rx_i`, la línea serie que llega del pin C4 de la tarjeta. De
`uart_peripheral` recibe `tx_data_i` y `tx_start_i`.

**Salidas.** `tx_o`, hacia el pin D4. Hacia `uart_peripheral`: `tx_busy_o`, `rx_data_o` y
`rx_valid_o`.

Los divisores de velocidad, calculados para 115200 baudios con un reloj de 100 MHz, son:

| Lado | Cálculo | Valor usado | Error |
|---|---|---:|---:|
| Transmisión | 100 000 000 / 115 200 ≈ 868,06 | 868 | −0,006 % |
| Recepción (sobremuestreo ×16) | (100 000 000 / 115 200) / 16 ≈ 54,25 | 54 | −0,47 % |

El lado de recepción queda con más error porque el redondeo se aplica sobre un número
dieciséis veces más chico. Como el receptor muestrea el bit *k* a 1,5 + *k* tiempos de bit
desde el flanco de arranque, en el último bit (el 8) ese error acumulado, sumado a la
latencia de detección del flanco de arranque, da un desfase de aproximadamente 10,2 % de
un bit. Como la ventana disponible antes de salirse del bit es del 50 %, el margen es de
casi cinco veces, así que el divisor de 54 es válido, aunque valía la pena calcularlo en
vez de darlo por supuesto.

**Con quién se comunica.** Por arriba, únicamente con `uart_peripheral`. Por abajo, sus dos
líneas van a los pines del puerto USB-serie de la tarjeta, que la computadora ve como un
puerto COM:

| Señal | Nombre en la tarjeta | Pin | Dirección |
|---|---|---|---|
| `rx_i` | `UART_TXD_IN` | C4 | entrada a la FPGA |
| `tx_o` | `UART_RXD_OUT` | D4 | salida de la FPGA |

Los nombres de la tarjeta están puestos desde el punto de vista de la computadora, así que
lo que para la PC es transmisión, para la FPGA es recepción. Confundir esto deja el enlace
sin funcionar, sin ningún mensaje de error visible.

**Qué hace por dentro.** El módulo resuelve dos particularidades del núcleo que no
coincidían con lo que se había supuesto al diseñar `uart_peripheral`:

La primera es que `tx_rdy` no es un nivel que indique "el transmisor está libre", como
sugiere el nombre, sino un pulso de un solo ciclo al terminar cada byte. Como
`uart_peripheral` necesita un nivel de ocupado, esta envoltura genera ese nivel con un
biestable que se pone al aceptar la petición y se limpia con ese pulso.

La segunda, más delicada, es que el núcleo ignora `tx_start` durante casi todo un tiempo
de bit después de terminar un byte, mientras mantiene en alto su propia señal interna de
reinicio de arranque. Si se le pasara la petición como un pulso de un ciclo, uno que caiga
en esa ventana se perdería sin dejar rastro, y quien esperara el fin de la transmisión se
quedaría esperando para siempre. Por eso esta envoltura sostiene la petición (en vez de
pulsarla) hasta que el núcleo confirma el fin. El costo de esto es que el reposo entre dos
bytes seguidos pasa de un tiempo de bit a unos tres, y el mensaje más largo pasa de durar
unos 3,0 ms a unos 4,0 ms. Ese reposo adicional es válido en cualquier receptor asíncrono,
porque el tiempo entre bytes no tiene un límite superior impuesto por el protocolo.

Con estas dos soluciones resueltas acá, ni el mapa de registros de `uart_peripheral`, ni
la semántica de `send` y `new_rx`, ni la capa de protocolo de `uart_msg`, ni el control del
juego tuvieron que modificarse.

**Cómo contribuye al sistema.** Es la última capa antes de la línea física. Aísla a todo
el resto del sistema de las particularidades del núcleo VHDL del curso, de modo que si ese
núcleo cambiara, en principio el cambio quedaría contenido acá.

![Diagrama modular de uart_core](FIGURAS/uart_core_modular.png)

**Verificación.** Este módulo no tiene testbench propio en SystemVerilog puro, porque
instancia entidades VHDL y solo se puede simular con una herramienta de lenguaje mixto
(Vivado). Lo cubre el testbench de integración del sistema completo. Para verificar las
capas superiores sin depender del VHDL existe además `uart_core_model.sv`, un modelo de
comportamiento con la misma interfaz, que usan otros testbenches como extremo opuesto de
la línea serie; ese modelo no reemplaza la verificación contra el núcleo real, que se hizo
aparte, en la tarjeta.

![Diagrama estructural RTL de uart_core](FIGURAS/uart_core_rtl.png)

En recursos, la envoltura agrega un solo registro propio (el biestable de la petición
sostenida) además de los registros internos de `UART_tx` y `UART_rx`, que el equipo no
diseñó. Se instancian dos entidades VHDL en total.

## 5. Integración de los módulos

Los tres módulos se conectan en cadena, y cada uno solo conoce la interfaz del vecino
inmediato:

- `uart_msg` conoce el mapa de registros de `uart_peripheral` (los bits `send` y
  `new_rx`, y las direcciones de los registros de datos), pero no sabe nada de baudios ni
  de la línea física.
- `uart_peripheral` conoce la interfaz de cinco señales hacia `uart_core`
  (`tx_data_o`, `tx_start_o`, `tx_busy_i`, `rx_data_i`, `rx_valid_i`), pero no sabe cómo
  están implementadas por dentro esas señales.
- `uart_core` es el único que conoce las particularidades reales del núcleo VHDL del
  curso, y las resuelve para que el resto de la cadena no tenga que enterarse.

Esta separación en fronteras es lo que permitió, según se explica en las secciones
anteriores, que las dos particularidades del núcleo real (el pulso de `tx_rdy` y la
ventana en que se ignora `tx_start`) se resolvieran en un solo módulo sin tener que tocar
el resto del sistema.

En modo de prueba, el único cambio de integración es que `uart_test_block` reemplaza a
`uart_msg` como maestro de `uart_peripheral`; la elección se resuelve en síntesis mediante
el parámetro `MODO_PRUEBA_UART` de `top`, así que en el hardware final solo existe un
camino.

## 6. Funcionamiento general del sistema

**Transmisión, de principio a fin.** El núcleo del juego dispara un evento hacia
`uart_msg` (`event_i` más los datos de la jugada). `uart_msg` anota la orden, el
`uart_msg_snapshot` congela los datos, y la FSM del bus empieza a recorrer los bytes de las
líneas correspondientes al evento, ayudada por `uart_msg_char_gen` para saber qué carácter
va en cada posición. Para cada byte, `uart_msg` escribe el registro de datos de
`uart_peripheral` y después el registro de control con `send` en uno. `uart_peripheral`
convierte esa orden en una petición sostenida hacia `uart_core`, que a su vez la mantiene
firme hasta que el núcleo VHDL confirma que terminó de transmitir el byte por el pin D4.
Cuando `send` vuelve a bajar, `uart_msg` sabe que puede escribir el siguiente byte, hasta
terminar todas las líneas del evento.

**Recepción, de principio a fin.** Un carácter llega por el pin C4 hacia `uart_core`, que
lo entrega tal cual junto con su aviso de dato válido. `uart_peripheral` lo guarda en su
registro de recepción y levanta el bit `new_rx`. `uart_msg`, que está sondeando ese aviso,
lee el byte, limpia el aviso y, si el byte es una letra entre `A` y `Z`, lo entrega
validado al núcleo del juego junto con el pulso `rx_valid_o`.

## 7. Verificación

Cada módulo cuenta con su propio testbench, salvo `uart_core`, que por instanciar
entidades VHDL solo puede verificarse con simulación de lenguaje mixto en Vivado y queda
cubierto por el testbench de integración del sistema completo. Los casos de prueba de cada
módulo ya se detallaron en la sección 4 correspondiente; en conjunto cubren:

- Que el mapa de registros de `uart_peripheral` funcione sin que una operación
  (transmitir, limpiar `new_rx`) interfiera con la otra.
- Que el formato de texto que arma `uart_msg` sea exactamente el esperado, verificado
  decodificando la línea serie bit a bit.
- Que los divisores de baudios calculados para `uart_core` dejen margen suficiente en el
  peor caso (según el cálculo de la sección 4.3, un margen de casi cinco veces sobre la
  ventana disponible).
- Que la petición sostenida hacia el núcleo evite el bloqueo que ocurriría si se le
  pasara como un pulso de un solo ciclo.

---

El subsistema UART quedó organizado en tres capas con responsabilidades bien separadas:
`uart_msg` se encarga del formato del protocolo y de validar lo que llega, `uart_peripheral`
expone el enlace como un periférico de registros sencillo de usar, y `uart_core` absorbe
las particularidades del núcleo VHDL entregado por el curso. Esta separación permitió que,
cuando aparecieron diferencias entre lo que se había supuesto del núcleo y lo que
realmente hacía (el pulso de `tx_rdy` y la ventana en la que ignora `tx_start`), el cambio
se resolviera en un solo módulo sin afectar el resto de la cadena. El mismo criterio de
frontera mínima se aplicó al diseñar el registro de control de `uart_peripheral`, que
resuelve mediante una semántica de bits independiente el conflicto entre transmitir y
limpiar el aviso de recepción al mismo tiempo.
