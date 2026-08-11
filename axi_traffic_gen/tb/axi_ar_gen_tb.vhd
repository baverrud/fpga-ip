-----------------------------------------------------------------------
--Filename         : axi_ar_gen_tb.vhd
--Description      : Comprehensive self-checking testbench for
--                   axi_ar_gen.
--
--                   Six DUT instances are run concurrently, sweeping
--                   GC_DATA_BYTES over {1,2,4,8,16,32} to verify the
--                   generator across every supported transfer width.
--                   All instances share one config and one ar_ready;
--                   address generation is verified per instance.
--
--                   The TB contains a spec-based reference model that
--                   independently predicts, every clock cycle, the
--                   address the DUT must present (linear wrap-around,
--                   random offset mask + window clamp, and the
--                   fit_addr align/clamp), plus a mirror xoroshiro128+
--                   (the shared xorshift128 entity) stepped in lockstep
--                   with the DUT PRNG.  A clocked
--                   checker compares the DUT outputs (sampled on the
--                   falling edge for determinism) against the model
--                   and runs independent protocol checks:
--                     - ar_addr aligned to C_DATA_BYTES
--                     - full burst fits inside [base, base+range]
--                     - ar_len == cfg_arlen (clamped)
--                     - ar_size == log2(GC_DATA_BYTES)
--                     - ar_burst == INCR, ar_id == cfg_id
--                     - VALID held and address stable until the
--                       handshake (AXI valid/ready protocol)
--
--                   Corner cases exercised:
--                     T1  linear wrap-around (cfg_pace=0, back-to-back)
--                     T2  unaligned base (align-down clamp)
--                     T3  wrap boundary at non-aligned window end
--                     T4  random mode + offset window clamp
--                     T5  cfg_pace / cfg_pace_init first-burst delay
--                     T6  backpressure: valid-hold, no address skip
--                     T7  enable/aperture gating incl. valid-hold
--                         while the gate drops mid-presentation
--                     T8  cfg_arlen extremes (1-beat, 256-beat) and
--                         degenerate burst>window clamp
--                     T9  stat_rst clears counters mid-run
--
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_ar_gen_tb is
end entity;

