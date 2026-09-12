// =====================================================================
// lcd_peripheral.sv - Periferico LCD con interfaz de registros
//
// Mapa de registros (interfaz estandar de 32 bits)
// ------------------------------------------------
//   addr 00  CONTROL / ESTADO
//              bit 0  start  W1P  emite el byte del registro de datos
//              bit 1  rs     RW   0 comando, 1 dato
//              bit 2  clear  W1P  limpia la pantalla
//              bit 3  home   W1P  cursor al inicio sin borrar
//              bit 8  busy   RO   hay una operacion en curso
//              bit 9  done   RO   la ultima operacion termino
//   addr 01  DATOS
//              bits 7:0  byte a enviar
//
// Los bits de solicitud se leen siempre como cero: son de pulso, no
// guardan estado. Lo que se consulta para saber si se puede pedir algo es
// busy, no ellos.
//
// done es un flag que se queda puesto
// -----------------------------------
// Se levanta al terminar una operacion y se mantiene hasta que se acepta
// la siguiente. Si fuera un pulso de un ciclo, un maestro que sondea el
// registro podria no coincidir nunca con ese ciclo y quedarse esperando
// indefinidamente. Es un fallo de integracion clasico y evitable.
//
// Prioridad entre solicitudes
// ---------------------------
// Si una misma escritura activa varios bits de solicitud se aplica
//     clear > home > start
// El orden no es arbitrario: limpiar la pantalla deja el cursor al
// inicio, asi que incluye el efecto de home, y ambos descartan el envio
// de un caracter que iba a acabar borrado.
//
// Una solicitud que llega con busy alto se descarta en silencio y no se
// encola. Esperar es responsabilidad de quien pide: encolar obligaria a
// decidir cuantas peticiones caben y que hacer al desbordar, y quien pide
// ya tiene que sondear busy de todos modos.
//
// clear y home no usan el registro de datos: el periferico conoce los
// codigos del juego de instrucciones y los genera el mismo.
// =====================================================================

module lcd_peripheral (
    input  logic        clk_i,
    input  logic        rst_i,

    // interfaz estandar de periferico
    input  logic        write_enable_i,
    input  logic [1:0]  addr_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] wdata_i,     // bits 31:10 reservados por la interfaz
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [31:0] rdata_o,

    // frontera con el controlador fisico
    output logic        start_o,
    output logic        rs_o,
    output logic [7:0]  data_o,
    input  logic        busy_i,
    input  logic        done_i
);

    localparam logic [1:0] ADDR_CTRL  = 2'b00;
    localparam logic [1:0] ADDR_DATOS = 2'b01;

    localparam logic [7:0] CMD_CLEAR = 8'h01;
    localparam logic [7:0] CMD_HOME  = 8'h02;

    logic [7:0] datos_q = 8'h00;
    logic       rs_q    = 1'b0;
    logic       done_q  = 1'b0;
    logic [7:0] cmd_q   = 8'h00;
    logic       crs_q   = 1'b0;
    logic       start_q = 1'b0;

    logic esc_ctrl, esc_datos;
    logic pide_start, pide_clear, pide_home, hay_peticion, acepta;

    assign esc_ctrl     = write_enable_i && (addr_i == ADDR_CTRL);
    assign esc_datos    = write_enable_i && (addr_i == ADDR_DATOS);
    assign pide_start   = esc_ctrl && wdata_i[0];
    assign pide_clear   = esc_ctrl && wdata_i[2];
    assign pide_home    = esc_ctrl && wdata_i[3];
    assign hay_peticion = pide_start || pide_clear || pide_home;
    assign acepta       = hay_peticion && !busy_i;

    assign start_o = start_q;
    assign rs_o    = crs_q;
    assign data_o  = cmd_q;

    // ---- lectura combinacional ----
    always_comb begin
        rdata_o = 32'd0;
        if (addr_i == ADDR_CTRL) begin
            rdata_o[1] = rs_q;       // los bits de solicitud leen cero
            rdata_o[8] = busy_i;
            rdata_o[9] = done_q;
        end else if (addr_i == ADDR_DATOS) begin
            rdata_o[7:0] = datos_q;
        end
    end

    always_ff @(posedge clk_i) begin
        start_q <= 1'b0;

        if (rst_i) begin
            datos_q <= 8'h00;
            rs_q    <= 1'b0;
            done_q  <= 1'b0;
            cmd_q   <= 8'h00;
            crs_q   <= 1'b0;
        end else begin
            if (esc_datos) datos_q <= wdata_i[7:0];
            if (esc_ctrl)  rs_q    <= wdata_i[1];

            if (done_i) done_q <= 1'b1;

            // La limpieza al aceptar va despues, para que gane si el fin de
            // la operacion anterior coincide con la peticion nueva.
            if (acepta) begin
                start_q <= 1'b1;
                done_q  <= 1'b0;
                if (pide_clear) begin
                    cmd_q <= CMD_CLEAR;
                    crs_q <= 1'b0;
                end else if (pide_home) begin
                    cmd_q <= CMD_HOME;
                    crs_q <= 1'b0;
                end else begin
                    cmd_q <= datos_q;
                    crs_q <= wdata_i[1];   // el rs de esta misma escritura
                end
            end
        end
    end

endmodule
