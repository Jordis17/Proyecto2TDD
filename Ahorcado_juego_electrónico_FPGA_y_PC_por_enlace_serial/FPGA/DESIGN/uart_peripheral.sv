// =====================================================================
// uart_peripheral.sv - Periferico UART con interfaz de registros
//
// Mapa de registros (interfaz estandar de 32 bits)
// ------------------------------------------------
//   addr 00  DATOS TX   bits [7:0] byte a transmitir
//   addr 01  DATOS RX   bits [7:0] ultimo byte recibido
//   addr 10  CONTROL    bit 0 send, bit 1 new_rx
//   addr 11  reservado, lee cero
//
// El registro CONTROL no es plano
// -------------------------------
// Hay que limpiar new_rx escribiendo el registro, pero una escritura de
// 32 bits toca send y new_rx a la vez. Con semantica plana, limpiar
// new_rx podria cancelar una transmision en curso, y lanzar una
// transmision podria borrar un new_rx recien llegado y perder la letra
// del jugador. Es una carrera real, y de las que se manifiestan como
// fallo intermitente justo el dia de la demostracion.
//
//   bit 0  send    escribir 1 arranca una transmision si no hay otra;
//                  escribir 0 no hace nada; se lee 1 mientras transmite
//                  y el hardware lo baja al terminar
//   bit 1  new_rx  escribir 1 limpia el aviso; escribir 0 no hace nada

// Prioridad en la recepcion
// -------------------------
// Si llega un byte en el mismo ciclo en que se limpia new_rx, gana la
// llegada: el aviso queda activo y el byte nuevo se conserva. 

// El modulo se disena contra una interfaz minima declarada como supuesto:
//
//     tx_data_o, tx_start_o, tx_busy_i, rx_data_i, rx_valid_i
//
// Si el nucleo real resulta distinto, solo cambia esta frontera: los
// registros, la semantica de send y new_rx y todo lo que hay por encima
// quedan intactos.
//
// La maquina de transmision tiene un estado intermedio de arranque
// porque entre el pulso de inicio y el momento en que el nucleo levanta
// tx_busy puede pasar mas de un ciclo. Sin ese estado, send se bajaria
// de inmediato al ver tx_busy todavia en cero.
// =====================================================================

