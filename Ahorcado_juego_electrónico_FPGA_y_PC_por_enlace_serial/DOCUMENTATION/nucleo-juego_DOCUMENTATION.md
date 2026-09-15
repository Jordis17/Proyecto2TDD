# Subsistema nucleo-juego — Ahorcado FPGA/PC


## 1. Introducción



La versión final del subsistema está formada por cuatro módulos principales:
* `lfsr`
* `word_rom`
* `round_timer`
* `game_controller`





## 2. Descripción general del sistema

El nucleo de juego esta compuesto por `game_controller`, es el encargado de gestionar el control de la partida, en conjunto con otros tres submodulos que son los encargados 
de generar la aleatoriedad del sistema (`lfsr`), una memoria de lectura que almacena la lista de palabras (`word_rom`) y un contador descendete síncrono (`round_timer`). En conjunto con estos tres modulos puede
ompara la entrada de letras enviadas por el usuario a través de la UART, evalúa en paralelo las coincidencias en la palabra cargada de la ROM, descuenta fallos o valida victorias, e informa el estado a los periféricos (pantalla, sonido y comunicación).




## 3. Diagrama modular de subsistema nucleo-juego

![Diagrama principal](./FIGURAS/diagrama_principal.png)



# 4. Descripción de los módulos

## 4.1 `lfsr`


## Diagrama 

![Diagrama lfsr](./FIGURAS/diagrama_lfsr.png)

### Objetivo

Producir una secuencia pseudoaleatoria de ocho bits que sirva para seleccionar la
palabra de cada partida, de modo que el juego no repita siempre el mismo orden.


### Entradas

| Señal | Ancho | Descripción |
|---|---|---|
| `clk_i` | 1 bit | Reloj del sistema, 100 MHz. |
| `rst_i` | 1 bit | Reinicio síncrono, activo en alto. Recarga la semilla. |

### Salidas


| Señal | Ancho | Descripción |
|---|---|---|
| `lfsr_o` | 8 bits | Estado actual del registro, disponible en todo momento. |


### Relación con otros módulos


`lfsr` se instancia una única vez en `top`, con el nombre de instancia `generador`.

Entrega su salida completa a `game_controller`, que la captura en el ciclo exacto en
que detecta la pulsación del botón de confirmación (funciona sin habilitación). De los ocho bits, el control
conserva seis y usa cinco o los seis según el modo elegido.


### Explicación de funcionamiento

En cada flanco de reloj el contenido se desplaza una posición hacia la izquierda, y por
la derecha entra un bit nuevo que es la operación XOR de cuatro posiciones del propio
registro:

```systemverilog
lfsr_q <= {lfsr_q[6:0], lfsr_q[7] ^ lfsr_q[5] ^ lfsr_q[4] ^ lfsr_q[3]};
```

La secuencia resultante recorre los 255 valores distintos de cero y vuelve a empezar,
de modo que el registro tarda 255 ciclos de reloj, o 2,55 µs a 100 MHz, en repetirse.


### Diseño

Se usa el polinomio primitivo:

```
x^8 + x^6 + x^5 + x^4 + 1        taps 8, 6, 5, 4
```

Un polinomio primitivo de grado *n* garantiza el ciclo máximo:

```
2^8 - 1 = 255 estados distintos de cero
```

Los taps se cuentan sobre las potencias del polinomio, pero el registro se indexa desde
cero, así que el bit que representa `x^i` vive en `lfsr_q[i-1]`:

| Tap del polinomio | Potencia | Bit del registro |
|---|---|---|
| 8 | `x^8` | `lfsr_q[7]` |
| 6 | `x^6` | `lfsr_q[5]` |
| 5 | `x^5` | `lfsr_q[4]` |
| 4 | `x^4` | `lfsr_q[3]` |


### Dimensionamiento del registro

El banco tiene 64 palabras, así que para direccionarlo bastarían seis bits:

| Ancho | Longitud del ciclo | Costo |
|---|---|---|
| 6 bits | 63 estados | 6 flip-flops |
| 8 bits | 255 estados | 8 flip-flops |

Se usan ocho. El patrón tarda cuatro veces más en repetirse y el costo adicional son
dos flip-flops, que en este dispositivo es despreciable. Los dos bits sobrantes se
descartan en `game_controller`, no aquí.


