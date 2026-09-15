"""
test_terminal.py - Pruebas autoverificables de la terminal del jugador

Mismo criterio que los testbenches del RTL: estimulos deterministas,
comprobacion automatica y un resumen de PASS/FAIL al final.

La partida se juega contra un puerto serie falso que responde como
responderia la FPGA, y la entrada del jugador se sustituye por un guion
de lo que teclearia. Asi se prueba el recorrido completo sin tarjeta:
que las lineas se troceen bien, que lo que se muestra sea lo que dijo la
FPGA, y que por el puerto no salga nunca nada que no sea una letra.

Ejecutar:
    python test_terminal.py
"""

import builtins
import contextlib
import io
import sys
import threading
import time
from pathlib import Path

# La terminal vive en otra carpeta del proyecto (DESIGN), asi que se
# agrega esa ruta antes de poder importarla como si fuera un modulo
# cualquiera.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "DESIGN"))
import ahorcado_terminal as app          # noqa: E402


# Lista compartida por todas las pruebas: cada check() fallido agrega
# aqui su mensaje, y al final main() la revisa para decidir PASS o FAIL.
fallos = []


def check(condicion, mensaje):
    """Version minima de un assert que no detiene las pruebas.

    Si se usara un assert normal, la primera comprobacion que fallara
    cortaria el resto del archivo y se perderia de ver que mas esta
    roto. Aqui, en cambio, se anota el fallo y se sigue adelante.
    """
    if not condicion:
        print(f"  FAIL: {mensaje}")
        fallos.append(mensaje)


# ---------------------------------------------------------------------
# 1. Troceo de las lineas
# ---------------------------------------------------------------------
def probar_parseo():
    """Verifica parsear() linea por linea, tanto las validas como las
    que deberian rechazarse.

    Cada mensaje del protocolo se prueba al menos una vez con datos
    tipicos, y despues se prueba con una lista de lineas dañadas para
    asegurar que ninguna de ellas se cuele como valida ni haga que la
    funcion reviente.
    """
    # Un caso representativo de cada tipo de mensaje que manda la FPGA,
    # junto con lo que parsear() deberia devolver para el.
    casos_validos = [
        ("START:F:07", "inicio", {"modo": "F", "longitud": 7}),
        ("START:D:10", "inicio", {"modo": "D", "longitud": 10}),
        ("PATT:_______", "patron", {"patron": "_______"}),
        ("PATT:T__L___", "patron", {"patron": "T__L___"}),
        ("LET:A:OK ", "letra", {"letra": "A", "resultado": "OK "}),
        ("LET:Z:NO ", "letra", {"letra": "Z", "resultado": "NO "}),
        ("LET:A:RPT", "letra", {"letra": "A", "resultado": "RPT"}),
        ("ERR:6", "intentos", {"intentos": 6}),
        ("ERR:0", "intentos", {"intentos": 0}),
        ("END:WIN:TECLADO", "fin", {"desenlace": "WIN", "palabra": "TECLADO"}),
        ("END:LER:SOL", "fin", {"desenlace": "LER", "palabra": "SOL"}),
        ("END:LTO:VENTILADOR", "fin",
         {"desenlace": "LTO", "palabra": "VENTILADOR"}),
    ]
    for linea, clase, campos in casos_validos:
        salida = app.parsear(linea)
        check(salida is not None, f"no se reconocio {linea!r}")
        if salida is not None:
            check(salida == (clase, campos),
                  f"{linea!r} se leyo como {salida}")

    # Lineas rotas, a medias o con ruido: ninguna debe reconocerse, y
    # sobre todo ninguna debe reventar el analizador. Aqui van casos de
    # cada tipo de mensaje con algun campo mal formado, largo incorrecto
    # o directamente vacio.
    casos_invalidos = [
        "", "X", "STAR", "START:", "START:X:07", "START:F:7", "START:F:AB",
        "START:F:070", "PATT:", "LET:", "LET:A:", "LET:A:XX", "LET:A:XXX",
        "LET:AB:OK ", "ERR:", "ERR:A", "ERR:12", "END:", "END:XXX:HOLA",
        "END:WIN", "END:WIN:", "basura", "ERR:6 ", " ERR:6",
    ]
    for linea in casos_invalidos:
        check(app.parsear(linea) is None,
              f"{linea!r} no deberia reconocerse y devolvio {app.parsear(linea)}")


