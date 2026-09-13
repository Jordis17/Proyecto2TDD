#!/usr/bin/env python3
"""
Protocolo
---------
De la PC a la FPGA va un solo byte, de la A a la Z.

De la FPGA a la PC vienen lineas ASCII terminadas en salto de linea, con
campos de ancho fijo:

    START:<M>:<LL>    M es F o D, LL es la longitud con dos digitos
    PATT:<p>          patron, con guion bajo en lo oculto
    LET:<X>:<R>       letra y resultado: 'OK ', 'NO ' o 'RPT'
    ERR:<n>           intentos fallidos que quedan
    END:<E>:<W>       desenlace WIN, LER o LTO, y la palabra completa

Los campos son de ancho fijo justamente para que aqui se puedan trocear
por posicion, sin expresiones regulares. Una linea que no encaje se
reporta y se descarta: nunca detiene la aplicacion.

Por que hay un hilo lector
--------------------------
El limite de tiempo corre en la FPGA. Si el jugador se queda pensando,
la partida puede terminar mientras la terminal esta esperando que
escriba algo. Con lectura sincronica ese aviso no se veria hasta que
escribiera, que es justo cuando ya no sirve. El hilo lector recibe
siempre, avisa en pantalla si la partida termina durante la espera, y la
letra que el jugador escriba despues se descarta.

Uso
---
    pip install pyserial
    python ahorcado_terminal.py --port COM4           (Windows)
"""

import argparse
import queue
import sys
import threading

# pyserial es la libreria que permite hablar con el puerto serie desde
# Python. 
try:
    import serial
    from serial.tools import list_ports
except ImportError:
    sys.exit("Falta pyserial. Instalalo con:  pip install pyserial")


# Velocidad del puerto serie (baudios). 
BAUDIOS = 115200

# Como traducir el codigo de tres letras que manda la FPGA para el
# resultado de una jugada, a un texto que se entienda en pantalla.
RESULTADOS = {
    "OK ": "correcta",
    "NO ": "incorrecta",
    "RPT": "repetida, no cuenta",
}

# Lo mismo, pero para como termino la partida.
DESENLACES = {
    "WIN": "GANASTE",
    "LER": "PERDISTE: se acabaron los intentos",
    "LTO": "PERDISTE: se acabo el tiempo",
}

# La FPGA manda el modo como una sola letra; aqui se traduce a
# un nombre legible.
MODOS = {"F": "Facil", "D": "Dificil"}


# ---------------------------------------------------------------------
# Analisis de las lineas recibidas
# ---------------------------------------------------------------------
def parsear(linea):
    """Devuelve (tipo, datos) o None si la linea no encaja con nada.

    El troceo es por posicion porque los campos son de ancho fijo. Cada
    caso comprueba su propio largo antes de cortar, de modo que una
    linea a medias o con ruido no rompe nada.

    Idea general de esta funcion: mirar con que palabra clave empieza
    la linea, confirmar que tenga exactamente el largo que se espera
    para ese tipo de mensaje, y solo entonces cortar los pedacitos que
    interesan. Si algo no calza, no se fuerza nada: se devuelve None y
    quien llamo a esta funcion decide que hacer con una linea rara.
    """
    if linea.startswith("START:"):
        
        if len(linea) == 10 and linea[7] == ":":
            modo = linea[6]
            largo = linea[8:10]
            if modo in MODOS and largo.isdigit():
                return "inicio", {"modo": modo, "longitud": int(largo)}

    elif linea.startswith("PATT:"):
        # Todo lo que viene despues de "PATT:" es el patron de la
        # palabra. No se valida mas que eso.
        patron = linea[5:]
        if patron:
            return "patron", {"patron": patron}

    elif linea.startswith("LET:"):
        # Se espera algo como "LET:A:OK " -> 9 caracteres en total.
        if len(linea) == 9 and linea[5] == ":":
            letra = linea[4]
            resultado = linea[6:9]
            if resultado in RESULTADOS:
                return "letra", {"letra": letra, "resultado": resultado}

    elif linea.startswith("ERR:"):
        # Un solo digito con los intentos que quedan, por ejemplo "ERR:3".
        if len(linea) == 5 and linea[4].isdigit():
            return "intentos", {"intentos": int(linea[4])}

    elif linea.startswith("END:"):
        # Por ejemplo "END:WIN:CASA" -> desenlace de tres letras y
        # despues la palabra completa, sin largo fijo porque las
        # palabras no siempre miden lo mismo.
        if len(linea) > 8 and linea[7] == ":":
            desenlace = linea[4:7]
            palabra = linea[8:]
            if desenlace in DESENLACES:
                return "fin", {"desenlace": desenlace, "palabra": palabra}

    # Si ninguna de las formas de arriba encajo, se avisa que esta
    # linea no se pudo traducir.
    return None


