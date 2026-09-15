// =====================================================================
// tb_lfsr.sv - Testbench autoverificable del generador pseudoaleatorio
//
// Comprueba:
//   1. tras el reset el estado es la semilla
//   2. el estado 0x00 nunca se alcanza
//   3. se recorren 255 estados DISTINTOS, sin repetir ninguno
//   4. tras exactamente 255 ciclos se vuelve a la semilla
//   5. cobertura: los 32 valores de lfsr[4:0] y los 64 de lfsr[5:0]
//      aparecen todos al menos una vez
//   6. la secuencia es reproducible tras un nuevo reset
//
// Las comprobaciones 3 y 4 son las que sostienen que el polinomio es de
// longitud maxima. No se da por buena esa propiedad citando una tabla:
// se mide.
//
// La comprobacion 5 es la que respalda la seleccion de palabra. Si algun
// valor de lfsr[4:0] no apareciera, habria palabras del modo dificil que
// no podrian salir nunca.
//
// El muestreo se hace en flanco de bajada para leer el estado ya
// establecido y no el previo al flanco de subida.
//
// =====================================================================
`timescale 1ns/1ps

module tb_lfsr;

    localparam logic [7:0] SEMILLA  = 8'h01;
    localparam int         N_ESTADOS = 255;

    logic       clk = 1'b0;
    logic       rst = 1'b1;
    logic [7:0] q;

    bit visto [0:255];
    bit cov5  [0:31];
    bit cov6  [0:63];

    logic [7:0] primeros [0:9];

    int errores = 0;
    int distintos = 0;
    int i, faltan5, faltan6;

    always #5 clk = ~clk;

    lfsr #(.SEED(SEMILLA)) dut (
        .clk_i(clk), .rst_i(rst), .lfsr_o(q)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            errores++;
        end
    endtask

    initial begin
        $display("");
        $display("=== tb_lfsr ===");

        // ---------- 1: semilla tras reset ----------
        repeat (2) @(negedge clk);
        check(q === SEMILLA,
              $sformatf("tras el reset se esperaba 0x%02h y hay 0x%02h", SEMILLA, q));
        rst = 1'b0;

        // ---------- 2, 3, 5: recorrido del ciclo completo ----------
        for (i = 0; i < N_ESTADOS; i++) begin
            check(q !== 8'h00, $sformatf("se alcanzo el estado 0x00 en el paso %0d", i));

            if (visto[q])
                check(1'b0, $sformatf("el estado 0x%02h se repitio en el paso %0d", q, i));
            else begin
                visto[q] = 1'b1;
                distintos++;
            end

            cov5[q[4:0]] = 1'b1;
            cov6[q[5:0]] = 1'b1;

            if (i < 10) primeros[i] = q;

            @(negedge clk);
        end

        check(distintos == N_ESTADOS,
              $sformatf("se esperaban %0d estados distintos y hubo %0d", N_ESTADOS, distintos));

        // ---------- 4: vuelta a la semilla ----------
        check(q === SEMILLA,
              $sformatf("tras %0d ciclos se esperaba 0x%02h y hay 0x%02h",
                        N_ESTADOS, SEMILLA, q));

        // ---------- 5: cobertura de los indices ----------
        faltan5 = 0;
        faltan6 = 0;
        for (i = 0; i < 32; i++) if (!cov5[i]) faltan5++;
        for (i = 0; i < 64; i++) if (!cov6[i]) faltan6++;
        check(faltan5 == 0,
              $sformatf("%0d valores de lfsr[4:0] nunca aparecen (modo dificil)", faltan5));
        check(faltan6 == 0,
              $sformatf("%0d valores de lfsr[5:0] nunca aparecen (modo facil)", faltan6));

        // ---------- 6: reproducibilidad ----------
        rst = 1'b1;
        @(negedge clk);
        check(q === SEMILLA, "el reset no devolvio el generador a la semilla");
        rst = 1'b0;
        for (i = 0; i < 10; i++) begin
            check(q === primeros[i],
                  $sformatf("la secuencia no se repite: paso %0d dio 0x%02h y antes 0x%02h",
                            i, q, primeros[i]));
            @(negedge clk);
        end

        // ---------- resumen ----------
        $display("");
        if (errores == 0) begin
            $display("  PASS  %0d estados distintos, sin el 0x00, vuelve a la semilla", distintos);
            $display("        cobertura completa: 32/32 indices dificiles y 64/64 faciles");
        end else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

endmodule