module uart_peripheral (
    input  logic        clk_i,
    input  logic        rst_i,

    // interfaz estandar de periferico
    input  logic        write_enable_i,
    input  logic [1:0]  addr_i,
    // Los bits 31:8 estan reservados por la interfaz estandar de 32 bits:
    // la carga util de este periferico es de un byte. Que no se usen es
    // deliberado, no un olvido.
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,

    // frontera con el nucleo UART
    output logic [7:0]  tx_data_o,
    output logic        tx_start_o,
    input  logic        tx_busy_i,
    input  logic [7:0]  rx_data_i,
    input  logic        rx_valid_i
);

    // Direcciones del mapa de registros. Usar localparam en vez de
    // comparar contra "2'b00" directamente en cada if hace que el
    // codigo se lea con nombres y que, si llega a cambiar el mapa
    // solo haya que tocar esta linea.
    localparam logic [1:0] ADDR_TX   = 2'b00;
    localparam logic [1:0] ADDR_RX   = 2'b01;
    localparam logic [1:0] ADDR_CTRL = 2'b10;

    // Estado de la maquina de transmision. TX_ARRANQUE existe solo por
    // el hueco de tiempo que puede pasar entre pedir el envio y que
    // tx_busy_i realmente suba.
    //Sin ese estado intermedio, la maquina revisaria tx_busy_i todavia en cero
    // y creeria que ya termino sin haber ni empezado.
    typedef enum logic [1:0] {
        TX_LIBRE,      // sin transmision
        TX_ARRANQUE,   // pulso enviado, esperando que el nucleo confirme
        TX_CURSO       // el nucleo esta transmitiendo
    } tx_estado_t;

    tx_estado_t tx_st_q = TX_LIBRE;

    logic [7:0] tx_reg_q  = 8'h00;
    logic [7:0] rx_reg_q  = 8'h00;
    logic       new_rx_q  = 1'b0;
    logic       tx_start_q = 1'b0;

    // ---- decodificacion de la escritura ----
    // Separar la decodificacion de direccion (esc_tx, esc_ctrl) de la
    // interpretacion de los bits de datos (pide_send, pide_limpiar) dos
    // niveles: primero "a quien le estan hablando" y despues "que le
    // estan pidiendo". Facilita leer el resto del modulo porque cada
    // always_ff de abajo solo necesita mirar el nombre con intencion
    // (pide_send), no reconstruir la condicion completa cada vez.
    logic esc_tx, esc_ctrl, pide_send, pide_limpiar;
    assign esc_tx       = write_enable_i && (addr_i == ADDR_TX);
    assign esc_ctrl     = write_enable_i && (addr_i == ADDR_CTRL);
    assign pide_send    = esc_ctrl && wdata_i[0];
    assign pide_limpiar = esc_ctrl && wdata_i[1];

    // send se lee alto desde que se acepta hasta que el nucleo termina
    // send_activo se calcula a partir del estado, no de un registro
    // propio: si ya existe una señal que dice en que estado esta la
    // maquina, duplicarla en otra variable solo abre la puerta a que un
    // dia queden desincronizadas.
    logic send_activo;
    assign send_activo = (tx_st_q != TX_LIBRE);

    // ---- lectura combinacional ----
    // El bus de lectura no tiene reloj: cambia de inmediato cuando
    // cambia addr_i, como corresponde a un mux. El "default" cubre
    // tanto la direccion reservada como cualquier valor imposible del
    // vector de 2 bits.
    always_comb begin
        unique case (addr_i)
            ADDR_TX:   rdata_o = {24'd0, tx_reg_q};
            ADDR_RX:   rdata_o = {24'd0, rx_reg_q};
            ADDR_CTRL: rdata_o = {30'd0, new_rx_q, send_activo};
            default:   rdata_o = 32'd0;
        endcase
    end

    // ---- registro de transmision ----
    // Un registro, sin mas condicion que "me estan escribiendo
    // en mi direccion". No depende de si hay una transmision en curso:
    // el dato queda guardado y solo se usa de verdad cuando llega send.
    always_ff @(posedge clk_i) begin
        if (rst_i)        tx_reg_q <= 8'h00;
        else if (esc_tx)  tx_reg_q <= wdata_i[7:0];
    end

    // ---- maquina de transmision ----
    // tx_start_q se limpia al principio de cada ciclo y solo se vuelve
    // a poner en 1 dentro del caso TX_LIBRE. Ese patron (limpiar primero,
    // levantar despues bajo una condicion).
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            tx_st_q    <= TX_LIBRE;
            tx_start_q <= 1'b0;
        end else begin
            tx_start_q <= 1'b0;
            unique case (tx_st_q)
                TX_LIBRE:
                    if (pide_send) begin
                        tx_start_q <= 1'b1;      // pulso de un ciclo
                        tx_st_q    <= TX_ARRANQUE;
                    end
                TX_ARRANQUE:
                    // se espera a que el nucleo confirme que ya tomo la peticion.
                    if (tx_busy_i) tx_st_q <= TX_CURSO;
                TX_CURSO:
                    if (!tx_busy_i) tx_st_q <= TX_LIBRE;
                default:
                    // Rama de seguridad: un enum de 2 bits solo tiene
                    // tres valores validos, pero el "default" documenta
                    // que, si por alguna razon el registro cayera en el
                    // cuarto valor, la maquina se recupera sola en vez
                    // de quedar atascada.
                    tx_st_q <= TX_LIBRE;
            endcase
        end
    end

    // ---- recepcion ----
    // Primero se pregunta
    // si llego un byte nuevo (rx_valid_i), y solo si no llego se atiende
    // el pedido de limpiar (pide_limpiar). Si las dos cosas pasaran en
    // el mismo ciclo, gana la llegada y new_rx_q se queda en 1.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            rx_reg_q <= 8'h00;
            new_rx_q <= 1'b0;
        end else if (rx_valid_i) begin
            rx_reg_q <= rx_data_i;               // la llegada tiene prioridad
            new_rx_q <= 1'b1;
        end else if (pide_limpiar) begin
            new_rx_q <= 1'b0;
        end
    end

    assign tx_data_o  = tx_reg_q;
    assign tx_start_o = tx_start_q;

endmodule
