module lcd_controller #(
    // Tiempo de espera después de energizar el LCD.
    // El datasheet recomienda al menos 20 ms; aquí se utilizan 50 ms
    // como margen de seguridad.
    parameter int POWERON_TICKS = 50,

    parameter int CIC_CORTA     = 6_000, //60 us a 100 MHz

    // Espera especial para instrucciones lentas.
    parameter int CIC_LARGA     = 200_000, //2 ms a 100 MHz

    // Tiempo durante el cual RS y el bus de datos permanecen estables
    // antes de activar Enable.
    parameter int CIC_SETUP     = 20, //200 ns

    // Duración del pulso alto de Enable.
    parameter int CIC_E_ALTO    = 100, //1 us

    // Tiempo que Enable permanece en bajo antes de finalizar el ciclo.
    parameter int CIC_E_BAJO    = 100 //1 us

) (


    // Reloj principal
    input  logic       clk_i,

    // Reinicio del controlador.
    // Solo cancela operaciones normales; nunca repite la inicialización.
    input  logic       rst_i,

    // Pulso de 1 ms.
    // Se utiliza únicamente durante el estado POWERON.
    input  logic       tick_i,

    // Solicitud de envío de un byte.
    // Debe durar un único ciclo de reloj.
    input  logic       start_i,

    // Register Select.
    // 0 -> comando.
    // 1 -> dato ASCII.
    input  logic       rs_i,

    // Byte que se desea transmitir al LCD.
    input  logic [7:0] data_i,

    // El controlador está ocupado mientras la FSM no esté en IDLE.
    output logic       busy_o,

    // Pulso de un ciclo indicando que terminó una transacción.
    output logic       done_o,

    // Bus paralelo de datos de 8 bits.
    output logic [7:0] lcd_db_o,

    // Register Select.
    output logic       lcd_rs_o,

    // Read/Write.
    // Siempre permanece en cero porque este controlador únicamente escribe.
    output logic       lcd_rw_o,

    // Señal Enable.
    output logic       lcd_e_o
);

    // ============================================================
    // Comandos utilizados durante la secuencia automática de inicio.
    // Estos bytes pertenecen al juego de instrucciones
    // ============================================================
    localparam logic [7:0] CMD_FUNCTION = 8'h38;
    localparam logic [7:0] CMD_DISPLAY  = 8'h0C;
    localparam logic [7:0] CMD_CLEAR    = 8'h01;
    localparam logic [7:0] CMD_ENTRY    = 8'h06;

    // ============================================================
    // Cálculo automático del tamaño de los contadores.
    // ============================================================
    localparam int MAX_ESPERA = (CIC_LARGA > CIC_CORTA) ? CIC_LARGA : CIC_CORTA;

    localparam int W_CIC = (MAX_ESPERA <= 1) ? 1 : $clog2(MAX_ESPERA);
    localparam int W_MS  = (POWERON_TICKS <= 1) ? 1 : $clog2(POWERON_TICKS);

    // ============================================================
    // Máquina de estados principal.
    // Cada estado representa una fase física del protocolo paralelo
    // del LCD.
    // ============================================================
    typedef enum logic [2:0] {

        // Espera inicial después del encendido.
        S_POWERON,

        // Coloca RS y los datos sobre el bus.
        S_CARGA,

        // Tiempo de establecimiento antes del pulso Enable.
        S_SETUP,

        // Enable permanece en alto.
        S_E_ALTO,

        // Enable baja y el LCD captura el byte.
        S_E_BAJO,

        // Espera mientras el LCD ejecuta internamente la instrucción.
        S_ESPERA,

        // Estado de reposo.
        S_IDLE

    } estado_t;

    // ============================================================
    // Registros internos de la FSM.
    // ============================================================

    // Estado actual de la máquina de estados.
    estado_t st_q = S_POWERON;

    // Paso actual de la secuencia de inicialización.
    logic [1:0] paso_q = 2'd0;

    // Se vuelve uno cuando el LCD quedó completamente configurado.
    logic init_q = 1'b0;

    // Contador de milisegundos usado únicamente en POWERON.
    logic [W_MS-1:0] ms_q = '0;

    // Contador general de temporización.
    logic [W_CIC-1:0] cic_q = '0;

    // Tiempo que debe esperar el estado ESPERA.
    logic [W_CIC-1:0] espera_q = '0;

    // Registro que mantiene estable el bus de datos.
    logic [7:0] db_q = 8'h00;

    // Registro que mantiene estable RS durante toda la transacción.
    logic rs_q = 1'b0;

    // Registro que controla físicamente Enable.
    logic e_q = 1'b0;

    // Pulso interno de finalización.
    logic done_q = 1'b0;

    // Buffer donde se guarda la siguiente operación solicitada.
    // Así data_i puede cambiar y la operación no se corrompe.
    logic [7:0] pend_db = 8'h00;
    logic       pend_rs = 1'b0;

    // ============================================================
    // Conexión entre registros internos y pines del LCD.
    // ============================================================
    assign lcd_db_o = db_q;
    assign lcd_rs_o = rs_q;

    // Nunca se realizan lecturas al LCD.
    assign lcd_rw_o = 1'b0;

    assign lcd_e_o  = e_q;

    // Busy depende únicamente del estado de la FSM.
    assign busy_o = (st_q != S_IDLE);

    // done es un pulso registrado.
    assign done_o = done_q;

    function automatic logic necesita_larga(
        input logic rs,
        input logic [7:0] d
    );

        return (!rs) &&
               ((d == 8'h01) || (d == 8'h02) || (d == 8'h03));

    endfunction

    // ============================================================
    // Decoder de la secuencia de inicialización.
    // Según paso_q selecciona el comando correspondiente y el tiempo
    // de espera asociado.
    // ============================================================
    logic [7:0] cmd_init;
    logic [W_CIC-1:0] esp_init;

    always_comb begin

        unique case (paso_q)

            // Configura el modo de funcionamiento del LCD.
            2'd0: begin
                cmd_init = CMD_FUNCTION;
                esp_init = W_CIC'(CIC_CORTA);
            end

            // Enciende el display y desactiva el cursor.
            2'd1: begin
                cmd_init = CMD_DISPLAY;
                esp_init = W_CIC'(CIC_CORTA);
            end

            // Limpia completamente la memoria del LCD.
            2'd2: begin
                cmd_init = CMD_CLEAR;
                esp_init = W_CIC'(CIC_LARGA);
            end

            // Configura el avance automático del cursor.
            default: begin
                cmd_init = CMD_ENTRY;
                esp_init = W_CIC'(CIC_CORTA);
            end

        endcase
    end

    // ============================================================
    // Máquina de estados secuencial.
    // Todo ocurre sincronizado con el flanco positivo del reloj.
    // ============================================================
    always_ff @(posedge clk_i) begin

        // done dura exactamente un ciclo.
        done_q <= 1'b0;

        // --------------------------------------------------------
        // Reinicio durante operación normal.
        // No reinicia la inicialización del LCD.
        // --------------------------------------------------------
        if (rst_i && init_q) begin

            st_q  <= S_IDLE;
            e_q   <= 1'b0;
            cic_q <= '0;

        end

        else begin

            unique case (st_q)

                // =================================================
                // POWERON
                // Espera POWERON_TICKS pulsos de 1 ms antes de enviar
                // cualquier instrucción al LCD.
                // =================================================
                S_POWERON: begin

                    e_q <= 1'b0;

                    if (tick_i) begin

                        if (ms_q == W_MS'(POWERON_TICKS - 1)) begin

                            ms_q   <= '0;
                            paso_q <= 2'd0;
                            st_q   <= S_CARGA;

                        end

                        else begin

                            ms_q <= ms_q + 1'b1;

                        end
                    end
                end

                // =================================================
                // CARGA
                // Coloca RS y DB sobre el bus y define cuánto tiempo
                // deberá esperar la siguiente instrucción.
                // =================================================
                S_CARGA: begin

                    if (!init_q) begin

                        db_q     <= cmd_init;
                        rs_q     <= 1'b0;
                        espera_q <= esp_init;

                    end

                    else begin

                        db_q <= pend_db;
                        rs_q <= pend_rs;

                        // Decide automáticamente si la instrucción necesita
                        // espera corta o larga.
                        espera_q <= necesita_larga(pend_rs, pend_db)
                                  ? W_CIC'(CIC_LARGA)
                                  : W_CIC'(CIC_CORTA);

                    end

                    // Reinicia el contador para comenzar el setup.
                    cic_q <= '0;
                    st_q  <= S_SETUP;

                end

                // =================================================
                // SETUP
                // RS y DB permanecen estables antes de activar Enable.
                // =================================================
                S_SETUP: begin

                    if (cic_q == W_CIC'(CIC_SETUP - 1)) begin

                        cic_q <= '0;

                        // Inicio del pulso Enable.
                        e_q   <= 1'b1;

                        st_q  <= S_E_ALTO;

                    end

                    else begin

                        cic_q <= cic_q + 1'b1;

                    end
                end

                // =================================================
                // E_ALTO
                // Mantiene Enable en nivel alto durante el tiempo
                // configurado.
                // =================================================
                S_E_ALTO: begin

                    if (cic_q == W_CIC'(CIC_E_ALTO - 1)) begin

                        cic_q <= '0';

                        // El flanco de bajada es el instante donde el LCD
                        // captura definitivamente el dato presente en DB.
                        e_q <= 1'b0;

                        st_q <= S_E_BAJO;

                    end

                    else begin

                        cic_q <= cic_q + 1'b1;

                    end
                end

                // =================================================
                // E_BAJO
                // Se mantiene Enable en bajo antes de iniciar la espera
                // interna del LCD.
                // =================================================
                S_E_BAJO: begin

                    if (cic_q == W_CIC'(CIC_E_BAJO - 1)) begin

                        cic_q <= '0;
                        st_q  <= S_ESPERA;

                    end

                    else begin

                        cic_q <= cic_q + 1'b1;

                    end
                end

                // =================================================
                // ESPERA
                // El LCD procesa internamente la instrucción recibida.
                // Durante este tiempo no debe enviarse otra operación.
                // =================================================
                S_ESPERA: begin

                    if (cic_q == espera_q - 1) begin

                        cic_q <= '0;

                        // ---------------- Inicialización ----------------
                        if (!init_q) begin

                            if (paso_q == 2'd3) begin

                                init_q <= 1'b1;
                                st_q   <= S_IDLE;

                            end

                            else begin

                                paso_q <= paso_q + 2'd1;
                                st_q   <= S_CARGA;

                            end

                        end

                        // ---------------- Operación ----------------
                        else begin

                            done_q <= 1'b1;
                            st_q   <= S_IDLE;

                        end

                    end

                    else begin

                        cic_q <= cic_q + 1'b1;

                    end
                end

                // =================================================
                // IDLE
                // El controlador permanece libre esperando una nueva
                // solicitud desde lcd_peripheral.
                // =================================================
                S_IDLE: begin

                    e_q <= 1'b0;

                    if (start_i) begin

                        // Se captura el dato y RS para mantenerlos estables
                        // durante toda la transacción.
                        pend_db <= data_i;
                        pend_rs <= rs_i;

                        st_q <= S_CARGA;

                    end
                end

                // Recuperación ante estados inválidos.
                default: st_q <= S_IDLE;

            endcase
        end
    end

endmodule