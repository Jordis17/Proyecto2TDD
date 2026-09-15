# Cómo funciona `gen_word_rom.py`

## Qué es y para qué sirve

Este script no corre en la FPGA ni durante la partida. Es una herramienta que se corre en la computadora, una sola vez (o cada vez que se cambia el banco de palabras), y lo que hace es tomar una lista de palabras escrita en Python y convertirla en `word_rom.sv`, el módulo de SystemVerilog que la FPGA sí usa mientras el juego está corriendo.

La idea de fondo es simple: escribir 64 palabras a mano dentro de un `case` de SystemVerilog, con el texto empacado en bits, sería tedioso y muy fácil de equivocar. Entonces el banco se escribe donde es cómodo editarlo (una lista de Python) y este script se encarga de revisar que esté bien armado y de generar el archivo `.sv` a partir de eso.

## Por qué el orden de la lista no es solo estético

Esta es la parte más importante de entender antes de leer el resto del código. El banco tiene exactamente 64 palabras, y se dividen en dos mitades **por posición**, no porque tengan una etiqueta aparte que diga "esta es difícil" o "esta es fácil":

- Índices 0 a 31: palabras de 6 letras o más. Sirven para el modo DIFICIL y también para FACIL.
- Índices 32 a 63: palabras de 4 o 5 letras. Solo sirven para FACIL.

¿Por qué importa el orden? Porque en la FPGA, la palabra se escoge truncando directamente los bits del LFSR, sin módulo, sin descartar valores y sin ningún bucle de reintento:

```
DIFICIL: rom_index = lfsr[4:0]   -> 0..31
FACIL:   rom_index = lfsr[5:0]   -> 0..63
```

En otras palabras, el índice que sale del LFSR ya es, tal cual, la dirección del banco. Eso es baratísimo en hardware (truncar bits no cuesta nada), pero la contrapartida es que si a alguien se le ocurre meter una palabra corta en medio de los índices 0-31, el modo DIFICIL podría terminar sorteando una palabra que no cumple su propio mínimo de 6 letras, sin que nadie se dé cuenta hasta que ya está jugando. Por eso el script no solo revisa que cada palabra esté bien escrita: también revisa que esté del lado correcto de esa frontera.

## Recorriendo el código

### Las constantes de arriba

```python
MAX_LEN = 12
N_WORDS = 64
N_HARD = 32
HARD_MIN_LEN = 6
```

Estas cuatro constantes establecen las restricciones que debe cumplir el banco de palabras para ser compatible con el hardware. `MAX_LEN` define cuántos bits mide `word_data_o` en el módulo generado (8 bits por carácter, hasta 12 caracteres). `N_WORDS`, `N_HARD` y `HARD_MIN_LEN` son justo los números que le permiten al RTL usar el LFSR truncado como índice sin tener que validar nada mientras el juego corre. Si cualquiera de estas cuatro cambia, hay que ir a revisar también el módulo de SystemVerilog que consume el ROM, porque ahí también se usan esos mismos números como parámetros.

### `HARD_WORDS`, `EASY_WORDS` y `WORDS`

`HARD_WORDS` son las 32 palabras largas y `EASY_WORDS` las 32 cortas. `WORDS = HARD_WORDS + EASY_WORDS` consiste simplemente en concatenar las dos listas, porque ese orden es justo el que después se convierte en índice del ROM. Las dos listas contienen 32 palabras cada una. `HARD_WORDS` trae 32 palabras (todas entre 6 y 11 letras, dentro del límite de `MAX_LEN`) y `EASY_WORDS` trae otras 32 (todas de 4 o 5 letras). Esto coincide con los valores definidos por las constantes.

### `validate(words)`

Esta función no genera nada, solo revisa. Junta una lista de errores en vez de detenerse en el primero que encuentra — esto tiene sentido porque si uno está armando el banco a mano y comete tres o cuatro errores de una vez, es mucho mejor verlos todos juntos que corregir uno, correr el script de nuevo, corregir otro, y así.

Lo que revisa, en orden:

1. Que haya exactamente `N_WORDS` palabras (64). Si hay de más o de menos, ya no cuadra con el ancho del índice del LFSR.
2. Que no haya palabras repetidas.
3. Para cada palabra: que sea puro A-Z mayúscula (usa `w.isascii() and w.isalpha() and w.isupper()`, que entre las tres condiciones terminan en conjunto exigen exactamente esas condiciones, sin tildes ni Ñ, porque la FPGA no tiene tabla para esos caracteres y tampoco los podría comparar con lo que llega por UART).
4. Que la longitud esté entre 4 y `MAX_LEN`.
5. Que si el índice es menor que `N_HARD` (o sea, está en la mitad de DIFICIL), la palabra tenga al menos `HARD_MIN_LEN` letras.
6. Que si el índice es mayor o igual a `N_HARD` (la mitad de FACIL), la palabra tenga **menos** de `HARD_MIN_LEN` letras (en la práctica, 4 o 5).

Los dos últimos puntos garantizan la separación entre las palabras de ambos modos de juego: el truncamiento del LFSR.

### `emit_sv(words)`

- Arma todo como una lista de líneas de texto (`lines.append`) y al final las junta con saltos de línea. Es más fácil de leer y de depurar que ir concatenando un string gigante.
- El encabezado del archivo generado avisa explícitamente "ARCHIVO GENERADO AUTOMATICAMENTE. No editar a mano." — un detalle chiquito pero importante para que nadie edite el `.sv` directamente y pierda el cambio la próxima vez que se regenere.
- Explica en un comentario cómo queda empacada cada palabra dentro de `word_data_o`: el primer carácter de la palabra queda en los bits más significativos. Esto es porque al escribir un string de Python como literal de texto en SystemVerilog (`"PUERTA      "`), el primer carácter queda naturalmente en la parte alta del vector.
- Cada palabra se rellena con espacios hasta `MAX_LEN` usando `w.ljust(MAX_LEN)`, porque el ancho de `word_data_o` en hardware es fijo — todas las entradas del `case` tienen que ocupar el mismo tamaño, sin importar si la palabra real mide 4 letras o 11. Por separado se guarda `word_len_o` con el largo real, para que el resto del para que el resto del circuito conozca la longitud real de la palabra.
- El formato `6'd{i:<2}` y `4'd{len(w):<2}` con el `<2` no cambia el valor, solo lo alinea visualmente con espacios para que el archivo generado se vea ordenado si alguien lo abre a revisar — únicamente mejora la legibilidad del archivo generado.
- Al final agrega un `default` para cuando `index_i` caiga fuera de las 64 entradas válidas. En teoría esto no debería pasar nunca en operación normal, el `case` debe definir un comportamiento para cualquier valor posible de index_i. Algo definido para cualquier valor posible, así que se entrega una palabra vacía en vez de dejar la salida sin definir (lo cual generaría un latch o un valor `X` en simulación).

### `main()`

Es la parte que decide qué hacer con las dos funciones de arriba:

1. Llama a `validate(WORDS)`.
2. Si hay errores, imprime `FAIL` con cada uno de ellos y termina devolviendo `1` — no llega a tocar ningún archivo.
3. Si no hay errores, imprime `PASS` junto con un resumen: cuántas palabras hay en total, cuántas son válidas para DIFICIL (con su rango de longitudes), cuántas son solo de FACIL, la longitud máxima encontrada, y cuánto ocupa el banco completo en bits.
4. Si se corrió con `--check`, se detiene ahí y devuelve `0` sin generar nada — sirve para revisar que el banco esté bien mientras se está editando, sin necesidad de regenerar el `.sv` cada vez.
5. Si no se pidió `--check`, llama a `emit_sv(WORDS)`, escribe el resultado en la ruta calculada a partir de la ubicación del propio script, e imprime esa ruta como confirmación.

## Cómo se ve esto en el diagrama de flujo

![Diagrama de flujo de gen_word_rom.py](FIGURAS/gen_word_rom_flujo.png)

El diagrama sigue exactamente esta lógica de `main()`. Un detalle importante es que los números dentro de las cajas (3., 4., 5.) se repiten porque cada rama del diagrama tiene su propia numeración interna, se repiten entre la rama de "hay errores" y la rama de "no hay errores" porque cada rama cuenta sus propios pasos por separado, no es una numeración corrida de todo el diagrama. No es un error, solo hay que tenerlo claro para no confundirse pensando que hay dos pasos "3" iguales.

## En resumen

`gen_word_rom.py` hace tres cosas, en este orden: valida que el banco de palabras cumpla exactamente lo que el hardware necesita (cantidad, alfabeto, largo, y sobre todo el orden que hace posible truncar el LFSR sin módulo), imprime un resumen para saber que todo salió bien, y solo si todo está en regla genera el archivo `.sv` final. La bandera `--check` permite hacer solo la primera parte, útil mientras se está editando el banco a mano.
