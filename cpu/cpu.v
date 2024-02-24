/* TinyQV: A RISC-V core designed to use minimal area.
  
   This CPU module interfaces with memory, the instruction decoder and the core.
 */

module tinyqv_cpu #(parameter NUM_REGS=16, parameter REG_ADDR_BITS=4) (
    input clk,
    input rstn,

    output [23:1] instr_addr,
    output        instr_fetch_restart,
    output        instr_fetch_stall,

    input         instr_fetch_started,
    input         instr_fetch_stopped,
    input  [15:0] instr_data_in,
    input         instr_ready,

    input  [3:0]  interrupt_req,

    output reg [27:0] data_addr,
    output reg [1:0]  data_write_n, // 11 = no write, 00 = 8-bits, 01 = 16-bits, 10 = 32-bits
    output reg [1:0]  data_read_n,  // 11 = no read,  00 = 8-bits, 01 = 16-bits, 10 = 32-bits
    output reg [31:0] data_out,

    input         data_ready,  // Transaction complete/data request can be modified.
    input  [31:0] data_in
);

    // Decoder interface
    // _de suffix used for decoded instruction that will be registered
    wire [31:0] instr;

    wire [31:0] imm_de;

    wire is_load_de;
    wire is_alu_imm_de;
    wire is_auipc_de;
    wire is_store_de;
    wire is_alu_reg_de;
    wire is_lui_de;
    wire is_branch_de;
    wire is_jalr_de;
    wire is_jal_de;
    wire is_system_de;

    wire [2:1] instr_len_de;
    wire [3:0] alu_op_de;
    wire [2:0] mem_op_de;

    wire [3:0] rs1_de;
    wire [3:0] rs2_de;
    wire [3:0] rd_de;

    tinyqv_decoder i_decoder(
        instr, 
        imm_de,

        is_load_de,
        is_alu_imm_de,
        is_auipc_de,
        is_store_de,
        is_alu_reg_de,
        is_lui_de,
        is_branch_de,
        is_jalr_de,
        is_jal_de,
        is_system_de,

        instr_len_de,
        alu_op_de,  // See tinyqv_alu for format
        mem_op_de,

        rs1_de,
        rs2_de,
        rd_de);

    reg [31:0] imm;

    reg is_load;
    reg is_alu_imm;
    reg is_auipc;
    reg is_store;
    reg is_alu_reg;
    reg is_lui;
    reg is_branch;
    reg is_jalr;
    reg is_jal;
    reg is_system;

    reg [2:1] instr_len;
    reg [3:0] alu_op;
    reg [2:0] mem_op;

    reg [3:0] rs1;
    reg [3:0] rs2;
    reg [3:0] rd;

    reg instr_valid;

    wire [31:0] pc;
    wire [31:0] next_pc_for_core;

    wire [27:0] addr_out;
    wire address_ready;
    wire instr_complete_core;
    wire branch;

    reg [4:2] counter_hi;
    wire [4:0] counter = {counter_hi, 2'b00};

    always @(posedge clk) begin
        if (!rstn) begin
            instr_valid <= 0;
            is_load <= 0;
            is_alu_imm <= 0;
            is_auipc <= 0;
            is_store <= 0;
            is_alu_reg <= 0;
            is_lui <= 0;
            is_branch <= 0;
            is_jalr <= 0;
            is_jal <= 0;
            is_system <= 0;
            instr_len <= 2'b10;
        end else if ((counter_hi == 3'd7 && !instr_valid) || instr_complete) begin
            if ({1'b0,instr_len_de} <= instr_avail_len) begin
                imm <= imm_de;
                is_load <= is_load_de;
                is_alu_imm <= is_alu_imm_de;
                is_auipc <= is_auipc_de;
                is_store <= is_store_de;
                is_alu_reg <= is_alu_reg_de;
                is_lui <= is_lui_de;
                is_branch <= is_branch_de;
                is_jalr <= is_jalr_de;
                is_jal <= is_jal_de;
                is_system <= is_system_de;
                instr_len <= instr_len_de;
                alu_op <= alu_op_de;
                mem_op <= mem_op_de;
                rs1 <= rs1_de;
                rs2 <= rs2_de;
                rd <= rd_de;
                instr_valid <= !branch;
            end else begin
                instr_valid <= 0;
            end
        end
    end

    wire [3:0] data_out_slice;
    reg data_ready_latch;
    reg data_ready_core;
    always @(posedge clk) begin
        if (!rstn) begin
            counter_hi <= 0;
            data_ready_core <= 0;
            data_ready_latch <= 0;
        end else begin
            counter_hi <= counter_hi + 1;

            if (counter_hi == 3'd7) begin
                data_ready_latch <= 0;
                if (data_ready || data_ready_latch) begin
                    data_ready_core <= 1;
                end else begin
                    data_ready_core <= 0;
                end
            end else if (!data_ready_latch) begin
                data_ready_latch <= data_ready;
            end
        end
    end

    always @(posedge clk) begin
        if (!rstn) begin
            // Only need to reset the pins that determine how
            // the address is routed
            data_addr[27:24] <= 4'b000;
        end else if (address_ready) begin
            data_addr <= addr_out;
        end
    end

    reg no_write_in_progress;
    always @(posedge clk) begin
        if (!rstn) begin
            data_write_n <= 2'b11;
            no_write_in_progress <= 1;
        end else if (is_store && address_ready) begin
            data_write_n <= mem_op[1:0];
            no_write_in_progress <= 0;
        end else if (data_ready) begin
            data_write_n <= 2'b11;
            if (counter_hi == 3'b111) no_write_in_progress <= 1;
        end else if (counter_hi == 3'b111) begin
            no_write_in_progress <= data_write_n == 2'b11;
        end
    end

    always @(posedge clk) begin
        if (is_store && no_write_in_progress) begin
            data_out[counter+:4] <= data_out_slice;
        end
    end

    reg load_started;
    always @(posedge clk) begin
        if (is_load) begin
            if (address_ready) begin
                data_read_n <= mem_op[1:0]; 
                load_started <= 1;
            end 
            if (data_ready && load_started) begin
                data_read_n <= 2'b11;
            end 
        end else begin
            data_read_n <= 2'b11;
            load_started <= 0;
        end
    end

    wire stall_core = !instr_valid || ((is_store || is_load) && !no_write_in_progress);
    wire interrupt_pending;
    reg interrupt_core;
    always @(posedge clk) begin
        if (!rstn)
            interrupt_core <= 0;
        else if (instr_complete_core)
            interrupt_core <= interrupt_pending;
    end

    tinyqv_core #(.REG_ADDR_BITS(REG_ADDR_BITS), .NUM_REGS(NUM_REGS))  i_core(
        clk,
        rstn,
        
        imm[counter+:4],
        imm[11:0],

        is_load && instr_valid && no_write_in_progress,
        is_alu_imm && instr_valid,
        is_auipc && instr_valid,
        is_store && instr_valid && no_write_in_progress,
        is_alu_reg && instr_valid,
        is_lui && instr_valid,
        is_branch && instr_valid,
        is_jalr && instr_valid,
        is_jal && instr_valid,
        is_system && instr_valid,
        interrupt_core,
        stall_core && !interrupt_core,

        alu_op,
        mem_op,

        rs1,
        rs2,
        rd,

        counter[4:2],
        pc[counter+:4],
        next_pc_for_core[counter+:4],
        data_in[counter+:4],
        data_ready_core,

        data_out_slice,
        addr_out,
        address_ready,
        instr_complete_core,
        branch,

        interrupt_req,
        interrupt_pending
        );

    /////// Instruction fetch ///////

    reg [15:0] instr_data[0:3];

    reg [23:3] instr_data_start;

    reg [2:1] pc_offset;
    reg [3:1] instr_write_offset;

    reg instr_fetch_running;

    wire instr_complete = instr_complete_core && !stall_core;

    wire [3:1] next_pc_offset = {1'b0, pc_offset} + {1'b0, instr_len};
    wire [23:0] next_pc = {instr_data_start, 3'b000} + {20'd0, next_pc_offset, 1'b0};
    wire pc_wrap = next_pc_offset[3] && instr_complete;
    wire [3:1] instr_avail_len = instr_write_offset - (instr_valid ? next_pc_offset : {1'b0, pc_offset});

    wire [3:1] next_instr_write_offset = instr_write_offset + (instr_ready && instr_fetch_running ? 3'b001 : 3'b000) - (pc_wrap ? 3'b100 : 3'b000);
    wire next_instr_stall = (next_instr_write_offset == {1'b1, pc_offset});

    always @(posedge clk) begin
        if (!rstn) begin
            instr_data[0][1:0] <= 2'b11;
            instr_data[1][1:0] <= 2'b11;
            instr_data[2][1:0] <= 2'b11;
            instr_data[3][1:0] <= 2'b11;
            instr_data_start <= 0;
            pc_offset <= 0;
            instr_write_offset <= 0;
            instr_fetch_running <= 0;

        end else begin

            if (branch) begin
                instr_data_start <= addr_out[23:3];
                instr_write_offset <= {1'b0, addr_out[2:1]};
                pc_offset <= addr_out[2:1];
                instr_fetch_running <= 0;
            end
            else begin
                if (instr_fetch_started)      instr_fetch_running <= 1;
                else if (instr_fetch_stopped) instr_fetch_running <= 0;

                instr_write_offset <= next_instr_write_offset;

                if (instr_complete) begin
                    pc_offset <= next_pc_offset[2:1];
                    instr_data_start <= next_pc[23:3];
                end
                if (instr_ready && instr_fetch_running) begin
                    instr_data[instr_write_offset[2:1]] <= instr_data_in;
                end
            end
        end
    end

    // Make sure instr_fetch_restart pulses low on branch
    assign instr_fetch_restart = !instr_fetch_running && !branch;
    assign instr_fetch_stall = next_instr_stall;

    assign instr_addr = {instr_data_start, 2'b00} + {20'd0, instr_write_offset};

    /* verilator lint_off WIDTHTRUNC */
    wire [2:1] pc_offset_hi = pc_offset + 2'b01;
    wire [2:1] next_pc_offset_hi = next_pc_offset + 2'b01;
    /* verilator lint_on WIDTHTRUNC */

    assign instr = instr_valid ? {instr_data[next_pc_offset_hi], instr_data[next_pc_offset[2:1]]} : {instr_data[pc_offset_hi], instr_data[pc_offset]};
    assign pc = {8'h00, instr_data_start, pc_offset, 1'b0};
    assign next_pc_for_core = {8'h00, next_pc};

endmodule
