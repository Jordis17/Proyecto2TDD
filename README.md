# Ahorcado — juego electrónico FPGA / PC por enlace serial

Juego del Ahorcado sobre una **FPGA**, con una aplicación Python en la
PC que funciona como terminal remota a través de un enlace serial UART.

Curso: **EL3313 — Taller de Diseño Digital**
---
Vídeo para la defensa: https://youtu.be/WKnffdmOIWA
---
Toda la lógica del juego vive en la FPGA: el banco de palabras, la selección
pseudoaleatoria, la validación de letras, el temporizador, el conteo de errores y
la decisión del resultado. La PC solo envía la letra que el jugador escribe y
muestra lo que la FPGA responde.

| Modo | Palabras | Tiempo |
|---|---|---:|
| Fácil | cualquiera del banco | 60 s |
| Difícil | de 6 letras o más | 45 s |

---

## Estructura del repositorio

```
Ahorcado_juego_electrónico_FPGA_y_PC_por_enlace_serial/
├── FPGA/
│   ├── DESIGN/                módulos .sv sintetizables, núcleo UART .vhd y restricciones .xdc
│   └── SIMULATION/            testbenches .sv y modelo del núcleo UART
└── DOCUMENTATION/             documentación de cada subsistema
    ├── *.md
    └── FIGURAS/

PYTHON/
├── DESIGN/                    aplicación de terminal y generador del banco de palabras
├── SIMULATION/                prueba autoverificable de la terminal
└── DOCUMENTATION/
    ├── *.md
    └── FIGURAS/

Docs/
├── Diseño/                    documento de diseño (diseño modular por niveles)
│   └── FIGURAS/
└── Informe/                   informe técnico

Avance/                        primer avance del diseño
```

El proyecto de Vivado no se versiona: es un artefacto generado. Las fuentes son
`FPGA/DESIGN` y `FPGA/SIMULATION`.

---

---

## Dependencias

| Herramienta | Versión | Para qué |
|---|---|---|
| Xilinx Vivado | 2019.2 o superior | síntesis, implementación, simulación |
| Digilent Nexys 4 | rev. B | implementación física |
| PmodCLP | rev. B, 3.3 V | LCD 16×2, controlador Samsung KS0066 |
| Python | 3.8 o superior | aplicación de terminal y generador del banco |
| pyserial | `pip install pyserial` | comunicación UART desde la PC |

Se necesita además un altavoz amplificado o audífonos en el jack de 3.5 mm

---

## Conexión del hardware

El PmodCLP usa interfaz paralela de 8 bits y ocupa un conector Pmod completo más
media fila de otro:

| PmodCLP | Señales | Conector |
|---|---|---|
| J1, 12 pines | `DB0`–`DB7` | JA completo |
| J2, 6 pines | `RS`, `R/W`, `E` | JB7–JB9, fila inferior del JB |

| Botón | Función |
|---|---|
| Central (`BTNC`) | reinicio general |
| Izquierdo (`BTNL`) | alterna Fácil / Difícil |
| Derecho (`BTNR`) | confirma el modo e inicia la partida |

| LED | Indica |
|---|---|
| LD0 | pantalla de selección |
| LD1 | partida en curso |
| LD2 | mostrando el resultado |
| LD15 | modo difícil |

Los displays muestran las victorias en los dos dígitos de la derecha y el tiempo
restante en los dos dígitos a la derecha del bloque izquierdo.

El mapeo completo está en `FPGA/DESIGN/nexys4_ahorcado.xdc`.

---

## Compilación e implementación

Desde la consola Tcl de Vivado, con el proyecto creado sobre las fuentes de
`FPGA/DESIGN`:

```tcl
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
```

Después, programar la tarjeta desde el Hardware Manager.

Antes de dar por terminada la implementación hay que revisar el timing summary,
el slack, la frecuencia máxima y que no se hayan inferido latches.

---

## Simulación

Los testbenches de `FPGA/SIMULATION` son autoverificables: comprueban los
resultados y terminan con un resumen de pase o fallo, sin necesidad de
inspeccionar formas de onda. Hay uno por módulo con lógica propia, más `tb_top`,
que juega una partida completa mirando solo las patas del LCD y la línea serie.

Se corren en el simulador de Vivado eligiendo cuál es el tope de la simulación:

```tcl
set_property top tb_word_rom [get_filesets sim_1]
launch_simulation
```

`lcd_screen_pkg.sv` tiene que estar agregado al proyecto, porque los módulos del
LCD lo importan. Vivado resuelve el orden de compilación por su cuenta.

