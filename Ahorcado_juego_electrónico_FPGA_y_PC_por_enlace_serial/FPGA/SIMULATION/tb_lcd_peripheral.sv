// =====================================================================
//    Cubre, sobre el mapa de registros documentado en el propio archivo:
//   - Escritura/lectura de DATOS.
//   - Aceptacion de start con busy_i en bajo: pulso de start_o de un
//     ciclo, rs_o/data_o "comprometidos" (crs_q/cmd_q).
//   - rs_q (bit de lectura de CONTROL) vs crs_q (el que sale a rs_o):
//     son registros distintos, se escriben en momentos distintos.
//   - Peticion descartada en silencio si llega con busy_i en alto.
//   - Prioridad clear > home > start.
//   - done que se mantiene puesto hasta la siguiente aceptacion, y que
//     pierde contra una aceptacion simultanea (la limpieza gana).
//   - Los bits de peticion (start/clear/home) siempre leen cero.
// =====================================================================
`timescale 1ns/1ps

module tb_lcd_peripheral;

    localparam int CLK_PERIOD = 10;

    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic        rst;
    logic        we;
    logic [1:0]  addr;
    logic [31:0] wdata;
    logic [31:0] rdata;

    logic        start_o, rs_o;
    logic [7:0]  data_o;
    logic        busy, done_i;

    int errcnt = 0;
    int checks = 0;

    localparam logic [1:0] A_CTRL  = 2'b00;
    localparam logic [1:0] A_DATOS = 2'b01;

    lcd_peripheral dut (
        .clk_i          (clk),
        .rst_i          (rst),
        .write_enable_i (we),
        .addr_i         (addr),
        .wdata_i        (wdata),
        .rdata_o        (rdata),
        .start_o        (start_o),
        .rs_o           (rs_o),
        .data_o         (data_o),
        .busy_i         (busy),
        .done_i         (done_i)
    );

    task automatic check(string etiqueta, logic [63:0] got, logic [63:0] exp);
        checks++;
        if (got !== exp) begin
            errcnt++;
            $display("[FALLO] %s: esperado=0x%0h obtenido=0x%0h", etiqueta, exp, got);
        end
    endtask

    // Escribe un registro durante un flanco de subida y lo retira despues.
    task automatic write_reg(logic [1:0] a, logic [31:0] d);
        @(negedge clk);
        we    = 1'b1;
        addr  = a;
        wdata = d;
        @(posedge clk);
        #1;
        @(negedge clk);
        we = 1'b0;
    endtask

    task automatic read_reg(logic [1:0] a, output logic [31:0] d);
        addr = a;
        we   = 1'b0;
        #1;
        d = rdata;
    endtask

    initial begin
        logic [31:0] leido;

        rst = 1'b1; we = 1'b0; addr = A_CTRL; wdata = 32'd0;
        busy = 1'b0; done_i = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        rst = 1'b0;

        // ---- estado tras reset ----
        read_reg(A_CTRL, leido);
        check("tras reset: CONTROL", leido, 32'd0);
        check("tras reset: start_o", start_o, 1'b0);

        // ---- escritura/lectura de DATOS ----
        write_reg(A_DATOS, 32'h0000_0041);   // 'A'
        read_reg(A_DATOS, leido);
        check("DATOS leido tras escritura", leido[7:0], 8'h41);

        // ---- aceptacion de start con busy_i bajo ----
        busy = 1'b0;
        write_reg(A_CTRL, 32'h0000_0003);   // start=1, rs=1
        #1;
        check("start_o pulsa tras aceptar", start_o, 1'b1);
        check("rs_o comprometido = 1",       rs_o,    1'b1);
        check("data_o comprometido = DATOS", data_o,  8'h41);
        read_reg(A_CTRL, leido);
        check("rs_q (lectura CONTROL bit1) = 1", leido[1], 1'b1);

        @(posedge clk); #1;
        check("start_o vuelve a 0 el ciclo siguiente", start_o, 1'b0);

        // ---- peticion descartada por busy_i en alto ----
        busy = 1'b1;
        write_reg(A_DATOS, 32'h0000_0042);  // 'B', no deberia importar
        write_reg(A_CTRL, 32'h0000_0001);   // pide start con busy_i=1
        #1;
        check("start_o NO pulsa si busy_i=1", start_o, 1'b0);
        check("data_o no cambia (sigue comprometido a 'A')", data_o, 8'h41);
        check("rs_o no cambia", rs_o, 1'b1);
        busy = 1'b0;

        // ---- prioridad home > start (sin clear) ----
        write_reg(A_CTRL, 32'h0000_0009);   // start=1, home=1
        #1;
        check("home gana sobre start: data_o = CMD_HOME", data_o, 8'h02);
        check("home gana sobre start: rs_o = 0",           rs_o,   1'b0);

        // ---- prioridad clear > home (y > start) ----
        write_reg(A_CTRL, 32'h0000_000D);   // start=1, home=1, clear=1
        #1;
        check("clear gana sobre home y start: data_o = CMD_CLEAR", data_o, 8'h01);
        check("clear gana sobre home y start: rs_o = 0",           rs_o,   1'b0);

        // ---- bits de peticion siempre leen cero ----
        read_reg(A_CTRL, leido);
        check("bit0 (start) siempre lee 0", leido[0], 1'b0);
        check("bit2 (clear) siempre lee 0", leido[2], 1'b0);
        check("bit3 (home) siempre lee 0",  leido[3], 1'b0);

        // ---- done se mantiene puesto hasta la siguiente aceptacion ----
        @(negedge clk);
        done_i = 1'b1;
        @(posedge clk);
        #1;
        done_i = 1'b0;
        read_reg(A_CTRL, leido);
        check("done se levanta y se mantiene", leido[9], 1'b1);
        @(posedge clk); #1;
        read_reg(A_CTRL, leido);
        check("done sigue en 1 sin nueva aceptacion", leido[9], 1'b1);

        // ---- una aceptacion simultanea con done_i limpia done (gana la limpieza) ----
        @(negedge clk);
        done_i = 1'b1;
        we     = 1'b1;
        addr   = A_CTRL;
        wdata  = 32'h0000_0001;   // start, busy_i ya esta en 0
        @(posedge clk);
        #1;
        done_i = 1'b0;
        we     = 1'b0;
        read_reg(A_CTRL, leido);
        check("done_i simultaneo con aceptacion: gana la limpieza (done=0)", leido[9], 1'b0);

        // ---- reset general limpia los registros ----
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk);
        #1;
        rst = 1'b0;
        read_reg(A_CTRL, leido);
        check("reset limpia rs_q/done_q", leido, 32'd0);
        read_reg(A_DATOS, leido);
        check("reset limpia datos_q", leido[7:0], 8'h00);

        $display("----------------------------------------------------");
        if (errcnt == 0)
            $display("PASA: lcd_peripheral (%0d verificaciones)", checks);
        else
            $display("FALLA: lcd_peripheral (%0d de %0d verificaciones fallaron)",
                      errcnt, checks);
        $display("----------------------------------------------------");
        $finish;
    end

endmodule
