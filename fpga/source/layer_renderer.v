`default_nettype none

module layer_renderer(
    input  wire        rst,
    input  wire        clk,

    input  wire        start_of_screen,
    input  wire        start_of_line,

    // Register interface
    input  wire  [3:0] regs_addr,
    input  wire  [7:0] regs_wrdata,
    output reg   [7:0] regs_rddata,
    input  wire        regs_write,

    // Bus master interface
    output reg  [17:0] bus_addr,
    input  wire [31:0] bus_rddata,
    output wire        bus_strobe,
    input  wire        bus_ack,

    // Line buffer interface
    output reg   [9:0] linebuf_wridx,
    output reg   [7:0] linebuf_wrdata,
    output reg         linebuf_wren);

    // Modes:
    // 0 - 16 color text mode (foreground / background color specified per character)
    // 1 - 256 color text mode (background color fixed at 0)
    // 2 - Bitmapped mode
    // 3 - Tile mode

    //////////////////////////////////////////////////////////////////////////
    // Register interface
    //////////////////////////////////////////////////////////////////////////
    reg        reg_enable_r;
    reg  [2:0] reg_mode_r;
    reg [15:0] reg_map_baseaddr_r;
    reg [15:0] reg_tile_baseaddr_r;
    reg  [9:0] reg_scroll_x_r;
    reg  [9:0] reg_scroll_y_r;

    always @* begin
        case (regs_addr)
            4'h0: regs_rddata = {reg_mode_r, 4'b0, reg_enable_r};
            4'h1: regs_rddata = reg_map_baseaddr_r[7:0];
            4'h2: regs_rddata = reg_map_baseaddr_r[15:8];
            4'h3: regs_rddata = reg_tile_baseaddr_r[7:0];
            4'h4: regs_rddata = reg_tile_baseaddr_r[15:8];
            4'h5: regs_rddata = reg_scroll_x_r[7:0];
            4'h6: regs_rddata = {6'b0, reg_scroll_x_r[9:8]};
            4'h7: regs_rddata = reg_scroll_y_r[7:0];
            4'h9: regs_rddata = {6'b0, reg_scroll_y_r[9:8]};
            default: regs_rddata = 8'h00;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            reg_enable_r        <= 0;
            reg_mode_r          <= 2'b00;
            reg_map_baseaddr_r  <= 16'h0000;
            reg_tile_baseaddr_r <= 16'h8000;
            reg_scroll_x_r      <= 10'd0;
            reg_scroll_y_r      <= 10'd0;

        end else begin
            if (regs_write) begin
                case (regs_addr[3:0])
                    4'h0: begin
                        reg_mode_r   <= regs_wrdata[7:5];
                        reg_enable_r <= regs_wrdata[0];
                    end

                    4'h1: reg_map_baseaddr_r[7:0]   <= regs_wrdata;
                    4'h2: reg_map_baseaddr_r[15:8]  <= regs_wrdata;
                    4'h3: reg_tile_baseaddr_r[7:0]  <= regs_wrdata;
                    4'h4: reg_tile_baseaddr_r[15:8] <= regs_wrdata;
                    4'h5: reg_scroll_x_r[7:0]       <= regs_wrdata;
                    4'h6: reg_scroll_x_r[9:8]       <= regs_wrdata[1:0];
                    4'h7: reg_scroll_y_r[7:0]       <= regs_wrdata;
                    4'h9: reg_scroll_y_r[9:8]       <= regs_wrdata[1:0];
                endcase
            end
        end
    end

    //////////////////////////////////////////////////////////////////////////
    // Line renderer
    //////////////////////////////////////////////////////////////////////////

    reg [2:0] state_r;
    parameter
        WAIT_START      = 3'b000,
        FETCH_MAP       = 3'b001,
        WAIT_FETCH_MAP  = 3'b010,
        FETCH_TILE      = 3'b011,
        WAIT_FETCH_TILE = 3'b100,
        RENDER          = 3'b101;

    // Address of start of current map row
    reg [15:0] map_row_addr_r;
    reg [15:0] map_addr_r;

    // Address of current map column (actually 2 columns per entry)
    reg [15:0] map_col_addr_r;

    // Current line within row (8 lines per row)
    reg  [2:0] row_line_r;

    // Data as fetched from memory
    reg [31:0] map_data_r;
    reg [31:0] tile_data_r;

    reg [3:0] xcnt_r;
    reg [2:0] ycnt_r;
    reg [2:0] ycnt_next_r;


    wire [15:0] cur_map_data = xcnt_r[3] ? map_data_r[31:16] : map_data_r[15:0];
    wire  [7:0] cur_tile_idx = cur_map_data[7:0];

    reg [7:0] cur_tile_data;
    always @* case (ycnt_r[1:0])
        2'd0: cur_tile_data = tile_data_r[7:0];
        2'd1: cur_tile_data = tile_data_r[15:8];
        2'd2: cur_tile_data = tile_data_r[23:16];
        2'd3: cur_tile_data = tile_data_r[31:24];
    endcase

    reg cur_pixel_data;
    always @* case (xcnt_r[2:0])
        3'd0: cur_pixel_data = cur_tile_data[7];
        3'd1: cur_pixel_data = cur_tile_data[6];
        3'd2: cur_pixel_data = cur_tile_data[5];
        3'd3: cur_pixel_data = cur_tile_data[4];
        3'd4: cur_pixel_data = cur_tile_data[3];
        3'd5: cur_pixel_data = cur_tile_data[2];
        3'd6: cur_pixel_data = cur_tile_data[1];
        3'd7: cur_pixel_data = cur_tile_data[0];
    endcase

    wire [7:0] cur_pixel_color = cur_pixel_data ? {4'b0, cur_map_data[11:8]} : {4'b0, cur_map_data[15:12]};

    reg [9:0] linebuf_wridx_r;


    reg bus_strobe_r;
    assign bus_strobe = bus_strobe_r && !bus_ack;


    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state_r        <= WAIT_START;

            bus_addr       <= 0;
            bus_strobe_r   <= 0;

            linebuf_wridx  <= 0;
            linebuf_wrdata <= 0;
            linebuf_wren   <= 0;

            linebuf_wridx_r <= 0;
            xcnt_r          <= 0;
            ycnt_r          <= 0;
            ycnt_next_r     <= 0;

            map_addr_r      <= 0;

        end else begin
            linebuf_wren <= 0;

            case (state_r)
                WAIT_START: begin
                end

                FETCH_MAP: begin
                    bus_addr <= {map_addr_r, 2'b00};
                    map_addr_r <= map_addr_r + 1;

                    bus_strobe_r <= 1;

                    state_r <= WAIT_FETCH_MAP;
                end

                WAIT_FETCH_MAP: begin
                    if (bus_ack) begin
                        map_data_r <= bus_rddata;
                        bus_strobe_r <= 0;

                        state_r <= FETCH_TILE;
                    end
                end

                FETCH_TILE: begin
                    bus_addr <= {reg_tile_baseaddr_r, 2'b00} + {cur_tile_idx, ycnt_r[2], 2'b0};
                    bus_strobe_r <= 1;

                    state_r <= WAIT_FETCH_TILE;
                end

                WAIT_FETCH_TILE: begin
                    if (bus_ack) begin
                        tile_data_r <= bus_rddata;
                        bus_strobe_r <= 0;

                        state_r <= RENDER;
                    end
                end

                RENDER: begin
                    linebuf_wridx <= linebuf_wridx_r;
                    linebuf_wrdata <= cur_pixel_color;
                    linebuf_wren <= 1;

                    linebuf_wridx_r <= linebuf_wridx_r + 1;

                    if (linebuf_wridx_r[2:0] == 7) begin
                        state_r <= linebuf_wridx_r[3] ? FETCH_MAP : FETCH_TILE;
                    end

                    xcnt_r <= xcnt_r + 1;
                end
            endcase

            if (start_of_line) begin
                state_r         <= FETCH_MAP;
                linebuf_wridx_r <= 0;
                xcnt_r          <= 0;
                ycnt_r          <= ycnt_next_r;
                ycnt_next_r     <= ycnt_next_r + 1;

                if (ycnt_next_r == 7) begin
                    map_row_addr_r  <= map_row_addr_r + 32;
                end
                map_addr_r      <= map_row_addr_r;
            end

            if (start_of_screen) begin
                map_row_addr_r <= reg_map_baseaddr_r;
                map_addr_r     <= reg_map_baseaddr_r;
                ycnt_r <= 0;
                ycnt_next_r <= 1;
            end
        end
    end

endmodule