`uart_core_model.sv` es un modelo de comportamiento del núcleo UART que
instancian `tb_uart_msg`, `tb_uart_peripheral` y `tb_uart_test_block` como
extremo opuesto del cable, para no depender del núcleo VHDL ni de una PC durante
la simulación.

`tb_top` es el único que usa el núcleo UART en VHDL, porque instancia `top`
completo. Vivado entiende lenguaje mixto, así que corre sin nada aparte.

La simulación post-implementación temporizada se corre sobre una variante con las
constantes de tiempo reducidas, para que el arranque del LCD y las tramas UART
sean simulables en un tiempo razonable.

---

## Regenerar el banco de palabras

`FPGA/DESIGN/word_rom.sv` es un archivo generado. La lista de palabras vive
dentro de `PYTHON/DESIGN/gen_word_rom.py`.

```bash
cd PYTHON/DESIGN
python gen_word_rom.py           # valida y regenera word_rom.sv
python gen_word_rom.py --check   # solo valida
```

El script comprueba que haya 64 palabras distintas, que los índices 0–31 sean de
6 letras o más, que los 32–63 sean de 4 o 5, y que no haya caracteres fuera de
A-Z. De ese orden depende la selección de palabra: en modo difícil el índice sale
de los cinco bits bajos del LFSR, así que no puede caer fuera del rango largo.

---

## Ejecutar la aplicación de PC

```bash
cd PYTHON/DESIGN
pip install pyserial
python ahorcado_terminal.py --list               # muestra los puertos
python ahorcado_terminal.py --port COM4          # Windows
python ahorcado_terminal.py --port /dev/ttyUSB0  # Linux
```

Enlace a 115200 baudios. Para saber el puerto: `--list`, o en Windows el
Administrador de dispositivos, *Puertos (COM y LPT)*, y en Linux
`ls /dev/ttyUSB*`. En Windows el puerto no se puede compartir: si otro programa
lo tiene abierto, la terminal falla con `Access is denied`.

El modo y el inicio de la partida se eligen en la tarjeta, no aquí: la terminal
espera a que la FPGA anuncie el comienzo. Para cerrarla, escribir `salir` cuando
pida una letra, o `Ctrl+C` en cualquier momento.

Las pruebas de la terminal no necesitan la tarjeta: juegan una partida completa
contra un puerto serie falso que responde como respondería la FPGA.

```bash
cd PYTHON/SIMULATION
python test_terminal.py
```

---

## Protocolo

Mensajes ASCII terminados en salto de línea, con campos de ancho fijo.

**PC a FPGA:** un byte, de la `A` a la `Z`. Cualquier otro byte se descarta.

**FPGA a PC:**

| Mensaje | Contenido | Cuándo |
|---|---|---|
| `START:<M>:<LL>` | modo (`F`/`D`) y longitud en dos dígitos | al iniciar la partida |
| `PATT:<p>` | patrón, `_` en lo oculto | al iniciar y tras cada letra nueva |
| `LET:<X>:<R>` | letra y resultado, siempre 3 caracteres: `OK `, `NO `, `RPT` | al evaluar una letra |
| `ERR:<n>` | intentos fallidos restantes | al iniciar y tras cada letra nueva |
| `END:<E>:<W>` | causa (`WIN`, `LER` por errores, `LTO` por tiempo) y palabra secreta | al terminar |

Una letra repetida solo produce `LET:<X>:RPT`, sin `PATT` ni `ERR`.

```
START:F:07
PATT:_______
ERR:6
LET:A:OK·
PATT:____A__
ERR:6
LET:Z:NO·
PATT:____A__
ERR:5
LET:A:RPT
END:LTO:TECLADO
```

El `·` marca el espacio con que se rellenan `OK` y `NO` hasta tres caracteres.
No se transmite un punto: se transmite un espacio.

El tiempo restante no se transmite: se muestra en los displays de 7 segmentos.

---

## Documentación

- Diseño por niveles: [`Docs/Diseño/Diseño.md`](Docs/Diseño/Diseño.md)
- Informe técnico: [`Docs/Informe/Informe.md`](Docs/Informe/Informe.md)
- Subsistemas: [`Ahorcado_juego_electrónico_FPGA_y_PC_por_enlace_serial/DOCUMENTATION`](Ahorcado_juego_electrónico_FPGA_y_PC_por_enlace_serial/DOCUMENTATION)
- Aplicación de PC y generador: [`PYTHON/DOCUMENTATION`](PYTHON/DOCUMENTATION)
