// =====================================================================
// tb_clk_tick_gen.sv - Testbench autoverificable de la base de tiempo
//
// Comprueba:
//   1. el periodo entre ticks es exactamente TICK_CYCLES
//   2. el periodo se mantiene constante entre ticks sucesivos
//   3. el tick dura exactamente un ciclo de reloj
//   4. el reset a mitad de cuenta reinicia el contador
//   5. con el valor real, un tick equivale a 1 ms de tiempo simulado
//
// Se instancian dos copias: una con un valor pequeno, para comprobar el
// comportamiento en pocos ciclos, y otra con el valor real de operacion.
// Poder hacer esto es la razon de que TICK_CYCLES sea un parametro.
// =====================================================================
`timescale 1ns/1ps

module tb_clk_tick_gen;

    localparam int TICK_CORTO = 10;
    localparam int TICK_REAL  = 100_000;
    localparam time T_CLK     = 10ns;      // 100 MHz

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic tick_corto, tick_real;

    int errores = 0;
    int ciclos, k;
    time t0, t1;

    always #(T_CLK/2) clk = ~clk;

    clk_tick_gen #(.TICK_CYCLES(TICK_CORTO)) dut_corto (
        .clk_i(clk), .rst_i(rst), .tick_o(tick_corto)
    );

    clk_tick_gen #(.TICK_CYCLES(TICK_REAL)) dut_real (
        .clk_i(clk), .rst_i(rst), .tick_o(tick_real)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            errores++;
        end
    endtask

    initial begin
        $display("");
        $display("=== tb_clk_tick_gen ===");

        // ---------- reset ----------
        repeat (3) @(posedge clk);
        check(tick_corto === 1'b0, "el tick no debe activarse durante el reset");
        rst = 1'b0;

        // ---------- 1 y 2: periodo constante e igual a TICK_CYCLES ----------
        do @(posedge clk); while (!tick_corto);   // sincronizar con el primer tick

        for (k = 0; k < 5; k++) begin
            ciclos = 0;
            do begin
                @(posedge clk);
                ciclos++;
            end while (!tick_corto);
            check(ciclos == TICK_CORTO,
                  $sformatf("periodo %0d medido en %0d ciclos, se esperaban %0d",
                            k + 1, ciclos, TICK_CORTO));
        end

        // ---------- 3: ancho del pulso ----------
        // en este punto acabamos de ver un tick; en el flanco siguiente debe estar bajo
        @(posedge clk);
        check(tick_corto === 1'b0, "el tick debe durar un solo ciclo");

        // ---------- 4: reset a mitad de cuenta ----------
        repeat (TICK_CORTO / 2) @(posedge clk);
        rst = 1'b1;
        @(posedge clk);
        rst = 1'b0;
        ciclos = 0;
        do begin
            @(posedge clk);
            ciclos++;
        end while (!tick_corto);
        check(ciclos == TICK_CORTO,
              $sformatf("tras el reset el primer tick llego en %0d ciclos, se esperaban %0d",
                        ciclos, TICK_CORTO));

        // ---------- 5: el valor real equivale a 1 ms ----------
        do @(posedge clk); while (!tick_real);
        t0 = $time;
        do @(posedge clk); while (!tick_real);
        t1 = $time;
        check((t1 - t0) == 1ms,
              $sformatf("el periodo real fue %0t, se esperaba 1 ms", t1 - t0));

        // ---------- resumen ----------
        $display("");
        if (errores == 0)
            $display("  PASS  periodo exacto, pulso de un ciclo, reset correcto y 1 ms reales");
        else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

endmodule
