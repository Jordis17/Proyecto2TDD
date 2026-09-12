// =====================================================================
// lcd_controller.sv - Temporizacion fisica del PmodCLP (Samsung KS0066)
//
// Interfaz paralela de 8 bits. R/W queda atado a cero: solo escritura.
//
// Por que no se lee la bandera de ocupado del LCD
// -----------------------------------------------
// Leerla obligaria a declarar el bus de datos como bidireccional, con
// buffers triestado sobre pines Pmod, control de direccion y riesgo de
// contencion electrica. Todo eso para ahorrar unos microsegundos que no
// significan nada frente a la resolucion de un segundo del juego. En su
// lugar se espera por contador con tiempos de peor caso, y todas las
// senales hacia el modulo quedan como salidas puras.
//
// Secuencia de arranque, tomada del manual del PmodCLP
// ----------------------------------------------------
//   encendido            esperar 20 ms (se adoptan 50)
//   Function Set  0x38   8 bits, 2 lineas, 5x8    -> 37 us (se adoptan 60)
//   Display On    0x0C   display si, cursor no    -> 37 us
//   Clear Display 0x01                            -> 1,52 ms (se adoptan 2)
//   Entry Mode    0x06   incremento, sin desplazamiento
//
// Arranca sola al salir de configuracion, sin depender del reinicio: el
// LCD debe quedar listo al encender la tarjeta, no cuando alguien pulse
// un boton. Por eso los registros declaran valor inicial y rst_i no
// reinicia la secuencia. Un reinicio durante la operacion normal aborta
// la transaccion en curso y vuelve a reposo, pero nunca repite los 50 ms
// de arranque, que no hacen falta.
//
// Ciclo de bus
// ------------
//   SETUP    datos y rs estables      200 ns
//   E alto                            1 us
//   E bajo   el dato entra en este flanco de bajada
//   ESPERA   segun la operacion
//
// El manual del PmodCLP no especifica el ancho de E ni los tiempos de
// establecimiento de rs y datos. Al no disponer del datasheet del KS0066,
// esos tres valores los fija el equipo con margen amplio: son varios
// ordenes de magnitud mayores que lo habitual en esta familia, y el ciclo
// resultante de 2,2 us es despreciable frente a los 60 us de espera entre
// operaciones. Quedan declarados como decision de diseno, no como dato de
// hoja de datos, y se validan sobre la tarjeta.
//
// La espera larga se decide aqui y no la pide quien llama: el controlador
// conoce el juego de instrucciones y sabe que Clear Display y Return Home
// necesitan 1,52 ms.
// =====================================================================

