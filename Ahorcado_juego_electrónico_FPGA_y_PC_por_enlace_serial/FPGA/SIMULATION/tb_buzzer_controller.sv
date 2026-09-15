// =====================================================================
// tb_buzzer_controller.sv - Testbench autoverificable del sonido
//
// Comprueba:
//   1. en reposo la salida no conmuta y busy esta bajo
//   2. aud_sd_o esta en el nivel de habilitacion del amplificador
//   3. acierto: semiperiodo de 2 kHz y duracion de 100 ms
//   4. error:   semiperiodo de 500 Hz y duracion de 150 ms
//   5. victoria: tres tonos ascendentes de 150 ms, total 450 ms
//   6. derrota:  dos tonos descendentes de 200 ms, total 400 ms
//   7. un evento normal que llega mientras suena otro se descarta
//   8. un evento de fin de partida corta el que esta sonando
//   9. al terminar, la salida queda en cero
//  10. la formula de los semiperiodos da los valores documentados a 100 MHz
//
// Para simular rapido se instancia el modulo con un reloj nominal de
// 100 kHz, de modo que los semiperiodos son de decenas de ciclos en vez
// de decenas de miles. La comprobacion 10 verifica aparte que la misma
// formula, evaluada a 100 MHz, produce los numeros de la documentacion.
// =====================================================================
`timescale 1ns/1ps

module tb_buzzer_controller;

    localparam int CLK_SIM  = 100_000;      // reloj nominal para la simulacion
    localparam int TICK_DIV = 4;            // ciclos por tick de "1 ms"

    // semiperiodos esperados con el reloj de simulacion
    localparam int E_2K0 = (CLK_SIM + 2000) / (2 * 2000);
    localparam int E_2K5 = (CLK_SIM + 2500) / (2 * 2500);
    localparam int E_3K0 = (CLK_SIM + 3000) / (2 * 3000);
    localparam int E_800 = (CLK_SIM +  800) / (2 *  800);
    localparam int E_500 = (CLK_SIM +  500) / (2 *  500);

    // los mismos, evaluados al reloj real
    localparam int R_2K0 = (100_000_000 + 2000) / (2 * 2000);
    localparam int R_2K5 = (100_000_000 + 2500) / (2 * 2500);
    localparam int R_3K0 = (100_000_000 + 3000) / (2 * 3000);
    localparam int R_800 = (100_000_000 +  800) / (2 *  800);
    localparam int R_500 = (100_000_000 +  500) / (2 *  500);

    localparam logic [2:0] EV_ACIERTO  = 3'd1;
    localparam logic [2:0] EV_ERROR    = 3'd2;
    localparam logic [2:0] EV_VICTORIA = 3'd3;
    localparam logic [2:0] EV_DERROTA  = 3'd4;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic [2:0] ev    = 3'd0;
    logic       start = 1'b0;
    logic pwm, sd, busy;

    int errores = 0;
    int sp1, sp2, sp3, dur, t0;

    // Contador libre de ticks. Medir la duracion restando dos lecturas de
    // este contador hace que la medida no dependa del tiempo que el
    // testbench gaste midiendo el semiperiodo.
    int ticks_totales = 0;

    always #5 clk = ~clk;

    int tick_cnt = 0;
    logic tick;
    assign tick = (tick_cnt == TICK_DIV - 1);
    always_ff @(posedge clk) tick_cnt <= tick ? 0 : tick_cnt + 1;
    always_ff @(posedge clk) if (tick) ticks_totales <= ticks_totales + 1;

    buzzer_controller #(.CLK_HZ(CLK_SIM), .AMP_ENABLE_LEVEL(1'b1)) dut (
        .clk_i(clk), .rst_i(rst), .tick_i(tick),
        .snd_event_i(ev), .snd_start_i(start),
        .aud_pwm_o(pwm), .aud_sd_o(sd), .busy_o(busy)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            errores++;
        end
    endtask

    task automatic disparar(input logic [2:0] e);
        @(negedge clk);
        ev    = e;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    endtask

    // Mide cuantos ciclos de reloj dura un semiperiodo de la salida
    task automatic medir_semiperiodo(output int ciclos);
        logic previo;
        @(negedge clk);
        previo = pwm;
        while (pwm === previo) @(negedge clk);   // esperar un cambio
        previo = pwm;
        ciclos = 0;
        while (pwm === previo) begin
            @(negedge clk);
            ciclos++;
        end
    endtask

    // Espera a que termine el sonido y devuelve cuantos ticks pasaron
    // desde la marca inicial
    task automatic esperar_fin(input int marca, output int ticks);
        while (busy) @(negedge clk);
        ticks = ticks_totales - marca;
        @(negedge clk);
    endtask

    initial begin
        $display("");
        $display("=== tb_buzzer_controller ===");

        // ---------- 10: la formula a 100 MHz da lo documentado ----------
        check(R_2K0 == 25000,  $sformatf("2 kHz a 100 MHz deberia dar 25000 y da %0d", R_2K0));
        check(R_2K5 == 20000,  $sformatf("2,5 kHz deberia dar 20000 y da %0d", R_2K5));
        check(R_3K0 == 16667,  $sformatf("3 kHz deberia dar 16667 y da %0d", R_3K0));
        check(R_800 == 62500,  $sformatf("800 Hz deberia dar 62500 y da %0d", R_800));
        check(R_500 == 100000, $sformatf("500 Hz deberia dar 100000 y da %0d", R_500));

        // ---------- 1 y 2: reposo ----------
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        check(busy === 1'b0, "no deberia haber sonido en reposo");
        check(pwm  === 1'b0, "la salida deberia estar en cero en reposo");
        check(sd   === 1'b1, "el amplificador deberia estar habilitado");
        repeat (40) @(negedge clk);
        check(pwm === 1'b0, "la salida conmuto sin evento");

        // ---------- 3: acierto ----------
        disparar(EV_ACIERTO);
        t0 = ticks_totales;
        check(busy === 1'b1, "el acierto no arranco");
        medir_semiperiodo(sp1);
        check(sp1 == E_2K0,
              $sformatf("acierto: semiperiodo %0d ciclos, se esperaban %0d", sp1, E_2K0));
        esperar_fin(t0, dur);
        check(dur >= 98 && dur <= 102,
              $sformatf("acierto: duro %0d ms, se esperaban 100", dur));
        check(pwm === 1'b0, "la salida no quedo en cero al terminar el acierto");

        // ---------- 4: error ----------
        disparar(EV_ERROR);
        t0 = ticks_totales;
        medir_semiperiodo(sp1);
        check(sp1 == E_500,
              $sformatf("error: semiperiodo %0d ciclos, se esperaban %0d", sp1, E_500));
        esperar_fin(t0, dur);
        check(dur >= 148 && dur <= 152,
              $sformatf("error: duro %0d ms, se esperaban 150", dur));

        // ---------- 5: victoria, tres tonos ascendentes ----------
        disparar(EV_VICTORIA);
        t0 = ticks_totales;
        medir_semiperiodo(sp1);                 // primer tono
        do @(posedge clk); while (!(tick && dut.ms_q == 8'd149));
        repeat (4) @(negedge clk);
        medir_semiperiodo(sp2);                 // segundo tono
        do @(posedge clk); while (!(tick && dut.ms_q == 8'd149));
        repeat (4) @(negedge clk);
        medir_semiperiodo(sp3);                 // tercer tono
        check(sp1 == E_2K0, $sformatf("victoria tono 1: %0d, se esperaban %0d", sp1, E_2K0));
        check(sp2 == E_2K5, $sformatf("victoria tono 2: %0d, se esperaban %0d", sp2, E_2K5));
        check(sp3 == E_3K0, $sformatf("victoria tono 3: %0d, se esperaban %0d", sp3, E_3K0));
        check(sp1 > sp2 && sp2 > sp3, "la victoria debe ser una secuencia ascendente");
        esperar_fin(t0, dur);
        check(dur >= 448 && dur <= 452,
              $sformatf("victoria: duro %0d ms en total, se esperaban 450", dur));
        check(pwm === 1'b0, "la salida no quedo en cero al terminar la victoria");

        // ---------- 7: evento normal descartado durante otro ----------
        disparar(EV_ERROR);
        repeat (20) @(negedge clk);
        disparar(EV_ACIERTO);                   // deberia ignorarse
        @(negedge clk);
        check(dut.ev_q === EV_ERROR,
              "un evento normal interrumpio al que estaba sonando");
        while (busy) @(negedge clk);

        // ---------- 8: el fin de partida si corta ----------
        disparar(EV_ACIERTO);
        repeat (20) @(negedge clk);
        disparar(EV_DERROTA);
        @(negedge clk);
        check(dut.ev_q === EV_DERROTA,
              "un evento de fin de partida no corto el sonido en curso");
        t0 = ticks_totales;

        // ---------- 6: derrota, dos tonos descendentes ----------
        medir_semiperiodo(sp1);
        do @(posedge clk); while (!(tick && dut.ms_q == 8'd199));
        repeat (4) @(negedge clk);
        medir_semiperiodo(sp2);
        check(sp1 == E_800, $sformatf("derrota tono 1: %0d, se esperaban %0d", sp1, E_800));
        check(sp2 == E_500, $sformatf("derrota tono 2: %0d, se esperaban %0d", sp2, E_500));
        check(sp1 < sp2, "la derrota debe ser una secuencia descendente");
        esperar_fin(t0, dur);
        check(dur >= 398 && dur <= 402,
              $sformatf("derrota: duro %0d ms en total, se esperaban 400", dur));

        // ---------- 9: reposo final ----------
        check(pwm  === 1'b0, "la salida no quedo en cero al final");
        check(busy === 1'b0, "el modulo quedo ocupado al final");

        $display("");
        if (errores == 0)
            $display("  PASS  frecuencias, duraciones, secuencias y politica de solapamiento correctas");
        else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

endmodule
