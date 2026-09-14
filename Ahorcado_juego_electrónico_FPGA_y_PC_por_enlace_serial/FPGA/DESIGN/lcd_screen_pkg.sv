// =====================================================================
// lcd_screen_pkg.sv - Constantes compartidas de la capa de presentacion
//
// Se centralizan aqui los codigos de pantalla y el mapa de registros del
// periferico para que lcd_screen_ctrl, lcd_text_gen y los testbenches
// usen siempre los mismos valores, en vez de repetir "numeros magicos"
// en cada archivo.
// =====================================================================

package lcd_screen_pkg;

    // codigos de pantalla (screen_i)
    localparam logic [2:0] SCR_SELECT      = 3'd0;
    localparam logic [2:0] SCR_PLAY        = 3'd1;
    localparam logic [2:0] SCR_WIN         = 3'd2;
    localparam logic [2:0] SCR_LOSE_FALLOS = 3'd3;
    localparam logic [2:0] SCR_LOSE_TIEMPO = 3'd4;

    // mapa de registros de lcd_peripheral
    localparam logic [1:0] A_CTRL  = 2'b00;
    localparam logic [1:0] A_DATOS = 2'b01;
    localparam int         B_BUSY  = 8;
    localparam int         B_DONE  = 9;

    // geometria de la pantalla (2 lineas x 16 columnas)
    localparam int N_COL = 16;

endpackage
