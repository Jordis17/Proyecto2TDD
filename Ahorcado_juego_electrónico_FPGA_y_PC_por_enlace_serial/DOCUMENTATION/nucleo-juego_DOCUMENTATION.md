# Subsistema nucleo-juego — Ahorcado FPGA/PC


## 1. Introducción



La versión final del subsistema está formada por cuatro módulos principales:

* `game_controller`
* `lfsr`
* `round_timer`
* `word_rom`



## 2. Descripción general del sistema





## 3. Diagrama modular de la versión final



# 4. Descripción de los módulos

## 4.1 `lfsr`

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

| Propiedad | Cómo se comprueba |
|---|---|
| Los 255 estados son distintos | se recorre la secuencia completa marcando cada valor visto y se verifica que ninguno se repita antes del ciclo 255 |
| El cero nunca aparece | se comprueba en cada ciclo del recorrido |
| La secuencia es reproducible | tras un reinicio, la secuencia vuelve a ser la misma |

### Recursos


| Recurso | Cantidad |
|---|---|
| Registros | 8 |
| Compuertas XOR | 1 de cuatro entradas |
| Multiplexores | 1 de dos entradas, para la carga de la semilla |

---

## 4.2 `word_rom`

## 4.3 `round_timer`

## 4.4 `game_controller`