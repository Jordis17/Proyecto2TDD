# Defensa Escrita — Generador del Banco de Palabras (`gen_word_rom.py`)

**Proyecto:** EL3313 — Taller de Diseño Digital, Proyecto 2 (Ahorcado FPGA/PC)
**Componente:** Herramienta de escritorio (offline) que genera hardware a partir de datos

> **Nota sobre las fuentes de este documento:** este análisis se hizo a partir de `README_gen_word_rom.md` y del diagrama de flujo `gen_word_rom_flujo.png`. No se tuvo acceso al archivo `gen_word_rom.py` en sí, así que las referencias son a funciones y comportamiento descritos en la documentación, no a números de línea. Si se sube el `.py`, este documento se puede ajustar para citar líneas exactas, igual que se hizo con la terminal.

---

## 1. Rol dentro del sistema completo

Este script **no corre en la FPGA ni durante la partida**: es una herramienta de desarrollo que se ejecuta en la PC, una vez (o cada vez que se edita el banco de palabras), para producir `word_rom.sv` — el módulo de SystemVerilog que el hardware sí usa en tiempo real. Es el mismo patrón que ya se justificó para la terminal del jugador: mantener en Python (fácil de leer, editar y validar) todo lo que no necesita correr en hardware, y generar automáticamente solo el artefacto final que sí lo necesita.

Vale la pena decirlo explícito en la defensa: **`gen_word_rom.py` es una herramienta de generación de hardware (un "code generator"), no parte del sistema en ejecución.** Si el jurado pregunta "¿esto corre en la tarjeta?", la respuesta es no — genera un archivo `.sv` que después se sintetiza junto con el resto del proyecto.

---

## 2. El contrato entre el banco de palabras y el hardware

Este es el punto más importante para defender, porque es el que menos obvio resulta a primera vista: **el orden de la lista de palabras en Python no es cosmético, es parte del contrato con el hardware.**

- El banco tiene exactamente **64 palabras** (`N_WORDS`), divididas por posición, no por ningún campo separado:
  - Índices **0–31**: palabras de 6+ letras (`N_HARD` = 32, `HARD_MIN_LEN` = 6). Sirven para Difícil y para Fácil.
  - Índices **32–63**: palabras de 4–5 letras. Solo sirven para Fácil.
- La FPGA elige la palabra **truncando directamente los bits del LFSR**, sin módulo ni descarte de valores:

```
DIFICIL: rom_index = lfsr[4:0]   -> 0..31
FACIL:   rom_index = lfsr[5:0]   -> 0..63
```

Esto significa que si una palabra corta se colara entre los índices 0–31, el modo Difícil podría sortear (por construcción del hardware, no por un bug de lógica) una palabra que no cumple su propio mínimo de longitud. Por eso `validate()` no solo revisa que las palabras sean válidas individualmente, sino que cada una **esté del lado correcto de la frontera** según su longitud — es una regla de integridad estructural del banco, no un detalle estético.

**Por qué truncar el LFSR en vez de usar módulo o rechazo de valores:** truncar bits es gratis en hardware (no requiere un divisor ni lógica de reintento); usar módulo o descartar valores fuera de rango sí cuesta lógica y ciclos. La contrapartida de esa simplicidad es que el banco *tiene* que tener exactamente 32 y 32 palabras, ordenadas así — de ahí que el script valide el conteo exacto antes de generar nada.

---

## 3. Las piezas del programa

| Pieza | Qué es | Para qué sirve |
|---|---|---|
| `MAX_LEN`, `N_WORDS`, `N_HARD`, `HARD_MIN_LEN` | Constantes de contrato | Fijan los números que el módulo `word_rom` en SystemVerilog espera; si cambian aquí, hay que revisar también el hardware |
| `HARD_WORDS`, `EASY_WORDS` | Listas de texto en Python | Las 32 palabras largas y las 32 cortas, editables a mano |
| `WORDS` | `HARD_WORDS + EASY_WORDS` | El banco completo, ya en el orden que el hardware usa como índice |
| `validate(WORDS)` | Validador | Revisa cantidad exacta, sin repetidas, alfabeto A-Z, largo máximo, y frontera Difícil/Fácil — acumula **todos** los errores antes de reportar |
| `emit_sv(WORDS)` | Generador | Arma el texto completo del módulo `word_rom.sv`: encabezado, declaración, `case` con una entrada por palabra más un valor por omisión |
| `main()` | Orquestador | Llama a `validate()`, decide si continuar o abortar, imprime el resumen, respeta `--check`, y si corresponde llama a `emit_sv()` y escribe el archivo |

---

## 4. Recorrido del diagrama de flujo

![Diagrama de flujo del generador de banco de palabras](FIGURAS/gen_word_rom_flujo.png)

El diagrama sigue exactamente la lógica de `main()` descrita en el README:

1. **`validate(WORDS)`** — se corre siempre, antes de tocar cualquier archivo.
2. **¿Hay errores?**
   - **Sí →** se imprime `FAIL` junto con **cada** error encontrado (no solo el primero) y el programa termina con `return 1`. Este código de retorno distinto de cero es importante si el script se llama desde un flujo automatizado (por ejemplo, un `Makefile` o un script de build): permite detectar la falla sin tener que leer la salida de texto.
   - **No →** se imprime `PASS` junto con estadísticas del banco (cuántas palabras de cada tipo, cuánto ocupa en bits) y se continúa.
3. **`--check`** (bandera de línea de comandos):
   - **Sí →** se termina con `return 0` **sin generar nada**. Esto separa "¿el banco es válido?" de "generar el hardware", útil para revisar el banco mientras se edita sin sobrescribir el `.sv` en cada intento.
   - **No →** se sigue al generador.