### Verificación

El testbench comprueba las dos propiedades que definen un LFSR de ciclo máximo:

 1. Los 255 estados son distintos 
 2. El cero nunca aparece 
 3. La secuencia es reproducible 

### Recursos


| Recurso | Cantidad |
|---|---|
| Registros | 8 |
| Compuertas XOR | 1 de cuatro entradas |
| Multiplexores | 1 de dos entradas, para la carga de la semilla |

---

## 4.2 `word_rom`

## Diagrama

![Diagrama lfsr](./FIGURAS/word_rom.png)

### Objetivo

Almacenar el banco de palabras del juego y entregar, para un índice dado, la palabra
completa en código ASCII junto con la cantidad de letras que tiene.


### Entradas
El módulo es puramente combinacional , no recibe señal de reloj.

| Señal | Ancho | Descripción |
|---|---|---|
| `index_i` | 6 bits | Selecciona una de las 64 palabras del banco. |

### Salidas

| Señal | Ancho | Descripción |
|---|---|---|
| `word_data_o` | 96 bits | Palabra en ASCII mayúscula, rellenada con espacios hasta los 12 caracteres. |
| `word_len_o` | 4 bits | Cantidad real de letras, de 4 a 11. |

El ancho de la palabra sale de la longitud máxima:

```
8 bits por caracter x 12 caracteres = 96 bits
```

Empaquetado de los caracteres. El carácter de la posición *i*, contando desde cero
para el primero de la palabra, ocupa:

```
word_data_o[8*(MAX_LEN-1-i) +: 8]
```

o sea que el primer carácter queda en los bits más significativos:

```
 bits   95..88  87..80  79..72   ...   7..0
        car 0   car 1   car 2    ...   car 11
```




### Relación con otros módulos

`word_rom` se instancia una única vez en `top`, con el nombre de instancia `banco`.

Su único interlocutor es `game_controller`, que le coloca el índice en el estado de
carga de la partida y registra de inmediato las dos salidas. De ahí en adelante la
palabra que se juega proviene de ese registro y no de la ROM, así que el índice puede
cambiar sin afectar la partida en curso.




### Explicación de funcionamiento

El módulo implementa una función combinacional pura: para cada valor de `index_i`
existe un par de salidas fijo, sin memoria ni dependencia del historial de entradas.
El resultado aparece tras el retardo de propagación de la lógica, sin esperar ningún
flanco de reloj.

El banco está ordenado por dificultad, y de ese orden depende la selección de la
palabra:

| Índices | Longitud de las palabras | Modos en que pueden salir |
|---|---|---|
| 0 a 31 | 6 a 11 letras | Fácil y Difícil |
| 32 a 63 | 4 o 5 letras | solo Fácil |

Las posiciones que sobran en una palabra corta se rellenan con el código del espacio,
 así las salidas siempre tienen el mismo ancho y quien la consume usa
`word_len_o` para saber hasta dónde leer.


### Diseño

El modo difícil solo puede usar palabras de seis letras o más. Ese requisito se
resuelve de la siguiente manera:

| Estrategia | Cómo se garantiza | Costo |
|---|---|---|
| Ordenar la tabla por dificultad | el índice se trunca a cinco bits y no puede pasar de 31 | una conexión a tierra en el bit 5 |

Con la tabla ordenada, el modo difícil queda garantizado por
construcción: el índice fuera de rango simplemente no se puede formar, así que no
existe ninguna comprobación de longitud en ninguna máquina de estados.

Ahora el orden de la tabla pasa a ser un requisito
estructural y no una convención cosmética.

### Verificación
El testbench comprueba las propiedades de las que depende la seleccion de palabra

1. Toda longitud esta entre 4 y 12
2. Los indices 0..31 tienen longitud >= 6   (modo dificil)
3. Los indices 32..63 tienen longitud 4 o 5 (solo modo facil)
4. Las posiciones validas contienen solo A-Z (sin minusculas ni acentos ni caracteres especiales)
5. Las posiciones de relleno contienen espacio


### Recursos

| Recurso | Cantidad |
|---|---|
| Registros | 0 |
| Bloques de memoria dedicados | 0 |
| Almacenamiento | 6 400 bits en lógica distribuida |
| Entradas de la función | 6 |


