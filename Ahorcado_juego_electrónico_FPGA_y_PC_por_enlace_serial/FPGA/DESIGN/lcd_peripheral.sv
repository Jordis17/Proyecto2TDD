module lcd_peripheral (

    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        write_enable_i,

    // Dirección del registro que se desea leer o escribir.
    // 00 -> Registro de control.
    // 01 -> Registro de datos.
    input  logic [1:0]  addr_i,

    // Bus de escritura de 32 bits.
    // Aunque únicamente se utilizan algunos bits, la interfaz mantiene
    // un ancho estándar de 32 bits para todos los periféricos.
    input  logic [31:0] wdata_i,
  
    // Bus de lectura del periférico.
    output logic [31:0] rdata_o,

    // ============== Interfaz hacia el controlador LCD ==============
    // Estas señales ya no hablan con el procesador, sino con el módulo
    // lcd_controller, encargado del protocolo físico del LCD.
    output logic        start_o,
    output logic        rs_o,
    output logic [7:0]  data_o,

    // busy_i indica que el controlador LCD está ocupado ejecutando una
    // instrucción y no puede aceptar otra solicitud.
    input  logic        busy_i,

    // done_i se activa cuando el controlador termina la operación.
    input  logic        done_i
);

    // ==============================================================
    // Direcciones de los registros internos del periférico.
    // Se utilizan constantes para evitar escribir valores binarios
    // directamente en el código y facilitar mantenimiento.
    // ==============================================================
    localparam logic [1:0] ADDR_CTRL  = 2'b00;
    localparam logic [1:0] ADDR_DATOS = 2'b01;

    // ==============================================================
    // El periférico conoce estos códigos para generar Clear y Home sin
    // necesidad de que el procesador escriba el byte manualmente.
    // ==============================================================
    localparam logic [7:0] CMD_CLEAR = 8'h01;
    localparam logic [7:0] CMD_HOME  = 8'h02;

    // ==============================================================
    // Registros que almacenan la configuración escrita por el maestro.
    // Estos registros conservan la información entre ciclos de reloj.
    // ==============================================================

    // Byte que el usuario desea enviar al LCD.
    logic [7:0] datos_q = 8'h00;

    // Valor de RS asociado al dato almacenado.
    logic       rs_q    = 1'b0;

    // Flag que indica que la última operación terminó correctamente.
    // Se mantiene en uno hasta aceptar una nueva solicitud.
    logic       done_q  = 1'b0;

    // Byte que realmente será enviado al controlador LCD.
    // Puede venir de datos_q o ser un comando interno (Clear/Home).
    logic [7:0] cmd_q   = 8'h00;

    // RS correspondiente al byte que se enviará.
    logic       crs_q   = 1'b0;

    // Pulso de inicio hacia lcd_controller.
    // Solo permanece activo un ciclo de reloj.
    logic       start_q = 1'b0;

    // Escritura al registro de control.
    logic esc_ctrl;

    // Escritura al registro de datos.
    logic esc_datos;

    // Solicitudes individuales.
    logic pide_start;
    logic pide_clear;
    logic pide_home;

    // Indica que existe alguna petición válida.
    logic hay_peticion;

    // La petición únicamente se acepta cuando el controlador LCD está libre.
    logic acepta;


    // Decodificación de dirección y bits de control.
    // Cada assign representa una condición lógica sencilla.

    assign esc_ctrl     = write_enable_i && (addr_i == ADDR_CTRL);
    assign esc_datos    = write_enable_i && (addr_i == ADDR_DATOS);

    // Bits de solicitud escritos por el procesador.
    assign pide_start   = esc_ctrl && wdata_i[0];
    assign pide_clear   = esc_ctrl && wdata_i[2];
    assign pide_home    = esc_ctrl && wdata_i[3];

    // Si cualquiera de estos bits está activo existe una solicitud.
    assign hay_peticion = pide_start || pide_clear || pide_home;

    // Solo se acepta cuando busy_i vale cero.
    assign acepta       = hay_peticion && !busy_i;


    assign start_o = start_q;
    assign rs_o    = crs_q;
    assign data_o  = cmd_q;

    always_comb begin

        // Valor por defecto para evitar latches.
        rdata_o = 32'd0;

        // Lectura del registro de control.
        if (addr_i == ADDR_CTRL) begin

            // RS almacenado por el periférico.
            rdata_o[1] = rs_q;

            // Estado actual del controlador LCD.
            rdata_o[8] = busy_i;

            // Flag persistente de operación completada.
            rdata_o[9] = done_q;

        end

        // Lectura del registro de datos.
        else if (addr_i == ADDR_DATOS) begin

            // Devuelve el último byte escrito.
            rdata_o[7:0] = datos_q;

        end
    end

    // ==============================================================
    // Lógica secuencial principal.
    // Aquí se almacenan registros y se generan pulsos sincronizados.
    // ==============================================================
    always_ff @(posedge clk_i) begin

        // start_q siempre vuelve a cero al inicio del ciclo.
        // Esto garantiza que start_o sea un pulso de exactamente un reloj.
        start_q <= 1'b0;

        // ======================== RESET =========================
        if (rst_i) begin

            // Se limpian todos los registros internos.
            datos_q <= 8'h00;
            rs_q    <= 1'b0;
            done_q  <= 1'b0;
            cmd_q   <= 8'h00;
            crs_q   <= 1'b0;

        end

        else begin

            // --------------------------------------------------
            // Escritura del registro de datos.
            // El byte queda almacenado hasta que se solicite start.
            // --------------------------------------------------
            if (esc_datos)
                datos_q <= wdata_i[7:0];

            // --------------------------------------------------
            // Escritura del bit RS.
            // Permite decidir si el siguiente byte será comando o dato.
            // --------------------------------------------------
            if (esc_ctrl)
                rs_q <= wdata_i[1];

            // --------------------------------------------------
            // Cuando lcd_controller termina una operación,
            // done_q se mantiene activo hasta la siguiente solicitud.
            // --------------------------------------------------
            if (done_i)
                done_q <= 1'b1;

            // --------------------------------------------------
            // Nueva solicitud aceptada.
            // Tiene prioridad sobre done_i para limpiar el flag si ambos
            // ocurren en el mismo ciclo.
            // --------------------------------------------------
            if (acepta) begin

                // Genera el pulso de inicio.
                start_q <= 1'b1;

                // La nueva operación consume el flag anterior.
                done_q  <= 1'b0;

                // ==========================================
                // Prioridad de solicitudes:
                // Clear -> Home -> Start
                // ==========================================

                if (pide_clear) begin

                    // Envía directamente el comando Clear Display.
                    cmd_q <= CMD_CLEAR;
                    crs_q <= 1'b0;

                end

                else if (pide_home) begin

                    // Envía Return Home.
                    cmd_q <= CMD_HOME;
                    crs_q <= 1'b0;

                end

                else begin

                    // Operación normal: transmitir el dato almacenado.
                    cmd_q <= datos_q;

                    // Se utiliza el RS escrito en esta misma operación,
                    // permitiendo cambiar RS y lanzar start simultáneamente.
                    crs_q <= wdata_i[1];

                end
            end
        end
    end

endmodule