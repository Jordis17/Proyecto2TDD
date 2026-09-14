// =====================================================================
// tb_uart_test_block.sv - Testbench del bloque de pruebas del UART
//
//   uart_test_block -> uart_peripheral -> uart_core_model -> linea serie
//
// El testbench hace de computadora. Un proceso MONITOR decodifica de
// forma permanente todo lo que sale por la linea de transmision y lo
// encola; las comprobaciones consumen de esa cola.
//
// El monitor permanente no es un adorno. El bloque transmite de forma
// continua, y la tarea que genera bytes en la linea de entrada tarda diez
// tiempos de bit en completarse. Un testbench que solo escuchara entre
// comprobacion y comprobacion perderia los caracteres emitidos mientras
// tanto y acusaria al modulo de saltarse la secuencia.
//
// Comprueba:
//   1. la secuencia automatica avanza sin saltarse ni repetir caracteres
//   2. un byte recibido aparece en la salida de evidencia local
//   3. ese byte se retransmite
//   4. el eco no descoloca la secuencia: al reanudarse continua en el
//      caracter que tocaba
// =====================================================================
`timescale 1ns/1ps

module tb_uart_test_block;

    localparam int BAUD_DIV   = 16;
    localparam int TICK_DIV   = 4;
    localparam int PERIODO_MS = 3;
    localparam int N_BUFFER   = 64;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic        we;
    logic [1:0]  addr;
    logic [31:0] wdata, rdata;
    logic [7:0]  ultimo_rx;

    logic [7:0] tx_data;
    logic       tx_start, tx_busy;
    logic [7:0] rx_data;
    logic       rx_valid;

    logic linea_tx;
    logic linea_rx = 1'b1;

    int errores = 0;

    // cola circular alimentada por el monitor
    logic [7:0] cola [0:N_BUFFER-1];
    int         cola_esc = 0;
    int         cola_lee = 0;

    always #5 clk = ~clk;

    int tick_cnt = 0;
    logic tick;
    assign tick = (tick_cnt == TICK_DIV - 1);
    always_ff @(posedge clk) tick_cnt <= tick ? 0 : tick_cnt + 1;

    uart_test_block #(.PERIODO_MS(PERIODO_MS)) bloque (
        .clk_i(clk), .rst_i(rst), .tick_i(tick),
        .we_o(we), .addr_o(addr), .wdata_o(wdata), .rdata_i(rdata),
        .ultimo_rx_o(ultimo_rx)
    );

    uart_peripheral periferico (
        .clk_i(clk), .rst_i(rst),
        .write_enable_i(we), .addr_i(addr), .wdata_i(wdata), .rdata_o(rdata),
        .tx_data_o(tx_data), .tx_start_o(tx_start), .tx_busy_i(tx_busy),
        .rx_data_i(rx_data), .rx_valid_i(rx_valid)
    );

    uart_core_model #(.BAUD_DIV(BAUD_DIV)) nucleo (
        .clk_i(clk), .rst_i(rst),
        .tx_o(linea_tx), .rx_i(linea_rx),
        .tx_data_i(tx_data), .tx_start_i(tx_start), .tx_busy_o(tx_busy),
        .rx_data_o(rx_data), .rx_valid_o(rx_valid)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            errores++;
        end
    endtask

    // ---- monitor permanente de la linea de transmision ----
    initial begin
        logic [7:0] d;
        forever begin
            @(negedge linea_tx);                            // bit de arranque
            repeat (BAUD_DIV + BAUD_DIV/2) @(posedge clk);  // centro del primer dato
            for (int i = 0; i < 8; i++) begin
                d[i] = linea_tx;
                repeat (BAUD_DIV) @(posedge clk);
            end
            cola[cola_esc % N_BUFFER] = d;
            cola_esc++;
        end
    end

    task automatic siguiente(output logic [7:0] dato);
        int espera;
        espera = 0;
        while (cola_lee >= cola_esc && espera < 200 * BAUD_DIV) begin
            @(posedge clk);
            espera++;
        end
        if (cola_lee >= cola_esc) begin
            $display("  FAIL: no llego ningun byte a tiempo");
            errores++;
            dato = 8'h00;
        end else begin
            dato = cola[cola_lee % N_BUFFER];
            cola_lee++;
        end
    endtask

    // la computadora emite un byte
    task automatic enviar_serie(input logic [7:0] dato);
        @(posedge clk);
        linea_rx = 1'b0;
        repeat (BAUD_DIV) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            linea_rx = dato[i];
            repeat (BAUD_DIV) @(posedge clk);
        end
        linea_rx = 1'b1;
        repeat (BAUD_DIV) @(posedge clk);
    endtask

    logic [7:0] b, esperado;
    int ecos_vistos, k;

    initial begin
        $display("");
        $display("=== tb_uart_test_block ===");

        repeat (4) @(negedge clk);
        rst = 1'b0;

        // ---------- 1: los primeros de la secuencia ----------
        esperado = "A";
        for (k = 0; k < 3; k++) begin
            siguiente(b);
            check(b == esperado,
                  $sformatf("se esperaba '%c' y llego 0x%02h", esperado, b));
            esperado = esperado + 8'd1;
        end

        // ---------- 2, 3, 4: primer eco ----------
        enviar_serie("7");
        ecos_vistos = 0;
        for (k = 0; k < 6; k++) begin
            siguiente(b);
            if (b == "7") begin
                ecos_vistos++;                      // es el eco, no avanza la secuencia
            end else begin
                check(b == esperado,
                      $sformatf("la secuencia se descoloco: se esperaba '%c' y llego 0x%02h",
                                esperado, b));
                esperado = esperado + 8'd1;
            end
        end
        check(ecos_vistos == 1,
              $sformatf("se esperaba un eco de '7' y hubo %0d", ecos_vistos));
        check(ultimo_rx == "7",
              $sformatf("la evidencia local muestra 0x%02h en vez de '7'", ultimo_rx));

        // ---------- segundo eco, para confirmar que no se descoloca ----------
        enviar_serie("#");
        ecos_vistos = 0;
        for (k = 0; k < 6; k++) begin
            siguiente(b);
            if (b == "#") begin
                ecos_vistos++;
            end else begin
                check(b == esperado,
                      $sformatf("tras el segundo eco se esperaba '%c' y llego 0x%02h",
                                esperado, b));
                esperado = esperado + 8'd1;
            end
        end
        check(ecos_vistos == 1,
              $sformatf("se esperaba un eco de '#' y hubo %0d", ecos_vistos));
        check(ultimo_rx == "#", "la evidencia local no se actualizo con el segundo eco");

        $display("");
        if (errores == 0)
            $display("  PASS  secuencia sin saltos, eco retransmitido y evidencia local correctos");
        else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

endmodule
