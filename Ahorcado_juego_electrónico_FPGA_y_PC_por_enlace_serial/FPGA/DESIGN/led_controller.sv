// =====================================================================
// led_controller.sv - Indicadores de estado y de modo
//
// Muestra en que etapa va el juego con tres LEDs, uno para la seleccion
// de modo, otro para la partida en curso y otro para la pantalla de
// resultado. Se usan tres y no uno solo para que las etapas se
// distingan de un vistazo, sin tener que interpretar parpadeos.
//
// Ademas se enciende el ultimo LED de la tarjeta mientras el modo
// elegido sea dificil.
//
// Todo el modulo es combinacional, no guarda ningun estado propio.
// =====================================================================

module led_controller #(
    parameter logic LED_ACTIVE_LEVEL = 1'b1
) (
    input  logic [1:0]  state_i,   // 00 seleccion, 01 partida, 10 resultado
    input  logic        mode_i,    // 0 facil, 1 dificil
    output logic [15:0] led_o
);

    logic [15:0] led;

    // Un 1 significa LED encendido.
    // La polaridad real de la tarjeta se aplica al final.
    always_comb begin
        led = '0;

        unique case (state_i)
            2'b00:   led[0] = 1'b1;
            2'b01:   led[1] = 1'b1;
            2'b10:   led[2] = 1'b1;

            // El codigo 11 no lo genera el control del juego. Como el
            // vector arranca en cero, esos LEDs quedan apagados igual
            // que los que no se usan.
            default: led = '0;
        endcase

        led[15] = mode_i;
    end

    // Si los LEDs de la tarjeta encendieran con nivel bajo se invierte
    // todo aqui para adaptar la salida a esa polaridad.
    assign led_o = LED_ACTIVE_LEVEL ? led : ~led;

endmodule