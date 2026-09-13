// =====================================================================
// uart_core.sv - Envoltura del nucleo UART en VHDL
//
// El nucleo lo proporciono el curso en VHDL (UART_tx.vhd y UART_rx.vhd)
// Este modulo lo adapta a la interfaz que el periferico
// espera.

// Velocidad a 100 MHz
// -------------------
//   transmision: ciclos por bit = 100e6 / 115200 = 868.06 -> 868
//               
//
//   recepcion:   el receptor sobremuestrea por 16, asi que su generico
//                es (100e6 / 115200) / 16 = 54.25 -> 54
//                bit real 16 x 54 = 864 ciclos


// tx_rdy es un pulso de un ciclo al terminar cada byte,
// no un nivel que diga si el transmisor esta libre. El periferico
// necesita un nivel de ocupado, y de eso se encarga esta envoltura.
//
// La peticion se mantiene, no se pulsa
// ------------------------------------
// El nucleo ignora tx_start durante casi todo un tiempo de bit despues
// de terminar un byte, mientras mantiene en alto su propio start_reset.
// Un pulso de un ciclo que caiga en esa ventana se pierde sin dejar
// rastro, y quien espera se queda esperando para siempre. Por eso aqui
// la peticion se convierte en un nivel que se mantiene hasta que el
// nucleo confirma el fin: en cuanto la ventana se cierra, el nucleo la
// toma.


module uart_core #(
    // ciclos por bit en transmision
    parameter int BAUD_DIV     = 868,
    // ciclos por muestra en recepcion, con sobremuestreo por 16
    parameter int BAUD_X16_DIV = 54
) (
    input  logic       clk_i,
    input  logic       rst_i,

    // linea serie
    output logic       tx_o,
    input  logic       rx_i,

    // frontera hacia el periferico
    input  logic [7:0] tx_data_i,
    input  logic       tx_start_i,
    output logic       tx_busy_o,
    output logic [7:0] rx_data_o,
    output logic       rx_valid_o
);

    // tx_fin es la senal que entrega el nucleo VHDL  
    logic tx_fin;          // pulso de un ciclo al terminar un byte

    // Este es el registro que hace todo el trabajo de este archivo:
    // convierte el pulso de peticion (tx_start_i, un ciclo) en un nivel
    // sostenido (peticion_q) que el nucleo puede recoger en cualquier
    // momento de su ventana de rearranque, no solo en el ciclo exacto en
    // que alguien lo pidio.
    logic peticion_q = 1'b0;

    // La peticion se levanta al recibir el pulso y se mantiene hasta que
    // el nucleo avisa del fin. Mientras esta alta, el periferico ve el
    // canal ocupado.
   
    always_ff @(posedge clk_i) begin
        if (rst_i)               peticion_q <= 1'b0;
        else if (tx_start_i)     peticion_q <= 1'b1;
        else if (tx_fin)         peticion_q <= 1'b0;
    end

    // tx_busy_o no es un registro nuevo: es peticion_q con otro nombre
    // hacia afuera. Nombrar la salida distinto de la senal interna dejar
    // claro cual es la interfaz publica del modulo y cual es el detalle
    // de implementacion.
    assign tx_busy_o = peticion_q;

    // Se pasa BAUD_DIV como el generico BAUD_CLK_TICKS de la entidad VHDL. 
    
    UART_tx #(
        .BAUD_CLK_TICKS(BAUD_DIV)
    ) transmisor (
        .clk         (clk_i),
        .reset       (rst_i),
        .tx_start    (peticion_q),   // nivel sostenido, no el pulso original
        .tx_rdy      (tx_fin),       // sigue siendo un pulso aqui adentro
        .tx_data_in  (tx_data_i),
        .tx_data_out (tx_o)
    );

    // El receptor no necesita ninguna adaptacion: su rx_data_rdy ya se
    // comporta como un pulso de un ciclo por byte recibido, que es
    // justo lo que rx_valid_o necesita hacia el periferico. Por eso se
    // conecta directo, sin registro intermedio.
    UART_rx #(
        .BAUD_X16_CLK_TICKS(BAUD_X16_DIV)
    ) receptor (
        .clk         (clk_i),
        .reset       (rst_i),
        .rx_data_in  (rx_i),
        .rx_data_rdy (rx_valid_o),
        .rx_data_out (rx_data_o)
    );

endmodule
