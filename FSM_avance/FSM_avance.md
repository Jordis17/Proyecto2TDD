# Primer Avance de Diseño: Módulo de Control y Máquina de Estados (FSM)

## 1. Módulo del Controlador del Juego (`game_controller`)

El módulo del controlador funciona como la unidad central de procesado del juego. Su objetivo principal es gestionar la lógica global del sistema, coordinando las interacciones entre las entradas del usuario y los periféricos de salida (pantalla LCD, comunicación UART y efectos de sonido).

![Diagrama de Bloques del Controlador](./FSM_images/Diagrama_FSM.png)

Para garantizar un funcionamiento metódico y libre de fallos de sincronización, la arquitectura interna del controlador está dividida en dos bloques funcionales bien definidos:

### Bloque Secuencial (Memoria y Registro de Estados)
Este bloque se encarga de almacenar la información actual del sistema y garantizar que las actualizaciones ocurran de manera síncrona con el reloj del sistema.
* **Entradas de Control e Interfaz**: Recibe las señales del sistema (reloj, reinicio), los botones del usuario y la entrada del generador aleatorio.
* **Manejo de Tiempos y Datos**: Monitorea el estado del temporizador de juego (límite de tiempo) y procesa los datos entrantes de la palabra seleccionada.
* **Comunicación y Retroalimentación**: Evalúa la información proveniente de la comunicación serie y la pantalla para verificar cuándo los periféricos han completado una tarea.
* **Actualización Interna**: Registra el próximo estado al que debe avanzar el sistema y mantiene al día los contadores internos (como la puntuación y las victorias acumuladas).

### Bloque Combinacional (Lógica de Decisiones y Salidas)
Este bloque reacciona de forma inmediata a los cambios en el estado actual y las señales del entorno para gobernar a los módulos periféricos.
* **Control de Pantalla (LCD)**: Emite las señales necesarias para cambiar las pantallas del juego (menú de inicio, tablero de juego o pantallas de resultado).
* **Control de Comunicación Serie (UART)**: Envía los comandos e información de eventos cada vez que el jugador realiza una acción o inicia una partida.
* **Control de Temporización**: Activa, pausa o reinicia el reloj del juego según la fase actual.
* **Estado Visible**: Exporta el indicador del estado del juego hacia otros submódulos del sistema para que trabajen en consonancia.

---

## 2. Flujo de Operación de la Máquina de Estados (FSM)

El comportamiento completo del juego está modelado como una Máquina de Estados Finitos (FSM). Esta estructura garantiza que el juego avance en una secuencia lógica ordenada, reaccionando a las acciones del jugador.

![Diagrama de Estados del Juego](./FSM_images/Maquina_estados_control.png)

### Fase de Configuración e Inicialización

* **Seleccionar Modo de Juego:** Es el punto de partida en reposo. Permite la navegación entre las opciones de dificultad y aguarda la confirmación del jugador.
* **Inicio de Juego:** Transmite la orden inicial para preparar los periféricos de visualización e informar el arranque de la partida.
* **Cargando Juego:** Limpia los contadores de fallos, resetea el mapa de letras probadas, consulta la palabra en la memoria y asigna el tiempo límite según la dificultad seleccionada.

---

### Fase Activa de Juego

* **Jugando:** Representa la etapa interactiva donde el temporizador permanece en cuenta regresiva y el sistema aguarda la llegada de una letra.
* **Revelar Letra Repetida:** Si el jugador envía un carácter que ya había ingresado con anterioridad, el sistema procesa el aviso sin penalizar intentos ni reducir el tiempo restante.
* **Evaluar y Revelar Letra:** Si el carácter es nuevo, se analiza contra la palabra oculta. De haber coincidencias, se desvelan las posiciones correspondientes; de lo contrario, se contabiliza una falla.

---

### Fase de Resolución de la Partida

Dependiendo de la acción evaluada o del estado del temporizador, la máquina de estados deriva a una de tres ramificaciones finales:

* **Ganar:** Ocurre al desvelar completamente la palabra secreta. Al ingresar a esta fase, el sistema incrementa el marcador general de partidas ganadas.
* **Pérdida por Error:** Ocurre cuando el jugador alcanza el tope máximo de fallos permitidos en una misma partida.
* **Pérdida por Tiempo:** Se desencadena si la cuenta del temporizador llega a cero antes de haber completado la palabra.

---

### Fase de Finalización y Reinicio

* **Resultado:** Concentra las tres vías de finalización para proyectar la pantalla con el veredicto de la partida durante un lapso determinado de tiempo (3 segundos). Una vez concluida esa pausa, el flujo retorna automáticamente al inicio para permitir una nueva partida.





