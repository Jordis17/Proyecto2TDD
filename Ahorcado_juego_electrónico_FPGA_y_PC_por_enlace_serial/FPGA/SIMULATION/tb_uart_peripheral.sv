// =====================================================================
// tb_uart_peripheral.sv - Testbench autoverificable del periferico UART
//
// El periferico se conecta al modelo del nucleo y la linea de
// transmision se realimenta a la de recepcion, de modo que cada byte
// escrito recorre el camino completo: registro TX, serializacion,
// linea, deserializacion, registro RX. Asi se comprueba el periferico y
// la trama de verdad, no solo el banco de registros.
//
// Comprueba:
//   1. tras el reset todos los registros leen cero
//   2. la direccion reservada lee cero
//   3. el registro TX guarda y devuelve lo que se le escribe
//   4. escribir 0 en send no arranca nada
//   5. escribir 1 en send arranca y send se lee alto durante el envio
//   6. send se baja solo al terminar, sin intervencion del maestro
//   7. escribir send otra vez durante una transmision no la reinicia
//   8. el byte llega intacto por la linea y aparece en el registro RX
//   9. new_rx se levanta al recibir
//  10. escribir 1 en new_rx lo limpia
//  11. escribir 0 en new_rx NO lo limpia
//  12. INDEPENDENCIA: limpiar new_rx no cancela una transmision en curso
//  13. INDEPENDENCIA: arrancar una transmision no borra un new_rx pendiente
// =====================================================================
`timescale 1ns/1ps

module tb_uart_peripheral;

    localparam int BAUD_DIV = 16;    // corto, para simular rapido
    localparam int CICLOS_TRAMA = BAUD_DIV * 10;

    localparam logic [1:0] ADDR_TX   = 2'b00;
    localparam logic [1:0] ADDR_RX   = 2'b01;
    localparam logic [1:0] ADDR_CTRL = 2'b10;
    localparam logic [1:0] ADDR_RSV  = 2'b11;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic        we    = 1'b0;
    logic [1:0]  addr  = 2'b00;
    logic [31:0] wdata = 32'd0;
    logic [31:0] rdata;

    logic [7:0] tx_data;
    logic       tx_start, tx_busy;
    logic [7:0] rx_data;
    logic       rx_valid;
    logic       linea;               // tx del nucleo realimentada a su rx

    int errores = 0;
    int esperas;

    always #5 clk = ~clk;

    uart_peripheral dut (
        .clk_i(clk), .rst_i(rst),
        .write_enable_i(we), .addr_i(addr), .wdata_i(wdata), .rdata_o(rdata),
        .tx_data_o(tx_data), .tx_start_o(tx_start), .tx_busy_i(tx_busy),
        .rx_data_i(rx_data), .rx_valid_i(rx_valid)
    );

    uart_core_model #(.BAUD_DIV(BAUD_DIV)) nucleo (
        .clk_i(clk), .rst_i(rst),
        .tx_o(linea), .rx_i(linea),          // lazo
        .tx_data_i(tx_data), .tx_start_i(tx_start), .tx_busy_o(tx_busy),
        .rx_data_o(rx_data), .rx_valid_o(rx_valid)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            errores++;
        end
    endtask

    task automatic escribir(input logic [1:0] a, input logic [31:0] d);
        @(negedge clk);
        addr  = a;
        wdata = d;
        we    = 1'b1;
        @(negedge clk);
        we    = 1'b0;
        wdata = 32'd0;
    endtask

    task automatic leer(input logic [1:0] a, output logic [31:0] d);
        @(negedge clk);
        addr = a;
        we   = 1'b0;
        #1;
        d = rdata;
    endtask

    logic [31:0] v;

    initial begin
        $display("");
        $display("=== tb_uart_peripheral ===");

        // ---------- 1 y 2: estado tras reset ----------
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        leer(ADDR_TX,   v); check(v == 32'd0, "el registro TX no arranca en cero");
        leer(ADDR_RX,   v); check(v == 32'd0, "el registro RX no arranca en cero");
        leer(ADDR_CTRL, v); check(v == 32'd0, "el registro CONTROL no arranca en cero");
        leer(ADDR_RSV,  v); check(v == 32'd0, "la direccion reservada deberia leer cero");

        // ---------- 3: el registro TX guarda ----------
        escribir(ADDR_TX, 32'h0000_0041);          // 'A'
        leer(ADDR_TX, v);
        check(v[7:0] == 8'h41,
              $sformatf("el registro TX devolvio 0x%02h en vez de 0x41", v[7:0]));

        // ---------- 4: escribir 0 en send no hace nada ----------
        escribir(ADDR_CTRL, 32'h0000_0000);
        leer(ADDR_CTRL, v);
        check(v[0] == 1'b0, "escribir 0 en send arranco una transmision");

        // ---------- 5 y 6: arranque y bajada automatica ----------
        escribir(ADDR_CTRL, 32'h0000_0001);        // send = 1
        leer(ADDR_CTRL, v);
        check(v[0] == 1'b1, "send deberia leerse alto durante la transmision");

        // ---------- 7: reintentar send no reinicia ----------
        repeat (BAUD_DIV * 3) @(negedge clk);
        escribir(ADDR_CTRL, 32'h0000_0001);
        check(dut.tx_st_q !== 2'd1,
              "un segundo send reinicio la transmision en curso");

        // esperar a que termine
        esperas = 0;
        do begin
            leer(ADDR_CTRL, v);
            esperas++;
        end while (v[0] && esperas < CICLOS_TRAMA * 3);
        check(v[0] == 1'b0, "send no se bajo solo al terminar la transmision");

        // ---------- 8 y 9: el byte volvio por el lazo ----------
        esperas = 0;
        do begin
            leer(ADDR_CTRL, v);
            esperas++;
        end while (!v[1] && esperas < CICLOS_TRAMA * 3);
        check(v[1] == 1'b1, "new_rx no se levanto tras recibir el byte");
        leer(ADDR_RX, v);
        check(v[7:0] == 8'h41,
              $sformatf("se recibio 0x%02h en vez de 0x41", v[7:0]));

        // ---------- 11: escribir 0 en new_rx no lo limpia ----------
        escribir(ADDR_CTRL, 32'h0000_0000);
        leer(ADDR_CTRL, v);
        check(v[1] == 1'b1, "escribir 0 en new_rx lo limpio");

        // ---------- 10: escribir 1 si lo limpia ----------
        escribir(ADDR_CTRL, 32'h0000_0002);
        leer(ADDR_CTRL, v);
        check(v[1] == 1'b0, "escribir 1 en new_rx no lo limpio");

        // ---------- 12: limpiar new_rx no cancela una transmision ----------
        escribir(ADDR_TX, 32'h0000_005A);          // 'Z'
        escribir(ADDR_CTRL, 32'h0000_0001);        // arrancar
        repeat (BAUD_DIV * 2) @(negedge clk);
        escribir(ADDR_CTRL, 32'h0000_0002);        // limpiar new_rx
        leer(ADDR_CTRL, v);
        check(v[0] == 1'b1,
              "limpiar new_rx cancelo la transmision en curso");

        // esperar el byte de vuelta
        esperas = 0;
        do begin
            leer(ADDR_CTRL, v);
            esperas++;
        end while (!v[1] && esperas < CICLOS_TRAMA * 3);
        check(v[1] == 1'b1, "no llego el segundo byte");
        leer(ADDR_RX, v);
        check(v[7:0] == 8'h5A,
              $sformatf("se recibio 0x%02h en vez de 0x5A", v[7:0]));

        // ---------- 13: arrancar una transmision no borra new_rx ----------
        // Hay que esperar a que la transmision anterior termine de verdad.
        // Con el lazo, el receptor muestrea el bit de parada en su centro,
        // o sea medio bit antes de que el transmisor suelte la linea: por
        // eso new_rx se levanta ANTES de que send baje. Dar por terminada
        // la transmision al ver new_rx seria un error, y aqui haria que el
        // send de esta prueba se ignorase por llegar con otra en curso.
        esperas = 0;
        do begin
            leer(ADDR_CTRL, v);
            esperas++;
        end while (v[0] && esperas < CICLOS_TRAMA * 3);
        check(v[0] == 1'b0, "la transmision anterior no termino");
        check(v[1] == 1'b1, "el aviso de recepcion se perdio mientras se esperaba");

        escribir(ADDR_TX, 32'h0000_004D);          // 'M'
        escribir(ADDR_CTRL, 32'h0000_0001);        // solo send
        leer(ADDR_CTRL, v);
        check(v[1] == 1'b1,
              "arrancar una transmision borro el aviso de recepcion pendiente");
        check(v[0] == 1'b1, "la transmision no arranco");

        $display("");
        if (errores == 0)
            $display("  PASS  registros, semantica por bit, independencia de campos y trama completa");
        else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

endmodule