# ---------------------------------------------------------------------
# 2. Validacion de lo que teclea el jugador
# ---------------------------------------------------------------------
def probar_entrada():
    """Verifica pedir_letra() reemplazando input() por un guion fijo.

    Se hace monkeypatching de builtins.input porque pedir_letra() llama
    a input() directamente (a traves de preguntar()); sustituirlo es la
    forma mas simple de manejarle un guion de texto sin necesitar un
    terminal de verdad ni un puerto serie.
    """
    # Un guion con entradas vacias, con espacios, con mas de una letra,
    # con simbolos y con letras fuera de A-Z (la enye y la a con
    # tilde), antes de la letra valida que deberia aceptarse al final.
    guion = ["", "   ", "ab", "hola", "3", "?", "ñ", "á", " t "]
    esperado = "T"

    pendientes = list(guion)

    def input_falso(_=""):
        return pendientes.pop(0)

    # Se captura todo lo que se imprime mientras corre pedir_letra(),
    # para poder revisar despues que los avisos de error salieron.
    salida = io.StringIO()
    original = builtins.input
    builtins.input = input_falso
    try:
        with contextlib.redirect_stdout(salida):
            letra = app.pedir_letra(threading.Event())
    finally:
        # Pase lo que pase, input() tiene que quedar como estaba antes
        # de esta prueba, o las pruebas siguientes quedarian rotas.
        builtins.input = original

    check(letra == esperado,
          f"tras las entradas invalidas devolvio {letra!r} en vez de {esperado!r}")
    check(pendientes == [], "no consumio todas las entradas del guion")

    texto = salida.getvalue()
    check("Solo una letra por turno." in texto,
          "no aviso de que solo se admite una letra")
    check("Eso no es una letra." in texto,
          "no aviso de que un simbolo no es una letra")
    check("tildes ni la enye" in texto,
          "no aviso de que el banco no lleva tildes ni enye")

    # La Q es una letra valida, no un atajo para cerrar
    pendientes = ["q"]
    builtins.input = input_falso
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            check(app.pedir_letra(threading.Event()) == "Q",
                  "la Q deberia aceptarse como letra, no cerrar la aplicacion")
    finally:
        builtins.input = original

    # salir en cualquiera de sus formas
    for palabra in ("salir", "SALIR", " Salir "):
        pendientes = [palabra]
        builtins.input = input_falso
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                check(app.pedir_letra(threading.Event()) is None,
                      f"{palabra!r} deberia cerrar la aplicacion")
        finally:
            builtins.input = original

    # cerrar la entrada estandar tampoco debe reventar
    def input_cortado(_=""):
        raise EOFError

    builtins.input = input_cortado
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            check(app.pedir_letra(threading.Event()) is None,
                  "cerrar la entrada estandar deberia cerrar la aplicacion")
    finally:
        builtins.input = original


# ---------------------------------------------------------------------
# 3. Partida completa contra un puerto falso
# ---------------------------------------------------------------------
class PuertoFalso:
    """Responde como responderia la FPGA y anota lo que se le escribe.

    Reemplaza al objeto serial.Serial real: tiene los mismos metodos
    que usa el resto de la aplicacion (read, write, in_waiting, close),
    pero en vez de hablar con un cable habla con listas de texto que
    arma esta misma prueba.
    """

    def __init__(self, respuestas):
        # respuestas: lo que contesta a la letra numero n, es decir,
        # respuestas[0] es lo que "manda la FPGA" despues de que la
        # terminal escriba la primera letra, respuestas[1] despues de
        # la segunda, y asi.
        self.respuestas = list(respuestas)
        self.escrito = bytearray()     # todo lo que la terminal mando
        self.pendiente = bytearray()   # lo que "la FPGA" aun no entrego
        # El hilo lector y el metodo write() (que corre en el hilo
        # principal) tocan self.pendiente al mismo tiempo, asi que
        # necesita su propio candado, igual que la consola real.
        self.lock = threading.Lock()
        self.cerrado = False

    def emitir(self, texto):
        """Pone texto en la cola de salida, como si lo mandara la FPGA."""
        with self.lock:
            self.pendiente.extend(texto.encode("ascii"))

    @property
    def in_waiting(self):
        with self.lock:
            return len(self.pendiente)

    def read(self, n):
        # Igual que el puerto real: si no hay nada pendiente, se espera
        # un poco en vez de devolver de inmediato, para imitar el
        # timeout que usa serial.Serial.
        with self.lock:
            if self.pendiente:
                datos = bytes(self.pendiente[:n])
                del self.pendiente[:n]
                return datos
        time.sleep(0.002)          # como el tiempo de espera del puerto real
        return b""

    def write(self, datos):
        # Cada letra que la terminal escribe dispara la respuesta que
        # le corresponde segun su posicion en la lista de respuestas,
        # simulando lo que la FPGA contestaria a esa jugada.
        self.escrito.extend(datos)
        indice = len(self.escrito) - 1
        if indice < len(self.respuestas):
            self.emitir(self.respuestas[indice])
        return len(datos)

    def close(self):
        self.cerrado = True