architecture sim of axi_ar_gen_tb is

  constant C_CLK_PERIOD : time := 10 ns;
  constant C_ADDR_WIDTH : positive := 49;
  constant C_ID_WIDTH   : positive := 6;
  constant C_MAX_BURST  : positive := 256;

  -- GC_DATA_BYTES sweep: one DUT instance per width
  constant C_NUM_DB : positive := 6;
  type db_arr_t is array (0 to C_NUM_DB-1) of positive;
  constant C_DB_ARR : db_arr_t := (1, 2, 4, 8, 16, 32);

  -- Clock / reset
  signal aclk     : std_logic := '0';
  signal aresetn  : std_logic := '0';
  signal sim_done : boolean   := false;

  -- Shared generator config (driven by the sequencer)
  signal enable     : std_logic := '0';
  signal aperture   : std_logic := '0';
  signal stat_rst   : std_logic := '0';
  signal cfg_id       : std_logic_vector(C_ID_WIDTH-1 downto 0) := (others => '0');
  signal cfg_arlen  : std_logic_vector(log2ceil(C_MAX_BURST)-1 downto 0) := (others => '0');
  signal cfg_pace       : std_logic_vector(31 downto 0) := (others => '0');
  signal cfg_pace_init  : std_logic_vector(31 downto 0) := (others => '0');
  signal cfg_base_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal cfg_addr_range : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal cfg_addr_mode  : std_logic := '0';
  signal ar_ready   : std_logic := '0';

  -- Per-instance DUT outputs
  signal ar_valid        : std_logic_vector(C_NUM_DB-1 downto 0);
  signal ar_addr         : slv_array_t(0 to C_NUM_DB-1)(C_ADDR_WIDTH-1 downto 0);
  signal ar_len          : slv_array_t(0 to C_NUM_DB-1)(7 downto 0);
  signal ar_size         : slv_array_t(0 to C_NUM_DB-1)(2 downto 0);
  signal ar_burst        : slv_array_t(0 to C_NUM_DB-1)(1 downto 0);
  signal ar_id           : slv_array_t(0 to C_NUM_DB-1)(C_ID_WIDTH-1 downto 0);
  signal stat_ar_stall   : slv_array_t(0 to C_NUM_DB-1)(31 downto 0);
  signal stat_ar_issued  : slv_array_t(0 to C_NUM_DB-1)(31 downto 0);
  signal stat_cfg_errors : slv_array_t(0 to C_NUM_DB-1)(31 downto 0);

  -- Falling-edge samples: deterministic view of each cycle
  signal s_valid  : std_logic_vector(C_NUM_DB-1 downto 0);
  signal s_addr   : slv_array_t(0 to C_NUM_DB-1)(C_ADDR_WIDTH-1 downto 0);
  signal s_len    : slv_array_t(0 to C_NUM_DB-1)(7 downto 0);
  signal s_size   : slv_array_t(0 to C_NUM_DB-1)(2 downto 0);
  signal s_burst  : slv_array_t(0 to C_NUM_DB-1)(1 downto 0);
  signal s_id     : slv_array_t(0 to C_NUM_DB-1)(C_ID_WIDTH-1 downto 0);
  signal s_ready  : std_logic;
  signal s_gate   : std_logic;
  signal s_rst    : std_logic := '0';  -- aresetn during the sampled cycle
  signal s_mode   : std_logic;
  signal s_arlen  : std_logic_vector(7 downto 0);
  signal s_pace   : std_logic_vector(31 downto 0);
  signal s_pace_i : std_logic_vector(31 downto 0);
  signal s_base   : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal s_range  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal s_arid   : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal s_prng   : std_logic_vector(63 downto 0);

  -- Checker results (read by the sequencer)
  signal chk_issues : unsigned(31 downto 0) := (others => '0');
  signal chk_stalls : unsigned(31 downto 0) := (others => '0');
  signal chk_errors : unsigned(31 downto 0) := (others => '0');

  -- Mirror PRNG (same seeds as the DUT PRNG)
  signal ref_prng_step : std_logic := '0';
  signal ref_prng_data : std_logic_vector(63 downto 0);

  ---------------------------------------------------------------------
  -- Reference-model helpers (spec-based, independent of the DUT code).
  ---------------------------------------------------------------------

  -- Low-bit alignment mask: low log2(db) bits forced to 0.
  function f_align(db : natural) return unsigned is
  begin
    return not to_unsigned(db - 1, C_ADDR_WIDTH);
  end function;

  -- Bytes per burst = (arlen + 1) * data_bytes.
  function f_bsize(arlen : unsigned; db : natural) return unsigned is
  begin
    return resize((resize(arlen, 32) + 1) * db, 32);
  end function;

  -- Highest legal start address: base + cfg_addr_range - bsize.
  function f_vmax(base, addr_range : unsigned; bsize : unsigned(31 downto 0)) return unsigned is
  begin
    return base + addr_range - resize(bsize, C_ADDR_WIDTH);
  end function;

  -- Clamp addr into [base, top] and align down (fit_addr semantics).
  function f_fit(addr, base, top : unsigned; db : natural) return unsigned is
    variable v : unsigned(C_ADDR_WIDTH-1 downto 0);
  begin
    if addr < base then
      v := base;
    elsif addr > top then
      v := top;
    else
      v := addr;
    end if;
    return v and f_align(db);
  end function;

  -- Random offset: mask to (cfg_addr_range-1), align, clamp to window end.
  function f_rand_off(prng : unsigned(63 downto 0);
                      addr_range, base, top : unsigned;
                      bsize : unsigned(31 downto 0); db : natural) return unsigned is
    variable v_off : unsigned(C_ADDR_WIDTH-1 downto 0);
  begin
    v_off := prng(C_ADDR_WIDTH-1 downto 0) and (addr_range - 1);
    v_off := v_off and f_align(db);
    if resize(bsize, C_ADDR_WIDTH) <= addr_range and v_off > (top - base) then
      v_off := (top - base) and f_align(db);
    end if;
    return v_off;
  end function;

  procedure wait_cycles(n : natural) is
  begin
    for i in 1 to n loop
      wait until rising_edge(aclk);
    end loop;
  end procedure;

  -- Hold aresetn low for n cycles (config must already be stable).
  procedure pulse_reset(signal arst : out std_logic; n : natural := 2) is
  begin
    arst <= '0';
    wait_cycles(n);
    arst <= '1';
    wait_cycles(2);
  end procedure;

  -- Wait until the checker has observed `target` issued ARs.
  procedure wait_until_issues(target : in natural) is
  begin
    loop
      wait until rising_edge(aclk);
      exit when chk_issues >= to_unsigned(target, 32);
    end loop;
  end procedure;

  -- Set the shared generator config (enable/aperture forced high).
  procedure set_cfg(
    constant l_mode    : in std_logic;
    constant l_arlen   : in natural;
    constant l_pace    : in natural;
    constant l_pace_i  : in natural;
    constant l_base    : in natural;
    constant l_range   : in natural;
    constant l_ready   : in std_logic;
    signal   s_enable  : out std_logic;
    signal   s_aperture: out std_logic;
    signal   s_arid    : out std_logic_vector(C_ID_WIDTH-1 downto 0);
    signal   s_arlen   : out std_logic_vector(log2ceil(C_MAX_BURST)-1 downto 0);
    signal   s_pace    : out std_logic_vector(31 downto 0);
    signal   s_pace_i  : out std_logic_vector(31 downto 0);
    signal   s_base    : out std_logic_vector(C_ADDR_WIDTH-1 downto 0);
    signal   s_range   : out std_logic_vector(C_ADDR_WIDTH-1 downto 0);
    signal   s_mode    : out std_logic;
    signal   s_ready   : out std_logic
  ) is
  begin
    s_enable   <= '1';
    s_aperture <= '1';
    s_arid     <= "001010";
    s_arlen    <= std_logic_vector(to_unsigned(l_arlen, log2ceil(C_MAX_BURST)));
    s_pace     <= std_logic_vector(to_unsigned(l_pace, 32));
    s_pace_i   <= std_logic_vector(to_unsigned(l_pace_i, 32));
    s_base     <= std_logic_vector(to_unsigned(l_base, C_ADDR_WIDTH));
    s_range    <= std_logic_vector(to_unsigned(l_range, C_ADDR_WIDTH));
    s_mode     <= l_mode;
    s_ready    <= l_ready;
  end procedure;

  -- End-of-test stat verification against the checker's counts.
  procedure check_stats(
    constant tname : in string;
    signal st_iss  : in slv_array_t(0 to C_NUM_DB-1)(31 downto 0);
    signal st_stall: in slv_array_t(0 to C_NUM_DB-1)(31 downto 0);
    signal st_cfg  : in slv_array_t(0 to C_NUM_DB-1)(31 downto 0)
  ) is
  begin
    wait_cycles(3);  -- let the DUT stat registers settle
    assert chk_errors = 0 report tname & ": address/protocol errors" severity failure;
    for i in 0 to C_NUM_DB-1 loop
      assert unsigned(st_iss(i)) = chk_issues
        report tname & ": stat_ar_issued(" & integer'image(i) & ") mismatch" severity failure;
      assert unsigned(st_stall(i)) = chk_stalls
        report tname & ": stat_ar_stall(" & integer'image(i) & ") mismatch" severity failure;
      assert unsigned(st_cfg(i)) = 0
        report tname & ": stat_cfg_errors(" & integer'image(i) & ") nonzero" severity failure;
    end loop;
    report tname & " PASS";
  end procedure;

