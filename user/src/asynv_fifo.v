`timescale 1 ns / 1 ns

/*
*   Date : 2024-07-02
*   Author : cjh
*   Module Name:   async_fifo.v - async_fifo
*   Target Device: [Target FPGA and ASIC Device]
*   Tool versions: vivado 18.3 & DC 2016
*   Revision Historyc :
*   Revision :
*       Revision 0.01 - File Created
*   Description : The synchronous dual-port SRAM has A, B ports to access the same memory location. 
*                 Both ports can be independently read or written from the memory array.
*                 1. In Vivado, EDA can directly use BRAM for synthesis.
*                 2. The module continuously outputs data when enabled, and when disabled, 
*                    it outputs the last data.
*                 3. When writing data to the same address on ports A and B simultaneously, 
*                    the write operation from port B will take precedence.
*                 4. In write mode, the current data input takes precedence for writing, 
*                    and the data from the address input at the previous clock cycle is read out. 
*                    In read mode, the data from the address input at the current clock cycle 
*                    is directly read out. In write mode, when writing to different addresses, 
*                    the data corresponding to the current address input at the current clock cycle 
*                    is directly read out.
*   Dependencies: none(FPGA) auto for BRAM in vivado | RAM_IP with IC 
*   Company : ncai Technology .Inc
*   Copyright(c) 1999, ncai Technology Inc, All right reserved
*/

// wavedom
/*
{signal: [
  {name: 'clka/b', wave: '101010101'},
  {name: 'ena/b', wave: '01...0...'},
  {name: 'wea/b', wave: '01...0...'},
  {name: 'addra/b', wave: 'x3...3.x.', data: ['addr0','addr2']},
  {name: 'dina/b', wave: 'x4.4.x...', data: ['data0','data1']},
  {name: 'douta/b', wave: 'x..5.5.x.', data: ['data0','data2']},
]}
*/

module async_fifo #(
    //The width parameter for writing data
    parameter    INPUT_WIDTH       = 128,
    //The width parameter for reading data
    parameter    OUTPUT_WIDTH      = 16,
    //The depth parameter of writing mem,if INPUT_WIDTH < OUTPUT_WIDTH, WR_DEPTH = (OUTPUT_WIDTH/INPUT_WIDTH) * RD_DEPTH
    parameter    WR_DEPTH          = 1024,
      //The depth parameter of reading mem,if INPUT_WIDTH > OUTPUT_WIDTH, RD_DEPTH = (INPUT_WIDTH/OUTPUT_WIDTH) * WR_DEPTH
    parameter    RD_DEPTH          = 8192,
    //The parameter of reading method
    parameter    MODE              = "FWFT",
    //Is data stored from high bits or from low bits
    parameter    DIRECTION         = "MSB",
    //Set error correction function
    parameter    ECC_MODE          = "no_ecc",
    //Specify the value of the programmable null threshold
    parameter    PROG_EMPTY_THRESH = 10,
    //Specify the value of programmable full threshold
    parameter    PROG_FULL_THRESH  = 10,
    //Enable the corresponding signal
    parameter    USE_ADV_FEATURES  = "0707"
) (
    //reser
    input                              reset,

    //wr_port

    //wr_port clock input
    input                              wr_clock,
    //wr_port enable active high
    input                              wr_en,
    //wr_port is ready to receive data
    output                             wr_ready,
    //wr_port data input
    input   [INPUT_WIDTH - 1 : 0]      din,

    //rd_port

    //rd_port clock input
    input                              rd_clock,
    //rd_port enable active high
    input                              rd_en,
    //rd_port rd_data valid active high
    output  reg                        valid,
    //rd_port data output
    output  reg [OUTPUT_WIDTH - 1 : 0] dout,

    output                             full,
    output                             empty,

    //wr_port num of the input data
    output  reg [$clog2(WR_DEPTH) : 0] wr_data_count,
    //wr_port num of the remaining data
    output      [$clog2(WR_DEPTH) : 0] wr_data_space,
    //rd_port num of the output data
    output  reg [$clog2(RD_DEPTH) : 0] rd_data_count,
    //rd_port num of the remaining data
    output      [$clog2(RD_DEPTH) : 0] rd_data_space,
    //fifo is about to be full,fifo can only perform one write, and after the write, the fifo becomes full
    output                             almost_full,
    //fifo is about to be empty,fifo can only perform one read, and after the read, the fifo becomes empty
    output                             almost_empty,
    //when the amount of data in the fifo is greater than or equal to the programmable full threshold, the signal is pulled high
    output                             prog_full,
    //when the amount of data in the fifo is less than or equal to the programmable null threshold, the signal is pulled high
    output                             prog_empty,
    //the write request from the previous clock cycle was rejected because the fifo is now full
    output  reg                        overflow,
    //the read request from the previous clock cycle was rejected because the fifo is now empty
    output  reg                        underflow,
    //the write request was successful in the previous clock cycle
    output                             wr_ack
);

//the number of ram needed to be operated
localparam RAM_NUM      = (INPUT_WIDTH >= OUTPUT_WIDTH) ? (INPUT_WIDTH/OUTPUT_WIDTH) : (OUTPUT_WIDTH/INPUT_WIDTH);

//the width of every operated ram
localparam RAM_WIDTH    = (INPUT_WIDTH >= OUTPUT_WIDTH) ? OUTPUT_WIDTH : INPUT_WIDTH;

//the depth of every operated ram
localparam RAM_DEPTH    = (INPUT_WIDTH >= OUTPUT_WIDTH) ? WR_DEPTH : (WR_DEPTH/RAM_NUM);

//the width of ram_wr_data
localparam RAM_WR_WIDTH = (INPUT_WIDTH >= OUTPUT_WIDTH) ? INPUT_WIDTH : OUTPUT_WIDTH;

//the width or ram_rd_data
localparam RAM_RD_WIDTH = RAM_WR_WIDTH;

//reset
reg                              rst_d1;         //buffer of acync reset
reg                              rst_d2;         //buffer of acync reset

wire                             rd_rst;         //read clock domain reset signal

reg                              rd_rst_d1 = 1'b0;//buffer of acync read reset
reg                              rd_rst_d2 = 1'b0;//buffer of acync read reset

wire                             wr_rst;        //write clock domain reset signal

//gray code counter
reg  [$clog2(WR_DEPTH) : 0]      wr_ptr;         //mark the location of fifo writing,use gray code counter
reg  [$clog2(WR_DEPTH) - 1 : 0]  wr_ptr_d1;      //buffer of wr_ptr,when counting gary code,need it 

reg  [$clog2(RD_DEPTH) : 0]      rd_ptr;         //mark the location of fifo reading,use gray code counter
reg  [$clog2(RD_DEPTH) - 1 : 0]  rd_ptr_d1;      //buffer of rd_ptr,when counting gary code,need it

reg  [$clog2(RD_DEPTH) : 0]      rd_ptr_next;    //mark the next position of fifo reading
reg  [$clog2(RD_DEPTH) : 0]      rd_ptr_next_d1; //buffer of rd_ptr_next,when counting gary code,need it

reg  [$clog2(RD_DEPTH) : 0]      rd_ptr_pre;     //mark the position of data in fifo before pre-reading
reg  [$clog2(RD_DEPTH) : 0]      rd_ptr_fwft;    //when in fwft mode,the change of ram_address need to use rd_ptr_fwft

//read mode 
reg  [$clog2(RD_DEPTH) : 0]      rd_ptr_fwft_d1; //buffer of rd_ptr_fwft

wire [RAM_RD_WIDTH - 1 : 0]      ram_rd_data;

//DPRAM_port
wire [RAM_NUM - 1 : 0]           ram_wr_en;     //DPRAM write enable signal
wire [RAM_NUM - 1 : 0]           ram_rd_en;     //DPRAM read  enable signal

wire [$clog2(RAM_DEPTH)     : 0] ram_wr_addr;   //DPRAM write address
wire [$clog2(RAM_DEPTH)     : 0] ram_rd_addr;   //DPRAM read  address

//full and empty judge
// wire [$clog2(RAM_DEPTH)     : 0] ram_wr_addr_g;     //the gray code of ram_wr_addr
// wire [$clog2(RAM_DEPTH)     : 0] ram_rd_addr_g;     //the gray code of ram_rd_addr

reg  [$clog2(RAM_DEPTH)     : 0] ram_wr_addr_g_d1;  //take one beat ram_wr_addr_g
reg  [$clog2(RAM_DEPTH)     : 0] ram_wr_addr_g_d2;  //take one beat ram_rd_addr_g

reg  [$clog2(RAM_DEPTH)     : 0] ram_rd_addr_g_d1; //take two beat ram_wr_addr_g
reg  [$clog2(RAM_DEPTH)     : 0] ram_rd_addr_g_d2; //take two beat ram_rd_addr_g

reg  [$clog2(WR_DEPTH)      : 0] wr_ptr_b;    //the binary of the gray code of wr_ptr in write clock domain
reg  [$clog2(RD_DEPTH)      : 0] rd_ptr_b;    //the binary of the gray code of rd_ptr in read  clock domain

wire [$clog2(RAM_DEPTH)     : 0] ram_wr_addr_b;    //the binary of the gray code of ram_wr_addr in write clock domain
wire [$clog2(RAM_DEPTH)     : 0] ram_rd_addr_b;    //the binary of the gray code of ram_rd_addr in read  clock domain

reg  [$clog2(RAM_DEPTH)     : 0] ram_wr_addr_b_d2; //the binary of the gray code of ram_wr_addr in read  clock domain
reg  [$clog2(RAM_DEPTH)     : 0] ram_rd_addr_b_d2; //the binary of the gray code of ram_rd_addr in write clock domain

reg                              empty_d1;         //buffer of empty
reg                              pre_valid;        //record the period before formal reading after pre reading
wire                             pre_read;         //when in fwft mode,pre-acquire data from fifo

//wr_port is ready to receive data
assign wr_ready = ~full;

//wr_port num of the remaining data
assign wr_data_space = WR_DEPTH - wr_data_count;

//rd_port num of the remaining data
assign rd_data_space = RD_DEPTH - rd_data_count;

//Asynchronous reset, synchronous release,first release read reset
assign rd_rst = rst_d2;

always @(posedge rd_clock or negedge reset) begin
    if(reset)begin
        rst_d1 <= 1'b0;
        rst_d2 <= 1'b0;
    end
    else begin
        rst_d1 <= 1'b1;
        rst_d2 <= rst_d1;
    end
end

//Asynchronous reset, synchronous release,release write reset after read reset
assign wr_rst = rd_rst_d2;

always @(posedge wr_clock) begin
    rd_rst_d1 <= rd_rst;
    rd_rst_d2 <= rd_rst_d1;
end

//mark the position of writing,use gray code counter
always @(posedge wr_clock or negedge wr_rst) begin
    if(wr_rst == 1'b0)begin
        wr_ptr_d1 <= 0;
    end
    else if(wr_en & (~full))begin
        wr_ptr_d1 <= wr_ptr[$clog2(WR_DEPTH) - 2 : 0];
    end
    else begin
        wr_ptr_d1 <= wr_ptr_d1;
    end
end

always @(posedge wr_clock or negedge wr_rst) begin
    if(wr_rst == 1'b0)begin
        wr_ptr[0]                  <= 0;
        wr_ptr[1]                  <= 0; 
        wr_ptr[$clog2(WR_DEPTH)-1] <= 0; 
        wr_ptr[$clog2(WR_DEPTH)]   <= 0;
    end
    else if(wr_en & (~full))begin
        wr_ptr[0]                  <= (~(wr_ptr_d1[0] ^ wr_ptr[0]))? ~wr_ptr[0] : wr_ptr[0];
        wr_ptr[1]                  <= (~(wr_ptr_d1[1] ^ wr_ptr[1]) & wr_ptr[0]) ? ~wr_ptr[1] : wr_ptr[1];
        wr_ptr[$clog2(WR_DEPTH)-1] <= (wr_ptr[$clog2(WR_DEPTH)-1] ^ wr_ptr[$clog2(WR_DEPTH)-2]) & ~(|wr_ptr[$clog2(WR_DEPTH)-3:0])? ~wr_ptr[$clog2(WR_DEPTH)-1] : wr_ptr[$clog2(WR_DEPTH)-1];
        wr_ptr[$clog2(WR_DEPTH)]   <= (wr_ptr[$clog2(WR_DEPTH)-1] & ~(|wr_ptr[$clog2(WR_DEPTH)-2:0]))? ~wr_ptr[$clog2(WR_DEPTH)] : wr_ptr[$clog2(WR_DEPTH)];
    end
end

genvar m;

generate for(m=2;m<$clog2(WR_DEPTH)-1;m=m+1)begin : WR_GRAY_COUNTER

    //wr_ptr
    always @(posedge wr_clock or negedge wr_rst)begin
        if(wr_rst == 1'b0)begin
            wr_ptr[m] <= 1'b0;
        end
        else if(wr_en & (~full))begin
            if(~(wr_ptr_d1[m]^wr_ptr[m]) & wr_ptr[m-1] & ~(|wr_ptr[m-2:0]))begin
                wr_ptr[m] <= ~wr_ptr[m];
            end
            else begin
                wr_ptr[m] <= wr_ptr[m];
            end
        end
    end

end
endgenerate

//mark the position of reading,use gray code counter
always @(posedge rd_clock or negedge rd_rst) begin
    if(rd_rst == 1'b0)begin
        rd_ptr_d1 <= 0;
    end
    else if(rd_en & (~empty))begin
        rd_ptr_d1 <= rd_ptr[$clog2(RD_DEPTH) - 2 : 0];
    end
end

always @(posedge rd_clock or negedge rd_rst) begin
    if(rd_rst == 1'b0)begin
        rd_ptr[0]                  <= 0;
        rd_ptr[1]                  <= 0;
        rd_ptr[$clog2(RD_DEPTH)-1] <= 0;
        rd_ptr[$clog2(RD_DEPTH)]   <= 0;
    end
    else if(rd_en & (~empty))begin
        rd_ptr[0]                  <= (~(rd_ptr_d1[0] ^ rd_ptr[0]))? ~rd_ptr[0] : rd_ptr[0];
        rd_ptr[1]                  <= (~(rd_ptr_d1[1] ^ rd_ptr[1]) & rd_ptr[0]) ? ~rd_ptr[1] : rd_ptr[1];
        rd_ptr[$clog2(RD_DEPTH)-1] <= ((rd_ptr[$clog2(RD_DEPTH)-1] ^ rd_ptr[$clog2(RD_DEPTH)-2]) & (~(|rd_ptr[$clog2(RD_DEPTH)-3:0]))) ? ~rd_ptr[$clog2(RD_DEPTH)-1] : rd_ptr[$clog2(RD_DEPTH)-1];
        rd_ptr[$clog2(RD_DEPTH)]   <= (rd_ptr[$clog2(RD_DEPTH)-1] & ~(|rd_ptr[$clog2(RD_DEPTH)-2:0]))? ~rd_ptr[$clog2(RD_DEPTH)] : rd_ptr[$clog2(RD_DEPTH)];
    end
end

//when in fwft mode,rd_ptr need to add one to pre-extract from fifo,use gray code counter
always @(posedge rd_clock or negedge rd_rst) begin
    if(rd_rst == 1'b0)begin
        rd_ptr_next_d1 <= 0;
    end
    else if((rd_en | pre_read) & (~empty))begin
        rd_ptr_next_d1 <= rd_ptr_next[$clog2(RD_DEPTH) - 2 : 0];
    end
end

always @(posedge rd_clock or negedge rd_rst) begin
    if(rd_rst == 1'b0)begin
        rd_ptr_next[0]                  <= 0;
        rd_ptr_next[1]                  <= 0;
        rd_ptr_next[$clog2(RD_DEPTH)-1] <= 0;
        rd_ptr_next[$clog2(RD_DEPTH)]   <= 0;
    end
    else if((rd_en | pre_read) & (~empty))begin
        rd_ptr_next[0]                  <= (~(rd_ptr_next_d1[0] ^ rd_ptr_next[0]))? ~rd_ptr_next[0] : rd_ptr_next[0];
        rd_ptr_next[1]                  <= (~(rd_ptr_next_d1[1] ^ rd_ptr_next[1]) & rd_ptr_next[0]) ? ~rd_ptr_next[1] : rd_ptr_next[1];
        rd_ptr_next[$clog2(RD_DEPTH)-1] <= ((rd_ptr_next[$clog2(RD_DEPTH)-1] ^ rd_ptr_next[$clog2(RD_DEPTH)-2]) & (~(|rd_ptr_next[$clog2(RD_DEPTH)-3:0]))) ? ~rd_ptr_next[$clog2(RD_DEPTH)-1] : rd_ptr_next[$clog2(RD_DEPTH)-1];
        rd_ptr_next[$clog2(RD_DEPTH)]   <= (rd_ptr_next[$clog2(RD_DEPTH)-1] & ~(|rd_ptr_next[$clog2(RD_DEPTH)-2:0]))? ~rd_ptr_next[$clog2(RD_DEPTH)] : rd_ptr_next[$clog2(RD_DEPTH)];
    end
end

genvar j;

generate for(j=2;j<$clog2(RD_DEPTH)-1;j=j+1) begin : RD_GRAY_COUNTER

    //rd_ptr
    always @(posedge rd_clock or negedge rd_rst)begin
        if(rd_rst == 1'b0)begin
            rd_ptr[j] <= 1'b0;
        end
        else if(rd_en & (~empty))begin
            if(~(rd_ptr_d1[j] ^ rd_ptr[j]) & rd_ptr[j-1] & ~(|rd_ptr[j-2:0]))begin
                rd_ptr[j] <= ~rd_ptr[j];
            end
            else begin
                rd_ptr[j] <= rd_ptr[j];
            end 
        end
    end

    //rd_ptr_next
    always @(posedge rd_clock or negedge rd_rst)begin
        if(rd_rst == 1'b0)begin
            rd_ptr_next[j] <= 1'b0;
        end
        else if((rd_en | pre_read) & (~empty))begin
            if(~(rd_ptr_next_d1[j] ^ rd_ptr_next[j]) & rd_ptr_next[j-1] & ~(|rd_ptr_next[j-2:0]))begin
                rd_ptr_next[j] <= ~rd_ptr_next[j];
            end
            else begin
                rd_ptr_next[j] <= rd_ptr_next[j];
            end 
        end
    end
end
endgenerate

//record the period before formal reading after pre reading
always @(posedge rd_clock or negedge rd_rst) begin
    if(rd_rst == 1'b0)begin
        pre_valid <= 1'b0;
    end
    else if(rd_en)begin
        pre_valid <= 1'b0;
    end
    else if(pre_read)begin
        pre_valid <= 1'b1;
    end
    else begin
        pre_valid <= pre_valid;
    end
end

//mark the position of data pre-read from fifo
always @(posedge rd_clock or negedge rd_rst) begin
    if(rd_rst == 1'b0)begin
        rd_ptr_pre <= 1'b0;
    end
    else if(pre_read)begin
        rd_ptr_pre <= rd_ptr_next;
    end
    else begin
        rd_ptr_pre <= rd_ptr_pre;
    end
end

//when in fwft mode,the change of ram_address need to use rd_ptr_fwft
always @(*) begin
    if(rd_rst == 1'b0)begin
        rd_ptr_fwft <= 1'b0;
    end
    //when reading formally,rd_ptr need to add one to pre-extract from fifo
    else if(rd_en)begin
        rd_ptr_fwft <= rd_ptr_next;
    end
    else begin
        //before formal reading after pre reading,read pre fetched data from FIFO
        if(pre_valid)begin
            rd_ptr_fwft <= rd_ptr_pre;
        end
        //When it is not officially read and the FIFO is not empty, there is no need to read it in advance
        else begin
            rd_ptr_fwft <= rd_ptr_next;
        end
    end
end

//while fifo is not empty,pre-read data from fifo
assign pre_read = (~empty) & empty_d1;

always @(posedge rd_clock or negedge rd_rst) begin
    if(rd_rst == 1'b0)begin
        empty_d1 <= 1'b1;
    end
    else begin
        empty_d1 <= empty;
    end
end

genvar i;

//valid
generate if(MODE == "Standard") begin : standard_mode_read

    always @(posedge rd_clock or negedge rd_rst) begin
        if(rd_rst == 1'b0)begin
            valid <= 1'b0;
        end
        else begin
            valid <= rd_en & (~empty);
        end
    end

end
endgenerate

generate if(MODE == "FWFT") begin : fwft_mode_read

    always @(*) begin
        if(rd_rst == 1'b0)begin
            valid <= 1'b0;
        end
        else begin
            valid <= ~empty_d1;
        end
    end

end
endgenerate

generate if(INPUT_WIDTH >= OUTPUT_WIDTH) begin : BIG_TO_SMALL_RAM

    reg  [RAM_NUM - 1 : 0]  ram_sel;    //choose which ram rd_data to output

    if(RAM_NUM >= 2)begin

        if(MODE == "Standard")begin
            
            always @(posedge rd_clock or negedge rd_rst) begin
                if(rd_rst == 1'b0)begin
                    ram_sel[RAM_NUM - 1]     <= 1'b1;
                    ram_sel[RAM_NUM - 2 : 0] <= 1'b0;
                end
                else if(rd_en & (~empty))begin
                    ram_sel <= {ram_sel[RAM_NUM - 2 : 0],ram_sel[RAM_NUM - 1]};
                end
                else begin
                    ram_sel <= ram_sel;
                end
            end

        end
        else if(MODE == "FWFT")begin
            
            always @(posedge rd_clock or negedge rd_rst) begin
                if(rd_rst == 1'b0)begin
                    ram_sel <= 1'b1;
                end
                else if(rd_en & (~empty))begin
                    ram_sel <= {ram_sel[RAM_NUM - 2 : 0],ram_sel[RAM_NUM - 1]};
                end
                else begin
                    ram_sel <= ram_sel;
                end
            end

        end

    end

    assign ram_wr_addr = wr_ptr;

    for(i=0;i<RAM_NUM;i=i+1)begin

        assign ram_wr_en[i] = wr_en & (~full);

        if(MODE == "Standard")begin
            assign ram_rd_en[i] = rd_en & (~empty);
        end
        else if(MODE == "FWFT")begin
            assign ram_rd_en[i] = (rd_en | pre_read) & (~empty); //fwft mode need to pre-read from fifo when fifo is not empty
        end

        if(DIRECTION == "LSB")begin

            DPRAM #(
	            .WIDTH 	( RAM_WIDTH  ),
	            .DEPTH 	( RAM_DEPTH  ))
            u_DPRAM(
	            .clka  	( wr_clock    ),
	            .ena   	( 1'b1        ),
	            .wea   	( ram_wr_en[i]),
	            .addra 	( ram_wr_addr[$clog2(RAM_DEPTH) - 1 : 0]),
	            .dina  	( din[(i+1) * RAM_WIDTH - 1 : i * RAM_WIDTH]),
	            .douta 	(             ),
	            .clkb  	( rd_clock    ),
	            .enb   	( ram_rd_en[i]),
	            .web   	(             ),
	            .addrb 	( ram_rd_addr[$clog2(RAM_DEPTH) - 1 : 0]),
	            .dinb  	(             ),
	            .doutb 	( ram_rd_data[(i+1) * RAM_WIDTH - 1 : i * RAM_WIDTH]));
        end
        else if(DIRECTION == "MSB")begin

            DPRAM #(
	            .WIDTH 	( RAM_WIDTH  ),
	            .DEPTH 	( RAM_DEPTH  ))
            u_DPRAM(
	            .clka  	( wr_clock    ),
	            .ena   	( 1'b1        ),
	            .wea   	( ram_wr_en[i]),
	            .addra 	( ram_wr_addr[$clog2(RAM_DEPTH) - 1 : 0]),
	            .dina  	( din[(i+1) * RAM_WIDTH - 1 : i * RAM_WIDTH]),
	            .douta 	(             ),
	            .clkb  	( rd_clock    ),
	            .enb   	( ram_rd_en[i]),
	            .web   	(             ),
	            .addrb 	( ram_rd_addr[$clog2(RAM_DEPTH) - 1 : 0]),
	            .dinb  	(             ),
	            .doutb 	( ram_rd_data[RAM_RD_WIDTH - i * RAM_WIDTH - 1 : RAM_RD_WIDTH - (i+1) * RAM_WIDTH]));
        end
    end

    //ram_rd_addr
    if(MODE == "Standard")begin
        assign ram_rd_addr = rd_ptr >> $clog2(RAM_NUM);
    end
    else if(MODE == "FWFT")begin
        assign ram_rd_addr = rd_ptr_fwft >> $clog2(RAM_NUM);
    end

    //rd_data
    case(RAM_NUM)

        4'd1:begin
            always @(*) begin
                if(rd_rst == 1'b0)begin
                    dout <= 1'b0;
            end
                else begin
                    dout <= ram_rd_data;
                end
            end
        end

        4'd2:begin
            always @(*) begin
                if(rd_rst == 1'b0)begin
                    dout <= 1'b0;
                end
                else begin
                    case(ram_sel)
                        2'b01 : dout <= ram_rd_data[OUTPUT_WIDTH - 1 : 0];
                        2'b10 : dout <= ram_rd_data[OUTPUT_WIDTH * 2 - 1 : OUTPUT_WIDTH];
                        default:begin
                            dout     <= ram_rd_data[OUTPUT_WIDTH - 1 : 0];
                        end
                    endcase
                end
            end
        end

        4'd4:begin
            always @(*) begin
                if(rd_rst == 1'b0)begin
                    dout <= 1'b0;
                end
                else begin
                    case(ram_sel)
                        4'b0001 : dout <= ram_rd_data[OUTPUT_WIDTH - 1 : 0];
                        4'b0010 : dout <= ram_rd_data[OUTPUT_WIDTH * 2 - 1 : OUTPUT_WIDTH];
                        4'b0100 : dout <= ram_rd_data[OUTPUT_WIDTH * 3 - 1 : OUTPUT_WIDTH * 2];
                        4'b1000 : dout <= ram_rd_data[OUTPUT_WIDTH * 4 - 1 : OUTPUT_WIDTH * 3];
                        default : begin
                            dout       <= ram_rd_data[OUTPUT_WIDTH - 1 : 0];
                        end
                    endcase
                end
            end
        end

        4'd8:begin
            always @(*) begin
                if(rd_rst == 1'b0)begin
                    dout <= 1'b0;
                end
                else begin
                    case(ram_sel)
                        8'b0000_0001 : dout <= ram_rd_data[OUTPUT_WIDTH - 1 : 0];
                        8'b0000_0010 : dout <= ram_rd_data[OUTPUT_WIDTH * 2 - 1 : OUTPUT_WIDTH];
                        8'b0000_0100 : dout <= ram_rd_data[OUTPUT_WIDTH * 3 - 1 : OUTPUT_WIDTH * 2];
                        8'b0000_1000 : dout <= ram_rd_data[OUTPUT_WIDTH * 4 - 1 : OUTPUT_WIDTH * 3];
                        8'b0001_0000 : dout <= ram_rd_data[OUTPUT_WIDTH * 5 - 1 : OUTPUT_WIDTH * 4];
                        8'b0010_0000 : dout <= ram_rd_data[OUTPUT_WIDTH * 6 - 1 : OUTPUT_WIDTH * 5];
                        8'b0100_0000 : dout <= ram_rd_data[OUTPUT_WIDTH * 7 - 1 : OUTPUT_WIDTH * 6];
                        8'b1000_0000 : dout <= ram_rd_data[OUTPUT_WIDTH * 8 - 1 : OUTPUT_WIDTH * 7];
                        default:begin
                            dout            <= ram_rd_data[OUTPUT_WIDTH - 1 : 0];
                        end
                    endcase
                end
            end
        end

    endcase

    //wr_data_count
    always @(*) begin
        if(wr_rst == 1'b0)begin
            wr_data_count <= 1'b0;
        end
        else if(ram_wr_addr[$clog2(RAM_DEPTH)] ^ ram_rd_addr_g_d2[$clog2(RAM_DEPTH)])begin
            wr_data_count <= {1'b1,ram_wr_addr_b[$clog2(RAM_DEPTH) - 1 : 0]} - {1'b0,ram_rd_addr_b_d2[$clog2(RAM_DEPTH) - 1 : 0]};
        end
        else begin
            wr_data_count <= ram_wr_addr_b - ram_rd_addr_b_d2;
        end
    end

    //rd_data_count
    always @(*) begin
        if(rd_rst == 1'b0)begin
            rd_data_count <= 1'b0;
        end
        else if(ram_rd_addr[$clog2(RAM_DEPTH)] ^ ram_wr_addr_g_d2[$clog2(RAM_DEPTH)])begin
            rd_data_count <= RAM_NUM * {1'b1,ram_wr_addr_b_d2[$clog2(RAM_DEPTH) - 1 : 0]} - {1'b0,rd_ptr_b[$clog2(RD_DEPTH) - 1 : 0]};
        end
        else begin
            rd_data_count <= RAM_NUM * ram_wr_addr_b_d2 - rd_ptr_b;
        end
    end

end
endgenerate

generate if(INPUT_WIDTH < OUTPUT_WIDTH) begin : SMALL_TO_BIG_RAM
    
    reg  [RAM_NUM - 1 : 0]           wr_en_d1;      //when input_width < output_width,enable each memory sequentially

    always @(posedge wr_clock or negedge wr_rst) begin
        if(wr_rst == 1'b0)begin
            wr_en_d1 <= 1'b1;
        end
        else if(wr_en)begin
            wr_en_d1 <= {wr_en_d1[RAM_NUM - 2 : 0],wr_en_d1[RAM_NUM - 1]};
        end
        else begin
            wr_en_d1 <= wr_en_d1;
        end
    end

    assign ram_wr_addr = wr_ptr >> $clog2(RAM_NUM);

    for(i=0;i<RAM_NUM;i=i+1)begin

        assign ram_wr_en[i] = wr_en & wr_en_d1[i] & (~full);

        if(MODE == "Standard")begin
            assign ram_rd_en[i] = rd_en & (~empty);
        end
        else if(MODE == "FWFT")begin
            assign ram_rd_en[i] = (rd_en | pre_read) & (~empty); //fwft mode need to pre-read from fifo when fifo is not empty
        end

        if(DIRECTION == "LSB")begin
            DPRAM #(
	            .WIDTH 	( RAM_WIDTH  ),
	            .DEPTH 	( RAM_DEPTH  ))
            u_DPRAM(
	            .clka  	( wr_clock    ),
	            .ena   	( 1'b1        ),
	            .wea   	( ram_wr_en[i]),
	            .addra 	( ram_wr_addr[$clog2(RAM_DEPTH) - 1 : 0]),
	            .dina  	( din         ),
	            .douta 	(             ),
	            .clkb  	( rd_clock    ),
	            .enb   	( ram_rd_en[i]),
	            .web   	(             ),
	            .addrb 	( ram_rd_addr[$clog2(RAM_DEPTH) - 1 : 0]),
	            .dinb  	(             ),
	            .doutb 	( ram_rd_data[(i+1) * RAM_WIDTH - 1 : i * RAM_WIDTH]));
        end
        else if(DIRECTION == "MSB")begin
            DPRAM #(
	            .WIDTH 	( RAM_WIDTH  ),
	            .DEPTH 	( RAM_DEPTH  ))
            u_DPRAM(
	            .clka  	( wr_clock    ),
	            .ena   	( 1'b1        ),
	            .wea   	( ram_wr_en[i]),
	            .addra 	( ram_wr_addr[$clog2(RAM_DEPTH) - 1 : 0]),
	            .dina  	( din         ),
	            .douta 	(             ),
	            .clkb  	( rd_clock    ),
	            .enb   	( ram_rd_en[i]),
	            .web   	(             ),
	            .addrb 	( ram_rd_addr[$clog2(RAM_DEPTH) - 1 : 0]),
	            .dinb  	(             ),
	            .doutb 	( ram_rd_data[RAM_RD_WIDTH - i * RAM_WIDTH - 1 : RAM_RD_WIDTH - (i+1) * RAM_WIDTH]));
        end
    end

    //ram_rd_addr
    if(MODE == "Standard")begin
        assign ram_rd_addr = rd_ptr;
    end
    else if(MODE == "FWFT")begin
        assign ram_rd_addr = rd_ptr_fwft;
    end

    //rd_data
    always @(*) begin
        if(rd_rst == 1'b0)begin
            dout <= 1'b0;
        end
        else begin
            dout <= ram_rd_data;
        end
    end

    //wr_data_count
    always @(*) begin
        if(wr_rst == 1'b0)begin
            wr_data_count <= 1'b0;
        end
        else if(ram_wr_addr[$clog2(RAM_DEPTH)] ^ ram_rd_addr_g_d2[$clog2(RAM_DEPTH)])begin
            wr_data_count <= {1'b1,wr_ptr_b[$clog2(WR_DEPTH) - 1 : 0]} - RAM_NUM * {1'b0,ram_rd_addr_b_d2[$clog2(RAM_DEPTH) - 1 : 0]};
        end
        else begin
            wr_data_count <= wr_ptr_b - RAM_NUM * ram_rd_addr_b_d2;
        end
    end

    //rd_data_count
    always @(*) begin
        if(rd_rst == 1'b0)begin
            rd_data_count  <= 1'b0;
        end
        else if(ram_rd_addr[$clog2(RAM_DEPTH)] ^ ram_wr_addr_g_d2[$clog2(RAM_DEPTH)])begin
             rd_data_count <= {1'b1,ram_wr_addr_b_d2[$clog2(RAM_DEPTH) - 1 : 0]} - {1'b0,ram_rd_addr_b[$clog2(RAM_DEPTH) - 1 : 0]};
        end
        else begin
            rd_data_count  <= ram_wr_addr_b_d2 - ram_rd_addr_b;
        end
    end

end
endgenerate

//full and empty operation
integer k;

//wr_ptr gray to binary
always @(*) begin
    if(wr_rst == 1'b0)begin
        wr_ptr_b <= 1'b0;
    end
    else begin
        wr_ptr_b[$clog2(WR_DEPTH)]   <= wr_ptr[$clog2(WR_DEPTH)];
        wr_ptr_b[$clog2(WR_DEPTH)-1] <= wr_ptr[$clog2(WR_DEPTH)-1];
        for(k=1;k<=$clog2(WR_DEPTH)-1;k=k+1)begin
            wr_ptr_b[k-1]           <= wr_ptr[k-1] ^ wr_ptr_b[k];
        end
    end
end

//rd_ptr gray to binary
generate if(MODE == "Standard") begin : standard_g2b

    always @(*) begin
        if(rd_rst == 1'b0)begin
            rd_ptr_b <= 1'b0;
        end
        else begin
            rd_ptr_b[$clog2(RD_DEPTH)]   <= rd_ptr[$clog2(RD_DEPTH)];
            rd_ptr_b[$clog2(RD_DEPTH)-1] <= rd_ptr[$clog2(RD_DEPTH)-1];
            for(k=1;k<=$clog2(RD_DEPTH)-1;k=k+1)begin
                rd_ptr_b[k-1]           <= rd_ptr[k-1] ^ rd_ptr_b[k];
        end
        end
    end

end
endgenerate

generate if(MODE == "FWFT") begin : fwft_g2b

    always @(*) begin
        if(rd_rst == 1'b0)begin
            rd_ptr_b <= 1'b0;
        end
        else begin
            rd_ptr_b[$clog2(RD_DEPTH)]   <= rd_ptr_fwft[$clog2(RD_DEPTH)];
            rd_ptr_b[$clog2(RD_DEPTH)-1] <= rd_ptr_fwft[$clog2(RD_DEPTH)-1];
            for(k=1;k<=$clog2(RD_DEPTH)-1;k=k+1)begin
                rd_ptr_b[k-1]            <= rd_ptr_fwft[k-1] ^ rd_ptr_b[k];
            end
        end
    end
end
endgenerate

//ram_wr_addr gray to binary
assign ram_wr_addr_b = (INPUT_WIDTH >= OUTPUT_WIDTH) ? wr_ptr_b : wr_ptr_b >> $clog2(RAM_NUM);

//ram_rd_addr to binary
assign ram_rd_addr_b = (INPUT_WIDTH >= OUTPUT_WIDTH) ? rd_ptr_b >> $clog2(RAM_NUM) : rd_ptr_b;

//in read clock domain,ram_wr_addr_g takes two beats 
always @(posedge rd_clock or negedge rd_rst) begin
    if(rd_rst == 1'b0)begin
        ram_wr_addr_g_d1 <= 1'b0;
        ram_wr_addr_g_d2 <= 1'b0;
    end
    else begin
        ram_wr_addr_g_d1 <= ram_wr_addr;
        ram_wr_addr_g_d2 <= ram_wr_addr_g_d1;
    end
end

//in write clock domain,ram_rd_addr_g takes two beats 
always @(posedge wr_clock or negedge wr_rst) begin
    if(wr_rst == 1'b0)begin
        ram_rd_addr_g_d1 <= 1'b0;
        ram_rd_addr_g_d2 <= 1'b0;
    end
    else begin
        ram_rd_addr_g_d1 <= ram_rd_addr;
        ram_rd_addr_g_d2 <= ram_rd_addr_g_d1;
    end
end

//ram_wr_addr_g_d2 gray to binary
always @(*) begin
    if(rd_rst == 1'b0)begin
        ram_wr_addr_b_d2 <= 1'b0;
    end
    else begin
        ram_wr_addr_b_d2[$clog2(RAM_DEPTH)]   <= ram_wr_addr_g_d2[$clog2(RAM_DEPTH)];
        ram_wr_addr_b_d2[$clog2(RAM_DEPTH)-1] <= ram_wr_addr_g_d2[$clog2(RAM_DEPTH)-1];
        for(k=1;k<=$clog2(RAM_DEPTH)-1;k=k+1)begin
            ram_wr_addr_b_d2[k-1]           <= ram_wr_addr_g_d2[k-1] ^ ram_wr_addr_b_d2[k];
        end
    end
end

//ram_rd_addr_g_d2 gray to binary
always @(*) begin
    if(wr_rst == 1'b0)begin
        ram_rd_addr_b_d2 <= 1'b0;
    end
    else begin
        ram_rd_addr_b_d2[$clog2(RAM_DEPTH)]   <= ram_rd_addr_g_d2[$clog2(RAM_DEPTH)];
        ram_rd_addr_b_d2[$clog2(RAM_DEPTH)-1] <= ram_rd_addr_g_d2[$clog2(RAM_DEPTH)-1];
        for(k=1;k<=$clog2(RAM_DEPTH)-1;k=k+1)begin
            ram_rd_addr_b_d2[k-1]           <= ram_rd_addr_g_d2[k-1] ^ ram_rd_addr_b_d2[k];
        end
    end
end

assign full          = (ram_wr_addr[$clog2(RAM_DEPTH)]         != ram_rd_addr_g_d2[$clog2(RAM_DEPTH)]) && 
                       (ram_wr_addr[$clog2(RAM_DEPTH) - 1 : 0] == ram_rd_addr_g_d2[$clog2(RAM_DEPTH) - 1 : 0]) ? 1'b1 : 1'b0;

assign empty         = (ram_rd_addr == ram_wr_addr_g_d2) ? 1'b1 : 1'b0;

//fifo is about to be full
generate if(USE_ADV_FEATURES[3] == 1'b1) begin : ALMOST_FULL_ENABLE

    if(INPUT_WIDTH >= OUTPUT_WIDTH)begin
        assign almost_full = (rd_data_count == RD_DEPTH - 1) ? 1'b1 : 1'b0;
    end
    else if(INPUT_WIDTH < OUTPUT_WIDTH)begin
        assign almost_full = (wr_data_count == WR_DEPTH - 1) ? 1'b1 : 1'b0;
    end

end
endgenerate

generate if(USE_ADV_FEATURES[3] == 1'b0) begin : ALMOST_FULL_DISABLE

    assign almost_full = 1'b0;

end
endgenerate

//fifo is about to be empty
generate if(USE_ADV_FEATURES[11] == 1'b1) begin : ALMOST_EMPTY_ENABLE

    if(INPUT_WIDTH >= OUTPUT_WIDTH)begin
        assign almost_empty = (rd_data_count == 1'b1) ? 1'b1 : 1'b0;
    end
    else if(INPUT_WIDTH < OUTPUT_WIDTH)begin
        assign almost_empty = (wr_data_count == 1'b1) ? 1'b1 : 1'b0;
    end

end
endgenerate

generate if(USE_ADV_FEATURES[11] == 1'b0) begin : ALMOST_EMPTY_DISABLE

    assign almost_empty = 1'b0;

end
endgenerate

//the amount of data in the fifo is greater than or equal to the programmable full threshold
generate if(USE_ADV_FEATURES[1] == 1'b1) begin : PROG_FULL_ENABLE
    
    if(INPUT_WIDTH >= OUTPUT_WIDTH)begin
        assign prog_full = (rd_data_count >= PROG_FULL_THRESH) ? 1'b1 : 1'b0;
    end
    else if(INPUT_WIDTH < OUTPUT_WIDTH)begin
        assign prog_full = (wr_data_count >= PROG_FULL_THRESH) ? 1'b1 : 1'b0;
    end

end
endgenerate

generate if(USE_ADV_FEATURES[1] == 1'b0) begin : PROG_FULL_DISABLE
    
    assign prog_full = 1'b0;

end
endgenerate

//the amount of data in the FIFO is less than or equal to the programmable null threshold
generate if(USE_ADV_FEATURES[9] == 1'b1) begin : PROG_EMPTY_ENABLE
    
    if(INPUT_WIDTH >= OUTPUT_WIDTH)begin
        assign prog_empty = (rd_data_count <= PROG_EMPTY_THRESH) ? 1'b1 : 1'b0;
    end
    else if(INPUT_WIDTH < OUTPUT_WIDTH)begin
        assign prog_empty = (wr_data_count <= PROG_EMPTY_THRESH) ? 1'b1 : 1'b0;
    end

end
endgenerate

generate if(USE_ADV_FEATURES[9] == 1'b0) begin : PROG_EMPTY_DISABLE
    
    assign prog_empty = 1'b0;

end
endgenerate

//the write request from the previous clock cycle was rejected because the FIFO is now full
generate if(USE_ADV_FEATURES[0] == 1'b1) begin : OVERFLOW_ENABLE
    
    always @(posedge wr_clock or negedge wr_rst) begin
        if(wr_rst == 1'b0)begin
            overflow <= 1'b0;
        end
        else if(full)begin
            if(wr_en)begin
                overflow <= 1'b1;
            end
            else begin
                overflow <= overflow;
            end
        end
        else begin
            overflow <= 1'b0;
        end
    end

end
endgenerate

generate if(USE_ADV_FEATURES[0] == 1'b0) begin : OVERFLOW_DISABLE
    
    always @(*) begin
        overflow <= 1'b0;
    end

end
endgenerate

//the read request from the previous clock cycle was rejected because the FIFO is now empty
generate if(USE_ADV_FEATURES[8] == 1'b1) begin : UNDERFLOW_ENABLE
    
    always @(posedge rd_clock or negedge rd_rst) begin
        if(rd_rst == 1'b0)begin
            underflow <= 1'b0;
        end
        else if(empty)begin
            if(rd_en)begin
                underflow <= 1'b1;
            end
            else begin
                underflow <= underflow;
            end
        end
        else begin
            overflow <= 1'b0;
        end
    end

end
endgenerate

generate if(USE_ADV_FEATURES[8] == 1'b0) begin : UNDERFLOW_DISABLE
    
    always @(*) begin
        underflow <= 1'b0;
    end

end
endgenerate

//the write request was successful in the previous clock cycle
generate if(USE_ADV_FEATURES[4] == 1'b1) begin : WR_ACK_ENABLE
    
    assign wr_ack = wr_en & (~full);

end
endgenerate

generate if(USE_ADV_FEATURES[4] == 1'b0) begin : WR_ACK_DISABLE
    
    assign wr_ack = 1'b0;

end
endgenerate

endmodule  //async_fifo