def probar_partida():
    """Juega una partida entera contra PuertoFalso y revisa que todo lo
    que se muestra en pantalla venga de lo que "dijo" la FPGA.

    El guion cubre una letra acertada, una fallada, una repetida y una
    derrota por tiempo, y despues arranca una segunda partida que el
    jugador cierra con 'salir'.
    """
    # Una partida con acierto, fallo, repetida y derrota por tiempo, y
    # despues una segunda partida que el jugador abandona.
    respuestas = [
        "LET:T:OK \nPATT:T______\nERR:6\n",                     # T
        "LET:Z:NO \nPATT:T______\nERR:5\n",                     # Z
        "LET:T:RPT\n",                                          # T repetida
        "LET:Q:NO \nPATT:T______\nERR:4\n"
        "END:LTO:TECLADO\n"
        "START:D:10\nPATT:__________\nERR:6\n",                 # Q y fin
    ]
    tecleado = ["t", "z", "T", "q", "salir"]

    puerto = PuertoFalso(respuestas)
    # La primera partida arranca sola, sin que el jugador escriba nada,
    # igual que en la aplicacion real cuando se pulsa el boton en la
    # tarjeta.
    puerto.emitir("START:F:07\nPATT:_______\nERR:6\n")

    cola = app.queue.Queue()
    esperando = threading.Event()
    hilo = threading.Thread(target=app.lector,
                            args=(puerto, cola, esperando), daemon=True)
    hilo.start()

    pendientes = list(tecleado)

    def input_falso(_=""):
        # La terminal solo pregunta cuando la FPGA cerro la jugada, asi
        # que basta con ir devolviendo el guion.
        time.sleep(0.01)
        return pendientes.pop(0)

    salida = io.StringIO()
    original = builtins.input
    builtins.input = input_falso
    try:
        with contextlib.redirect_stdout(salida):
            app.jugar(puerto, cola, esperando)
    finally:
        builtins.input = original

    texto = salida.getvalue()

    check(pendientes == [], "no llego al final del guion del jugador")
    # Por el puerto deben salir las cuatro letras que de verdad se
    # mandaron a la FPGA (T, Z, otra vez T aunque resulte repetida, y
    # Q), nunca nada de lo que se tecleo mal, porque eso ni siquiera
    # llega a escribirse.
    check(bytes(puerto.escrito) == b"TZTQ",
          f"por el puerto salio {bytes(puerto.escrito)!r} en vez de b'TZTQ'")

    # lo que se muestra viene de lo que dijo la FPGA
    check("modo Facil" in texto, "no anuncio el modo de la primera partida")
    check("7 letras" in texto, "no anuncio la longitud de la palabra")
    check("T _ _ _ _ _ _" in texto, "no mostro el patron tras acertar")
    check("Intentos: 5" in texto, "no mostro los intentos tras fallar")
    check("T -> correcta" in texto, "no mostro el resultado de la letra correcta")
    check("Z -> incorrecta" in texto, "no mostro el resultado de la letra fallada")
    check("repetida, no cuenta" in texto, "no mostro que la letra era repetida")
    check("PERDISTE: se acabo el tiempo" in texto,
          "no mostro la derrota por tiempo")
    check("La palabra era: TECLADO" in texto,
          "no mostro la palabra al terminar")
    check("modo Dificil" in texto, "no anuncio la segunda partida")
    # Si esto aparece, quiere decir que alguna linea valida del
    # protocolo se rechazo por error en parsear().
    check("linea no reconocida" not in texto,
          "descarto como no reconocida alguna linea valida")


# ---------------------------------------------------------------------
# 4. Lineas con ruido en medio de una partida
# ---------------------------------------------------------------------
def probar_ruido():
    """Mezcla texto basura y bytes invalidos entre los mensajes reales,
    para comprobar que el hilo lector los descarta sin trabarse y sin
    arrastrar ese ruido a la siguiente linea valida.
    """
    respuestas = [
        "basura\nLET:T:OK \n\x00\x01\nPATT:T______\nERR:6\n"
        "END:WIN:TECLADO\nSTART:F:07\nPATT:_______\nERR:6\n",
    ]
    puerto = PuertoFalso(respuestas)
    puerto.emitir("ruido antes de empezar\nSTART:F:07\nPATT:_______\nERR:6\n")

    cola = app.queue.Queue()
    esperando = threading.Event()
    threading.Thread(target=app.lector, args=(puerto, cola, esperando),
                     daemon=True).start()

    pendientes = ["t", "salir"]

    def input_falso(_=""):
        time.sleep(0.01)
        return pendientes.pop(0)

    salida = io.StringIO()
    original = builtins.input
    builtins.input = input_falso
    try:
        with contextlib.redirect_stdout(salida):
            app.jugar(puerto, cola, esperando)
    finally:
        builtins.input = original

    texto = salida.getvalue()
    check(pendientes == [], "el ruido detuvo la aplicacion")
    check(bytes(puerto.escrito) == b"T",
          f"con ruido salio {bytes(puerto.escrito)!r} en vez de b'T'")
    check("linea no reconocida" in texto, "no reporto las lineas con ruido")
    check("GANASTE" in texto, "no mostro la victoria pese al ruido")


# ---------------------------------------------------------------------
def main():
    """Corre las cuatro baterias de pruebas en orden y deja al final un
    solo veredicto, para poder revisarlo de un vistazo o usarlo como
    codigo de salida en un script de CI.
    """
    print()
    print("=== test_terminal ===")
    probar_parseo()
    probar_entrada()
    probar_partida()
    probar_ruido()
    print()
    if not fallos:
        print("  PASS  troceo, validacion de entrada, partida completa "
              "y tolerancia al ruido correctos")
    else:
        print(f"  FAIL  {len(fallos)} comprobaciones fallidas")
    print()
    return 1 if fallos else 0


if __name__ == "__main__":
    sys.exit(main())