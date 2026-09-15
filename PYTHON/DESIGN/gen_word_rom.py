"""
Generador del banco de palabras -> FPGA/DESIGN/word_rom.sv

Fuente unica de verdad del banco. El orden de esta lista NO es
cosmetico: es lo que hace posible la seleccion directa del indice.

    indices  0..31 -> longitud >= 6  (validas para DIFICIL y para FACIL)
    indices 32..63 -> longitud 4 o 5 (validas solo para FACIL)

Gracias a ese orden, la seleccion de palabra es un truncamiento directo
del LFSR, sin modulo, sin rechazo y sin bucles:

    DIFICIL: rom_index = lfsr[4:0]   -> 0..31
    FACIL:   rom_index = lfsr[5:0]   -> 0..63

Uso:
    python gen_word_rom.py            # valida y genera ../rtl/word_rom.sv
    python gen_word_rom.py --check    # solo valida, no escribe
"""

import argparse
import sys
from pathlib import Path

# Estas cinco constantes son el contrato con el hardware: MAX_LEN fija
# el ancho de word_data_o, y N_WORDS/N_HARD/HARD_MIN_LEN son justo lo
# que le permite al RTL usar el LFSR truncado como indice, sin validar
# nada en tiempo de ejecucion. Si alguna cambia, hay que revisar tambien
# el modulo que la consume en SystemVerilog.
MAX_LEN = 12
N_WORDS = 64
N_HARD = 32
HARD_MIN_LEN = 6

# --- Indices 0..31 : longitud >= 6 -----------------------------------------
# El orden de esta lista importa: el indice dentro de HARD_WORDS es el
# mismo que despues usa el hardware, asi que agregar o quitar una
# palabra de en medio corre el indice de todas las que vienen despues.
HARD_WORDS = [
    "PUERTA", "SENSOR", "VOLCAN", "MADERA", "CAMISA",
    "BOTELLA", "VENTANA", "TECLADO", "MONITOR", "MEMORIA",
    "SISTEMA", "DIGITAL", "LAMPARA", "ESCUELA", "PLANETA",
    "CIRCUITO", "REGISTRO", "CONTADOR", "GUITARRA", "ELEFANTE",
    "MARIPOSA", "TELEFONO", "PANTALLA", "CUADERNO",
    "BICICLETA", "INGENIERO", "MICROFONO",
    "VENTILADOR",
    "COMPUTADORA", "LABORATORIO", "HERRAMIENTA", "RESISTENCIA",
]

# --- Indices 32..63 : longitud 4 o 5 ---------------------------------------
EASY_WORDS = [
    "CASA", "MESA", "SILLA", "LIBRO", "PERRO", "GATO", "LUNA", "NUBE",
    "FLOR", "ARBOL", "CIELO", "FUEGO", "AGUA", "VERDE", "ROJO", "AZUL",
    "NEGRO", "CINCO", "TRES", "SIETE", "OCHO", "NUEVE", "LAPIZ", "PAPEL",
    "CABLE", "DATOS", "RELOJ", "CHIP", "PUNTO", "CAMPO", "PLAYA", "BARCO",
]

# El banco completo, en el mismo orden en que despues se numeran los
# indices del ROM: primero las 32 de DIFICIL, luego las 32 de FACIL.
WORDS = HARD_WORDS + EASY_WORDS


def validate(words):
    """Devuelve una lista de errores. Vacia = banco valido.

    Revisa tanto el tamaño y el contenido de cada palabra (alfabeto,
    largo) como el orden exigido por el hardware (las primeras N_HARD
    deben ser largas, el resto cortas). Se acumulan todos los errores
    en vez de detenerse en el primero, para poder corregir el banco de
    una sola pasada en vez de una palabra a la vez.
    """
    errs = []

    if len(words) != N_WORDS:
        errs.append(f"se esperaban {N_WORDS} palabras, hay {len(words)}")

    dupes = {w for w in words if words.count(w) > 1}
    if dupes:
        errs.append(f"palabras repetidas: {sorted(dupes)}")

    for i, w in enumerate(words):
        # Solo A-Z mayusculas: la FPGA no tiene tabla de tildes ni de
        # la N con virgulilla, asi que cualquier otro caracter no se
        # podria ni mostrar en el LCD ni comparar con lo que llega por
        # UART.
        if not w.isascii() or not w.isalpha() or not w.isupper():
            errs.append(f"[{i}] '{w}': solo se permiten A-Z mayusculas "
                        f"(sin tildes ni N con virgulilla)")
        if not (4 <= len(w) <= MAX_LEN):
            errs.append(f"[{i}] '{w}': longitud {len(w)} fuera de 4..{MAX_LEN}")
        # Estas dos comprobaciones son las que protegen el truncamiento
        # directo del LFSR: si una palabra corta se colara entre los
        # indices de DIFICIL (o una larga entre los de FACIL), el modo
        # DIFICIL podria sortear una palabra que no cumple su propio
        # minimo de longitud.
        if i < N_HARD and len(w) < HARD_MIN_LEN:
            errs.append(f"[{i}] '{w}': longitud {len(w)} < {HARD_MIN_LEN}; "
                        f"los indices 0..{N_HARD-1} son del modo DIFICIL")
        if i >= N_HARD and len(w) >= HARD_MIN_LEN:
            errs.append(f"[{i}] '{w}': longitud {len(w)} >= {HARD_MIN_LEN}; "
                        f"los indices {N_HARD}..{N_WORDS-1} deben ser de 4 o 5")

    return errs