---


## 4.3 `round_timer`

## Diagrama

![Diagrama round_timer](./FIGURAS/round_timer.png)

### Objetivo

Llevar la cuenta regresiva del tiempo de la partida, entregar en todo momento los
segundos que quedan, y mantener un aviso de vencimiento que el control del juego pueda
atender cuando esté en condiciones de hacerlo.


### Entradas

| Señal | Ancho | Descripción |
|---|---|---|
| `clk_i` | 1 bit | Reloj del sistema, 100 MHz. |
| `rst_i` | 1 bit | Reinicio síncrono, activo en alto. Deja la cuenta en cero. |
| `tick_i` | 1 bit | Habilitación periódica de 1 ms generada por `clk_tick_gen`. El acumulador solo avanza cuando esta señal está activa. |
| `load_i` | 1 bit | Pulso que carga un nuevo intervalo y limpia el acumulador de milisegundos. |
| `seconds_i` | 7 bits | Duración del intervalo a medir, en segundos. |
| `run_i` | 1 bit | Habilita la cuenta descendente. Mientras está en bajo, la cuenta se detiene sin perder su valor. |


### Salidas

| Señal | Ancho | Descripción |
|---|---|---|
| `time_s_o` | 7 bits | Segundos restantes. Válido en todo momento, también con la cuenta detenida. |
| `timeout_o` | 1 bit | Nivel activo mientras la cuenta esté en cero y el temporizador habilitado. |


### Relación con otros módulos

`round_timer` se instancia una única vez en `top`, con el nombre de instancia
`temporizador`.

Recibe su base temporal de `clk_tick_gen`, que le entrega un pulso cada milisegundo.
Sin esa señal el acumulador no avanza, aunque el reloj siga corriendo.

Todo su control proviene de `game_controller`, que decide cuándo cargar, con qué valor y
cuándo habilitar la cuenta. La señal `timeout_o` regresa a esa misma máquina de estados
como condición de transición.

La salida `time_s_o` tiene dos destinos:

| Destino | Para qué la usa |
|---|---|
| `game_controller` | forma parte del estado de la partida |
| `display_controller` | la muestra en dos dígitos de los displays de siete segmentos |

Los intervalos que atiende:

| Situación | Valor cargado | Efecto del vencimiento |
|---|---|---|
| Partida en modo Fácil | `SEG_FACIL`, 60 s | derrota por tiempo |
| Partida en modo Difícil | `SEG_DIFICIL`, 45 s | derrota por tiempo |



### Explicación de funcionamiento

El módulo son dos contadores encadenados sobre la misma habilitación de milisegundo.

El primero acumula pulsos de `tick_i` y, al completar mil, ordena descontar un segundo y
vuelve a cero. El segundo lleva los segundos restantes y baja de uno en uno hasta cero,
donde se detiene.

**Carga.** Cuando `game_controller` necesita medir un intervalo, coloca la duración en
`seconds_i` y activa `load_i` durante un ciclo. El contador de segundos toma ese valor y
el acumulador de milisegundos se pone a cero.

**Prioridad de la carga.** La carga se evalúa antes que la cuenta. Si en un mismo ciclo
coincidieran una orden de carga y un pulso de milisegundo, el contador toma el valor
nuevo completo en lugar de restarle una unidad de entrada.

**Detención en cero.** La condición de descuento incluye la comprobación de que el
contador de segundos no esté ya en cero. Sin ella, la resta produciría un
desbordamiento y el registro pasaría a su valor máximo, iniciando una cuenta de 127
segundos que nadie pidió.


### Diseño

Se utiliza una única señal de habilitación en lugar de generar relojes derivados, evitando problemas de distribución 
y temporización. Las señales load_i y run_i se mantienen separadas para permitir cargar el 
tiempo inicial y detener posteriormente la cuenta sin perder el valor mostrado durante 
la pantalla de resultados. Al cargar un nuevo tiempo, el acumulador de milisegundos se reinicia 
para garantizar que el primer segundo tenga una duración completa. Finalmente, timeout_o se implementa 
como un nivel que permanece activo mientras el tiempo sea cero y el temporizador esté habilitado, evitando que el vencimiento 
se pierda mientras el controlador se encuentra ocupado con el LCD o la comunicación serial. 
Así, el módulo mantiene una temporización sencilla, eficiente y robusta, adaptada a las necesidades del sistema.