module lcd_controller #(
    parameter int POWERON_TICKS = 50,       // ms de espera al encender
    parameter int CIC_CORTA     = 6_000,    // 60 us a 100 MHz
    parameter int CIC_LARGA     = 200_000,  // 2 ms a 100 MHz
    parameter int CIC_SETUP     = 20,       // 200 ns
    parameter int CIC_E_ALTO    = 100,      // 1 us
    parameter int CIC_E_BAJO    = 100       // 1 us
) (
    input  logic       clk_i,
    input  logic       rst_i,
    input  logic       tick_i,      // pulso de 1 ms

    input  logic       start_i,     // pulso: emitir data_i con rs_i
    input  logic       rs_i,
    input  logic [7:0] data_i,
    output logic       busy_o,
    output logic       done_o,      // pulso de un ciclo al terminar

    output logic [7:0] lcd_db_o,
    output logic       lcd_rs_o,
    output logic       lcd_rw_o,
    output logic       lcd_e_o
);

    // comandos de la secuencia de arranque
    localparam logic [7:0] CMD_FUNCTION = 8'h38;
    localparam logic [7:0] CMD_DISPLAY  = 8'h0C;
    localparam logic [7:0] CMD_CLEAR    = 8'h01;
    localparam logic [7:0] CMD_ENTRY    = 8'h06;

    localparam int MAX_ESPERA = (CIC_LARGA > CIC_CORTA) ? CIC_LARGA : CIC_CORTA;
    localparam int W_CIC = (MAX_ESPERA <= 1) ? 1 : $clog2(MAX_ESPERA);
    localparam int W_MS  = (POWERON_TICKS <= 1) ? 1 : $clog2(POWERON_TICKS);

    typedef enum logic [2:0] {
        S_POWERON,     // espera de encendido
        S_CARGA,       // presenta datos y rs en el bus
        S_SETUP,       // establecimiento antes de subir E
        S_E_ALTO,
        S_E_BAJO,
        S_ESPERA,      // espera propia de la operacion
        S_IDLE
    } estado_t;

    estado_t          st_q     = S_POWERON;
    logic [1:0]       paso_q   = 2'd0;      // paso de la inicializacion
    logic             init_q   = 1'b0;      // inicializacion terminada
    logic [W_MS-1:0]  ms_q     = '0;
    logic [W_CIC-1:0] cic_q    = '0;
    logic [W_CIC-1:0] espera_q = '0;
    logic [7:0]       db_q     = 8'h00;
    logic             rs_q     = 1'b0;
    logic             e_q      = 1'b0;
    logic             done_q   = 1'b0;
    logic [7:0]       pend_db  = 8'h00;
    logic             pend_rs  = 1'b0;

    assign lcd_db_o = db_q;
    assign lcd_rs_o = rs_q;
    assign lcd_rw_o = 1'b0;      // solo escritura
    assign lcd_e_o  = e_q;
    assign busy_o   = (st_q != S_IDLE);
    assign done_o   = done_q;

    // Clear Display y Return Home necesitan la espera larga.
    // Return Home es 0x02 y su bit 0 es indiferente, de ahi el 0x03.
    function automatic logic necesita_larga(input logic rs, input logic [7:0] d);
        return (!rs) && ((d == 8'h01) || (d == 8'h02) || (d == 8'h03));
    endfunction

    // comando y espera de cada paso de la inicializacion
    logic [7:0]       cmd_init;
    logic [W_CIC-1:0] esp_init;
    always_comb begin
        unique case (paso_q)
            2'd0:    begin cmd_init = CMD_FUNCTION; esp_init = W_CIC'(CIC_CORTA); end
            2'd1:    begin cmd_init = CMD_DISPLAY;  esp_init = W_CIC'(CIC_CORTA); end
            2'd2:    begin cmd_init = CMD_CLEAR;    esp_init = W_CIC'(CIC_LARGA); end
            default: begin cmd_init = CMD_ENTRY;    esp_init = W_CIC'(CIC_CORTA); end
        endcase
    end

    always_ff @(posedge clk_i) begin
        done_q <= 1'b0;

        // El reinicio solo actua una vez terminada la inicializacion, y
        // nunca la repite: aborta lo que hubiera en curso y vuelve a reposo.
        if (rst_i && init_q) begin
            st_q  <= S_IDLE;
            e_q   <= 1'b0;
            cic_q <= '0;
        end else begin
            unique case (st_q)

                S_POWERON: begin
                    e_q <= 1'b0;
                    if (tick_i) begin
                        if (ms_q == W_MS'(POWERON_TICKS - 1)) begin
                            ms_q   <= '0;
                            paso_q <= 2'd0;
                            st_q   <= S_CARGA;
                        end else begin
                            ms_q <= ms_q + 1'b1;
                        end
                    end
                end

                S_CARGA: begin
                    if (!init_q) begin
                        db_q     <= cmd_init;
                        rs_q     <= 1'b0;
                        espera_q <= esp_init;
                    end else begin
                        db_q     <= pend_db;
                        rs_q     <= pend_rs;
                        espera_q <= necesita_larga(pend_rs, pend_db)
                                    ? W_CIC'(CIC_LARGA) : W_CIC'(CIC_CORTA);
                    end
                    cic_q <= '0;
                    st_q  <= S_SETUP;
                end

                S_SETUP: begin
                    if (cic_q == W_CIC'(CIC_SETUP - 1)) begin
                        cic_q <= '0;
                        e_q   <= 1'b1;
                        st_q  <= S_E_ALTO;
                    end else begin
                        cic_q <= cic_q + 1'b1;
                    end
                end

                S_E_ALTO: begin
                    if (cic_q == W_CIC'(CIC_E_ALTO - 1)) begin
                        cic_q <= '0;
                        e_q   <= 1'b0;      // el dato entra en este flanco
                        st_q  <= S_E_BAJO;
                    end else begin
                        cic_q <= cic_q + 1'b1;
                    end
                end

                S_E_BAJO: begin
                    if (cic_q == W_CIC'(CIC_E_BAJO - 1)) begin
                        cic_q <= '0;
                        st_q  <= S_ESPERA;
                    end else begin
                        cic_q <= cic_q + 1'b1;
                    end
                end

                S_ESPERA: begin
                    if (cic_q == espera_q - 1) begin
                        cic_q <= '0;
                        if (!init_q) begin
                            if (paso_q == 2'd3) begin
                                init_q <= 1'b1;
                                st_q   <= S_IDLE;
                            end else begin
                                paso_q <= paso_q + 2'd1;
                                st_q   <= S_CARGA;
                            end
                        end else begin
                            done_q <= 1'b1;     // fin de una operacion pedida
                            st_q   <= S_IDLE;
                        end
                    end else begin
                        cic_q <= cic_q + 1'b1;
                    end
                end

                S_IDLE: begin
                    e_q <= 1'b0;
                    if (start_i) begin
                        pend_db <= data_i;
                        pend_rs <= rs_i;
                        st_q    <= S_CARGA;
                    end
                end

                default: st_q <= S_IDLE;
            endcase
        end
    end

endmodule
