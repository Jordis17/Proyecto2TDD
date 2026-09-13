// =====================================================================
// uart_msg.sv - Capa de presentacion del protocolo con la PC
//
// Traduce un evento del juego en las lineas ASCII que espera la
// aplicacion de PC y las entrega byte a byte al periferico UART, y en el
// sentido contrario recoge la letra que el jugador escribe.
//
// El trabajo esta repartido en tres piezas:
//
//   uart_msg_snapshot   congela los datos de la jugada al aceptar la orden
//   uart_msg_char_gen   dice que caracter va en cada posicion del mensaje
//   uart_msg            (este) recorre las posiciones y habla con el bus
//
// Aqui queda solo el recorrido y el dialogo con el periferico. El formato
// de los mensajes esta entero en el generador de caracteres, de modo que
// cambiar una linea del protocolo no obliga a mirar la maquina de estados.
//
// Por que existe esta capa
// ------------------------
// La secuencia mas larga son unos 35 bytes, cada uno con su escritura de
// registro y su espera. Metida en el control del juego, esa cuenta
// convertiria una maquina de siete estados en uno de esos bloques que
// nadie quiere leer ni defender.
//
// Un evento que llega con busy_o en alto se ignora, igual que en las
// demas capas: esperar es tarea de quien pide.
//
// Dialogo con el periferico
// -------------------------
//   1. leer CONTROL hasta que send este en cero
//   2. escribir el byte en DATOS TX
//   3. escribir CONTROL con send
//   4. leer CONTROL hasta que send vuelva a cero
//
// El fin se detecta por send y no por ninguna otra senal. Con lazo de
// retorno, el receptor muestrea el bit de parada en su centro, medio bit
// antes de que el transmisor suelte la linea: cualquier aviso de
// recepcion llega antes de que la transmision haya terminado de verdad.

// --------------------------------------
// El periferico se maneja por registros, y limpiar el aviso de byte
// nuevo es una escritura mas sobre el mismo bus. Si el control del juego
// leyera por su cuenta habria dos maestros sobre el mismo periferico, con
// una trama saliendo y una letra entrando a la vez. Con la recepcion
// aqui se mantiene la regla de un solo maestro por periferico.
//
// El sondeo del byte recibido ocurre solo en reposo, y una peticion de
// envio que caiga justo en esos dos ciclos queda anotada y se atiende al
// volver: lo que no se acepta es un envio con otro ya en curso.
//
// Validacion de la letra
// ----------------------
// Solo pasan los codigos de la A a la Z. Cualquier otra cosa se lee, se
// limpia el aviso y se descarta sin avisar a nadie: es filtrado de
// protocolo, no una regla del juego.
//
// rx_valid_o es un pulso de un ciclo. Si el control del juego no esta en
// disposicion de atenderlo, el byte se pierde, y eso es exactamente lo
// que se quiere fuera de la partida: una letra recibida en la pantalla
// de seleccion o mostrando el resultado se ignora, pero el aviso queda
// limpio y no se cuela como primera letra de la partida siguiente.
// =====================================================================