| Condición | `ms_q` siguiente | `secs_q` siguiente | `timeout_o` |
|---|---|---|---|
| `rst_i` activo | 0 | 0 | 0 |
| `load_i` activo | 0 | `seconds_i` | 0 |
| `run_i`, `tick_i`, `ms_q` < 999 | `ms_q` + 1 | `secs_q` | 0 |
| `run_i`, `tick_i`, `ms_q` = 999, `secs_q` > 0 | 0 | `secs_q` − 1 | 0 |
| `run_i`, `tick_i`, `ms_q` = 999, `secs_q` = 0 | 0 | 0 | **1** |
| `run_i` inactivo | `ms_q` | `secs_q` | 0 |



### Dimensionamiento del registro

El acumulador de milisegundos debe llegar hasta 999:

```
ceil(log2(1000)) = 10 bits        2^10 = 1024 >= 1000
```

El ancho se calcula en el código a partir del parámetro, con `$clog2`, de modo que si el
periodo del tick cambiara el registro se redimensiona solo.


El contador de segundos es de siete bits, lo que representa hasta 127. El valor más
grande que llega a cargarse es 60, correspondiente al modo fácil, de modo que existe
margen. Con seis bits, que llegan a 63, también alcanzaría, pero el margen sería de solo
tres unidades y cualquier cambio de los tiempos de juego obligaría a revisar el ancho.

### Verificación

| Caso | Qué comprueba |
|---|---|
| Carga y cuenta completa | que el intervalo medido sea el solicitado |
| Detención con `run_i` en bajo | que el valor se conserve y la cuenta no avance |
| Recarga a mitad de una cuenta | que el valor nuevo reemplace el anterior por completo |
| Llegada a cero | que la cuenta se detenga y no dé la vuelta |
| Nivel de vencimiento | que se mantenga activo mientras el temporizador esté habilitado |
| Vencimiento con el temporizador detenido | que no se active |


### Recursos

| Recurso | Cantidad |
|---|---|
| Registros | 17 (10 del acumulador y 7 del contador de segundos) |
| Incrementadores | 1 de 10 bits |
| Decrementadores | 1 de 7 bits |
| Comparadores de igualdad | 2 contra constantes |
| Multiplexores de carga | 2 |

---

## 4.4 `game_controller`
 

## Diagrama

![Diagrama game_controller](./FIGURAS/Diagrama_FSM.png)


## Maquina de Estados

![Diagrama game_controller](./FIGURAS/Maquina_estados_control.png)

### Objetivo

Implementar las reglas de la partida: seleccionar la palabra, validar cada letra
recibida, revelar las coincidencias, contar los errores, resolver el desenlace y
mantener el marcador acumulado de victorias, sin escribir directamente en ningún
periférico.



### Entradas

| Señal | Ancho | Descripción |
|---|---|---|
| `clk_i` | 1 bit | Reloj del sistema, 100 MHz. |
| `rst_i` | 1 bit | Reinicio síncrono, activo en alto. |
| `tick_i` | 1 bit | Habilitación de 1 ms, para contar los tres segundos del resultado. |
| `btn_sel_i` | 1 bit | Pulso de un ciclo del botón de selección de modo. |
| `btn_ok_i` | 1 bit | Pulso de un ciclo del botón de confirmación. |
| `lfsr_i` | 8 bits | Estado del generador pseudoaleatorio, en corrida libre. |
| `rom_data_i` | 96 bits | Palabra que entrega el banco para el índice pedido. |
| `rom_len_i` | 4 bits | Longitud de esa palabra. |
| `timer_timeout_i` | 1 bit | Nivel, el tiempo de la partida se agotó. |
| `rx_letter_i` | 8 bits | Letra recibida de la computadora, ya validada. |
| `rx_valid_i` | 1 bit | Pulso de un ciclo, hay una letra nueva. |
| `lcd_busy_i` | 1 bit | La capa de pantalla está ocupada. |
| `uart_busy_i` | 1 bit | La capa de protocolo está ocupada. |

### Salidas

Hacia el banco de palabras y el temporizador:

| Señal | Ancho | Descripción |
|---|---|---|
| `rom_index_o` | 6 bits | Índice de la palabra pedida. |
| `timer_load_o` | 1 bit | Pulso, carga el temporizador. |
| `timer_seconds_o` | 7 bits | Segundos que corresponden al modo elegido. |
| `timer_run_o` | 1 bit | Habilita el descuento. |

Hacia las dos capas de presentación:

| Señal | Ancho | Descripción |
|---|---|---|
| `screen_o` | 3 bits | Código de la pantalla que se quiere mostrar. |
| `redraw_o` | 1 bit | Pulso, redibujar el LCD. |
| `uart_event_o` | 2 bits | Código del evento a notificar. |
| `uart_send_o` | 1 bit | Pulso, notificar por el enlace serial. |

Datos de la jugada, que las dos capas leen:

| Señal | Ancho | Descripción |
|---|---|---|
| `word_data_o` | 96 bits | Palabra de la partida en curso. |
| `word_len_o` | 4 bits | Su longitud. |
| `revealed_o` | 12 bits | Bit en uno por cada posición ya descubierta. |
| `errors_o` | 3 bits | Errores cometidos, de 0 a 6. |
| `mode_o` | 1 bit | 0 fácil, 1 difícil. |
| `letter_o` | 8 bits | Letra que se acaba de evaluar. |
| `hit_o` | 1 bit | Si esa letra acertó. |
| `end_code_o` | 2 bits | 0 victoria, 1 derrota por fallos, 2 derrota por tiempo. |

Hacia el sonido y los indicadores locales:

| Señal | Ancho | Descripción |
|---|---|---|
| `snd_event_o` | 3 bits | Código del sonido a reproducir. |
| `snd_start_o` | 1 bit | Pulso, disparar el sonido. |
| `state_o` | 2 bits | 00 selección, 01 partida, 10 resultado. |
| `wins_bcd_o` | 8 bits | Victorias acumuladas, dos dígitos BCD. |




### Relación con otros módulos

`game_controller` se instancia una única vez en `top`, con el nombre de instancia
`juego`. Es el centro del sistema, pero con una restricción importante: **no escribe en
ningún periférico**. No sabe emitir un byte por el enlace serial ni un carácter en el
LCD.

| Módulo | Qué intercambian |
|---|---|
| `word_rom` | le coloca el índice y registra la palabra y su longitud |
| `lfsr` | captura su valor al confirmar el modo |
| `round_timer` | lo carga, lo habilita, lo detiene y lee su vencimiento |
| `lcd_screen_ctrl` | le pide una pantalla y espera a que deje de estar ocupada |
| `uart_msg` | le pide un evento, espera a que quede libre y recibe las letras validadas |
| `buzzer_controller` | le dispara un evento de sonido y no consulta nada |
| `display_controller` | le publica las victorias |
| `led_controller` | le publica el estado y el modo |
| `button_input` (`filtro_sel` y `filtro_ok`) | recibe los pulsos de modo y de confirmación |
| `clk_tick_gen` | recibe la habilitación de 1 ms |

Los datos de la jugada salen como un grupo de señales que las dos capas de presentación
leen en paralelo. El control las publica y cada capa toma lo que necesita: la de pantalla
usa la palabra, el patrón, los errores, el modo y las victorias; la de protocolo usa
además la letra, su resultado y el código de desenlace.




### Explicación de funcionamiento

La máquina de estados tiene doce estados y recorre el ciclo de una partida:

| Estado | Qué hace | Cómo sale |
|---|---|---|
| `S_DIBUJA_SEL` | pide la pantalla de selección | cuando la capa de pantalla acepta |
| `S_SELECCION` | `btn_sel_i` alterna el modo | `btn_ok_i` pasa a la carga |
| `S_CARGA` | lee la ROM y registra la palabra, limpia reveladas, usadas y errores, carga el temporizador | incondicional, un ciclo |
| `S_INICIO` | dispara la pantalla y la trama de comienzo | incondicional |
| `S_ESPERA_INICIO` | espera | cuando las dos capas están libres |
| `S_JUGANDO` | descuenta el tiempo, atiende `rx_valid_i` o el vencimiento | letra nueva o tiempo agotado |
| `S_EVALUA` | compara la letra, revela coincidencias, cuenta el error | incondicional, un ciclo |
| `S_PUBLICA` | dispara lo que corresponda a la jugada | incondicional |
| `S_ESPERA_JUGADA` | espera y resuelve el desenlace | cuando las dos capas están libres |
| `S_FIN` | dispara la pantalla de resultado, la trama y el sonido | incondicional |
| `S_ESPERA_FIN` | espera y arranca la cuenta de tres segundos | cuando las dos capas están libres |
| `S_RESULTADO` | cuenta los tres segundos | al vencer, vuelve a la selección |