4. **`emit_sv(WORDS)`** — arma el texto completo del módulo.
5. **Escribir `word_rom.sv`** — se guarda el archivo generado.
6. **Imprimir la ruta generada** — confirmación en pantalla de dónde quedó el archivo.
7. **`return 0`** — fin exitoso.

**Nota sobre la numeración del diagrama:** los números dentro de las cajas (`3.`, `4.`, `5.`) se repiten entre la rama de error y la rama de éxito porque cuentan el paso **dentro de cada rama**, no una numeración global del diagrama completo. Si el jurado pregunta por qué hay dos cajas distintas marcadas "3.", esa es la razón: son el tercer paso de caminos distintos, no el mismo paso duplicado.

---

## 5. Decisiones de diseño y su justificación

- **Separar el banco de palabras del hardware que lo usa:** escribir 64 entradas de un `case` a mano, con el texto empacado en bits, es tedioso y propenso a error. Mantener el banco como una lista de Python legible, y generar el `.sv` automáticamente, mueve el riesgo de error humano a un solo lugar (la lista) en vez de repartirlo por todo el archivo generado.
- **`validate()` acumula todos los errores en vez de detenerse en el primero:** si el banco tiene, por ejemplo, tres palabras repetidas y dos con tilde, es más eficiente corregir las cinco de una vez que descubrirlas una por una en corridas sucesivas del script.
- **Validar la frontera Difícil/Fácil según la posición, no solo el contenido:** como se explicó en la sección 2, esta es la regla que protege la suposición de hardware de que "truncar el LFSR = índice válido". Sin esta validación, un banco "válido" en apariencia (64 palabras, sin repetidas, alfabeto correcto) podría seguir rompiendo la garantía de longitud mínima del modo Difícil.
- **La bandera `--check`:** separa la pregunta "¿es válido el banco?" de la acción "generar el archivo". Esto evita sobrescribir `word_rom.sv` cada vez que se está iterando sobre el banco de palabras, y es el tipo de opción típica de una herramienta de build (equivalente a un "dry run").
- **Rellenar cada palabra con espacios hasta `MAX_LEN` y guardar el largo real aparte:** el bus de datos en el hardware tiene un ancho fijo (determinado por la palabra más larga permitida), así que todas las entradas del `case` deben tener el mismo ancho de bits aunque las palabras tengan distinta longitud real; guardar el largo real por separado es lo que le permite al resto del circuito saber dónde termina la palabra dentro del campo de ancho fijo.
- **Mismo alfabeto (A-Z, sin tildes ni Ñ) que valida `ahorcado_terminal.py` del lado PC:** esto no es casualidad — es el mismo alfabeto que la FPGA entiende en todo el sistema. La terminal descarta en la entrada del jugador lo que el banco de palabras nunca podría contener, y viceversa: si el banco tuviera una palabra fuera de ese alfabeto, ninguna letra que el jugador pudiera enviar coincidiría nunca con ese carácter. Vale la pena mencionar esta coherencia entre los dos scripts si el jurado pregunta cómo se garantiza que "todo hable el mismo idioma" en el proyecto.
- **Código de retorno distinto según el resultado (`return 1` en falla, `return 0` en éxito o en `--check`):** permite integrar el script en un flujo de compilación automatizado que necesite saber si generar el hardware fue exitoso, sin depender de parsear la salida de texto.

---

## 6. Preguntas esperadas del jurado y respuestas sugeridas

**¿Por qué no escribir `word_rom.sv` directamente a mano?**
Porque el banco tiene una regla estructural (el orden define el rango del LFSR) que es fácil de romper por accidente al editar un `case` de 64 entradas a mano; automatizar la generación mueve esa validación a un solo lugar, ejecutado cada vez.

**¿Qué pasa si agrego una palabra de 5 letras en el rango 0–31 por error?**
`validate()` lo detecta como un error de frontera Difícil/Fácil y el script termina con `FAIL` sin generar nada — nunca se produce un `word_rom.sv` a partir de un banco inválido.

**¿Por qué el hardware no valida el banco también?**
Porque el banco se fija en tiempo de síntesis, no en tiempo de ejecución: la validación tiene que pasar *antes* de generar el hardware, no durante el juego. Validar en tiempo de ejecución en la FPGA sería gastar lógica en comprobar algo que ya se garantizó en el flujo de generación.

**¿Qué significa `--check` exactamente?**
Ejecuta la misma validación completa, pero se detiene ahí: no llama a `emit_sv()` ni escribe ningún archivo. Sirve para revisar el banco mientras se edita, sin regenerar el hardware en cada intento.

**¿Por qué el banco tiene que ser de exactamente 64 palabras y no una cantidad flexible?**
Porque el índice del LFSR truncado tiene un rango fijo determinado por su ancho de bits (`lfsr[5:0]` da 64 valores posibles); si el banco tuviera menos de 64 palabras, algunos valores del LFSR no tendrían palabra asociada, y si tuviera más, algunas palabras nunca podrían salir sorteadas.

---

## 7. Conclusión

`gen_word_rom.py` traslada al mundo de Python (donde es barato validar y fácil de leer) una responsabilidad que de otro modo viviría, frágil y oculta, dentro de un `case` de SystemVerilog escrito a mano: garantizar que el banco de palabras cumpla exactamente las suposiciones que el hardware hace sobre él para poder sortear una palabra con solo truncar bits. La validación exhaustiva antes de generar cualquier archivo, la bandera `--check` para iterar sin sobrescribir, y la coherencia de alfabeto con el resto del proyecto son las tres piezas que hay que poder justificar si se pregunta por qué el script está construido así y no de otra forma.

---

