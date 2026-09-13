// =====================================================================
// tb_led_controller.sv - Testbench autoverificable de los indicadores
//
// Comprueba:
//   1. cada estado enciende el LED que le corresponde
//   2. exclusividad mutua: nunca hay dos LEDs de estado encendidos
//   3. el codigo de estado no usado apaga los tres
//   4. led_o[15] sigue al modo
//   5. los LEDs 3 a 14 estan siempre apagados
//   6. con la polaridad invertida el comportamiento logico es el mismo
// =====================================================================
`timescale 1ns/1ps

module tb_led_controller;

    logic [1:0]  state = 2'd0;
    logic        mode  = 1'b0;
    logic [15:0] led_alto, led_bajo;

    // vista logica: uno = encendido, sea cual sea la polaridad fisica
    logic [15:0] vista_alto, vista_bajo;

    int errores = 0;
    int i, m, encendidos;

    led_controller #(.LED_ACTIVE_LEVEL(1'b1)) dut_alto (
        .state_i(state), .mode_i(mode), .led_o(led_alto)
    );
    led_controller #(.LED_ACTIVE_LEVEL(1'b0)) dut_bajo (
        .state_i(state), .mode_i(mode), .led_o(led_bajo)
    );

    assign vista_alto =  led_alto;
    assign vista_bajo = ~led_bajo;

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            errores++;
        end
    endtask

    initial begin
        $display("");
        $display("=== tb_led_controller ===");

        for (m = 0; m < 2; m++) begin
            for (i = 0; i < 4; i++) begin
                state = i[1:0];
                mode  = m[0];
                #1;

                // 1 y 3: el LED correcto encendido
                case (i)
                    0: check(vista_alto[2:0] === 3'b001, "el estado 00 debe encender solo LED0");
                    1: check(vista_alto[2:0] === 3'b010, "el estado 01 debe encender solo LED1");
                    2: check(vista_alto[2:0] === 3'b100, "el estado 10 debe encender solo LED2");
                    3: check(vista_alto[2:0] === 3'b000, "el estado 11 debe apagar los tres");
                endcase

                // 2: exclusividad mutua
                encendidos = 0;
                if (vista_alto[0]) encendidos++;
                if (vista_alto[1]) encendidos++;
                if (vista_alto[2]) encendidos++;
                check(encendidos <= 1,
                      $sformatf("hay %0d LEDs de estado encendidos a la vez", encendidos));
                if (i != 3)
                    check(encendidos == 1, "debe haber exactamente un LED de estado encendido");

                // 4: LED de modo
                check(vista_alto[15] === mode, "led_o[15] no sigue al modo");

                // 5: LEDs sin uso apagados
                check(vista_alto[14:3] === 12'd0,
                      $sformatf("hay LEDs sin uso encendidos: %b", vista_alto[14:3]));

                // 6: la polaridad invertida da la misma vista logica
                check(vista_bajo === vista_alto,
                      $sformatf("la polaridad invertida difiere: %b contra %b",
                                vista_bajo, vista_alto));
            end
        end

        $display("");
        if (errores == 0)
            $display("  PASS  decodificacion, exclusividad, modo y polaridad correctos");
        else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

endmodule