**Selección de la palabra.** Al confirmar el modo se captura el generador. El índice se
arma truncando ese valor según el modo.

**Evaluación de la letra.** La comparación se hace contra las doce posiciones a la vez,
de modo que una letra que aparece varias veces en la palabra revela todas sus
apariciones en el mismo paso, sin repetir el proceso ni llevar un índice de recorrido.

**Letra repetida.** Se mantiene un registro con un bit por cada letra del alfabeto. Si la
letra ya estaba marcada, no consume intento, no toca el contador de errores y no se
vuelve a evaluar: solo se notifica a la computadora que fue repetida, y el LCD no se
redibuja porque nada visible cambió.


### Diseño

### Selección de la palabra por truncamiento

Del generador se conservan seis bits, y el índice se forma así:

```systemverilog
assign rom_index_o = mode_q ? {1'b0, lfsr_cap_q[4:0]} : lfsr_cap_q;
```

| Modo | Bits usados | Rango del índice | Tramo del banco |
|---|---|---|---|
| Difícil | `lfsr_cap_q[4:0]` | 0 a 31 | palabras de 6 letras o más |
| Fácil | `lfsr_cap_q[5:0]` | 0 a 63 | el banco entero |

En modo difícil el bit 5 se fuerza a cero, así que el rango de palabras cortas no se
puede alcanzar. El requisito de longitud mínima queda garantizado por construcción, sin
ninguna comprobación en la máquina de estados.



### Evaluación de la letra en paralelo

Para cada una de las doce posiciones se calculan dos bits:

```
mascara_valida[c] = (c < len_q)
coincide[c]       = (c < len_q) && (caracter[c] == letra_q)
```

y de ellos salen las cuatro señales que resuelven la jugada:

| Señal | Expresión | Significado |
|---|---|---|
| `acierto` | OR de todos los `coincide` | la letra está en la palabra |
| `rev_next` | `rev_q` OR `coincide` | posiciones reveladas después de la jugada |
| `gana` | `rev_next` igual a `mascara_valida` | no queda ninguna posición oculta |
| `err_next` | `acierto ? err_q : err_q + 1` | errores después de la jugada |

La máscara de validez es lo que hace que las posiciones de relleno no cuenten: sin ella,
`gana` nunca se cumpliría en una palabra de menos de doce letras, porque las posiciones
sobrantes jamás se revelan.

**Alternativa descartada: recorrido secuencial.** Comparar posición por posición
necesitaría doce ciclos y un contador de recorrido, y obligaría a un estado adicional
para el caso de la letra que aparece varias veces. La comparación en paralelo son doce
comparadores de ocho bits que caben de sobra en el ciclo de reloj.

### Tabla de resolución de la jugada

Se evalúa en este orden de prioridad:

| Prioridad | Condición | Desenlace | `end_code_o` |
|---|---|---|---|
| 1 | `gana` | victoria | 0 |
| 2 | `err_next` igual a 6 | derrota por fallos | 1 |
| 3 | `timer_timeout_i` | derrota por tiempo | 2 |
| — | ninguna | la partida continúa | — |

La victoria va primero porque una letra que completa la palabra no puede ser al mismo
tiempo un fallo. El sexto error pierde aunque quede tiempo en el reloj.

### Un solo estado de fin, no tres

Ganar, perder por fallos y perder por tiempo hacen exactamente lo mismo: pintar una
pantalla, notificar a la computadora, sonar y esperar. Lo único distinto entre los tres
es un código de dos bits, y ese código es justamente lo que las dos capas de presentación
reciben como entrada.

| Estrategia | Consecuencia |
|---|---|
| Tres estados de fin | la misma secuencia de publicación escrita tres veces, y tres lugares que mantener cuando cambie |
| Un estado con código de dos bits | una secuencia, y la diferencia queda en el camino de datos |