begin

  ---------------------------------------------------------------------
  -- Clock / watchdog
  ---------------------------------------------------------------------
  aclk <= not aclk after C_CLK_PERIOD/2 when not sim_done else '0';

  p_watchdog : process
  begin
    wait for 50 ms;
    assert sim_done report "Watchdog timeout" severity failure;
    wait;
  end process;

  ---------------------------------------------------------------------
  -- Mirror PRNG -- must step exactly when the DUT PRNG steps, i.e. once
  -- per accepted AR in random mode.  Both PRNGs start from the same
  -- seeds and reset together, so their outputs stay in lockstep.
  ---------------------------------------------------------------------
  ref_prng_step <= '1' when (ar_valid(0) = '1' and ar_ready = '1' and cfg_addr_mode = '1')
                         else '0';

  u_ref_prng : entity work.xorshift128
    port map (
      clk  => aclk,
      rstn => aresetn,
      step => ref_prng_step,
      data => ref_prng_data
    );

  ---------------------------------------------------------------------
  -- DUT instances -- one per GC_DATA_BYTES, all sharing the config and
  -- ar_ready (valid/pacing timing is independent of data bytes).
  ---------------------------------------------------------------------
  gen_dut : for i in 0 to C_NUM_DB-1 generate
    u_dut : entity work.axi_ar_gen
      generic map (
        GC_DATA_BYTES => C_DB_ARR(i),
        GC_ADDR_WIDTH => C_ADDR_WIDTH,
        GC_ID_WIDTH   => C_ID_WIDTH,
        GC_MAX_BURST  => C_MAX_BURST
      )
      port map (
        aclk       => aclk,
        aresetn    => aresetn,
        enable     => enable,
        aperture   => aperture,
        stat_rst   => stat_rst,
        cfg_id       => cfg_id,
        cfg_arlen  => cfg_arlen,
        cfg_pace       => cfg_pace,
        cfg_pace_init  => cfg_pace_init,
        cfg_base_addr  => cfg_base_addr,
        cfg_addr_range => cfg_addr_range,
        cfg_addr_mode  => cfg_addr_mode,
        ar_valid   => ar_valid(i),
        ar_ready   => ar_ready,
        ar_id      => ar_id(i),
        ar_addr    => ar_addr(i),
        ar_len     => ar_len(i),
        ar_size    => ar_size(i),
        ar_burst   => ar_burst(i),
        stat_ar_stall   => stat_ar_stall(i),
        stat_ar_issued  => stat_ar_issued(i),
        stat_cfg_errors => stat_cfg_errors(i)
      );
  end generate;

  ---------------------------------------------------------------------
  -- Falling-edge sampler -- captures each cycle's DUT outputs so the
  -- checker never hits delta-cycle ambiguity at the rising edge.
  ---------------------------------------------------------------------
  p_sample : process
  begin
    wait until falling_edge(aclk);
    s_valid <= ar_valid;
    s_addr  <= ar_addr;
    s_len   <= ar_len;
    s_size  <= ar_size;
    s_burst <= ar_burst;
    s_id    <= ar_id;
    s_ready <= ar_ready;
    s_gate  <= enable and aperture;
    s_rst   <= aresetn;
    s_mode  <= cfg_addr_mode;
    s_arlen <= cfg_arlen;
    s_pace  <= cfg_pace;
    s_pace_i<= cfg_pace_init;
    s_base  <= cfg_base_addr;
    s_range <= cfg_addr_range;
    s_arid  <= cfg_id;
    s_prng  <= ref_prng_data;
  end process;

  ---------------------------------------------------------------------
  -- Clocked checker + reference model.
  --
  -- At each rising edge the s_* samples describe the cycle that just
  -- ended.  The reference state (v_ref) holds the expected DUT
  -- registers for that same cycle; the checker compares, then advances
  -- the reference for the next cycle, mirroring p_comb/p_reg exactly.
  ---------------------------------------------------------------------
  p_check : process(aclk)
    type ref_t is record
      valid : boolean;
      addr  : unsigned(C_ADDR_WIDTH-1 downto 0);
      id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
      len   : std_logic_vector(7 downto 0);
      cur   : unsigned(C_ADDR_WIDTH-1 downto 0);
      pace_cnt  : unsigned(31 downto 0);
    end record;
    type ref_arr_t is array (0 to C_NUM_DB-1) of ref_t;
    variable v_ref    : ref_arr_t;
    variable v_bsize  : unsigned(31 downto 0);
    variable v_vmax   : unsigned(C_ADDR_WIDTH-1 downto 0);
    variable v_next   : unsigned(C_ADDR_WIDTH-1 downto 0);
    variable v_off    : unsigned(C_ADDR_WIDTH-1 downto 0);
    variable v_issues : natural := 0;
    variable v_stalls : natural := 0;
    variable v_errors : natural := 0;
  begin
    if rising_edge(aclk) then

      -- STEP 1: verify the DUT behavior during the sampled cycle.
      if s_rst = '1' then
        for i in 0 to C_NUM_DB-1 loop
          if (s_valid(i) = '1') /= v_ref(i).valid then
            v_errors := v_errors + 1;
            report "[" & integer'image(i) & "] valid mismatch: got " &
                   std_logic'image(s_valid(i)) & " expected " &
                   boolean'image(v_ref(i).valid) severity error;
          end if;

          if v_ref(i).valid then
            -- Expected presented address
            if unsigned(s_addr(i)) /= v_ref(i).addr then
              v_errors := v_errors + 1;
              report "[" & integer'image(i) & "] addr mismatch: got 0x" &
                     to_hstring(unsigned(s_addr(i))) & " expected 0x" &
                     to_hstring(v_ref(i).addr) severity error;
            end if;

            -- Alignment to data bytes
            if C_DB_ARR(i) > 1 then
              if unsigned(s_addr(i)(log2ceil(C_DB_ARR(i))-1 downto 0)) /= 0 then
                v_errors := v_errors + 1;
                report "[" & integer'image(i) & "] addr not aligned to " &
                       integer'image(C_DB_ARR(i)) & " bytes" severity error;
              end if;
            end if;

            -- Channel bundle
            if s_len(i) /= v_ref(i).len then
              v_errors := v_errors + 1;
              report "[" & integer'image(i) & "] ar_len mismatch" severity error;
            end if;
            if s_size(i) /= std_logic_vector(to_unsigned(log2ceil(C_DB_ARR(i)), 3)) then
              v_errors := v_errors + 1;
              report "[" & integer'image(i) & "] ar_size mismatch (data bytes " &
                     integer'image(C_DB_ARR(i)) & ")" severity error;
            end if;
            if s_burst(i) /= "01" then
              v_errors := v_errors + 1;
              report "[" & integer'image(i) & "] ar_burst not INCR" severity error;
            end if;
            if s_id(i) /= v_ref(i).id then
              v_errors := v_errors + 1;
              report "[" & integer'image(i) & "] ar_id mismatch" severity error;
            end if;

            -- Full burst must fit in [base, base+range] (only when the
            -- burst fits the range at all; otherwise the degenerate
            -- clamp case applies and is checked via the address model).
            v_bsize := f_bsize(unsigned(s_arlen), C_DB_ARR(i));
            if resize(v_bsize, C_ADDR_WIDTH) <= unsigned(s_range) then
              v_vmax := f_vmax(unsigned(s_base), unsigned(s_range), v_bsize);
              if unsigned(s_addr(i)) > v_vmax then
                v_errors := v_errors + 1;
                report "[" & integer'image(i) & "] addr 0x" &
                       to_hstring(unsigned(s_addr(i))) & " above window end 0x" &
                       to_hstring(v_vmax) severity error;
              end if;
            end if;
          end if;
        end loop;

        -- Issue/stall accounting (identical across instances)
        if s_valid(0) = '1' and s_ready = '1' then
          v_issues := v_issues + 1;
        elsif s_valid(0) = '1' then
          v_stalls := v_stalls + 1;
        end if;
      end if;

      -- STEP 2: advance the reference model for the next cycle.
      if s_rst = '0' then
        -- DUT was held in reset during the sampled cycle: the reference
        -- is reloaded with the post-reset state for the next cycle.
        for i in 0 to C_NUM_DB-1 loop
          v_ref(i).valid := false;
          v_ref(i).addr  := (others => '0');
          v_ref(i).id    := (others => '0');
          v_ref(i).len   := (others => '0');
          v_ref(i).cur   := unsigned(s_base);
          v_ref(i).pace_cnt  := unsigned(s_pace_i) + 1;
        end loop;
        v_issues := 0;
        v_stalls := 0;
      else
        for i in 0 to C_NUM_DB-1 loop
          v_bsize := f_bsize(unsigned(s_arlen), C_DB_ARR(i));
          v_vmax  := f_vmax(unsigned(s_base), unsigned(s_range), v_bsize);

          if v_ref(i).valid then
            if s_ready = '1' then
              -- Accepted: advance to the next address.
              if s_mode = '1' then
                v_off := f_rand_off(unsigned(s_prng), unsigned(s_range),
                                     unsigned(s_base), v_vmax, v_bsize, C_DB_ARR(i));
                v_ref(i).cur := unsigned(s_base) + v_off;
              else
                v_next := v_ref(i).addr + resize(v_bsize, C_ADDR_WIDTH);
                if resize(v_bsize, C_ADDR_WIDTH) <= unsigned(s_range) and
                   v_next > v_vmax then
                  v_next := unsigned(s_base);
                end if;
                v_ref(i).cur := v_next and f_align(C_DB_ARR(i));
              end if;
              v_ref(i).pace_cnt := unsigned(s_pace);
              if s_gate = '1' and unsigned(s_pace) = 0 then
                v_ref(i).valid := true;
                v_ref(i).addr  := f_fit(v_ref(i).cur, unsigned(s_base), v_vmax,
                                        C_DB_ARR(i));
                v_ref(i).id    := s_arid;
                v_ref(i).len   := std_logic_vector(resize(unsigned(s_arlen), 8));
              else
                v_ref(i).valid := false;
              end if;
            end if;
            -- else: backpressure -> hold valid/addr/cfg_pace (unchanged)
          elsif s_gate = '1' and v_ref(i).pace_cnt <= 1 then
            v_ref(i).valid := true;
            v_ref(i).addr  := f_fit(v_ref(i).cur, unsigned(s_base), v_vmax,
                                    C_DB_ARR(i));
            v_ref(i).id    := s_arid;
            v_ref(i).len   := std_logic_vector(resize(unsigned(s_arlen), 8));
            v_ref(i).pace_cnt  := unsigned(s_pace);
          elsif s_gate = '1' then
            v_ref(i).valid := false;
            v_ref(i).pace_cnt  := v_ref(i).pace_cnt - 1;
          else
            v_ref(i).valid := false;
          end if;
        end loop;
      end if;

      chk_issues <= to_unsigned(v_issues, 32);
      chk_stalls <= to_unsigned(v_stalls, 32);
      chk_errors <= to_unsigned(v_errors, 32);
    end if;
  end process p_check;

  ---------------------------------------------------------------------
  -- Sequencer -- drives the shared config and runs the sub-tests.
  ---------------------------------------------------------------------
  p_seq : process
    variable v_gap    : natural := 0;  -- low cycles between consecutive ARs
    variable v_gap_init : natural := 0;  -- first-AR delay (cycles after gate)
  begin
    aresetn <= '0';
    wait_cycles(3);

    -- ================= T1: linear wrap-around, cfg_pace=0 =================
    set_cfg('0', 15, 0, 0, 16#1000#, 16#1000#, '1',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    pulse_reset(aresetn);
    wait_until_issues(40);
    check_stats("T1  linear wrap-around, cfg_pace=0 (40 issues)", stat_ar_issued,
                stat_ar_stall, stat_cfg_errors);

    -- ============ T2: unaligned base -> align-down clamp =============
    set_cfg('0', 3, 0, 0, 16#1234#, 16#2000#, '1',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    pulse_reset(aresetn);
    wait_until_issues(20);
    check_stats("T2  unaligned base align-down (20 issues)", stat_ar_issued,
                stat_ar_stall, stat_cfg_errors);

    -- ======= T3: wrap boundary at non-aligned window end =============
    set_cfg('0', 7, 0, 0, 16#1000#, 16#1018#, '1',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    pulse_reset(aresetn);
    wait_until_issues(30);
    check_stats("T3  wrap boundary non-aligned window end (30 issues)",
                stat_ar_issued, stat_ar_stall, stat_cfg_errors);

    -- ========== T4: random mode + window clamp =======================
    set_cfg('1', 15, 0, 0, 16#2000#, 16#1000#, '1',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    pulse_reset(aresetn);
    wait_until_issues(200);
    check_stats("T4  random mode + offset clamp (200 issues)", stat_ar_issued,
                stat_ar_stall, stat_cfg_errors);

    -- ========== T5: cfg_pace=2, cfg_pace_init=3 (first-burst delay) ==========
    set_cfg('0', 3, 2, 3, 16#1000#, 16#1000#, '1',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    pulse_reset(aresetn);
    wait_until_issues(15);
    check_stats("T5  cfg_pace=2 / cfg_pace_init=3 (15 issues)", stat_ar_issued,
                stat_ar_stall, stat_cfg_errors);

    -- ======== T5B: cfg_pace=1 -> every 2nd cycle (gap regression) =========
    -- Independent of the reference model: directly counts the number of
    -- cycles where ar_valid is low between two consecutive presentations.
    -- With cfg_pace=1 there must be exactly one idle cycle between ARs
    -- (old FSM presented every 3rd cycle, i.e. two idle cycles).
    set_cfg('0', 3, 1, 0, 16#1000#, 16#1000#, '1',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    pulse_reset(aresetn);
    wait until rising_edge(aclk);
    while ar_valid(0) /= '1' loop
      wait until rising_edge(aclk);
    end loop;                       -- first presentation
    wait until rising_edge(aclk);   -- step past it
    v_gap := 0;
    while ar_valid(0) /= '1' loop
      v_gap := v_gap + 1;           -- count idle (low) cycles
      wait until rising_edge(aclk);
    end loop;                       -- second presentation
    assert v_gap = 1
      report "T5B FAIL: cfg_pace=1 idle gap is " & integer'image(v_gap) &
             " cycle(s), expected 1 (every 2nd cycle)" severity failure;
    report "T5B PASS: cfg_pace=1 issues every 2nd cycle (1 idle)";
    wait_until_issues(15);
    check_stats("T5B  cfg_pace=1 (15 issues)", stat_ar_issued,
                stat_ar_stall, stat_cfg_errors);

    -- ========= T5C: cfg_pace_init first-burst delay (regression) =========
    -- Independent of the reference model: the gate is held low while the
    -- initial delay is loaded, then raised; measures the cycle distance to
    -- the first AR for cfg_pace_init=1 vs =0 with identical methodology.
    -- The old FSM collapsed both to the same delay; after the fix, init=1
    -- must be exactly one cycle later than init=0.
    set_cfg('0', 3, 0, 1, 16#1000#, 16#1000#, '1',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    enable   <= '0';
    aperture <= '0';
    aresetn  <= '0';
    wait_cycles(3);
    aresetn  <= '1';
    wait_cycles(2);                 -- pace_cnt = init+1 = 2, gate still low
    wait until rising_edge(aclk);   -- sync edge (gate stays low this cycle)
    aperture <= '1';
    enable   <= '1';                -- gate rises here
    v_gap_init := 0;
    while ar_valid(0) /= '1' loop
      wait until rising_edge(aclk);
      v_gap_init := v_gap_init + 1;
    end loop;
    report "T5C: cfg_pace_init=1 first-AR delay = " & integer'image(v_gap_init) &
           " cycles";
    wait_until_issues(8);
    check_stats("T5C  cfg_pace_init=1 (8 issues)", stat_ar_issued,
                stat_ar_stall, stat_cfg_errors);

    -- Same measurement with cfg_pace_init=0.  The absolute count depends on
    -- delta-cycle timing of the readback, so only the difference is asserted:
    -- init=1 must be exactly one cycle later than init=0 (they used to
    -- collapse to the same value).
    set_cfg('0', 3, 0, 0, 16#1000#, 16#1000#, '1',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    enable   <= '0';
    aperture <= '0';
    aresetn  <= '0';
    wait_cycles(3);
    aresetn  <= '1';
    wait_cycles(2);                 -- pace_cnt = init+1 = 1, gate still low
    wait until rising_edge(aclk);   -- sync edge (gate stays low this cycle)
    aperture <= '1';
    enable   <= '1';                -- gate rises here
    v_gap := 0;
    while ar_valid(0) /= '1' loop
      wait until rising_edge(aclk);
      v_gap := v_gap + 1;
    end loop;
    report "T5C: cfg_pace_init=0 first-AR delay = " & integer'image(v_gap) &
           " cycles";
    assert v_gap_init = v_gap + 1
      report "T5C FAIL: cfg_pace_init=1 first-AR delay (" &
             integer'image(v_gap_init) & ") is not exactly 1 cycle later than " &
             "cfg_pace_init=0 (" & integer'image(v_gap) & ")" severity failure;
    report "T5C PASS: cfg_pace_init first-AR delay increases with cfg_pace_init";

    -- ========== T6: backpressure (valid-hold, no skip) ===============
    set_cfg('0', 3, 0, 0, 16#1000#, 16#1000#, '0',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    pulse_reset(aresetn);
    -- After reset, cfg_pace=0 keeps VALID high continuously.  Stall for 3
    -- cycles, accept for 1, repeat: each issue is preceded by 3 stalls.
    wait_cycles(2);  -- let VALID assert
    cfg_id    <= "111001";
    cfg_arlen <= std_logic_vector(to_unsigned(15, log2ceil(C_MAX_BURST)));
    wait_cycles(3);
    for i in 0 to C_NUM_DB-1 loop
      assert ar_valid(i) = '1' and ar_id(i) = "001010" and ar_len(i) = x"03"
        report "T6: AR payload changed while stalled" severity failure;
    end loop;
    report "T6A PASS: ARID/ARLEN held while configuration changed";
    for k in 1 to 12 loop
      ar_ready <= '0';
      wait_cycles(3);
      ar_ready <= '1';
      wait_cycles(1);
    end loop;
    ar_ready <= '0';
    wait_cycles(2);
    for i in 0 to C_NUM_DB-1 loop
      assert unsigned(stat_ar_issued(i)) = 12
        report "T6: issued count(" & integer'image(i) & ")=" &
               integer'image(to_integer(unsigned(stat_ar_issued(i)))) severity failure;
      assert unsigned(stat_ar_stall(i)) >= 36
        report "T6: stall count too low" severity failure;
    end loop;
    assert chk_errors = 0 report "T6: protocol errors" severity failure;
    report "T6  backpressure 3-cycle stalls (12 issues) PASS";

    -- ============ T7: enable/aperture gating =========================
    -- Part A: enable=0 -> no ARs at all
    enable <= '0'; aperture <= '1';
    pulse_reset(aresetn);
    wait_cycles(10);
    for i in 0 to C_NUM_DB-1 loop
      assert unsigned(stat_ar_issued(i)) = 0 report "T7A: issues while disabled" severity failure;
    end loop;
    assert chk_errors = 0 report "T7A: protocol errors" severity failure;
    report "T7A PASS: no ARs while enable=0";

    -- Part B: aperture=0 -> no ARs at all
    enable <= '1'; aperture <= '0';
    pulse_reset(aresetn);
    wait_cycles(10);
    for i in 0 to C_NUM_DB-1 loop
      assert unsigned(stat_ar_issued(i)) = 0 report "T7B: issues while aperture=0" severity failure;
    end loop;
    assert chk_errors = 0 report "T7B: protocol errors" severity failure;
    report "T7B PASS: no ARs while aperture=0";

    -- Part C: valid-hold while the gate drops mid-presentation
    set_cfg('0', 3, 0, 0, 16#1000#, 16#1000#, '0',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    pulse_reset(aresetn);
    wait_cycles(2);  -- VALID asserted, READY low (held)
    aperture <= '0';  -- gate drops while a value is presented
    wait_cycles(4);   -- VALID must stay high (held), addr stable
    ar_ready <= '1';  -- accept despite the gate being low
    wait_cycles(1);
    ar_ready <= '0';
    wait_cycles(4);   -- VALID must now be low (not re-presented)
    for i in 0 to C_NUM_DB-1 loop
      assert unsigned(stat_ar_issued(i)) = 1
        report "T7C: expected exactly 1 issue, got " &
               integer'image(to_integer(unsigned(stat_ar_issued(i)))) severity failure;
    end loop;
    assert chk_errors = 0 report "T7C: protocol errors" severity failure;
    report "T7C PASS: valid-hold across gate drop";

    -- Part D: re-enable and resume with correct next address
    aperture <= '1';
    ar_ready <= '1';
    wait_until_issues(6);
    check_stats("T7D  gating resume (6 issues)", stat_ar_issued,
                stat_ar_stall, stat_cfg_errors);

    -- ============ T8: cfg_arlen extremes =============================
    -- Part A: cfg_arlen=0 (1-beat bursts)
    set_cfg('0', 0, 0, 0, 16#1000#, 16#4000#, '1',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    pulse_reset(aresetn);
    wait_until_issues(20);
    check_stats("T8A  cfg_arlen=0, 1-beat bursts (20 issues)", stat_ar_issued,
                stat_ar_stall, stat_cfg_errors);

    -- Part B: cfg_arlen=255 (256-beat max burst)
    set_cfg('0', 255, 0, 0, 16#1000#, 16#40000#, '1',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    pulse_reset(aresetn);
    wait_until_issues(8);
    check_stats("T8B  cfg_arlen=255, 256-beat bursts (8 issues)", stat_ar_issued,
                stat_ar_stall, stat_cfg_errors);

    -- Part C: degenerate burst > window -> everything clamps to the
    -- window end (db=32: bsize=512 > range=256, so top < base and
    -- fit_addr clamps every presentation to top).
    set_cfg('0', 15, 0, 0, 16#1000#, 16#100#, '1',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    pulse_reset(aresetn);
    wait_until_issues(10);
    check_stats("T8C  degenerate burst>window clamp (10 issues)", stat_ar_issued,
                stat_ar_stall, stat_cfg_errors);

    -- ============ T9: stat_rst clears counters mid-run ===============
    set_cfg('0', 3, 0, 0, 16#1000#, 16#1000#, '1',
            enable, aperture, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
            cfg_base_addr, cfg_addr_range, cfg_addr_mode, ar_ready);
    pulse_reset(aresetn);
    wait_until_issues(10);
    wait_cycles(2);
    -- Deassert VALID first: drop the gate, then accept the pending AR
    -- (with the gate low the DUT will not re-present).  stat_rst only
    -- clears the counters when neither an accept nor a stall is active.
    aperture <= '0';
    ar_ready <= '1';
    wait_cycles(1);
    ar_ready <= '0';
    wait_cycles(2);
    stat_rst <= '1';
    wait_cycles(1);
    stat_rst <= '0';
    wait_cycles(2);
    -- Counters must be cleared (generation state is untouched)
    for i in 0 to C_NUM_DB-1 loop
      assert unsigned(stat_ar_issued(i)) = 0 report "T9: issued not cleared" severity failure;
      assert unsigned(stat_ar_stall(i)) = 0  report "T9: stall not cleared" severity failure;
      assert unsigned(stat_cfg_errors(i)) = 0 report "T9: cfg not cleared" severity failure;
    end loop;
    report "T9A PASS: stat_rst cleared counters";
    -- Re-enable and verify exactly 10 new issues are counted
    aperture <= '1';
    ar_ready <= '0';
    wait_cycles(2);  -- let VALID re-assert
    for k in 1 to 10 loop
      ar_ready <= '1';
      wait_cycles(1);
      ar_ready <= '0';
      wait_cycles(1);
    end loop;
    ar_ready <= '0';
    wait_cycles(2);
    for i in 0 to C_NUM_DB-1 loop
      assert unsigned(stat_ar_issued(i)) = 10
        report "T9: issued after stat_rst = " &
               integer'image(to_integer(unsigned(stat_ar_issued(i)))) severity failure;
    end loop;
    assert chk_errors = 0 report "T9: protocol errors" severity failure;
    report "T9B PASS: counting resumed after stat_rst";

    -- ===================== Final summary =============================
    assert chk_errors = 0
      report "axi_ar_gen_tb: FAILED with " & integer'image(to_integer(chk_errors)) &
             " errors" severity failure;
    report "axi_ar_gen_tb: ALL TESTS PASSED (0 errors)";
    sim_done <= true;
    std.env.stop;
    wait;
  end process p_seq;

end architecture;