# ---------------------------------------------------------------------
# Hilo lector
# ---------------------------------------------------------------------
def lector(puerto, cola, esperando_letra):
    """Arma lineas con lo que llega y las mete en la cola.

    Si la partida termina mientras el jugador esta escribiendo, lo avisa
    en pantalla; si no, el aviso no aparece hasta que escriba, que es
    cuando ya no sirve de nada.

    Esta funcion corre en un hilo aparte, es decir, al mismo tiempo que
    el resto del programa sigue haciendo lo suyo. Su unico trabajo es
    juntar bytes hasta formar una linea completa y pasarla a la cola.
    """
    # Aqui se van acumulando los bytes de la linea que se esta armando,
    # hasta que aparezca el salto de linea que la cierra.
    buffer = bytearray()
    while True:
        try:
            # Lee lo que haya disponible en el puerto en este momento
            # (o al menos un byte, para no quedarse en un ciclo vacio).
            datos = puerto.read(puerto.in_waiting or 1)
        except Exception as error:                    # el puerto se fue
            # Si el puerto serie se desconecto (por ejemplo, se
            # desenchufo el cable), se avisa y se termina el hilo.
            cola.put(("desconectado", {"detalle": str(error)}))
            return

        for byte in datos:
            if byte == 0x0A:                          # salto de linea
                # Llego el fin de una linea: se convierte lo acumulado
                # a texto y se vacia el acumulador para la siguiente.
                linea = buffer.decode("ascii", errors="replace")
                buffer.clear()
                if linea.startswith("END:") and esperando_letra.is_set():
                    # Si justo en este momento el jugador esta escribiendo
                    # su letra, se le avisa de inmediato que la partida
                    # ya se termino, sin esperar a que termine de escribir.
                    print("\n  >> la FPGA termino la partida. "
                          "Pulsa Enter para ver el resultado.")
                cola.put(("linea", {"texto": linea}))
            elif byte != 0x0D:                     
                # El retorno se ignora; cualquier otro byte se
                # va sumando a la linea que se esta armando.
                buffer.append(byte)
                if len(buffer) > 80:                  # linea absurda: al tacho
                    # Si una linea crece demasiado sin cerrar, algo salio
                    # mal (ruido en la conexion, por ejemplo). Se descarta
                    # todo lo acumulado en vez de dejar crecer el error.
                    buffer.clear()


# ---------------------------------------------------------------------
# Estado que se muestra, tal como lo va diciendo la FPGA
# ---------------------------------------------------------------------
class Estado:
    """Guarda solo lo ultimo que conto la FPGA, para mostrarlo en
    pantalla de forma ordenada. No decide nada del juego: es solo una
    libretita de apuntes."""

    def __init__(self):
        self.reiniciar()

    def reiniciar(self):
        # Se llama al empezar una partida nueva, para borrar los datos
        # de la partida anterior.
        self.modo = None
        self.longitud = None
        self.patron = None
        self.intentos = None
        self.ultima = None

    def mostrar(self):
        # Imprime en pantalla solo los datos que ya se conocen; si algo
        # todavia no llego de la FPGA, simplemente no se muestra esa
        # linea.
        if self.patron is not None:
            print("  Palabra : " + " ".join(self.patron))
        if self.intentos is not None:
            print(f"  Intentos: {self.intentos}")
        if self.ultima is not None:
            letra, resultado = self.ultima
            print(f"  Ultima  : {letra} -> {RESULTADOS[resultado]}")


# ---------------------------------------------------------------------
# Entrada del jugador
# ---------------------------------------------------------------------
def pedir_letra(esperando_letra):
    """Devuelve una letra A-Z, o None si el jugador quiere salir.

    Vuelve a preguntar cuantas veces haga falta. Nada de lo que escriba
    el jugador llega al puerto sin pasar por aqui.
    """
    while True:
        # Se marca que ahora se esta esperando que el jugador escriba,
        # para que el hilo lector sepa si conviene avisar de inmediato
        # si llega un fin de partida mientras tanto.
        esperando_letra.set()
        try:
            texto = input("  Letra: ")
        except (EOFError, KeyboardInterrupt):
            print()
            return None
        finally:
            # Se quite lo que se quite de la espera, siempre se limpia
            # esta marca al terminar de leer lo que escribio.
            esperando_letra.clear()

        texto = texto.strip()

        # Solo "salir" cierra. Nada de atajos de una letra: la Q es una
        # letra del banco y el jugador tiene que poder intentarla.
        if texto.lower() == "salir":
            return None
        if len(texto) == 0:
            print("  Escribe una letra.")
            continue
        if len(texto) > 1:
            print("  Solo una letra por turno.")
            continue

        letra = texto.upper()
        if not letra.isalpha():
            print("  Eso no es una letra.")
            continue
        if not ("A" <= letra <= "Z"):
            # El banco de palabras no lleva tildes ni la N con virguilla, asi que la
            # FPGA solo entiende A-Z y descartaria el byte en silencio.
            print("  El banco de palabras no usa tildes ni la N con virguilla ")
            continue

        return letra