module uart_msg #(
    parameter int MAX_LEN = 12
) (
    input  logic        clk_i,
    input  logic        rst_i,

    // orden de envio
    input  logic [1:0]  event_i,      // 0 inicio, 1 letra, 2 repetida, 3 fin
    input  logic        send_i,       // pulso
    output logic        busy_o,

    // letra recibida de la PC, ya validada
    output logic [7:0]  rx_letter_o,
    output logic        rx_valid_o,   // pulso de un ciclo

    // datos del evento
    input  logic [7:0]           letter_i,     // letra evaluada, en ASCII
    input  logic                 hit_i,        // 1 acierto, 0 fallo
    input  logic [1:0]           end_code_i,   // 0 WIN, 1 LER, 2 LTO
    input  logic [8*MAX_LEN-1:0] word_data_i,  // primer caracter en los bits altos
    input  logic [3:0]           word_len_i,
    input  logic [MAX_LEN-1:0]   revealed_i,
    input  logic [2:0]           errors_i,     // errores cometidos, 0 a 6
    input  logic                 mode_i,       // 0 facil, 1 dificil

    // hacia uart_peripheral
    output logic        write_enable_o,
    output logic [1:0]  addr_o,
    output logic [31:0] wdata_o,
    input  logic [31:0] rdata_i       // solo se miran los bits de send y new_rx
);

    // mapa de registros del periferico
    localparam logic [1:0] A_TX     = 2'b00;
    localparam logic [1:0] A_RX     = 2'b01;
    localparam logic [1:0] A_CTRL   = 2'b10;
    localparam int         B_SEND   = 0;
    localparam int         B_NEW_RX = 1;

    localparam logic [7:0] CAR_A = 8'h41;
    localparam logic [7:0] CAR_Z = 8'h5A;

    // Siete estados para dos trabajos distintos: los primeros cuatro
    // (S_LIBRE..S_FIN) son el dialogo de transmision descrito en el
    // encabezado, un byte a la vez; los ultimos dos (S_RX_LEER,
    // S_RX_LIMPIAR) son la mitad de recepcion, que solo se visita desde
    // S_IDLE cuando no hay nada pendiente por transmitir.
    typedef enum logic [2:0] {
        S_IDLE,
        S_LIBRE,       // esperar a que el transmisor quede libre
        S_DATOS,       // cargar el byte
        S_CTRL,        // pedir el envio
        S_FIN,         // esperar a que termine
        S_RX_LEER,     // leer el byte recibido
        S_RX_LIMPIAR   // limpiar el aviso de byte nuevo
    } estado_t;

    estado_t    st_q    = S_IDLE;
    logic [1:0] linea_q = 2'd0;    // linea dentro de la secuencia
    logic [4:0] idx_q   = 5'd0;    // byte dentro de la linea

    logic pend_q = 1'b0;    // envio anotado y todavia no empezado
    logic rx_val_q = 1'b0;
    logic [7:0] rx_byte_q = 8'h00;

    assign rx_letter_o = rx_byte_q;
    assign rx_valid_o  = rx_val_q;

    // Una transmision en curso ocupa los cuatro estados del dialogo. El
    // sondeo de recepcion no cuenta como ocupado: dura dos ciclos y no
    // impide anotar un envio.
    //
    // busy_o combina dos cosas que, vistas desde afuera, significan lo
    // mismo ("no me mandes otro evento todavia"): estar en medio del
    // dialogo con el periferico (tx_en_curso) o ya tener uno anotado
    // esperando a que termine el que esta en curso (pend_q). Sin el
    // segundo termino, un evento que llegara mientras se sondea la
    // recepcion podria colarse dos veces si el control del juego lo
    // reenviara al ver busy_o en cero por error.
    logic tx_en_curso;
    assign tx_en_curso = (st_q == S_LIBRE) || (st_q == S_DATOS) ||
                         (st_q == S_CTRL)  || (st_q == S_FIN);
    assign busy_o      = tx_en_curso || pend_q;

    // ---------------------------------------------------------------
    // Copia estable de los datos de la jugada
    // ---------------------------------------------------------------
    // La orden se acepta y los datos se copian en el mismo ciclo en que
    // llega, aunque el sondeo de recepcion este a mitad. Solo se descarta
    // si ya hay una transmision en curso.
    //
    // capturar es la condicion exacta que define "este send_i cuenta
    // como una orden nueva": tiene que llegar el pulso, no puede haber
    // ya algo en curso, y no puede haber ya algo anotado. Si send_i
    // llegara dos veces seguidas antes de que la primera se procese, la
    // segunda simplemente no cumple esta condicion y se pierde en
    // silencio, que es el comportamiento que describe el encabezado
    // ("esperar es tarea de quien pide").
    logic capturar;
    assign capturar = !rst_i && send_i && !tx_en_curso && !pend_q;

    logic [1:0]           ev_cong;
    logic [7:0]           let_cong;
    logic                 hit_cong;
    logic [1:0]           fin_cong;
    logic [8*MAX_LEN-1:0] wd_cong;
    logic [3:0]           wl_cong;
    logic [MAX_LEN-1:0]   rev_cong;
    logic [2:0]           err_cong;
    logic                 mode_cong;

    uart_msg_snapshot #(.MAX_LEN(MAX_LEN)) datos_congelados (
        .clk_i(clk_i), .capture_i(capturar),
        .event_i(event_i), .letter_i(letter_i), .hit_i(hit_i),
        .end_code_i(end_code_i), .word_data_i(word_data_i),
        .word_len_i(word_len_i), .revealed_i(revealed_i),
        .errors_i(errors_i), .mode_i(mode_i),
        .event_o(ev_cong), .letter_o(let_cong), .hit_o(hit_cong),
        .end_code_o(fin_cong), .word_data_o(wd_cong),
        .word_len_o(wl_cong), .revealed_o(rev_cong),
        .errors_o(err_cong), .mode_o(mode_cong)
    );

    // ---------------------------------------------------------------
    // Caracter que toca emitir
    // ---------------------------------------------------------------
    // El generador tambien devuelve cuantas lineas tiene el evento y cual
    // es el ultimo indice de la linea actual, que es lo que la maquina de
    // estados necesita para saber cuando avanzar.
    //
    // Notese que generador se alimenta de las senales _cong (ya
    // congeladas), nunca de las entradas _i originales. Esa es la unica
    // conexion que le importa a esta FSM: mientras se respete, el
    // formato exacto del mensaje es un problema completamente aparte,
    // resuelto adentro de uart_msg_char_gen.
    logic [7:0] car;
    logic [4:0] ult_idx;
    logic [1:0] n_lineas;

    uart_msg_char_gen #(.MAX_LEN(MAX_LEN)) generador (
        .event_i(ev_cong), .letter_i(let_cong), .hit_i(hit_cong),
        .end_code_i(fin_cong), .word_data_i(wd_cong),
        .word_len_i(wl_cong), .revealed_i(rev_cong),
        .errors_i(err_cong), .mode_i(mode_cong),
        .line_i(linea_q), .idx_i(idx_q),
        .char_o(car), .last_idx_o(ult_idx), .n_lines_o(n_lineas)
    );

    // ---------------------------------------------------------------
    // Bus hacia el periferico
    // ---------------------------------------------------------------
    // Fuera de las escrituras la direccion se deja en CONTROL, que es el
    // registro que hay que sondear.
    //
    // Este always_comb es el que traduce "en que estado estoy" a "que
    // hago con el bus ahora mismo". Es puramente combinacional a
    // proposito: las salidas del bus tienen que reflejar el estado
    // actual sin esperar un flanco de reloj mas, porque el periferico ya
    // esta mirando write_enable_o y addr_o en este mismo ciclo.
    always_comb begin
        write_enable_o = 1'b0;
        addr_o         = A_CTRL;
        wdata_o        = 32'd0;

        unique case (st_q)
            S_DATOS: begin
                write_enable_o = 1'b1;
                addr_o         = A_TX;
                wdata_o        = {24'd0, car};
            end
            S_CTRL: begin
                write_enable_o = 1'b1;
                wdata_o        = 32'd1;      // solo send; new_rx no se toca
            end
            S_RX_LEER: addr_o = A_RX;
            S_RX_LIMPIAR: begin
                write_enable_o = 1'b1;
                wdata_o        = 32'd2;      // solo new_rx; send no se toca
            end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------
    // Recorrido de la secuencia
    // ---------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        // rx_val_q es un pulso: se limpia al principio de cada ciclo y
        // solo se vuelve a levantar dentro de S_RX_LIMPIAR, el mismo
        // patron que ya se vio en uart_peripheral para tx_start_q.
        rx_val_q <= 1'b0;

        if (rst_i) begin
            st_q      <= S_IDLE;
            linea_q   <= 2'd0;
            idx_q     <= 5'd0;
            pend_q    <= 1'b0;
            rx_byte_q <= 8'h00;
        end else begin
            // pend_q se actualiza fuera del case, no adentro de S_IDLE.
            // La razon es la que explica el encabezado: capturar puede
            // hacerse verdadero mientras la maquina esta en S_RX_LEER o
            // S_RX_LIMPIAR (dos estados que no forman parte de
            // tx_en_curso), y en esos estados igual hay que anotar el
            // envio para atenderlo apenas se vuelva a S_IDLE.
            if (capturar) pend_q <= 1'b1;

            unique case (st_q)

                S_IDLE: begin
                    // Prioridad explicita: si hay un envio pendiente se
                    // atiende antes que un byte recibido. Se eligio asi
                    // porque anotar un envio ya paso por la condicion
                    // capturar (que exige que no haya nada mas en
                    // curso), asi que cuando pend_q esta en 1 es una
                    // orden que el control del juego ya esta esperando
                    // ver salir.
                    if (pend_q) begin
                        pend_q  <= 1'b0;
                        linea_q <= 2'd0;
                        idx_q   <= 5'd0;
                        st_q    <= S_LIBRE;
                    end else if (rdata_i[B_NEW_RX]) begin
                        st_q <= S_RX_LEER;
                    end
                end

                S_RX_LEER: begin
                    rx_byte_q <= rdata_i[7:0];
                    st_q      <= S_RX_LIMPIAR;
                end

                S_RX_LIMPIAR: begin
                    // el aviso se limpia siempre; el pulso solo sale si el
                    // byte es una letra
                    //
                    // La escritura de A_CTRL con bit new_rx
                    // (definida en el always_comb de arriba) ocurre en
                    // este mismo estado sin condicion: se limpia el
                    // aviso este byte sea o no una letra valida. Lo
                    // unico condicionado aqui es si ademas se levanta
                    // rx_val_q para avisar hacia arriba.
                    if ((rx_byte_q >= CAR_A) && (rx_byte_q <= CAR_Z)) begin
                        rx_val_q <= 1'b1;
                    end
                    st_q <= S_IDLE;
                end

                S_LIBRE: if (!rdata_i[B_SEND]) st_q <= S_DATOS;

                S_DATOS: st_q <= S_CTRL;

                S_CTRL:  st_q <= S_FIN;

                S_FIN: begin
                    // Esta es la unica rama donde se decide si hay que
                    // repetir el dialogo con el siguiente byte de la
                    // misma linea, saltar a la primera posicion de la
                    // siguiente linea, o terminar del todo. Las tres
                    // posibilidades se leen de arriba hacia abajo como
                    // una prioridad: "todavia falta byte en esta linea"
                    // antes que "todavia falta otra linea" antes que
                    // "ya termine".
                    if (!rdata_i[B_SEND]) begin
                        if (idx_q != ult_idx) begin
                            idx_q <= idx_q + 5'd1;
                            st_q  <= S_LIBRE;
                        end else if (linea_q != n_lineas - 2'd1) begin
                            linea_q <= linea_q + 2'd1;
                            idx_q   <= 5'd0;
                            st_q    <= S_LIBRE;
                        end else begin
                            st_q <= S_IDLE;
                        end
                    end
                end

                default: st_q <= S_IDLE;
            endcase
        end
    end

endmodule