Tres estados idénticos que solo se diferencian en un dato pertenecen al camino de datos y
no al control. La diferencia sigue viéndose donde importa: el LCD muestra GANASTE,
PERDISTE: FALLOS o PERDISTE: TIEMPO, la computadora recibe WIN, LER o LTO, y el sonido de victoria es distinto al de derrota.

### Estado de carga separado

Las dos capas de presentación copian los datos de la partida en el mismo flanco en que
aceptan la orden. Eso obliga a separar el registro del disparo:

| Estrategia | Qué copiarían las capas |
|---|---|
| Registrar la palabra y disparar el dibujo en el mismo estado | los valores anteriores, porque el registro todavía no cambió |
| `S_CARGA` registra y `S_INICIO` dispara | los valores nuevos, un ciclo después |

El costo es un estado y un ciclo de reloj. Sin esa separación, la primera pantalla de cada
partida mostraría la palabra de la partida anterior.

### Atención diferida del vencimiento

`timer_timeout_i` es un nivel y no un pulso, y eso permite atenderlo cuando el control
está en condiciones:

| Momento en que vence el tiempo | Qué ocurre |
|---|---|
| En `S_JUGANDO` | se atiende de inmediato |
| Con una pantalla a medio pintar | el aviso sigue presente y se atiende en `S_ESPERA_JUGADA` |
| Con una trama a medio enviar | igual, al llegar al estado de espera |

Cortar a mitad dejaría media pantalla escrita en el LCD o una trama truncada en el enlace
serial, que la aplicación de computadora no podría trocear por posición.

### El temporizador no se detiene mientras se publica

Notificar una jugada tarda unos milisegundos entre el LCD y el enlace serial. Detener el
reloj en cada letra le regalaría ese tiempo al jugador, y en una partida con muchas
letras la diferencia se acumularía hasta que el límite dejara de ser el que declara el
modo. El temporizador solo se detiene en los estados de resultado.

### Contador de victorias en BCD con saturación

El destino del marcador es un par de dígitos de siete segmentos, así que se almacena ya
separado en decenas y unidades:

| Estado actual | Siguiente valor |
|---|---|
| unidades menores que 9 | unidades + 1 |
| unidades igual a 9 | decenas + 1, unidades a 0 |
| valor igual a `8'h99` | se mantiene en `8'h99` |

Guardarlo en BCD permite que `display_controller` solo parta el byte en dos grupos de
cuatro bits, sin necesidad de dividir entre diez. La saturación evita que después de 99
victorias el marcador vuelva a 00, y también que aparezca un código mayor que 9 en un
dígito, que el decodificador mostraría como un guion.

### Recepción del generador completo

El módulo recibe los ocho bits del `lfsr` aunque solo conserve seis. Descartar los dos
altos es la decisión que hace funcionar el truncamiento, así que vive en el control, que
es el módulo donde alguien la buscaría. Si el generador entregara solo seis bits, la
decisión quedaría escondida en un módulo donde nadie la leería.


### Verificación

| Caso | Qué comprueba |
|---|---|
| Reinicio | pantalla de selección, victorias en 00, errores en 0, sin reveladas |
| Cambio de modo | que `btn_sel_i` alterne y que el tiempo cargado corresponda |
| Letra correcta | revela todas las coincidencias en un paso |
| Letra incorrecta | incrementa errores y no revela nada |
| Letra repetida | no consume intento ni toca errores, y solo notifica |
| Victoria | se detecta al revelarse la última posición |
| Seis errores | derrota por fallos aunque quede tiempo |
| Vencimiento | derrota por tiempo |
| Vencimiento durante una publicación | la trama sale entera y después se resuelve |
| Prioridad | victoria antes que sexto error antes que vencimiento |
| Retorno | vuelve solo a la selección tras los tres segundos |
| Saturación del marcador | se queda en 99 |


### Recursos
| Recurso | Cantidad |
|---|---|
| Registros | 185 |
| Comparadores de 8 bits | 12, para la evaluación en paralelo |
| Registro de palabra | 96 bits |
| Registros de posiciones | 12 de reveladas y 26 de letras usadas |
| Contador de milisegundos | 1 de 12 bits, para los tres segundos |
| Contador BCD | 1 de 8 bits con saturación |


---