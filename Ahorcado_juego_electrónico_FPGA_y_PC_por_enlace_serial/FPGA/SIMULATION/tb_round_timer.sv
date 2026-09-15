// =====================================================================
// tb_round_timer.sv - Testbench autoverificable de la cuenta regresiva
//
// Comprueba:
//   1. tras el reset, cuenta en cero y sin aviso de vencimiento
//   2. load carga el valor y no dispara el vencimiento
//   3. con run_i bajo la cuenta no avanza
//   4. un segundo cuesta exactamente TICKS_POR_SEGUNDO ticks
//   5. el modo facil (60 s) vence tras 60 x TICKS ticks, ni antes ni despues
//   6. el modo dificil (45 s) vence antes que el facil
//   7. al llegar a cero la cuenta se detiene y no da la vuelta a 127
//   8. timeout_o es un nivel que se mantiene, no un pulso
//   9. un nuevo load reinicia la cuenta y retira el aviso
//
// =====================================================================
`timescale 1ns/1ps

module tb_round_timer;

    localparam int TICKS_CORTO = 5;      // "segundo" corto para simular rapido
    localparam int TICKS_REAL  = 1000;   // valor de operacion
    localparam int TICK_DIV    = 4;      // ciclos de reloj por tick
    localparam int T_FACIL     = 60;
    localparam int T_DIFICIL   = 45;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic load = 1'b0;
    logic run  = 1'b0;
    logic [6:0] seconds = 7'd0;

    logic [6:0] t_corto, t_real;
    logic       to_corto, to_real;

    int errores = 0;
    int n, k, ticks_contados;

    always #5 clk = ~clk;

    int tick_cnt = 0;
    logic tick;
    assign tick = (tick_cnt == TICK_DIV - 1);
    always_ff @(posedge clk) tick_cnt <= tick ? 0 : tick_cnt + 1;

    round_timer #(.TICKS_POR_SEGUNDO(TICKS_CORTO)) dut_corto (
        .clk_i(clk), .rst_i(rst), .tick_i(tick),
        .load_i(load), .seconds_i(seconds), .run_i(run),
        .time_s_o(t_corto), .timeout_o(to_corto)
    );

    round_timer #(.TICKS_POR_SEGUNDO(TICKS_REAL)) dut_real (
        .clk_i(clk), .rst_i(rst), .tick_i(tick),
        .load_i(load), .seconds_i(seconds), .run_i(run),
        .time_s_o(t_real), .timeout_o(to_real)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            errores++;
        end
    endtask

    task automatic esperar_ticks(input int cuantos);
        for (int t = 0; t < cuantos; t++) begin
            do @(posedge clk); while (!tick);
        end
        @(negedge clk);
    endtask

    task automatic cargar(input int segundos);
        @(negedge clk);
        seconds = segundos[6:0];
        load    = 1'b1;
        @(negedge clk);
        load    = 1'b0;
    endtask

    initial begin
        $display("");
        $display("=== tb_round_timer ===");

        // ---------- 1: estado tras reset ----------
        repeat (3) @(negedge clk);
        check(t_corto === 7'd0,   "la cuenta debe estar en cero tras el reset");
        check(to_corto === 1'b0,  "no debe haber aviso de vencimiento tras el reset");
        rst = 1'b0;
        @(negedge clk);

        // ---------- 2: carga ----------
        cargar(T_FACIL);
        check(t_corto === T_FACIL[6:0],
              $sformatf("tras cargar se esperaban %0d s y hay %0d", T_FACIL, t_corto));
        check(to_corto === 1'b0, "la carga no debe disparar el vencimiento");

        // ---------- 3: sin run_i no avanza ----------
        run = 1'b0;
        esperar_ticks(TICKS_CORTO * 3);
        check(t_corto === T_FACIL[6:0],
              $sformatf("con run_i bajo la cuenta cambio a %0d", t_corto));

        // ---------- 4: un segundo cuesta TICKS_CORTO ticks ----------
        @(negedge clk);
        run = 1'b1;
        esperar_ticks(TICKS_CORTO);
        check(t_corto === (T_FACIL - 1),
              $sformatf("tras un segundo se esperaban %0d s y hay %0d", T_FACIL - 1, t_corto));

        // ---------- 5: vencimiento exacto del modo facil ----------
        @(negedge clk);
        run = 1'b0;
        cargar(T_FACIL);
        @(negedge clk);
        run = 1'b1;
        ticks_contados = 0;
        while (!to_corto && ticks_contados < T_FACIL * TICKS_CORTO * 2) begin
            esperar_ticks(1);
            ticks_contados++;
        end
        check(ticks_contados == T_FACIL * TICKS_CORTO,
              $sformatf("el modo facil vencio en %0d ticks, se esperaban %0d",
                        ticks_contados, T_FACIL * TICKS_CORTO));

        // ---------- 7: no da la vuelta ----------
        esperar_ticks(TICKS_CORTO * 3);
        check(t_corto === 7'd0,
              $sformatf("la cuenta siguio tras llegar a cero y vale %0d", t_corto));

        // ---------- 8: el aviso es un nivel ----------
        check(to_corto === 1'b1, "el aviso de vencimiento debe mantenerse activo");

        // ---------- 9: un nuevo load reinicia ----------
        cargar(T_DIFICIL);
        check(t_corto === T_DIFICIL[6:0], "el nuevo load no cargo el valor");
        check(to_corto === 1'b0, "el nuevo load no retiro el aviso");

        // ---------- 6: el modo dificil vence antes ----------
        ticks_contados = 0;
        while (!to_corto && ticks_contados < T_FACIL * TICKS_CORTO * 2) begin
            esperar_ticks(1);
            ticks_contados++;
        end
        check(ticks_contados == T_DIFICIL * TICKS_CORTO,
              $sformatf("el modo dificil vencio en %0d ticks, se esperaban %0d",
                        ticks_contados, T_DIFICIL * TICKS_CORTO));
        check(T_DIFICIL * TICKS_CORTO < T_FACIL * TICKS_CORTO,
              "el modo dificil debe dar menos tiempo que el facil");

        // ---------- 4 bis: con el valor real, un segundo son 1000 ticks ----------
        @(negedge clk);
        run = 1'b0;
        cargar(7'd3);
        @(negedge clk);
        run = 1'b1;
        esperar_ticks(TICKS_REAL);
        check(t_real === 7'd2,
              $sformatf("con 1000 ticks se esperaban 2 s y hay %0d", t_real));

        // ---------- resumen ----------
        $display("");
        if (errores == 0)
            $display("  PASS  carga, habilitacion, segundo exacto, vencimiento de 60 s y 45 s, sin vuelta");
        else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

endmodule