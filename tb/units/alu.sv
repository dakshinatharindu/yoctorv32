// =============================================================================
// tb/alu/tb_alu.sv
// =============================================================================
// Self-checking testbench for rtl/core/execute/alu.sv
// - Directed corner tests + randomized tests
// - Uses core_pkg::alu_op_e and core_pkg::xlen_t
// - Exits with $fatal on failure (good for CI/regress)
// =============================================================================

`timescale 1ns / 1ps

module tb_alu;

  import core_pkg::*;

  // DUT signals
  xlen_t a, b;
  alu_op_e op;
  xlen_t   y;
  logic eq, lt, ltu;

  // Instantiate DUT
  alu dut (
      .a  (a),
      .b  (b),
      .op (op),
      .y  (y),
      .eq (eq),
      .lt (lt),
      .ltu(ltu)
  );

  // ---------------------------------------------------------------------------
  // Reference model (golden)
  // ---------------------------------------------------------------------------
  function automatic xlen_t ref_y(input xlen_t ra, input xlen_t rb, input alu_op_e rop);
    logic signed [XLEN-1:0] ra_s, rb_s;
    logic [4:0] shamt;
    ra_s  = signed'(ra);
    rb_s  = signed'(rb);
    shamt = rb[4:0];

    unique case (rop)
      ALU_ADD:    ref_y = ra + rb;
      ALU_SUB:    ref_y = ra - rb;
      ALU_AND:    ref_y = ra & rb;
      ALU_OR:     ref_y = ra | rb;
      ALU_XOR:    ref_y = ra ^ rb;
      ALU_SLL:    ref_y = ra << shamt;
      ALU_SRL:    ref_y = ra >> shamt;
      ALU_SRA:    ref_y = xlen_t'(ra_s >>> shamt);
      ALU_SLT:    ref_y = xlen_t'({{(XLEN - 1) {1'b0}}, (ra_s < rb_s)});
      ALU_SLTU:   ref_y = xlen_t'({{(XLEN - 1) {1'b0}}, (ra < rb)});
      ALU_COPY_A: ref_y = ra;
      ALU_COPY_B: ref_y = rb;
      ALU_ZERO:   ref_y = '0;
      default:    ref_y = '0;
    endcase
  endfunction

  function automatic logic ref_eq(input xlen_t ra, input xlen_t rb);
    return (ra == rb);
  endfunction

  function automatic logic ref_lt(input xlen_t ra, input xlen_t rb);
    return (signed'(ra) < signed'(rb));
  endfunction

  function automatic logic ref_ltu(input xlen_t ra, input xlen_t rb);
    return (ra < rb);
  endfunction

  // ---------------------------------------------------------------------------
  // Checker
  // ---------------------------------------------------------------------------
  int error_count = 0;
  int test_count = 0;

  task automatic apply_and_check(input xlen_t ta, input xlen_t tb, input alu_op_e top);
    xlen_t exp_y;
    logic exp_eq, exp_lt, exp_ltu;

    begin
      a  = ta;
      b  = tb;
      op = top;

      // combinational DUT: settle
      #1;

      exp_y   = ref_y(ta, tb, top);
      exp_eq  = ref_eq(ta, tb);
      exp_lt  = ref_lt(ta, tb);
      exp_ltu = ref_ltu(ta, tb);

      test_count++;

      if (y !== exp_y || eq !== exp_eq || lt !== exp_lt || ltu !== exp_ltu) begin
        error_count++;
        $display(
            "FAIL[%0d]: op=%0d a=0x%08h b=0x%08h | y=0x%08h(exp 0x%08h) eq=%0b(exp %0b) lt=%0b(exp %0b) ltu=%0b(exp %0b)",
            test_count, top, ta, tb, y, exp_y, eq, exp_eq, lt, exp_lt, ltu, exp_ltu);
        $fatal(1, "ALU mismatch");
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Directed tests
  // ---------------------------------------------------------------------------
  task automatic directed_tests;
    begin
      // Basic identities
      apply_and_check('0, '0, ALU_ADD);
      apply_and_check(32'h1, 32'h1, ALU_ADD);
      apply_and_check(32'h2, 32'h1, ALU_SUB);

      // Carry/overflow boundaries (still wrap in RV32)
      apply_and_check(32'hFFFF_FFFF, 32'h1, ALU_ADD);  // wraps to 0
      apply_and_check(32'h8000_0000, 32'h1, ALU_SUB);

      // AND/OR/XOR patterns
      apply_and_check(32'hAAAA_AAAA, 32'h5555_5555, ALU_AND);
      apply_and_check(32'hAAAA_AAAA, 32'h5555_5555, ALU_OR);
      apply_and_check(32'hAAAA_AAAA, 32'h5555_5555, ALU_XOR);

      // Shifts: shamt uses b[4:0]
      apply_and_check(32'h1, 32'd0, ALU_SLL);
      apply_and_check(32'h1, 32'd1, ALU_SLL);
      apply_and_check(32'h1, 32'd31, ALU_SLL);

      apply_and_check(32'h8000_0000, 32'd1, ALU_SRL);
      apply_and_check(32'h8000_0000, 32'd31, ALU_SRL);

      // SRA sign extension
      apply_and_check(32'h8000_0000, 32'd1, ALU_SRA);
      apply_and_check(32'h8000_0000, 32'd31, ALU_SRA);
      apply_and_check(32'h7FFF_FFFF, 32'd1, ALU_SRA);

      // SLT signed
      apply_and_check(32'hFFFF_FFFF, 32'h0, ALU_SLT);  // -1 < 0 => 1
      apply_and_check(32'h8000_0000, 32'h7FFF_FFFF, ALU_SLT);  // most neg < most pos

      // SLTU unsigned
      apply_and_check(32'hFFFF_FFFF, 32'h0, ALU_SLTU);  // max unsigned < 0 => 0
      apply_and_check(32'h0, 32'hFFFF_FFFF, ALU_SLTU);  // 0 < max => 1

      // Copy and zero
      apply_and_check(32'hDEAD_BEEF, 32'h1111_2222, ALU_COPY_A);
      apply_and_check(32'hDEAD_BEEF, 32'h1111_2222, ALU_COPY_B);
      apply_and_check(32'hDEAD_BEEF, 32'h1111_2222, ALU_ZERO);

      // Equality flag check (independent of op)
      apply_and_check(32'h1234_5678, 32'h1234_5678, ALU_XOR);
      apply_and_check(32'h1234_5678, 32'h1234_5679, ALU_XOR);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Random tests
  // ---------------------------------------------------------------------------
  task automatic random_tests(int unsigned n = 5000);
    alu_op_e ops[$];
    int unsigned i;
    xlen_t ra, rb;

    begin
      // List ops you want covered
      ops.push_back(ALU_ADD);
      ops.push_back(ALU_SUB);
      ops.push_back(ALU_AND);
      ops.push_back(ALU_OR);
      ops.push_back(ALU_XOR);
      ops.push_back(ALU_SLL);
      ops.push_back(ALU_SRL);
      ops.push_back(ALU_SRA);
      ops.push_back(ALU_SLT);
      ops.push_back(ALU_SLTU);
      ops.push_back(ALU_COPY_A);
      ops.push_back(ALU_COPY_B);
      ops.push_back(ALU_ZERO);

      for (i = 0; i < n; i++) begin
        ra = $urandom();
        rb = $urandom();
        apply_and_check(ra, rb, ops[$urandom_range(0, ops.size()-1)]);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  initial begin
    // init
    a  = '0;
    b  = '0;
    op = ALU_ZERO;
    #1;

    $display("Starting ALU TB...");

    directed_tests();
    random_tests(10000);

    $display("ALU TB PASSED: %0d tests", test_count);
    $finish;
  end

endmodule
