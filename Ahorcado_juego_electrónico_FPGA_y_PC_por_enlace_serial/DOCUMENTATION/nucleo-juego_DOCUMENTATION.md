# Subsistema nucleo-juego — Ahorcado FPGA/PC


## 1. Introducción



La versión final del subsistema está formada por cuatro módulos principales:
* `lfsr`
* `word_rom`
* `round_timer`
* `game_controller`





## 2. Descripción general del sistema





## 3. Diagrama modular de la versión final



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


### Objetivo




### Entradas


### Salidas





### Relación con otros módulos





### Explicación de funcionamiento




### Diseño



### Dimensionamiento del registro



### Verificación


### Recursos



---