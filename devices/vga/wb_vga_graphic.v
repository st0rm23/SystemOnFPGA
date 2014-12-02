`include "define.vh"


/**
 * VGA graphic mode with wishbone connection interfaces and inner buffer.
 * Author: Zhao, Hongyu  <power_zhy@foxmail.com>
 */
module wb_vga_graphic (
	input wire clk,  // main clock
	input wire rst,  // synchronous reset
	input wire vga_clk,  // VGA clock generated by VGA core
	input wire [H_COUNT_WIDTH-1:0] h_count_core,  // horizontal sync count from VGA core
	input wire [P_COUNT_WIDTH-1:0] p_disp_max,  // maximum display range for pixels
	input wire h_sync_core,  // horizontal sync from VGA core
	input wire v_sync_core,  // vertical sync from VGA core
	input wire h_en_core,  // scan line inside horizontal display range from VGA core
	input wire v_en_core,  // scan line inside vertical display range from VGA core
	input wire [31:20] vram_base,  // base address for VRAM
	// VGA interfaces
	output reg h_sync,
	output reg v_sync,
	output reg [2:0] r,
	output reg [2:0] g,
	output reg [1:0] b,
	// wishbone master interfaces
	input wire wbm_clk_i,
	output reg wbm_cyc_o,
	output reg wbm_stb_o,
	output reg [31:2] wbm_addr_o,
	output reg [2:0] wbm_cti_o,
	output reg [1:0] wbm_bte_o,
	output reg [3:0] wbm_sel_o,
	output reg wbm_we_o,
	input wire [31:0] wbm_data_i,
	output reg [31:0] wbm_data_o,
	input wire wbm_ack_i
	);
	
	`include "function.vh"
	`include "vga_define.vh"
	localparam
		BUF_ADDR_WIDTH = 8,
		REFILL_THRESHOLD = 64;
	
	// delay core signals 1 clock for fetching pixels
	reg [H_COUNT_WIDTH-1:0] h_count_d1;
	reg h_sync_d1;
	reg v_sync_d1;
	reg h_en_d1;
	reg v_en_d1;
	
	always @(posedge vga_clk) begin
		if (rst) begin
			h_count_d1 <= 0;
			h_sync_d1 <= 0;
			v_sync_d1 <= 0;
			h_en_d1 <= 0;
			v_en_d1 <= 0;
		end
		else begin
			h_count_d1 <= h_count_core;
			h_sync_d1 <= h_sync_core;
			v_sync_d1 <= v_sync_core;
			h_en_d1 <= h_en_core;
			v_en_d1 <= v_en_core;
		end
	end
	
	// buffer
	reg fifo_clear;
	wire full_w, near_full_w;
	wire [7:0] space_count;
	wire en_r;
	wire [31:0] buf_data_r;
	
	fifo_asy #(
		.DATA_BITS(32),  // one data containing four pixels
		.ADDR_BITS(BUF_ADDR_WIDTH)
		) FIFO_ASY (
		.rst(rst | fifo_clear),
		.clk_w(wbm_clk_i),
		.en_w(wbm_cyc_o & wbm_ack_i),
		.data_w(wbm_data_i),
		.full_w(full_w),
		.near_full_w(near_full_w),
		.space_count(space_count),
		.clk_r(vga_clk),
		.en_r(en_r),
		.data_r(buf_data_r),
		.empty_r(),
		.near_empty_r(),
		.data_count()
		);
	
	// data transmission control
	reg h_en_prev, v_en_prev;
	wire vga_line_done, vga_frame_done;
	wire vga_line_done_d, vga_frame_done_d;
	
	always @(posedge vga_clk) begin
		if (rst) begin
			h_en_prev <= 0;
			v_en_prev <= 0;
		end
		else begin
			h_en_prev <= h_en_d1;
			v_en_prev <= v_en_d1;
		end
	end
	
	assign
		vga_line_done = h_en_prev & (~h_en_d1),
		vga_frame_done = v_en_prev & (~v_en_d1);
	
	pulse_detector #(.PULSE_VALUE(1))
		PD1 (.clk_i(vga_clk), .dat_i(vga_line_done), .clk_d(wbm_clk_i), .dat_d(vga_line_done_d)),
		PD2 (.clk_i(vga_clk), .dat_i(vga_frame_done), .clk_d(wbm_clk_i), .dat_d(vga_frame_done_d));
	
	localparam
		S_IDLE = 0,  // idle
		S_BURST = 1,  // read VRAM's data
		S_WAIT = 2,  // wait for display
		S_FRAME_END = 3,  // frame read complete, wait for display complete
		S_CLEAR = 4;  // clear FIFO, prepare for next frame
	
	reg [2:0] state = 0;
	reg [2:0] next_state;
	
	always @(*) begin
		next_state = 0;
		fifo_clear = 0;
		case (state)
			S_IDLE: begin
				if (~full_w && ~near_full_w)
					next_state = S_BURST;
				else
					next_state = S_IDLE;
			end
			S_BURST: begin
				if (wbm_addr_o[19:2] == p_disp_max>>2)
					next_state = S_FRAME_END;
				else if (near_full_w && wbm_ack_i)
					next_state = S_WAIT;
				else
					next_state = S_BURST;
			end
			S_WAIT: begin
				if (space_count == ((1<<BUF_ADDR_WIDTH) - REFILL_THRESHOLD))
					next_state = S_BURST;
				else
					next_state = S_WAIT;
			end
			S_FRAME_END: begin
				if (vga_frame_done_d)
					next_state = S_CLEAR;
				else
					next_state = S_FRAME_END;
			end
			S_CLEAR: begin
				fifo_clear = 1;
				if (vga_line_done_d)
					next_state = S_IDLE;
				else
					next_state = S_CLEAR;
			end
		endcase
	end
	
	always @(posedge wbm_clk_i) begin
		if (rst)
			state <= 0;
		else
			state <= next_state;
	end
	
	always @(*) begin
		wbm_we_o <= 0;
		wbm_sel_o <= 4'b1111;
		wbm_data_o <= 0;
		wbm_addr_o[31:20] <= vram_base;
	end
	
	always @(posedge wbm_clk_i) begin
		wbm_cyc_o <= 0;
		wbm_stb_o <= 0;
		wbm_cti_o <= 0;
		wbm_bte_o <= 0;
		if (rst) begin
			wbm_addr_o[19:2] <= 0;
		end
		else case (next_state)
			S_IDLE, S_CLEAR: begin
				wbm_addr_o[19:2] <= 0;
			end
			S_BURST: begin
				wbm_cyc_o <= 1;
				wbm_stb_o <= 1;
				wbm_cti_o <= 3'b010;  // incrementing burst
				wbm_bte_o <= 2'b00;  // linear burst
				if (wbm_cyc_o && wbm_ack_i)
					wbm_addr_o[19:2] <= wbm_addr_o[19:2] + 1'h1;
			end
			S_WAIT: begin
				if (wbm_cyc_o && wbm_ack_i)
					wbm_addr_o[19:2] <= wbm_addr_o[19:2] + 1'h1;
			end
		endcase
	end
	
	// pixel
	assign
		en_r = h_en_d1 & v_en_d1 & (h_count_d1[1:0] == 2'b11);  // "buf_data_r" is valid without "en_r", thus only uttered when next word is needed
	
	wire [7:0] pixel_data;
	assign
		pixel_data = h_count_d1[1] ? (h_count_d1[0] ? buf_data_r[31:24] : buf_data_r[23:16]) : (h_count_d1[0] ? buf_data_r[15:8] : buf_data_r[7:0]);
	
	always @(posedge vga_clk) begin
		if (rst) begin
			h_sync <= 0;
			v_sync <= 0;
			r <= 0;
			g <= 0;
			b <= 0;
		end
		else begin
			h_sync <= h_sync_d1;
			v_sync <= v_sync_d1;
			if (h_en_d1 && v_en_d1) begin
				r <= pixel_data[7:5];
				g <= pixel_data[4:2];
				b <= pixel_data[1:0];
			end
			else begin
				r <= 0;
				g <= 0;
				b <= 0;
			end
		end
	end
	
endmodule
