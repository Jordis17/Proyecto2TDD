// =====================================================================
// lcd_screen_ctrl.sv - Capa de presentacion del LCD
//
// Convierte una orden de alto nivel, "dibuja esta pantalla", en las 34
// transacciones que hacen falta sobre el periferico: dos comandos de
// direccion y los 32 caracteres de las dos lineas.
//
//Se apoya en tres bloques:
//   lcd_screen_snapshot - copia registrada de los datos de la partida
//   lcd_step_decoder    - decodifica el paso en comando/fila/columna
//   lcd_text_gen        - arma el byte de cada pantalla
//
// Maquina de estados que dialoga con lcd_peripheral (el maestro del bus):
//   1. leer CONTROL hasta que busy este en cero
//   2. escribir el byte en DATOS
//   3. escribir CONTROL con rs y start
//   4. leer CONTROL hasta que done este en uno
//
// Una orden que llega con busy_o en alto se ignora, igual que antes:
// solo se acepta un redraw_i nuevo estando en S_IDLE.
// =====================================================================

module lcd_screen_ctrl #(
    parameter int MAX_LEN = 12
) (
    input  logic        clk_i,
    input  logic        rst_i,

    // orden de dibujo
    input  logic [2:0]  screen_i,     // lcd_screen_pkg
    input  logic        redraw_i,     // pulso
    output logic        busy_o,

    // datos de la partida
    input  logic [8*MAX_LEN-1:0] word_data_i,   // primer caracter en los bits altos
    input  logic [3:0]           word_len_i,
    input  logic [MAX_LEN-1:0]   revealed_i,    // bit c en uno: posicion c revelada
    input  logic [2:0]           errors_i,      // errores cometidos, 0 a 6
    input  logic                 mode_i,        // 0 facil, 1 dificil
    input  logic [7:0]           wins_i,        // BCD de dos digitos

    // hacia lcd_peripheral
    output logic        write_enable_o,
    output logic [1:0]  addr_o,
    output logic [31:0] wdata_o,

    input  logic [31:0] rdata_i       // solo se miran los bits de busy y done
  
);

    import lcd_screen_pkg::A_CTRL, lcd_screen_pkg::A_DATOS,
           lcd_screen_pkg::B_BUSY, lcd_screen_pkg::B_DONE;

    typedef enum logic [2:0] {
        S_IDLE,
        S_LIBRE,    // esperar a que el periferico quede libre
        S_DATOS,    // cargar el byte
        S_CTRL,     // pedir la transaccion
        S_FIN       // esperar el aviso de fin
    } estado_t;

    estado_t    st_q   = S_IDLE;
    logic [5:0] paso_q = 6'd0;

    assign busy_o = (st_q != S_IDLE);

    // se acepta una orden nueva solo estando libres
    logic capture_en;
    assign capture_en = (st_q == S_IDLE) && redraw_i;

    // ---------------------------------------------------------------
    // Copia de los datos de la partida
    // ---------------------------------------------------------------
    logic [2:0]           scr_q;
    logic [8*MAX_LEN-1:0] wd_q;
    logic [3:0]           wl_q;
    logic [MAX_LEN-1:0]   rev_q;
    logic [2:0]           err_q;
    logic                 mode_q;
    logic [7:0]           wins_q;

    lcd_screen_snapshot #(
        .MAX_LEN (MAX_LEN)
    ) u_snapshot (
        .clk_i       (clk_i),
        .capture_i   (capture_en),
        .screen_i    (screen_i),
        .word_data_i (word_data_i),
        .word_len_i  (word_len_i),
        .revealed_i  (revealed_i),
        .errors_i    (errors_i),
        .mode_i      (mode_i),
        .wins_i      (wins_i),
        .scr_o       (scr_q),
        .word_data_o (wd_q),
        .word_len_o  (wl_q),
        .revealed_o  (rev_q),
        .errors_o    (err_q),
        .mode_o      (mode_q),
        .wins_o      (wins_q)
    );

    // ---------------------------------------------------------------
    // De que paso se trata
    // ---------------------------------------------------------------
    logic       es_comando, fila, es_ultimo;
    logic [3:0] col;

    lcd_step_decoder u_step_decoder (
        .paso_i       (paso_q),
        .es_comando_o (es_comando),
        .fila_o       (fila),
        .col_o        (col),
        .es_ultimo_o  (es_ultimo)
    );

    // ---------------------------------------------------------------
    // Byte a enviar en el paso actual
    // ---------------------------------------------------------------
    logic [7:0] byte_tx;
    logic       rs_tx;

    lcd_text_gen #(
        .MAX_LEN (MAX_LEN)
    ) u_text_gen (
        .scr_i        (scr_q),
        .fila_i       (fila),
        .col_i        (col),
        .es_comando_i (es_comando),
        .word_data_i  (wd_q),
        .word_len_i   (wl_q),
        .revealed_i   (rev_q),
        .errors_i     (err_q),
        .mode_i       (mode_q),
        .wins_i       (wins_q),
        .byte_o       (byte_tx),
        .rs_o         (rs_tx)
    );

    // ---------------------------------------------------------------
    // Bus hacia el periferico
    // ---------------------------------------------------------------
    // Fuera de las dos escrituras la direccion se deja en CONTROL, que es
    // el registro que hay que sondear.
    always_comb begin
        write_enable_o = 1'b0;
        addr_o         = A_CTRL;
        wdata_o        = 32'd0;

        unique case (st_q)
            S_DATOS: begin
                write_enable_o = 1'b1;
                addr_o         = A_DATOS;
                wdata_o        = {24'd0, byte_tx};
            end
            S_CTRL: begin
                write_enable_o = 1'b1;
                wdata_o        = {30'd0, rs_tx, 1'b1};   // rs y start
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            st_q   <= S_IDLE;
            paso_q <= 6'd0;
        end else begin
            unique case (st_q)

                S_IDLE: begin
                    if (redraw_i) begin
                        paso_q <= 6'd0;
                        st_q   <= S_LIBRE;
                    end
                end

                S_LIBRE: if (!rdata_i[B_BUSY]) st_q <= S_DATOS;

                S_DATOS: st_q <= S_CTRL;

                S_CTRL:  st_q <= S_FIN;

                S_FIN: begin
                    if (rdata_i[B_DONE]) begin
                        if (es_ultimo) begin
                            st_q <= S_IDLE;
                        end else begin
                            paso_q <= paso_q + 6'd1;
                            st_q   <= S_LIBRE;
                        end
                    end
                end

                default: st_q <= S_IDLE;
            endcase
        end
    end

endmodule
