// =====================================================================
// uart_test_block.sv - Bloque de pruebas del periferico UART
//
// Modulo independiente del juego, que se activa por parametro del modulo
// superior. Sirve para validar el enlace con la computadora antes de
// integrar.
//
// Hace tres cosas:
//   1. transmite en ciclo la secuencia 'A'..'Z' seguida de un salto de
//      linea, a un ritmo marcado por el tick de 1 ms
//   2. retransmite cualquier byte que reciba, lo que valida el camino de
//      recepcion desde la computadora

// El eco tiene prioridad sobre la secuencia. Asi, quien esta al otro lado
// puede escribir un caracter y verlo volver de inmediato, en vez de tener
// que buscarlo entre el flujo automatico.
//
// Este bloque es maestro de la interfaz estandar: sondea el registro de
// control, lee, escribe y espera igual que hara el juego. Si funciona
// aqui, la secuencia de acceso a los registros es correcta.
// =====================================================================

module uart_test_block #(
    parameter int PERIODO_MS = 200        // separacion entre bytes de la secuencia
) (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        tick_i,

    // maestro de la interfaz estandar
    output logic        we_o,
    output logic [1:0]  addr_o,
    output logic [31:0] wdata_o,
    // De rdata_i solo se usan los bits bajos: el byte recibido y los dos
    // bits de control. El resto son reservados de la interfaz de 32 bits.
    input  logic [31:0] rdata_i,

    // evidencia local
    output logic [7:0]  ultimo_rx_o
);

    localparam logic [1:0] ADDR_TX   = 2'b00;
    localparam logic [1:0] ADDR_RX   = 2'b01;
    localparam logic [1:0] ADDR_CTRL = 2'b10;

    localparam logic [7:0] PRIMERA = 8'h41;   // 'A'
    localparam logic [7:0] ULTIMA  = 8'h5A;   // 'Z'
    localparam logic [7:0] SALTO   = 8'h0A;   // '\n'

    // El contador de milisegundos necesita el ancho justo para llegar a
    // PERIODO_MS - 1.
    localparam int W_MS = (PERIODO_MS <= 1) ? 1 : $clog2(PERIODO_MS);

    // Esta maquina de estados es, en esencia, un pequeno "programa" que
    // repite el mismo dialogo de cuatro pasos (sondear, escribir dato,
    // pedir envio, esperar).
    // Se agregan T_LEER_RX y T_LIMPIAR antes de ese dialogo cuando lo que
    // hay que mandar es un eco, para ir a buscar el byte recibido antes
    // de poder cargarlo como si fuera el dato a transmitir.
    typedef enum logic [2:0] {
        T_OCIOSO,     // sondea el registro de control
        T_LEER_RX,    // lee el byte recibido
        T_LIMPIAR,    // limpia el aviso de recepcion
        T_CARGAR,     // escribe el byte a transmitir
        T_ARRANCAR,   // ordena la transmision
        T_ESPERAR     // espera a que la transmision termine
    } estado_t;

    estado_t        st_q      = T_OCIOSO;
    logic [7:0]     sec_q     = PRIMERA;    // siguiente byte de la secuencia
    logic [7:0]     dato_q    = PRIMERA;    // byte que se esta enviando
    logic [7:0]     ult_rx_q  = 8'h00;
    logic           es_eco_q  = 1'b0;
    logic           pedir_q   = 1'b0;
    logic [W_MS-1:0] ms_q     = '0;

    assign ultimo_rx_o = ult_rx_q;

    // ---- salidas de la interfaz, derivadas del estado ----
    // Las salidas del bus se calculan solo a partir de st_q, nunca al
    // reves. Esto mantiene una sola fuente de verdad (el estado) y evita
    // el error clasico de terminar con dos lugares distintos que deciden
    // que se escribe.
    always_comb begin
        we_o    = 1'b0;
        addr_o  = ADDR_CTRL;
        wdata_o = 32'd0;
        unique case (st_q)
            T_OCIOSO:   begin addr_o = ADDR_CTRL; end
            T_LEER_RX:  begin addr_o = ADDR_RX;   end
            T_LIMPIAR:  begin addr_o = ADDR_CTRL; we_o = 1'b1; wdata_o = 32'h0000_0002; end
            T_CARGAR:   begin addr_o = ADDR_TX;   we_o = 1'b1; wdata_o = {24'd0, dato_q}; end
            T_ARRANCAR: begin addr_o = ADDR_CTRL; we_o = 1'b1; wdata_o = 32'h0000_0001; end
            T_ESPERAR:  begin addr_o = ADDR_CTRL; end
            default:    begin addr_o = ADDR_CTRL; end
        endcase
    end

    // ---- temporizador de la secuencia automatica ----
    // pedir_q es una bandera "pendiente de enviar" separada del contador
    // de milisegundos. Se pone en 1 cuando se cumple el periodo

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            ms_q    <= '0;
            pedir_q <= 1'b0;
        end else begin
            if (tick_i) begin
                if (ms_q == W_MS'(PERIODO_MS - 1)) begin
                    ms_q    <= '0;
                    pedir_q <= 1'b1;
                end else begin
                    ms_q <= ms_q + 1'b1;
                end
            end
            // la peticion se consume al empezar un envio de secuencia
            //
            // Se comprueba el estado actual (T_OCIOSO) y el registro de
            // control ya leido (rdata_i) en el mismo ciclo, no un valor
            // guardado aparte: como la lectura del periferico es
            // combinacional, rdata_i siempre refleja lo que hay ahora en
            // el registro CONTROL para la direccion que este puesta en
            // addr_o.
            if (st_q == T_OCIOSO && !rdata_i[1] && !rdata_i[0] && pedir_q)
                pedir_q <= 1'b0;
        end
    end

    // ---- maquina principal ----
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            st_q     <= T_OCIOSO;
            sec_q    <= PRIMERA;
            dato_q   <= PRIMERA;
            ult_rx_q <= 8'h00;
            es_eco_q <= 1'b0;
        end else begin
            unique case (st_q)
                T_OCIOSO: begin
                    // El orden de estas dos condiciones es la regla de
                    // prioridad del modulo escrita en codigo: se revisa
                    // primero si hay un byte esperando (rdata_i[1], el
                    // bit new_rx), y solo si no lo hay se mira si toca
                    // mandar el siguiente de la secuencia automatica.
                    if (rdata_i[1]) begin            // hay byte recibido: el eco manda
                        st_q     <= T_LEER_RX;
                        es_eco_q <= 1'b1;
                    end else if (pedir_q && !rdata_i[0]) begin
                        dato_q   <= sec_q;
                        es_eco_q <= 1'b0;
                        st_q     <= T_CARGAR;
                    end
                end

                T_LEER_RX: begin
                    // El mismo byte que se acaba de leer se guarda dos
                    // veces: en dato_q, para reenviarlo por T_CARGAR, y
                    // en ult_rx_q, que es la evidencia local que ve el
                    // resto del sistema. Son dos usos distintos del
                    // mismo valor y por eso conviene tenerlos separados
                    // en vez de leer dos veces del registro RX.
                    dato_q   <= rdata_i[7:0];
                    ult_rx_q <= rdata_i[7:0];
                    st_q     <= T_LIMPIAR;
                end

                T_LIMPIAR: st_q <= T_CARGAR;

                T_CARGAR:  st_q <= T_ARRANCAR;

                T_ARRANCAR: begin
                    st_q <= T_ESPERAR;
                    // es_eco_q distingue si lo que se acaba de arrancar
                    // vino de la secuencia o fue un eco. Solo cuando es
                    // la secuencia tiene sentido calcular cual es el
                    // siguiente caracter; un eco no debe adelantar nada.
                    if (!es_eco_q) begin
                        // avanzar la secuencia solo si lo enviado era de ella
                        if      (sec_q == ULTIMA) sec_q <= SALTO;
                        else if (sec_q == SALTO)  sec_q <= PRIMERA;
                        else                      sec_q <= sec_q + 8'd1;
                    end
                end

                T_ESPERAR: if (!rdata_i[0]) st_q <= T_OCIOSO;

                default:   st_q <= T_OCIOSO;
            endcase
        end
    end

endmodule
