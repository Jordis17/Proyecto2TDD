// =====================================================================
// tb_button_input.sv - Testbench autoverificable del acondicionamiento
//
// Comprueba:
//   1. tras el reset, nivel y pulso en cero
//   2. una pulsacion limpia produce exactamente un pulso
//   3. el pulso NO llega antes de DEBOUNCE_MS
//   4. un rebote corto, mas breve que DEBOUNCE_MS, no produce pulso
//   5. rebotes seguidos de nivel estable producen un solo pulso
//   6. soltar el boton no produce pulso (solo cuenta el flanco de subida)
//   7. mantener presionado no produce pulsos adicionales
//   8. dos pulsaciones separadas producen dos pulsos
//   9. con la polaridad invertida el comportamiento es identico
//
// Se usa un debounce corto y un tick rapido para que la simulacion dure
// poco; el comportamiento no depende de los valores absolutos.
// =====================================================================
`timescale 1ns/1ps

module tb_button_input;

    localparam int DEB      = 5;    // ms de filtrado
    localparam int TICK_DIV = 4;    // ciclos de reloj por tick

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic tick;
    logic btn = 1'b0;

    logic pulse, level;
    logic pulse_inv, level_inv;

    int errores  = 0;
    int n_pulsos = 0;
    int n_pulsos_inv = 0;
    int base, k;

    always #5 clk = ~clk;

    // Generador de tick local, para no depender de otro modulo
    int tick_cnt = 0;
    assign tick = (tick_cnt == TICK_DIV - 1);
    always_ff @(posedge clk) tick_cnt <= tick ? 0 : tick_cnt + 1;

    // Polaridad normal
    button_input #(.DEBOUNCE_MS(DEB), .BTN_ACTIVE_LEVEL(1'b1)) dut (
        .clk_i(clk), .rst_i(rst), .tick_i(tick), .btn_i(btn),
        .pulse_o(pulse), .level_o(level)
    );

    // Polaridad invertida, alimentada con la senal complementaria:
    // debe comportarse exactamente igual
    button_input #(.DEBOUNCE_MS(DEB), .BTN_ACTIVE_LEVEL(1'b0)) dut_inv (
        .clk_i(clk), .rst_i(rst), .tick_i(tick), .btn_i(~btn),
        .pulse_o(pulse_inv), .level_o(level_inv)
    );

    always_ff @(posedge clk) begin
        if (!rst && pulse)     n_pulsos     <= n_pulsos + 1;
        if (!rst && pulse_inv) n_pulsos_inv <= n_pulsos_inv + 1;
    end

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            errores++;
        end
    endtask

    // Espera n ticks completos
    task automatic esperar_ticks(input int n);
        for (int t = 0; t < n; t++) begin
            do @(posedge clk); while (!tick);
        end
    endtask

    // Rebote determinista: alterna el boton durante n ciclos de reloj
    task automatic rebotar(input int n);
        for (int b = 0; b < n; b++) begin
            @(posedge clk);
            btn = ~btn;
        end
    endtask

    initial begin
        $display("");
        $display("=== tb_button_input ===");

        // ---------- 1: estado tras reset ----------
        repeat (4) @(posedge clk);
        check(level === 1'b0, "el nivel debe estar en cero tras el reset");
        check(pulse === 1'b0, "el pulso debe estar en cero tras el reset");
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ---------- 3: no debe pulsar antes de tiempo ----------
        base = n_pulsos;
        btn  = 1'b1;
        esperar_ticks(DEB - 2);
        check(n_pulsos == base, "el pulso llego antes de completar el filtrado");

        // ---------- 2: una pulsacion limpia da un pulso ----------
        // La espera es holgada a proposito. La pulsacion no esta alineada
        // con el tick, asi que el primer tick tras presionar suele perderse
        // porque el sincronizador todavia no ha propagado el cambio, y la
        // adopcion ocurre en el flanco siguiente al ultimo tick. El contrato
        // del modulo es "el pulso llega tras DEBOUNCE_MS de estabilidad", no
        // "en un flanco exacto". Que no llegue antes ya lo comprobo el caso 3.
        esperar_ticks(DEB);
        repeat (2) @(posedge clk);
        check(n_pulsos == base + 1,
              $sformatf("se esperaba 1 pulso, hubo %0d", n_pulsos - base));
        check(level === 1'b1, "el nivel debe seguir alto con el boton presionado");

        // ---------- 7: mantener presionado no repite ----------
        base = n_pulsos;
        esperar_ticks(DEB * 4);
        check(n_pulsos == base, "mantener presionado genero pulsos adicionales");

        // ---------- 6: soltar no produce pulso ----------
        base = n_pulsos;
        btn  = 1'b0;
        esperar_ticks(DEB + 2);
        check(n_pulsos == base, "soltar el boton produjo un pulso");
        check(level === 1'b0, "el nivel debe caer al soltar");

        // ---------- 4: rebote corto no produce pulso ----------
        base = n_pulsos;
        rebotar(6);                 // oscila durante 6 ciclos
        btn = 1'b0;                 // vuelve a reposo
        esperar_ticks(DEB + 2);
        check(n_pulsos == base, "un rebote corto produjo un pulso");

        // ---------- 5: rebote y luego nivel estable, un solo pulso ----------
        base = n_pulsos;
        rebotar(7);
        btn = 1'b1;                 // se estabiliza presionado
        esperar_ticks(DEB + 2);
        check(n_pulsos == base + 1,
              $sformatf("tras el rebote se esperaba 1 pulso, hubo %0d", n_pulsos - base));

        // ---------- 8: dos pulsaciones, dos pulsos ----------
        btn = 1'b0;
        esperar_ticks(DEB + 2);
        base = n_pulsos;
        for (k = 0; k < 2; k++) begin
            btn = 1'b1;
            esperar_ticks(DEB + 2);
            btn = 1'b0;
            esperar_ticks(DEB + 2);
        end
        check(n_pulsos == base + 2,
              $sformatf("se esperaban 2 pulsos, hubo %0d", n_pulsos - base));

        // ---------- 9: la polaridad invertida cuenta lo mismo ----------
        check(n_pulsos_inv == n_pulsos,
              $sformatf("polaridad invertida conto %0d pulsos y la normal %0d",
                        n_pulsos_inv, n_pulsos));

        // ---------- resumen ----------
        $display("");
        if (errores == 0)
            $display("  PASS  filtrado, flanco, rebotes y polaridad correctos (%0d pulsos contados)", n_pulsos);
        else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

endmodule