# ---------------------------------------------------------------------
def jugar(puerto, cola, esperando_letra):
    """Ciclo principal: se turna entre revisar lo que dijo la FPGA y
    pedirle una letra al jugador, hasta que la partida (o el programa)
    se termine."""
    estado = Estado()
    en_partida = False
    turno = False        # la FPGA ya dijo todo lo de la jugada anterior

    print("Conectado. Elegi el modo en la tarjeta y pulsa el boton derecho")
    print("para empezar. Escribi 'salir' para cerrar.\n")

    while True:
        # ---- atender lo que haya dicho la FPGA ----
        # Mientras no sea el turno del jugador, o mientras sigan
        # llegando lineas nuevas en la cola, se van procesando una por
        # una antes de volver a pedir una letra.
        while not turno or not cola.empty():
            tipo, datos = cola.get()

            if tipo == "desconectado":
                print(f"\nSe perdio el puerto serie: {datos['detalle']}")
                return

            evento = parsear(datos["texto"])
            if evento is None:
                if datos["texto"]:
                    print(f"  (linea no reconocida: {datos['texto']!r})")
                continue

            clase, campos = evento

            if clase == "inicio":
                # Empieza una partida nueva: se olvida todo lo anterior.
                estado.reiniciar()
                estado.modo = campos["modo"]
                estado.longitud = campos["longitud"]
                en_partida = True
                turno = False
                print(f"\n--- Partida nueva | modo {MODOS[campos['modo']]} "
                      f"| {campos['longitud']} letras ---")

            elif clase == "patron":
                estado.patron = campos["patron"]

            elif clase == "letra":
                estado.ultima = (campos["letra"], campos["resultado"])
                if campos["resultado"] == "RPT":
                    # Si la letra estaba repetida, la FPGA no manda nada
                    # mas detras (ni patron ni intentos), asi que aqui
                    # mismo se cierra esta jugada y se vuelve a preguntar.
                    print()
                    estado.mostrar()
                    turno = en_partida

            elif clase == "intentos":
                # Este es el ultimo dato que llega en una jugada normal
                # (no repetida), asi que aqui se muestra todo junto y se
                # habilita el turno del jugador.
                estado.intentos = campos["intentos"]
                print()
                estado.mostrar()
                turno = en_partida

            elif clase == "fin":
                print()
                print(f"  {DESENLACES[campos['desenlace']]}")
                print(f"  La palabra era: {campos['palabra']}")
                print("\nElegi el modo en la tarjeta y pulsa el boton derecho")
                print("para jugar otra vez.\n")
                estado.reiniciar()
                en_partida = False
                turno = False

        # ---- turno del jugador ----
        letra = pedir_letra(esperando_letra)
        if letra is None:
            print("Hasta luego.")
            return

        # Mientras se escribia pudo llegar el final de la partida. En ese
        # caso la letra ya no vale para nada, asi que se descarta sin
        # mandarla.
        if not cola.empty() or not en_partida:
            turno = False
            continue

        try:
            puerto.write(letra.encode("ascii"))
        except Exception as error:
            print(f"\nNo se pudo enviar: {error}")
            return
        turno = False


# ---------------------------------------------------------------------
def main():
    # Se leen las opciones con las que se ejecuto el programa desde la
    # linea de comandos: que puerto usar, a que velocidad, o si solo se
    # quiere ver la lista de puertos disponibles.
    analizador = argparse.ArgumentParser(
        description="Terminal del jugador para el Ahorcado en FPGA")
    analizador.add_argument("--port", help="puerto serie, por ejemplo COM4")
    analizador.add_argument("--baud", type=int, default=BAUDIOS,
                            help=f"baudios (por omision {BAUDIOS})")
    analizador.add_argument("--list", action="store_true",
                            help="lista los puertos disponibles y termina")
    opciones = analizador.parse_args()

    puertos = list(list_ports.comports())

    if opciones.list:
        # Con --list solo se muestra que puertos hay y se termina, sin
        # intentar conectar con ninguno.
        if not puertos:
            print("No hay puertos serie disponibles.")
        for p in puertos:
            print(f"{p.device}  {p.description}")
        return 0

    nombre = opciones.port
    if nombre is None:
        # Si no se indico un puerto y solo hay uno disponible, se usa
        # ese directamente para no obligar a escribirlo siempre.
        if len(puertos) == 1:
            nombre = puertos[0].device
            print(f"Unico puerto disponible: {nombre}")
        else:
            print("Indica el puerto con --port. Para verlos: --list")
            return 1

    try:
        # El tiempo de espera evita que el hilo lector se quede clavado
        # cuando la tarjeta no dice nada.
        puerto = serial.Serial(nombre, opciones.baud, timeout=0.2)
    except Exception as error:
        print(f"No se pudo abrir {nombre}: {error}")
        return 1

    # La cola es donde el hilo lector deja las lineas que va armando, y
    # de donde jugar() las va sacando para procesarlas.
    cola = queue.Queue()
    # Esta bandera indica si en este momento se le esta pidiendo una
    # letra al jugador (para que el hilo lector sepa si avisar de una
    # vez si llega un fin de partida).
    esperando_letra = threading.Event()

    hilo = threading.Thread(target=lector,
                            args=(puerto, cola, esperando_letra),
                            daemon=True)
    hilo.start()

    try:
        jugar(puerto, cola, esperando_letra)
    except KeyboardInterrupt:
        print("\nInterrumpido.")
    finally:
        puerto.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