def emit_sv(words):
    """Arma el texto completo del modulo word_rom en SystemVerilog.

    Se construye como una lista de lineas (mas facil de leer y de
    editar que una sola cadena gigante) y se junta con saltos de linea
    al final. El modulo resultante es puro combinacional: un case con
    una entrada por palabra, mas un default para indices fuera de rango.
    """
    lines = []
    a = lines.append

    a("// =====================================================================")
    a("// word_rom.sv - Banco de palabras del Ahorcado")
    a("//")
    a("// ARCHIVO GENERADO AUTOMATICAMENTE. No editar a mano.")
    a("// Fuente: python/gen_word_rom.py")
    a("// Regenerar con: python gen_word_rom.py")
    a("//")
    a("// Orden del banco (de esto depende la seleccion del indice):")
    a(f"//   indices  0..{N_HARD-1} -> longitud >= {HARD_MIN_LEN} (DIFICIL y FACIL)")
    a(f"//   indices {N_HARD}..{N_WORDS-1} -> longitud 4 o 5      (solo FACIL)")
    a("//")
    a("// Empaquetado de word_data_o:")
    a("//   El caracter de la posicion i (i = 0 es el primero de la palabra)")
    a("//   ocupa word_data_o[8*(MAX_LEN-1-i) +: 8]. El primer caracter queda")
    a("//   en los bits mas significativos, lo que permite escribir cada")
    a("//   palabra como un literal de texto legible y revisable.")
    a("//   Las posiciones posteriores a word_len_o se rellenan con 8'h20.")
    a("//")
    a("// Lectura combinacional; el consumidor la registra en START_GAME.")
    a("// =====================================================================")
    a("")
    a("module word_rom #(")
    a(f"    parameter int N_WORDS = {N_WORDS},")
    a(f"    parameter int MAX_LEN = {MAX_LEN}")
    a(") (")
    a("    input  logic [$clog2(N_WORDS)-1:0] index_i,")
    a("    output logic [8*MAX_LEN-1:0]    word_data_o,")
    a("    output logic [3:0]              word_len_o")
    a(");")
    a("")
    a("    always_comb begin")
    a("        unique case (index_i)")

    # Una linea de case por palabra. ljust rellena con espacios hasta
    # MAX_LEN caracteres para que el literal de texto quepa siempre
    # completo en word_data_o, sin importar el largo real de la
    # palabra; word_len_o guarda ese largo real para que el consumidor
    # sepa donde termina la palabra dentro del relleno.
    for i, w in enumerate(words):
        padded = w.ljust(MAX_LEN)
        tag = "DIFICIL" if i < N_HARD else "FACIL  "
        a(f'            6\'d{i:<2} : begin word_data_o = "{padded}";'
          f' word_len_o = 4\'d{len(w):<2}; end  // {tag} {w}')

    # Si index_i cae fuera de las N_WORDS entradas (no deberia pasar en
    # operacion normal, pero un case en hardware siempre necesita un
    # default), se entrega una palabra vacia en vez de dejar la salida
    # sin definir.
    a("            default: begin word_data_o = \"            \";"
      " word_len_o = 4'd0;  end")
    a("        endcase")
    a("    end")
    a("")
    a("endmodule")
    a("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="solo validar, no escribir")
    args = ap.parse_args()

    errs = validate(WORDS)
    if errs:
        print("FAIL - el banco de palabras no es valido:")
        for e in errs:
            print("  -", e)
        return 1

    hard = WORDS[:N_HARD]
    easy = WORDS[N_HARD:]
    print("PASS - banco de palabras valido")
    print(f"  palabras totales      : {len(WORDS)} (minimo exigido: 50)")
    print(f"  validas para DIFICIL  : {len(hard)} "
          f"(longitudes {min(map(len,hard))}..{max(map(len,hard))})")
    print(f"  solo FACIL            : {len(easy)} "
          f"(longitudes {min(map(len,easy))}..{max(map(len,easy))})")
    print(f"  longitud maxima       : {max(map(len,WORDS))} (permitida: {MAX_LEN})")
    print(f"  almacenamiento        : {N_WORDS*(8*MAX_LEN+4)} bits")

    # --check sirve para validar el banco (por ejemplo, en CI o antes de
    # un commit) sin tocar el arbol de fuentes de SystemVerilog.
    if args.check:
        return 0

    raiz = Path(__file__).resolve().parents[2]   # DESIGN -> PYTHON -> raiz del repo
    out = (raiz / "Ahorcado_juego_electrónico_FPGA_y_PC_por_enlace_serial"
                / "FPGA" / "DESIGN" / "word_rom.sv")
    out.write_text(emit_sv(WORDS), encoding="utf-8")
    print(f"  generado              : {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
