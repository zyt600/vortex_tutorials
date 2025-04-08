// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

`ifndef NOPAE
`include "afu_json_info.vh"
`else
`include "vortex_afu.vh"
`endif

module vortex_afu import ccip_if_pkg::*; import local_mem_cfg_pkg::*; import VX_gpu_pkg::*; #(
    parameter NUM_LOCAL_MEM_BANKS = 2
) (
    // global signals
    input wire clk,
    input wire reset,

    // IF signals between CCI and AFU
    input   t_if_ccip_Rx  cp2af_sRxPort,
    output  t_if_ccip_Tx  af2cp_sTxPort,

    // Avalon signals for local memory access
    output  t_local_mem_data      avs_writedata [NUM_LOCAL_MEM_BANKS],
    input   t_local_mem_data      avs_readdata [NUM_LOCAL_MEM_BANKS],
    output  t_local_mem_addr      avs_address [NUM_LOCAL_MEM_BANKS],
    input   wire                  avs_waitrequest [NUM_LOCAL_MEM_BANKS],
    output  wire                  avs_write [NUM_LOCAL_MEM_BANKS],
    output  wire                  avs_read [NUM_LOCAL_MEM_BANKS],
    output  t_local_mem_byte_mask avs_byteenable [NUM_LOCAL_MEM_BANKS],
    output  t_local_mem_burst_cnt avs_burstcount [NUM_LOCAL_MEM_BANKS],
    input   wire                  avs_readdatavalid [NUM_LOCAL_MEM_BANKS]
);
    localparam LMEM_DATA_WIDTH    = $bits(t_local_mem_data);
    localparam LMEM_DATA_SIZE     = LMEM_DATA_WIDTH / 8;
    localparam LMEM_ADDR_WIDTH    = $bits(t_local_mem_addr);

    localparam LMEM_BYTE_ADDR_WIDTH = LMEM_ADDR_WIDTH + $clog2(LMEM_DATA_SIZE);
    localparam CCI_VX_ADDR_WIDTH  = `VX_MEM_ADDR_WIDTH + ($clog2(`VX_MEM_DATA_WIDTH) - $clog2(LMEM_DATA_WIDTH));

    localparam LMEM_BURST_CTRW    = $bits(t_local_mem_burst_cnt);

    localparam MEM_PORTS_BITS     = `CLOG2(`VX_MEM_PORTS);
    localparam MEM_PORTS_WIDTH    = `UP(MEM_PORTS_BITS);

    localparam CCI_DATA_WIDTH     = $bits(t_ccip_clData);
    localparam CCI_DATA_SIZE      = CCI_DATA_WIDTH / 8;
    localparam CCI_ADDR_WIDTH     = $bits(t_ccip_clAddr);

    localparam RESET_CTR_WIDTH    = `CLOG2(`RESET_DELAY+1);

    localparam AVS_RD_QUEUE_SIZE  = 32;
    localparam VX_AVS_REQ_TAGW    = `VX_MEM_TAG_WIDTH + `CLOG2(LMEM_DATA_WIDTH) - `CLOG2(`VX_MEM_DATA_WIDTH);
    localparam CCI_AVS_REQ_TAGW   = CCI_ADDR_WIDTH + `CLOG2(LMEM_DATA_WIDTH) - `CLOG2(CCI_DATA_WIDTH);
    localparam VX_AVS_REQ_TAGW2   = `MAX(`VX_MEM_TAG_WIDTH, VX_AVS_REQ_TAGW);
    localparam CCI_AVS_REQ_TAGW2  = `MAX(CCI_ADDR_WIDTH, CCI_AVS_REQ_TAGW);
    localparam CCI_VX_TAG_WIDTH   = `MAX(VX_AVS_REQ_TAGW2, CCI_AVS_REQ_TAGW2);
    localparam AVS_TAG_WIDTH      = CCI_VX_TAG_WIDTH + 1; // adding the arbiter bit

    localparam CCI_RD_WINDOW_SIZE = 8;
    localparam CCI_RW_PENDING_SIZE= 256;

    localparam AFU_ID_L           = 16'h0002;      // AFU ID Lower
    localparam AFU_ID_H           = 16'h0004;      // AFU ID Higher

    localparam CMD_IDLE           = 0;
    localparam CMD_MEM_READ       = `AFU_IMAGE_CMD_MEM_READ;
    localparam CMD_MEM_WRITE      = `AFU_IMAGE_CMD_MEM_WRITE;
    localparam CMD_DCR_WRITE      = `AFU_IMAGE_CMD_DCR_WRITE;
    localparam CMD_RUN            = `AFU_IMAGE_CMD_RUN;
    localparam CMD_TYPE_WIDTH     = `CLOG2(`AFU_IMAGE_CMD_MAX_VALUE+1);

    localparam MMIO_CMD_TYPE      = `AFU_IMAGE_MMIO_CMD_TYPE;
    localparam MMIO_CMD_ARG0      = `AFU_IMAGE_MMIO_CMD_ARG0;
    localparam MMIO_CMD_ARG1      = `AFU_IMAGE_MMIO_CMD_ARG1;
    localparam MMIO_CMD_ARG2      = `AFU_IMAGE_MMIO_CMD_ARG2;
    localparam MMIO_STATUS        = `AFU_IMAGE_MMIO_STATUS;

    localparam COUT_TID_WIDTH     = `CLOG2(`VX_MEM_BYTEEN_WIDTH);
    localparam COUT_QUEUE_DATAW   = COUT_TID_WIDTH + 8;
    localparam COUT_QUEUE_SIZE    = 1024;

    localparam MMIO_DEV_CAPS      = `AFU_IMAGE_MMIO_DEV_CAPS;
    localparam MMIO_ISA_CAPS      = `AFU_IMAGE_MMIO_ISA_CAPS;

    localparam CCI_RD_QUEUE_SIZE  = 2 * CCI_RD_WINDOW_SIZE;
    localparam CCI_RD_QUEUE_TAGW  = `CLOG2(CCI_RD_WINDOW_SIZE);
    localparam CCI_RD_QUEUE_DATAW = CCI_DATA_WIDTH + CCI_ADDR_WIDTH;

    localparam STATE_IDLE         = 0;
    localparam STATE_MEM_WRITE    = 1;
    localparam STATE_MEM_READ     = 2;
    localparam STATE_RUN          = 3;
    localparam STATE_DCR_WRITE    = 4;
    localparam STATE_WIDTH        = `CLOG2(STATE_DCR_WRITE+1);

    wire [127:0] afu_id = `AFU_ACCEL_UUID;

    wire [63:0] dev_caps = {8'b0,
                            5'(LMEM_BYTE_ADDR_WIDTH-20),
                            3'(`CLOG2(NUM_LOCAL_MEM_BANKS)),
                            8'(`LMEM_ENABLED ? `LMEM_LOG_SIZE : 0),
                            16'(`NUM_CORES * `NUM_CLUSTERS),
                            8'(`NUM_WARPS),
                            8'(`NUM_THREADS),
                            8'(`IMPLEMENTATION_ID)};

    wire [63:0] isa_caps = {32'(`MISA_EXT),
                            2'(`CLOG2(`XLEN)-4),
                            30'(`MISA_STD)};

    reg [STATE_WIDTH-1:0] state;

    // Vortex ports ///////////////////////////////////////////////////////////

    wire                            vx_mem_req_valid [`VX_MEM_PORTS];
    wire                            vx_mem_req_rw [`VX_MEM_PORTS];
    wire [`VX_MEM_BYTEEN_WIDTH-1:0] vx_mem_req_byteen [`VX_MEM_PORTS];
    wire [`VX_MEM_ADDR_WIDTH-1:0]   vx_mem_req_addr [`VX_MEM_PORTS];
    wire [`VX_MEM_DATA_WIDTH-1:0]   vx_mem_req_data [`VX_MEM_PORTS];
    wire [`VX_MEM_TAG_WIDTH-1:0]    vx_mem_req_tag [`VX_MEM_PORTS];
    wire                            vx_mem_req_ready [`VX_MEM_PORTS];

    wire                            vx_mem_rsp_valid [`VX_MEM_PORTS];
    wire [`VX_MEM_DATA_WIDTH-1:0]   vx_mem_rsp_data [`VX_MEM_PORTS];
    wire [`VX_MEM_TAG_WIDTH-1:0]    vx_mem_rsp_tag [`VX_MEM_PORTS];
    wire                            vx_mem_rsp_ready [`VX_MEM_PORTS];

    // CMD variables //////////////////////////////////////////////////////////

    reg [2:0][63:0] cmd_args;

    t_ccip_clAddr cmd_io_addr;
    assign cmd_io_addr = t_ccip_clAddr'(cmd_args[0]);

    wire [CCI_ADDR_WIDTH-1:0] cmd_mem_addr  = CCI_ADDR_WIDTH'(cmd_args[1]);
    wire [CCI_ADDR_WIDTH-1:0] cmd_data_size = CCI_ADDR_WIDTH'(cmd_args[2]);

    wire [`VX_DCR_ADDR_WIDTH-1:0] cmd_dcr_addr = `VX_DCR_ADDR_WIDTH'(cmd_args[0]);
    wire [`VX_DCR_DATA_WIDTH-1:0] cmd_dcr_data = `VX_DCR_DATA_WIDTH'(cmd_args[1]);

    // MMIO controller ////////////////////////////////////////////////////////

    t_ccip_c0_ReqMmioHdr mmio_req_hdr;
    assign mmio_req_hdr = t_ccip_c0_ReqMmioHdr'(cp2af_sRxPort.c0.hdr[$bits(t_ccip_c0_ReqMmioHdr)-1:0]);
    `UNUSED_VAR (mmio_req_hdr)

    t_if_ccip_c2_Tx mmio_rsp;
    assign af2cp_sTxPort.c2 = mmio_rsp;

`ifdef SCOPE

    localparam MMIO_SCOPE_READ  = `AFU_IMAGE_MMIO_SCOPE_READ;
    localparam MMIO_SCOPE_WRITE = `AFU_IMAGE_MMIO_SCOPE_WRITE;

    reg [63:0] cmd_scope_rdata;
    reg [63:0] cmd_scope_wdata;

    reg cmd_scope_reading;
    reg cmd_scope_writing;

    reg  scope_bus_in;
    wire scope_bus_out;

    reg [5:0] scope_bus_ctr;

    wire scope_reset = reset;

    always @(posedge clk) begin
        if (reset) begin
            cmd_scope_reading <= 0;
            cmd_scope_writing <= 0;
            scope_bus_in      <= 0;
        end else begin
            scope_bus_in <= 0;
            if (scope_bus_out) begin
                cmd_scope_reading <= 1;
                scope_bus_ctr     <= 63;
            end
            if (cp2af_sRxPort.c0.mmioWrValid
             && (MMIO_SCOPE_WRITE == mmio_req_hdr.address)) begin
                cmd_scope_wdata   <= 64'(cp2af_sRxPort.c0.data);
                cmd_scope_writing <= 1;
                scope_bus_ctr     <= 63;
                scope_bus_in      <= 1;
            end
            if (cmd_scope_writing) begin
                scope_bus_in  <= cmd_scope_wdata[scope_bus_ctr];
                scope_bus_ctr <= scope_bus_ctr - 6'd1;
                if (scope_bus_ctr == 0) begin
                    cmd_scope_writing <= 0;
                    scope_bus_ctr <= 0;
                end
            end
            if (cmd_scope_reading) begin
                cmd_scope_rdata <= {cmd_scope_rdata[62:0], scope_bus_out};
                scope_bus_ctr   <= scope_bus_ctr - 6'd1;
                if (scope_bus_ctr == 0) begin
                    cmd_scope_reading <= 0;
                    scope_bus_ctr <= 0;
                end
            end
        end
    end

`endif

    // Console output queue read //////////////////////////////////////////////

    wire [`VX_MEM_PORTS-1:0][COUT_QUEUE_DATAW-1:0] cout_q_dout;
    wire [`VX_MEM_PORTS-1:0] cout_q_full, cout_q_empty, cout_q_pop;

    reg [MEM_PORTS_WIDTH-1:0] cout_q_id;

    always @(posedge clk) begin
        if (reset) begin
            cout_q_id <= 0;
        end else begin
            if (cp2af_sRxPort.c0.mmioRdValid && mmio_req_hdr.address == MMIO_STATUS) begin
                cout_q_id <= cout_q_id + 1;
            end
        end
    end

    for (genvar i = 0; i < `VX_MEM_PORTS; ++i) begin : g_cout_q_pop
        assign cout_q_pop[i] = (cp2af_sRxPort.c0.mmioRdValid && mmio_req_hdr.address == MMIO_STATUS)
                            && (cout_q_id == i)
                            && ~cout_q_empty[i];
    end

    wire [COUT_QUEUE_DATAW-1:0] cout_q_dout_s = cout_q_dout[cout_q_id] & {COUT_QUEUE_DATAW{!cout_q_empty[cout_q_id]}};
    wire cout_q_empty_all = & cout_q_empty;

`ifdef SIMULATION
`ifndef VERILATOR
    // disable assertions until full reset
    reg [`CLOG2(`RESET_DELAY+1)-1:0] assert_delay_ctr;
    initial begin
        $assertoff;
    end
    always @(posedge clk) begin
        if (reset) begin
            assert_delay_ctr <= '0;
        end else begin
            assert_delay_ctr <= assert_delay_ctr + $bits(assert_delay_ctr)'(1);
            if (assert_delay_ctr == (`RESET_DELAY-1)) begin
                $asserton; // enable assertions
            end
        end
    end
`endif
`endif

    // MMIO controller ////////////////////////////////////////////////////////

    // Handle MMIO read requests
    always @(posedge clk) begin
        if (reset) begin
            mmio_rsp.mmioRdValid <= 0;
            cout_q_id <= 0;
        end else begin
            mmio_rsp.mmioRdValid <= cp2af_sRxPort.c0.mmioRdValid;
        end

        mmio_rsp.hdr.tid <= mmio_req_hdr.tid;

        if (cp2af_sRxPort.c0.mmioRdValid) begin
            case (mmio_req_hdr.address)
            // AFU header
            16'h0000: mmio_rsp.data <= {
                4'b0001, // Feature type = AFU
                8'b0,    // reserved
                4'b0,    // afu minor revision = 0
                7'b0,    // reserved
                1'b1,    // end of DFH list = 1
                24'b0,   // next DFH offset = 0
                4'b0,    // afu major revision = 0
                12'b0    // feature ID = 0
            };
            AFU_ID_L: mmio_rsp.data <= afu_id[63:0];   // afu id low
            AFU_ID_H: mmio_rsp.data <= afu_id[127:64]; // afu id hi
            16'h0006: mmio_rsp.data <= 64'h0; // next AFU
            16'h0008: mmio_rsp.data <= 64'h0; // reserved
            MMIO_STATUS: begin
                mmio_rsp.data <= 64'({cout_q_dout_s, ~cout_q_empty_all, 8'(state)});
            `ifdef DBG_TRACE_AFU
                if (state != STATE_WIDTH'(mmio_rsp.data)) begin
                    `TRACE(2, ("%t: AFU: MMIO_STATUS: addr=0x%0h, state=%0d\n", $time, mmio_req_hdr.address, state))
                end
            `endif
            end
            `ifdef SCOPE
            MMIO_SCOPE_READ: begin
                mmio_rsp.data <= cmd_scope_rdata;
            `ifdef DBG_TRACE_AFU
                `TRACE(2, ("%t: AFU: MMIO_SCOPE_READ: data=0x%h\n", $time, cmd_scope_rdata))
            `endif
            end
            `endif
            MMIO_DEV_CAPS: begin
                mmio_rsp.data <= dev_caps;
            `ifdef DBG_TRACE_AFU
                `TRACE(2, ("%t: AFU: MMIO_DEV_CAPS: data=0x%h\n", $time, dev_caps))
            `endif
            end
            MMIO_ISA_CAPS: begin
                mmio_rsp.data <= isa_caps;
            `ifdef DBG_TRACE_AFU
                if (state != STATE_WIDTH'(mmio_rsp.data)) begin
                    `TRACE(2, ("%t: AFU: MMIO_ISA_CAPS: data=%0d\n", $time, isa_caps))
                end
            `endif
            end
            default: begin
                mmio_rsp.data <= 64'h0;
            `ifdef DBG_TRACE_AFU
                `TRACE(2, ("%t: AFU: Unknown MMIO Rd: addr=0x%0h\n", $time, mmio_req_hdr.address))
            `endif
            end
            endcase
        end
    end

    // Handle MMIO write requests
    always @(posedge clk) begin
        if (cp2af_sRxPort.c0.mmioWrValid) begin
            case (mmio_req_hdr.address)
            MMIO_CMD_ARG0: begin
                cmd_args[0] <= 64'(cp2af_sRxPort.c0.data);
            `ifdef DBG_TRACE_AFU
                `TRACE(2, ("%t: AFU: MMIO_CMD_ARG0: data=0x%h\n", $time, 64'(cp2af_sRxPort.c0.data)))
            `endif
            end
            MMIO_CMD_ARG1: begin
                cmd_args[1] <= 64'(cp2af_sRxPort.c0.data);
            `ifdef DBG_TRACE_AFU
                `TRACE(2, ("%t: AFU: MMIO_CMD_ARG1: data=0x%h\n", $time, 64'(cp2af_sRxPort.c0.data)))
            `endif
            end
            MMIO_CMD_ARG2: begin
                cmd_args[2] <= 64'(cp2af_sRxPort.c0.data);
            `ifdef DBG_TRACE_AFU
                `TRACE(2, ("%t: AFU: MMIO_CMD_ARG2: data=%0d\n", $time, 64'(cp2af_sRxPort.c0.data)))
            `endif
            end
            MMIO_CMD_TYPE: begin
            `ifdef DBG_TRACE_AFU
                `TRACE(2, ("%t: AFU: MMIO_CMD_TYPE: data=%0d\n", $time, 64'(cp2af_sRxPort.c0.data)))
            `endif
            end
            `ifdef SCOPE
            MMIO_SCOPE_WRITE: begin
            `ifdef DBG_TRACE_AFU
                `TRACE(2, ("%t: AFU: MMIO_SCOPE_WRITE: data=0x%h\n", $time, 64'(cp2af_sRxPort.c0.data)))
            `endif
            end
            `endif
            default: begin
                `ifdef DBG_TRACE_AFU
                `TRACE(2, ("%t: Unknown MMIO Wr: addr=0x%0h, data=0x%h\n", $time, mmio_req_hdr.address, 64'(cp2af_sRxPort.c0.data)))
                `endif
            end
            endcase
        end
    end

    // COMMAND FSM ////////////////////////////////////////////////////////////

    wire cmd_mem_rd_done;
    reg  cmd_mem_wr_done;

    reg [RESET_CTR_WIDTH-1:0] vx_reset_ctr;
    reg  vx_busy_wait;
    reg  vx_reset = 1; // asserted at initialization
    wire vx_busy;

    wire is_mmio_wr_cmd = cp2af_sRxPort.c0.mmioWrValid && (MMIO_CMD_TYPE == mmio_req_hdr.address);
    wire [CMD_TYPE_WIDTH-1:0] cmd_type = is_mmio_wr_cmd ? CMD_TYPE_WIDTH'(cp2af_sRxPort.c0.data) : CMD_TYPE_WIDTH'(CMD_IDLE);

    always @(posedge clk) begin
        if (reset) begin
            state    <= STATE_IDLE;
            vx_reset <= 1;
        end else begin
            case (state)
            STATE_IDLE: begin
                case (cmd_type)
                CMD_MEM_READ: begin
                `ifdef DBG_TRACE_AFU
                    `TRACE(2, ("%t: AFU: Goto STATE MEM_READ: ia=0x%0h addr=0x%0h size=%0d\n", $time, cmd_io_addr, cmd_mem_addr, cmd_data_size))
                `endif
                    state <= STATE_MEM_READ;
                end
                CMD_MEM_WRITE: begin
                `ifdef DBG_TRACE_AFU
                    `TRACE(2, ("%t: AFU: Goto STATE MEM_WRITE: ia=0x%0h addr=0x%0h size=%0d\n", $time, cmd_io_addr, cmd_mem_addr, cmd_data_size))
                `endif
                    state <= STATE_MEM_WRITE;
                end
                CMD_DCR_WRITE: begin
                `ifdef DBG_TRACE_AFU
                    `TRACE(2, ("%t: AFU: Goto STATE DCR_WRITE: addr=0x%0h data=%0d\n", $time, cmd_dcr_addr, cmd_dcr_data))
                `endif
                    state <= STATE_DCR_WRITE;
                end
                CMD_RUN: begin
                `ifdef DBG_TRACE_AFU
                    `TRACE(2, ("%t: AFU: Goto STATE RUN\n", $time))
                `endif
                    state <= STATE_RUN;
                    vx_reset_ctr <= RESET_CTR_WIDTH'(`RESET_DELAY-1);
					vx_reset <= 1;
                end
                default: begin
                    state <= state;
                end
                endcase
            end
            STATE_MEM_READ: begin
                if (cmd_mem_rd_done) begin
                    state <= STATE_IDLE;
                `ifdef DBG_TRACE_AFU
                    `TRACE(2, ("%t: AFU: Goto STATE IDLE\n", $time))
                `endif
                end
            end
            STATE_MEM_WRITE: begin
                if (cmd_mem_wr_done) begin
                    state <= STATE_IDLE;
                end
            end
            STATE_DCR_WRITE: begin
                state <= STATE_IDLE;
            `ifdef DBG_TRACE_AFU
                `TRACE(2, ("%t: AFU: Goto STATE IDLE\n", $time))
            `endif
            end
            STATE_RUN: begin
                if (vx_reset) begin
                    // wait until the reset network is ready
					if (vx_reset_ctr == RESET_CTR_WIDTH'(0)) begin
					`ifdef DBG_TRACE_AFU
						`TRACE(2, ("%t: AFU: Begin execution\n", $time))
					`endif
						vx_busy_wait <= 1;
						vx_reset <= 0;
					end
                end else begin
                    if (vx_busy_wait) begin
						// wait until processor goes busy
						if (vx_busy) begin
							vx_busy_wait <= 0;
						end
					end else begin
						// wait until the processor is not busy
						if (~vx_busy) begin
						`ifdef DBG_TRACE_AFU
							`TRACE(2, ("%t: AFU: End execution\n", $time))
                            `TRACE(2, ("%t: AFU: Goto STATE IDLE\n", $time))
						`endif
							state <= STATE_IDLE;
						end
					end
                end
            end
            default:;
            endcase

            // ensure reset network initialization
			if (vx_reset_ctr != RESET_CTR_WIDTH'(0)) begin
				vx_reset_ctr <= vx_reset_ctr - RESET_CTR_WIDTH'(1);
			end
        end
    end

    // AVS Controller /////////////////////////////////////////////////////////

    wire cci_mem_rd_req_valid;
    wire cci_mem_wr_req_valid;
    wire [CCI_RD_QUEUE_DATAW-1:0] cci_rdq_dout;

    wire cci_mem_req_valid;
    wire cci_mem_req_rw;
    wire [CCI_ADDR_WIDTH-1:0] cci_mem_req_addr;
    wire [CCI_DATA_WIDTH-1:0] cci_mem_req_data;
    wire [CCI_ADDR_WIDTH-1:0] cci_mem_req_tag;
    wire cci_mem_req_ready;

    wire cci_mem_rsp_valid;
    wire [CCI_DATA_WIDTH-1:0] cci_mem_rsp_data;
    wire [CCI_ADDR_WIDTH-1:0] cci_mem_rsp_tag;
    wire cci_mem_rsp_ready;

    // adjust VX mnemory interface to be compatible with CCI

    VX_mem_bus_if #(
        .DATA_SIZE  (LMEM_DATA_SIZE),
        .ADDR_WIDTH (CCI_VX_ADDR_WIDTH),
        .TAG_WIDTH  (CCI_VX_TAG_WIDTH)
    ) vx_mem_bus_if[`VX_MEM_PORTS]();

    wire [`VX_MEM_PORTS-1:0] vx_mem_req_valid_qual;
    wire [`VX_MEM_PORTS-1:0] vx_mem_req_ready_qual;

    for (genvar i = 0; i < `VX_MEM_PORTS; ++i) begin : g_vx_mem_adapter
        VX_mem_data_adapter #(
            .SRC_DATA_WIDTH (`VX_MEM_DATA_WIDTH),
            .DST_DATA_WIDTH (LMEM_DATA_WIDTH),
            .SRC_ADDR_WIDTH (`VX_MEM_ADDR_WIDTH),
            .DST_ADDR_WIDTH (CCI_VX_ADDR_WIDTH),
            .SRC_TAG_WIDTH  (`VX_MEM_TAG_WIDTH),
            .DST_TAG_WIDTH  (CCI_VX_TAG_WIDTH),
            .REQ_OUT_BUF    (0),
            .RSP_OUT_BUF    (2)
        ) vx_mem_data_adapter (
            .clk                (clk),
            .reset              (reset),

            .mem_req_valid_in   (vx_mem_req_valid_qual[i]),
            .mem_req_addr_in    (vx_mem_req_addr[i]),
            .mem_req_rw_in      (vx_mem_req_rw[i]),
            .mem_req_byteen_in  (vx_mem_req_byteen[i]),
            .mem_req_data_in    (vx_mem_req_data[i]),
            .mem_req_tag_in     (vx_mem_req_tag[i]),
            .mem_req_ready_in   (vx_mem_req_ready_qual[i]),

            .mem_rsp_valid_in   (vx_mem_rsp_valid[i]),
            .mem_rsp_data_in    (vx_mem_rsp_data[i]),
            .mem_rsp_tag_in     (vx_mem_rsp_tag[i]),
            .mem_rsp_ready_in   (vx_mem_rsp_ready[i]),

            .mem_req_valid_out  (vx_mem_bus_if[i].req_valid),
            .mem_req_addr_out   (vx_mem_bus_if[i].req_data.addr),
            .mem_req_rw_out     (vx_mem_bus_if[i].req_data.rw),
            .mem_req_byteen_out (vx_mem_bus_if[i].req_data.byteen),
            .mem_req_data_out   (vx_mem_bus_if[i].req_data.data),
            .mem_req_tag_out    (vx_mem_bus_if[i].req_data.tag),
            .mem_req_ready_out  (vx_mem_bus_if[i].req_ready),

            .mem_rsp_valid_out  (vx_mem_bus_if[i].rsp_valid),
            .mem_rsp_data_out   (vx_mem_bus_if[i].rsp_data.data),
            .mem_rsp_tag_out    (vx_mem_bus_if[i].rsp_data.tag),
            .mem_rsp_ready_out  (vx_mem_bus_if[i].rsp_ready)
        );
        assign vx_mem_bus_if[i].req_data.flags = '0;
    end

    // adjust CCI mnemory interface to be compatible with VX

    VX_mem_bus_if #(
        .DATA_SIZE  (LMEM_DATA_SIZE),
        .ADDR_WIDTH (CCI_VX_ADDR_WIDTH),
        .TAG_WIDTH  (CCI_VX_TAG_WIDTH)
    ) cci_vx_mem_arb_in_if[2]();

    VX_mem_data_adapter #(
        .SRC_DATA_WIDTH (CCI_DATA_WIDTH),
        .DST_DATA_WIDTH (LMEM_DATA_WIDTH),
        .SRC_ADDR_WIDTH (CCI_ADDR_WIDTH),
        .DST_ADDR_WIDTH (CCI_VX_ADDR_WIDTH),
        .SRC_TAG_WIDTH  (CCI_ADDR_WIDTH),
        .DST_TAG_WIDTH  (CCI_VX_TAG_WIDTH),
        .REQ_OUT_BUF    (0),
        .RSP_OUT_BUF    (0)
    ) cci_mem_data_adapter (
        .clk                (clk),
        .reset              (reset),

        .mem_req_valid_in   (cci_mem_req_valid),
        .mem_req_addr_in    (cci_mem_req_addr),
        .mem_req_rw_in      (cci_mem_req_rw),
        .mem_req_byteen_in  ({CCI_DATA_SIZE{1'b1}}),
        .mem_req_data_in    (cci_mem_req_data),
        .mem_req_tag_in     (cci_mem_req_tag),
        .mem_req_ready_in   (cci_mem_req_ready),

        .mem_rsp_valid_in   (cci_mem_rsp_valid),
        .mem_rsp_data_in    (cci_mem_rsp_data),
        .mem_rsp_tag_in     (cci_mem_rsp_tag),
        .mem_rsp_ready_in   (cci_mem_rsp_ready),

        .mem_req_valid_out  (cci_vx_mem_arb_in_if[1].req_valid),
        .mem_req_addr_out   (cci_vx_mem_arb_in_if[1].req_data.addr),
        .mem_req_rw_out     (cci_vx_mem_arb_in_if[1].req_data.rw),
        .mem_req_byteen_out (cci_vx_mem_arb_in_if[1].req_data.byteen),
        .mem_req_data_out   (cci_vx_mem_arb_in_if[1].req_data.data),
        .mem_req_tag_out    (cci_vx_mem_arb_in_if[1].req_data.tag),
        .mem_req_ready_out  (cci_vx_mem_arb_in_if[1].req_ready),

        .mem_rsp_valid_out  (cci_vx_mem_arb_in_if[1].rsp_valid),
        .mem_rsp_data_out   (cci_vx_mem_arb_in_if[1].rsp_data.data),
        .mem_rsp_tag_out    (cci_vx_mem_arb_in_if[1].rsp_data.tag),
        .mem_rsp_ready_out  (cci_vx_mem_arb_in_if[1].rsp_ready)
    );
    assign cci_vx_mem_arb_in_if[1].req_data.flags = '0;

    // arbitrate between CCI and VX memory interfaces

    `ASSIGN_VX_MEM_BUS_IF(cci_vx_mem_arb_in_if[0], vx_mem_bus_if[0]);

    VX_mem_bus_if #(
        .DATA_SIZE  (LMEM_DATA_SIZE),
        .ADDR_WIDTH (CCI_VX_ADDR_WIDTH),
        .TAG_WIDTH  (AVS_TAG_WIDTH)
    ) cci_vx_mem_arb_out_if[1]();

    VX_mem_arb #(
        .NUM_INPUTS  (2),
        .NUM_OUTPUTS (1),
        .DATA_SIZE   (LMEM_DATA_SIZE),
        .ADDR_WIDTH  (CCI_VX_ADDR_WIDTH),
        .TAG_WIDTH   (CCI_VX_TAG_WIDTH),
        .ARBITER     ("P"), // prioritize VX requests
        .REQ_OUT_BUF (0),
        .RSP_OUT_BUF (0)
    ) mem_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (cci_vx_mem_arb_in_if),
        .bus_out_if (cci_vx_mem_arb_out_if)
    );
    `UNUSED_VAR (cci_vx_mem_arb_out_if[0].req_data.flags)

    // final merged memory interface
    wire                         mem_req_valid [`VX_MEM_PORTS];
    wire                         mem_req_rw [`VX_MEM_PORTS];
    wire [CCI_VX_ADDR_WIDTH-1:0] mem_req_addr [`VX_MEM_PORTS];
    wire [LMEM_DATA_SIZE-1:0]    mem_req_byteen [`VX_MEM_PORTS];
    wire [LMEM_DATA_WIDTH-1:0]   mem_req_data [`VX_MEM_PORTS];
    wire [AVS_TAG_WIDTH-1:0]     mem_req_tag [`VX_MEM_PORTS];
    wire                         mem_req_ready [`VX_MEM_PORTS];

    wire                         mem_rsp_valid [`VX_MEM_PORTS];
    wire [LMEM_DATA_WIDTH-1:0]   mem_rsp_data [`VX_MEM_PORTS];
    wire [AVS_TAG_WIDTH-1:0]     mem_rsp_tag [`VX_MEM_PORTS];
    wire                         mem_rsp_ready [`VX_MEM_PORTS];

    for (genvar i = 0; i < `VX_MEM_PORTS; ++i) begin : g_mem_bus_if
        if (i == 0) begin : g_i0
            // assign port0 to CCI/VX arbiter
            assign mem_req_valid[i] = cci_vx_mem_arb_out_if[i].req_valid;
            assign mem_req_rw[i]    = cci_vx_mem_arb_out_if[i].req_data.rw;
            assign mem_req_addr[i]  = cci_vx_mem_arb_out_if[i].req_data.addr;
            assign mem_req_byteen[i]= cci_vx_mem_arb_out_if[i].req_data.byteen;
            assign mem_req_data[i]  = cci_vx_mem_arb_out_if[i].req_data.data;
            assign mem_req_tag[i]   = cci_vx_mem_arb_out_if[i].req_data.tag;
            assign cci_vx_mem_arb_out_if[i].req_ready = mem_req_ready[i];

            assign cci_vx_mem_arb_out_if[i].rsp_valid     = mem_rsp_valid[i];
            assign cci_vx_mem_arb_out_if[i].rsp_data.data = mem_rsp_data[i];
            assign cci_vx_mem_arb_out_if[i].rsp_data.tag  = mem_rsp_tag[i];
            assign mem_rsp_ready[i] = cci_vx_mem_arb_out_if[i].rsp_ready;
        end else begin : g_i
            // assign other ports to VX memory bus
            assign mem_req_valid[i] = vx_mem_bus_if[i].req_valid;
            assign mem_req_rw[i]    = vx_mem_bus_if[i].req_data.rw;
            assign mem_req_addr[i]  = vx_mem_bus_if[i].req_data.addr;
            assign mem_req_byteen[i]= vx_mem_bus_if[i].req_data.byteen;
            assign mem_req_data[i]  = vx_mem_bus_if[i].req_data.data;
            assign mem_req_tag[i]   = AVS_TAG_WIDTH'(vx_mem_bus_if[i].req_data.tag);
            assign vx_mem_bus_if[i].req_ready = mem_req_ready[i];

            assign vx_mem_bus_if[i].rsp_valid     = mem_rsp_valid[i];
            assign vx_mem_bus_if[i].rsp_data.data = mem_rsp_data[i];
            assign vx_mem_bus_if[i].rsp_data.tag  = CCI_VX_TAG_WIDTH'(mem_rsp_tag[i]);
            assign mem_rsp_ready[i] = vx_mem_bus_if[i].rsp_ready;
        end
    end

    // convert merged memory interface to AVS
    VX_avs_adapter #(
        .DATA_WIDTH    (LMEM_DATA_WIDTH),
        .ADDR_WIDTH_IN (CCI_VX_ADDR_WIDTH),
        .ADDR_WIDTH_OUT(LMEM_ADDR_WIDTH),
        .BURST_WIDTH   (LMEM_BURST_CTRW),
        .NUM_PORTS_IN  (`VX_MEM_PORTS),
        .NUM_BANKS_OUT (NUM_LOCAL_MEM_BANKS),
        .TAG_WIDTH     (AVS_TAG_WIDTH),
        .RD_QUEUE_SIZE (AVS_RD_QUEUE_SIZE),
        .INTERLEAVE    (`PLATFORM_MEMORY_INTERLEAVE),
        .REQ_OUT_BUF   (2), // always needed due to CCI/VX arbiter
        .RSP_OUT_BUF   ((`VX_MEM_PORTS > 1 || NUM_LOCAL_MEM_BANKS > 1) ? 2 : 0)
    ) avs_adapter (
        .clk              (clk),
        .reset            (reset),

        // Memory request
        .mem_req_valid    (mem_req_valid),
        .mem_req_rw       (mem_req_rw),
        .mem_req_byteen   (mem_req_byteen),
        .mem_req_addr     (mem_req_addr),
        .mem_req_data     (mem_req_data),
        .mem_req_tag      (mem_req_tag),
        .mem_req_ready    (mem_req_ready),

        // Memory response
        .mem_rsp_valid    (mem_rsp_valid),
        .mem_rsp_data     (mem_rsp_data),
        .mem_rsp_tag      (mem_rsp_tag),
        .mem_rsp_ready    (mem_rsp_ready),

        // AVS bus
        .avs_writedata    (avs_writedata),
        .avs_readdata     (avs_readdata),
        .avs_address      (avs_address),
        .avs_waitrequest  (avs_waitrequest),
        .avs_write        (avs_write),
        .avs_read         (avs_read),
        .avs_byteenable   (avs_byteenable),
        .avs_burstcount   (avs_burstcount),
        .avs_readdatavalid(avs_readdatavalid)
    );

    // CCI-P Read Request /////////////////////////////////////////////////////

    reg [CCI_ADDR_WIDTH-1:0] cci_mem_wr_req_ctr;
    wire [CCI_ADDR_WIDTH-1:0] cci_mem_wr_req_addr;
    reg [CCI_ADDR_WIDTH-1:0] cci_mem_wr_req_addr_base;

    wire cci_rd_req_fire;
    t_ccip_clAddr cci_rd_req_addr;
    reg cci_rd_req_valid, cci_rd_req_wait;
    reg [CCI_ADDR_WIDTH-1:0] cci_rd_req_ctr;
    wire [CCI_ADDR_WIDTH-1:0] cci_rd_req_ctr_next;
    wire [CCI_RD_QUEUE_TAGW-1:0] cci_rd_req_tag;

    wire [CCI_RD_QUEUE_TAGW-1:0] cci_rd_rsp_tag;
    reg [CCI_RD_QUEUE_TAGW-1:0] cci_rd_rsp_ctr;

    wire cci_rdq_push, cci_rdq_pop;
    wire [CCI_RD_QUEUE_DATAW-1:0] cci_rdq_din;
    wire cci_rdq_empty;

    always @(*) begin
        af2cp_sTxPort.c0.valid       = cci_rd_req_fire;
        af2cp_sTxPort.c0.hdr         = t_ccip_c0_ReqMemHdr'(0);
        af2cp_sTxPort.c0.hdr.address = cci_rd_req_addr;
        af2cp_sTxPort.c0.hdr.mdata   = t_ccip_mdata'(cci_rd_req_tag);
    end

    wire cci_mem_wr_req_fire = cci_mem_wr_req_valid && cci_mem_req_ready;

    wire cci_rd_rsp_fire = cp2af_sRxPort.c0.rspValid
                        && (cp2af_sRxPort.c0.hdr.resp_type == eRSP_RDLINE);

    assign cci_rd_req_tag = CCI_RD_QUEUE_TAGW'(cci_rd_req_ctr);
    assign cci_rd_rsp_tag = CCI_RD_QUEUE_TAGW'(cp2af_sRxPort.c0.hdr.mdata);

    assign cci_rdq_push = cci_rd_rsp_fire;
    assign cci_rdq_pop  = cci_mem_wr_req_fire;
    assign cci_rdq_din  = {cp2af_sRxPort.c0.data, cci_mem_wr_req_addr_base + CCI_ADDR_WIDTH'(cci_rd_rsp_tag)};

    wire [`CLOG2(CCI_RD_QUEUE_SIZE+1)-1:0] cci_pending_reads;
    wire cci_pending_reads_full;
    VX_pending_size #(
        .SIZE (CCI_RD_QUEUE_SIZE)
    ) cci_rd_pending_size (
        .clk   (clk),
        .reset (reset),
        .incr  (cci_rd_req_fire),
        .decr  (cci_rdq_pop),
        `UNUSED_PIN (empty),
        `UNUSED_PIN (alm_empty),
        .full  (cci_pending_reads_full),
        `UNUSED_PIN (alm_full),
        .size  (cci_pending_reads)
    );

    `UNUSED_VAR (cci_pending_reads)

    assign cci_rd_req_ctr_next = cci_rd_req_ctr + CCI_ADDR_WIDTH'(cci_rd_req_fire ? 1 : 0);

    assign cci_rd_req_fire = cci_rd_req_valid && !(cci_rd_req_wait || cci_pending_reads_full);

    assign cci_mem_wr_req_valid = !cci_rdq_empty;

    assign cci_mem_wr_req_addr = cci_rdq_dout[CCI_ADDR_WIDTH-1:0];

    // Send read requests to CCI
    always @(posedge clk) begin
        if (reset) begin
            cci_rd_req_valid <= 0;
            cci_rd_req_wait  <= 0;
        end else begin
            if ((STATE_IDLE == state)
             && (CMD_MEM_WRITE == cmd_type)) begin
                cci_rd_req_valid <= (cmd_data_size != 0);
                cci_rd_req_wait  <= 0;
            end

            cci_rd_req_valid <= (STATE_MEM_WRITE == state)
                             && (cci_rd_req_ctr_next != cmd_data_size)
                             && !cp2af_sRxPort.c0TxAlmFull;

            if (cci_rd_req_fire
             && (cci_rd_req_tag == CCI_RD_QUEUE_TAGW'(CCI_RD_WINDOW_SIZE-1))) begin
                cci_rd_req_wait <= 1; // end current request batch
            end

            if (cci_rd_rsp_fire
             && (cci_rd_rsp_ctr == CCI_RD_QUEUE_TAGW'(CCI_RD_WINDOW_SIZE-1))) begin
                cci_rd_req_wait <= 0; // begin new request batch
            end
        end

        if ((STATE_IDLE == state)
         && (CMD_MEM_WRITE == cmd_type)) begin
            cci_rd_req_addr    <= cmd_io_addr;
            cci_rd_req_ctr     <= '0;
            cci_rd_rsp_ctr     <= '0;
            cci_mem_wr_req_ctr <= '0;
            cci_mem_wr_req_addr_base <= cmd_mem_addr;
            cmd_mem_wr_done     <= 0;
        end

        if (cci_rd_req_fire) begin
            cci_rd_req_addr <= cci_rd_req_addr + 1;
            cci_rd_req_ctr  <= cci_rd_req_ctr + $bits(cci_rd_req_ctr)'(1);
        `ifdef DBG_TRACE_AFU
            `TRACE(2, ("%t: AFU: CCI Rd Req: addr=0x%0h, tag=0x%0h, rem=%0d, pending=%0d\n", $time, cci_rd_req_addr, cci_rd_req_tag, (cmd_data_size - cci_rd_req_ctr - 1), cci_pending_reads))
        `endif
        end

        if (cci_rd_rsp_fire) begin
            cci_rd_rsp_ctr <= cci_rd_rsp_ctr + CCI_RD_QUEUE_TAGW'(1);
            if (CCI_RD_QUEUE_TAGW'(cci_rd_rsp_ctr) == CCI_RD_QUEUE_TAGW'(CCI_RD_WINDOW_SIZE-1)) begin
                cci_mem_wr_req_addr_base <= cci_mem_wr_req_addr_base + CCI_ADDR_WIDTH'(CCI_RD_WINDOW_SIZE);
            end
        `ifdef DBG_TRACE_AFU
            `TRACE(2, ("%t: AFU: CCI Rd Rsp: idx=%0d, ctr=%0d, data=0x%h\n", $time, cci_rd_rsp_tag, cci_rd_rsp_ctr, cp2af_sRxPort.c0.data))
        `endif
        end

        if (cci_rdq_pop) begin
        `ifdef DBG_TRACE_AFU
            `TRACE(2, ("%t: AFU: CCI Rd Queue Pop: pending=%0d\n", $time, cci_pending_reads))
        `endif
        end

        if (cci_mem_wr_req_fire) begin
            cci_mem_wr_req_ctr <= cci_mem_wr_req_ctr + CCI_ADDR_WIDTH'(1);
            if (cci_mem_wr_req_ctr == (cmd_data_size-1)) begin
                cmd_mem_wr_done <= 1;
            end
        end
    end

    VX_fifo_queue #(
        .DATAW (CCI_RD_QUEUE_DATAW),
        .DEPTH (CCI_RD_QUEUE_SIZE)
    ) cci_rd_req_queue (
        .clk      (clk),
        .reset    (reset),
        .push     (cci_rdq_push),
        .pop      (cci_rdq_pop),
        .data_in  (cci_rdq_din),
        .data_out (cci_rdq_dout),
        .empty    (cci_rdq_empty),
        `UNUSED_PIN (full),
        `UNUSED_PIN (alm_empty),
        `UNUSED_PIN (alm_full),
        `UNUSED_PIN (size)
    );

`DEBUG_BLOCK(
    reg [CCI_RD_WINDOW_SIZE-1:0] dbg_cci_rd_rsp_mask;
    always @(posedge clk) begin
        if (reset) begin
            dbg_cci_rd_rsp_mask <= '0;
        end else begin
            if (cci_rd_rsp_fire) begin
                if (cci_rd_rsp_ctr == 0) begin
                    dbg_cci_rd_rsp_mask <= (CCI_RD_WINDOW_SIZE'(1) << cci_rd_rsp_tag);
                end else begin
                    assert(!dbg_cci_rd_rsp_mask[cci_rd_rsp_tag]);
                    dbg_cci_rd_rsp_mask[cci_rd_rsp_tag] <= 1;
                end
            end
        end
    end
)

    // CCI-P Write Request ////////////////////////////////////////////////////

    reg [CCI_ADDR_WIDTH-1:0] cci_mem_rd_req_ctr;
    reg [CCI_ADDR_WIDTH-1:0] cci_mem_rd_req_addr;
    reg cci_mem_rd_req_done;

    reg [CCI_ADDR_WIDTH-1:0] cci_wr_req_ctr;
    reg           cci_wr_req_fire;
    t_ccip_clAddr cci_wr_req_addr;
    t_ccip_clData cci_wr_req_data;
    reg cci_wr_req_done;

    always @(*) begin
        af2cp_sTxPort.c1.valid       = cci_wr_req_fire;
        af2cp_sTxPort.c1.hdr         = t_ccip_c1_ReqMemHdr'(0);
        af2cp_sTxPort.c1.hdr.sop     = 1; // single line write mode
        af2cp_sTxPort.c1.hdr.address = cci_wr_req_addr;
        af2cp_sTxPort.c1.data        = cci_wr_req_data;
    end

    wire cci_mem_rd_req_fire = cci_mem_rd_req_valid && cci_mem_req_ready;
    wire cci_mem_rd_rsp_fire = cci_mem_rsp_valid && cci_mem_rsp_ready;

    wire cci_wr_rsp_fire = (STATE_MEM_READ == state)
                        && cp2af_sRxPort.c1.rspValid
                        && (cp2af_sRxPort.c1.hdr.resp_type == eRSP_WRLINE);

    wire [`CLOG2(CCI_RW_PENDING_SIZE+1)-1:0] cci_pending_writes;
    wire cci_pending_writes_empty;
    wire cci_pending_writes_full;

    VX_pending_size #(
        .SIZE (CCI_RW_PENDING_SIZE)
    ) cci_wr_pending_size (
        .clk   (clk),
        .reset (reset),
        .incr  (cci_mem_rd_rsp_fire),
        .decr  (cci_wr_rsp_fire),
        .empty (cci_pending_writes_empty),
        `UNUSED_PIN (alm_empty),
        .full  (cci_pending_writes_full),
        `UNUSED_PIN (alm_full),
        .size  (cci_pending_writes)
    );

    `UNUSED_VAR (cci_pending_writes)

    assign cci_mem_rd_req_valid = (STATE_MEM_READ == state) && ~cci_mem_rd_req_done;

    assign cci_mem_rsp_ready = ~cp2af_sRxPort.c1TxAlmFull && ~cci_pending_writes_full;

    assign cmd_mem_rd_done = cci_wr_req_done && cci_pending_writes_empty;

    // Send write requests to CCI
    always @(posedge clk) begin
        if (reset) begin
            cci_wr_req_fire <= 0;
        end else begin
            cci_wr_req_fire <= cci_mem_rd_rsp_fire;
        end

        if ((STATE_IDLE == state)
        &&  (CMD_MEM_READ == cmd_type)) begin
            cci_mem_rd_req_ctr  <= '0;
            cci_mem_rd_req_addr <= cmd_mem_addr;
            cci_mem_rd_req_done <= 0;
            cci_wr_req_ctr      <= cmd_data_size;
            cci_wr_req_done     <= 0;
        end

        if (cci_mem_rd_req_fire) begin
            cci_mem_rd_req_addr <= cci_mem_rd_req_addr + CCI_ADDR_WIDTH'(1);
            cci_mem_rd_req_ctr  <= cci_mem_rd_req_ctr + CCI_ADDR_WIDTH'(1);
            if (cci_mem_rd_req_ctr == (cmd_data_size-1)) begin
                cci_mem_rd_req_done <= 1;
            end
        end

        cci_wr_req_addr <= cmd_io_addr + t_ccip_clAddr'(cci_mem_rsp_tag);
        cci_wr_req_data <= t_ccip_clData'(cci_mem_rsp_data);

        if (cci_wr_req_fire) begin
            `ASSERT(cci_wr_req_ctr != 0, ("runtime error"));
            cci_wr_req_ctr <= cci_wr_req_ctr - CCI_ADDR_WIDTH'(1);
            if (cci_wr_req_ctr == CCI_ADDR_WIDTH'(1)) begin
            cci_wr_req_done <= 1;
            end
        `ifdef DBG_TRACE_AFU
            `TRACE(2, ("%t: AFU: CCI Wr Req: addr=0x%0h, rem=%0d, pending=%0d, data=0x%h\n", $time, cci_wr_req_addr, (cci_wr_req_ctr - 1), cci_pending_writes, af2cp_sTxPort.c1.data))
        `endif
        end

        if (cci_wr_rsp_fire) begin
        `ifdef DBG_TRACE_AFU
            `TRACE(2, ("%t: AFU: CCI Wr Rsp: pending=%0d\n", $time, cci_pending_writes))
        `endif
        end
    end

    //--

    assign cci_mem_req_rw = state[0];
    `STATIC_ASSERT(STATE_MEM_WRITE == 1, ("invalid value")); // 01
    `STATIC_ASSERT(STATE_MEM_READ  == 2, ("invalid value")); // 10

    assign cci_mem_req_valid = cci_mem_req_rw ? cci_mem_wr_req_valid : cci_mem_rd_req_valid;
    assign cci_mem_req_addr  = cci_mem_req_rw ? cci_mem_wr_req_addr : cci_mem_rd_req_addr;
    assign cci_mem_req_data  = cci_rdq_dout[CCI_RD_QUEUE_DATAW-1:CCI_ADDR_WIDTH];
    assign cci_mem_req_tag   = cci_mem_req_rw ? cci_mem_wr_req_ctr : cci_mem_rd_req_ctr;

    // Vortex /////////////////////////////////////////////////////////////////

    wire vx_dcr_wr_valid = (STATE_DCR_WRITE == state);
    wire [`VX_DCR_ADDR_WIDTH-1:0] vx_dcr_wr_addr = cmd_dcr_addr;
    wire [`VX_DCR_DATA_WIDTH-1:0] vx_dcr_wr_data = cmd_dcr_data;

    `SCOPE_IO_SWITCH (2);

    Vortex vortex (
        `SCOPE_IO_BIND  (1)

        .clk            (clk),
        .reset          (vx_reset),

        // Memory request
        .mem_req_valid  (vx_mem_req_valid),
        .mem_req_rw     (vx_mem_req_rw),
        .mem_req_byteen (vx_mem_req_byteen),
        .mem_req_addr   (vx_mem_req_addr),
        .mem_req_data   (vx_mem_req_data),
        .mem_req_tag    (vx_mem_req_tag),
        .mem_req_ready  (vx_mem_req_ready),

        // Memory response
        .mem_rsp_valid  (vx_mem_rsp_valid),
        .mem_rsp_data   (vx_mem_rsp_data),
        .mem_rsp_tag    (vx_mem_rsp_tag),
        .mem_rsp_ready  (vx_mem_rsp_ready),

        // DCR write request
        .dcr_wr_valid   (vx_dcr_wr_valid),
        .dcr_wr_addr    (vx_dcr_wr_addr),
        .dcr_wr_data    (vx_dcr_wr_data),

        // Status
        .busy           (vx_busy)
    );

    // COUT HANDLING //////////////////////////////////////////////////////////

    for (genvar i = 0; i < `VX_MEM_PORTS; ++i) begin : g_cout

        wire [COUT_TID_WIDTH-1:0] cout_tid;

        VX_onehot_encoder #(
            .N (`VX_MEM_BYTEEN_WIDTH)
        ) cout_tid_enc (
            .data_in  (vx_mem_req_byteen[i]),
            .data_out (cout_tid),
            `UNUSED_PIN (valid_out)
        );

        wire [`VX_MEM_BYTEEN_WIDTH-1:0][7:0] vx_mem_req_data_m = vx_mem_req_data[i];

        wire [7:0] cout_char = vx_mem_req_data_m[cout_tid];

        wire [`VX_MEM_ADDR_WIDTH-1:0] io_cout_addr_b = `VX_MEM_ADDR_WIDTH'(`IO_COUT_ADDR >> `CLOG2(`MEM_BLOCK_SIZE));

        wire vx_mem_is_cout = (vx_mem_req_addr[i] == io_cout_addr_b);

        assign vx_mem_req_valid_qual[i] = vx_mem_req_valid[i] && ~vx_mem_is_cout;
        assign vx_mem_req_ready[i] = vx_mem_is_cout ? ~cout_q_full[i] : vx_mem_req_ready_qual[i];

        wire cout_q_push = vx_mem_req_valid[i] && vx_mem_is_cout && ~cout_q_full[i];

        VX_fifo_queue #(
            .DATAW (COUT_QUEUE_DATAW),
            .DEPTH (COUT_QUEUE_SIZE)
        ) cout_queue (
            .clk      (clk),
            .reset    (reset),
            .push     (cout_q_push),
            .pop      (cout_q_pop[i]),
            .data_in  ({cout_tid, cout_char}),
            .data_out (cout_q_dout[i]),
            .empty    (cout_q_empty[i]),
            .full     (cout_q_full[i]),
            `UNUSED_PIN (alm_empty),
            `UNUSED_PIN (alm_full),
            `UNUSED_PIN (size)
        );
    end

    // SCOPE //////////////////////////////////////////////////////////////////

`ifdef DBG_SCOPE_AFU
    reg [STATE_WIDTH-1:0] state_prev;
    always @(posedge clk) begin
        state_prev <= state;
    end
    wire state_changed   = (state != state_prev);
    wire vx_mem_req_fire = vx_mem_req_valid[0] && vx_mem_req_ready[0];
    wire vx_mem_rsp_fire = vx_mem_rsp_valid[0] && vx_mem_rsp_ready[0];
    wire avs_req_fire    = (avs_write[0] || avs_read[0]) && ~avs_waitrequest[0];
    wire reset_negedge;
    `NEG_EDGE (reset_negedge, reset);
    `SCOPE_TAP (0, 0, {
            vx_reset,
            vx_busy,
            vx_mem_req_valid[0],
            vx_mem_req_ready[0],
            vx_mem_rsp_valid[0],
            vx_mem_rsp_ready[0],
            avs_read[0],
            avs_write[0],
            avs_waitrequest[0],
            cp2af_sRxPort.c0.rspValid,
            cp2af_sRxPort.c1.rspValid,
            af2cp_sTxPort.c0.valid,
            af2cp_sTxPort.c1.valid,
            cp2af_sRxPort.c0TxAlmFull,
            cp2af_sRxPort.c1TxAlmFull
        },{
            state_changed,
            vx_dcr_wr_valid, // ack-free
            avs_readdatavalid[0], // ack-free
            cp2af_sRxPort.c0.mmioRdValid, // ack-free
            cp2af_sRxPort.c0.mmioWrValid, // ack-free
            af2cp_sTxPort.c2.mmioRdValid, // ack-free
            cp2af_sRxPort.c0.rspValid, // ack-free
            cp2af_sRxPort.c1.rspValid, // ack-free
            cci_rd_req_fire,
            cci_wr_req_fire,
            avs_req_fire,
            vx_mem_req_fire,
            vx_mem_rsp_fire
        },{
            cmd_type,
            state,
            vx_mem_req_rw[0],
            vx_mem_req_byteen[0],
            vx_mem_req_addr[0],
            vx_mem_req_data[0],
            vx_mem_req_tag[0],
            vx_mem_rsp_data[0],
            vx_mem_rsp_tag[0],
            vx_dcr_wr_addr,
            vx_dcr_wr_data,
            mmio_req_hdr.address,
            cp2af_sRxPort.c0.hdr.mdata,
            af2cp_sTxPort.c0.hdr.address,
            af2cp_sTxPort.c0.hdr.mdata,
            af2cp_sTxPort.c1.hdr.address,
            avs_address[0],
            avs_byteenable[0],
            avs_burstcount[0],
            cci_mem_rd_req_ctr,
            cci_mem_wr_req_ctr,
            cci_rd_req_ctr,
            cci_rd_rsp_ctr,
            cci_wr_req_ctr
        },
        reset_negedge, 1'b0, 4096
	);
`else
    `SCOPE_IO_UNUSED(0)
`endif

    ///////////////////////////////////////////////////////////////////////////

`ifdef DBG_TRACE_AFU
    always @(posedge clk) begin
        for (integer i = 0; i < NUM_LOCAL_MEM_BANKS; ++i) begin
            if (avs_write[i] && ~avs_waitrequest[i]) begin
                `TRACE(2, ("%t: AVS Wr Req[%0d]: addr=0x%0h, byteen=0x%0h, burst=0x%0h, data=0x%h\n", $time, i, `TO_FULL_ADDR(avs_address[i]), avs_byteenable[i], avs_burstcount[i], avs_writedata[i]))
            end
            if (avs_read[i] && ~avs_waitrequest[i]) begin
                `TRACE(2, ("%t: AVS Rd Req[%0d]: addr=0x%0h, byteen=0x%0h,  burst=0x%0h\n", $time, i, `TO_FULL_ADDR(avs_address[i]), avs_byteenable[i], avs_burstcount[i]))
            end
            if (avs_readdatavalid[i]) begin
                `TRACE(2, ("%t: AVS Rd Rsp[%0d]: data=0x%h\n", $time, i, avs_readdata[i]))
            end
        end
    end
`endif

endmodule
