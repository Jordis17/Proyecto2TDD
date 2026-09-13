# Terminal del Jugador — `ahorcado_terminal.py`

## ¿Qué es este programa?

Es la aplicación que corre en la computadora para poder jugar Ahorcado
contra una tarjeta FPGA. El juego completo (elegir la palabra secreta,
revisar cada letra, contar los intentos fallidos y controlar el tiempo)
lo hace la FPGA. Esta terminal no juega ni decide nada: solo manda la
letra que la persona escribe y muestra en pantalla lo que la FPGA
contesta. Es, básicamente, un traductor entre el teclado de la
computadora y el puerto serie.

## ¿Por qué se necesita, si el juego ya vive en la FPGA?

Porque la FPGA no tiene teclado ni una pantalla cómoda para escribir
texto. Alguien tiene que:

1. Preguntarle a la persona qué letra quiere jugar y revisar que tenga
   sentido (que sea una sola letra, entre la A y la Z).
2. Convertir esa letra en un byte y mandarlo por el puerto serie.
3. Recibir lo que la FPGA contesta (que también son bytes) y
   convertirlo de vuelta en algo legible: la palabra con guiones, los
   intentos que quedan, si ganó o perdió.

Ese trabajo de "traducir en los dos sentidos" es exactamente lo que
hace este programa.

## Cómo se hablan la computadora y la FPGA

**De la computadora hacia la FPGA** va un solo byte por turno: una
letra de la A a la Z.

**De la FPGA hacia la computadora** llegan líneas de texto que siempre
terminan en un salto de línea, y donde cada dato ocupa un lugar fijo
dentro de la línea (ancho fijo). Gracias a eso, la terminal nunca tiene
que "adivinar" dónde empieza o termina un dato: siempre está en la
misma posición, así que se puede cortar la línea por posición en vez
de usar reglas complicadas de búsqueda de texto.

Los tipos de línea que puede mandar la FPGA son:

| Línea    | Qué avisa |
|----------|-----------|
| `START`  | Empieza una partida nueva: en qué modo (Fácil o Difícil) y de cuántas letras es la palabra. |
| `PATT`   | El patrón actual de la palabra, con guion bajo donde todavía falta adivinar. |
| `LET`    | Qué pasó con la última letra jugada: correcta, incorrecta o repetida. |
| `ERR`    | Cuántos intentos fallidos le quedan al jugador. |
| `END`    | Cómo terminó la partida (ganó, se acabaron los intentos o se acabó el tiempo) y cuál era la palabra completa. |

Si llega una línea rara o incompleta, el programa simplemente la
descarta y avisa que no la entendió; nunca se cae por eso.

## Las piezas del programa, una por una

### 1. El analizador de líneas — `parsear()`
Recibe una línea de texto y decide de qué tipo es, revisando su forma:
que empiece con la palabra clave correcta, que tenga el largo
esperado, que los datos en esas posiciones tengan sentido. Si algo no
cuadra, devuelve "no reconocido" en vez de intentar forzar una
interpretación.

### 2. El hilo lector — `lector()`
Un "hilo" es como una segunda tarea que corre al mismo tiempo que el
resto del programa, sin estorbarse. Esta tarea está todo el tiempo
leyendo bytes del puerto serie y armando líneas completas. Cada vez
que encuentra un salto de línea, entrega esa línea a una **cola**
(una especie de bandeja de entrada, donde las cosas se van apilando en
el orden en que llegan) para que el resto del programa la revise
cuando pueda.


### 3. El estado que se muestra — clase `Estado`
Es una libreta que solo guarda lo último que contó la FPGA: la
palabra con sus guiones, cuántos intentos quedan y cuál fue la última
letra jugada. No decide nada del juego, solo recuerda lo que ya se dijo
para poder mostrarlo ordenado en pantalla.

### 4. Preguntar la letra — `pedir_letra()`
Le pregunta a la persona qué letra quiere jugar y revisa que sea
válida: una sola letra, de la A a la Z, sin tildes ni la letra Ñ
(porque el banco de palabras de la FPGA no las usa). Si la respuesta
no tiene sentido, vuelve a preguntar. La única forma de salir del
programa desde aquí es escribiendo "salir".

### 5. El ciclo principal — `jugar()`
Es el corazón del programa. Se turna constantemente entre dos cosas:

- Revisar si llegó algo nuevo de la FPGA (sacándolo de la cola),
  traducirlo con `parsear()` y actualizar lo que se ve en pantalla.
- Preguntarle a la persona su letra y mandarla por el puerto serie.

Justo antes de mandar la letra, se revisa si
mientras la persona estaba escribiendo llegó un aviso de que la
partida ya terminó. Si eso pasó, la letra ya no se manda, porque no
tendría sentido jugarla en una partida que ya se acabó.

### 6. El arranque — `main()`
Es la parte de "poner todo en marcha": lee las opciones con las que se
ejecutó el programa (qué puerto usar, a qué velocidad), abre la
conexión serie con la FPGA, arranca el hilo lector, y por último llama
a `jugar()` para que empiece la partida.

## En resumen

Este programa no juega Ahorcado: hace de intérprete entre una persona
y una FPGA. Escucha todo el tiempo con un hilo aparte para no perderse
ningún aviso importante, entiende lo que la FPGA dice porque los
mensajes siempre vienen con el mismo formato fijo, y manda al puerto
serie solamente letras que ya se revisaron como válidas.