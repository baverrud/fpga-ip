-----------------------------------------------------------------------
--Filename         : axi_req_gen_pace_tb.vhd
--Description      : Unit testbench for the axi_req_gen credit bucket.
--                   The request channel is hand-driven (no bridge), so
--                   the transfer rate is set purely by cfg_pace and by
--                   the consumer's ready.  Verifies:
--                     - cfg_pace=0 runs back-to-back at line rate
--                     - the paced handshake grid is exactly cfg_pace+1
--                     - cfg_pace_init offsets the first credit
--                     - a stall accumulates credits which are then spent
--                       back-to-back
--                     - the bucket saturates at 255 and never wraps
--                     - the number of requests issued over a fixed window
--                       is the same with and without a long stall, i.e.
--                       cfg_pace is a bandwidth requirement, not a
--                       minimum gap
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_req_gen_pace_tb is
end entity;

architecture sim of axi_req_gen_pace_tb is
  constant C_DATA_BYTES : positive := 64;
  constant C_ADDR_WIDTH : positive := 32;
  constant C_MAX_BURST  : positive := 32;
  constant C_LEN_WIDTH  : positive := log2ceil(C_MAX_BURST);
  constant C_PERIOD     : time := 10 ns;
  constant C_TIMEOUT    : time := 1 ms;

  signal aclk     : std_logic := '0';
  signal aresetn  : std_logic := '0';
  signal sim_done : boolean := false;

  -- Gate
  signal enable   : std_logic := '0';
  signal aperture : std_logic := '1';

  -- Configuration
  signal cfg_req_len    : std_logic_vector(C_LEN_WIDTH-1 downto 0) := (others => '0');
  signal cfg_len_mode   : std_logic := '0';
  signal cfg_max_len    : std_logic_vector(C_LEN_WIDTH-1 downto 0) := (others => '0');
  signal cfg_pace       : std_logic_vector(31 downto 0) := (others => '0');
  signal cfg_pace_init  : std_logic_vector(31 downto 0) := (others => '0');
  signal cfg_base_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0) :=
                            std_logic_vector(to_unsigned(16#1000#, C_ADDR_WIDTH));
  signal cfg_addr_range : std_logic_vector(C_ADDR_WIDTH-1 downto 0) :=
                            std_logic_vector(to_unsigned(16#1000#, C_ADDR_WIDTH));
  signal cfg_addr_mode  : std_logic := '0';

  -- Request channel
  signal req_valid : std_logic;
  signal req_ready : std_logic := '0';
  signal req_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal req_len   : std_logic_vector(C_LEN_WIDTH-1 downto 0);

  -- Handshake measurement
  signal cnt_rst  : std_logic := '0';
  signal issued   : natural := 0;   -- handshakes since cnt_rst
  signal run_len  : natural := 0;   -- current back-to-back handshake run
  signal run_max  : natural := 0;   -- longest back-to-back run

  -- Callback used by the watchdog.
  signal watchdog_fired : boolean := false;

begin

  p_clk : process
  begin
    aclk <= '0';
    while not sim_done loop
      wait for C_PERIOD / 2;
      aclk <= not aclk;
    end loop;
    aclk <= '0';
    wait;
  end process;

  p_watchdog : process
  begin
    wait for C_TIMEOUT;
    if not sim_done then
      watchdog_fired <= true;
      report "axi_req_gen_pace_tb watchdog timeout" severity failure;
    end if;
    wait;
  end process;

  u_dut : entity work.axi_req_gen
    generic map (
      GC_DATA_BYTES => C_DATA_BYTES,
      GC_ADDR_WIDTH => C_ADDR_WIDTH,
      GC_MAX_BURST  => C_MAX_BURST
    )
    port map (
      aclk           => aclk,
      aresetn        => aresetn,
      enable         => enable,
      aperture       => aperture,
      cfg_req_len    => cfg_req_len,
      cfg_len_mode   => cfg_len_mode,
      cfg_max_len    => cfg_max_len,
      cfg_pace       => cfg_pace,
      cfg_pace_init  => cfg_pace_init,
      cfg_base_addr  => cfg_base_addr,
      cfg_addr_range => cfg_addr_range,
      cfg_addr_mode  => cfg_addr_mode,
      req_valid      => req_valid,
      req_ready      => req_ready,
      req_addr       => req_addr,
      req_len        => req_len
    );

  -- Count handshakes and the longest run of consecutive-cycle handshakes.
  -- A long run is the signature of the credit bucket spending a debt.
  p_count : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' or cnt_rst = '1' then
        issued  <= 0;
        run_len <= 0;
        run_max <= 0;
      else
        if req_valid = '1' and req_ready = '1' then
          issued <= issued + 1;
          if run_len + 1 > run_max then
            run_max <= run_len + 1;
          end if;
          run_len <= run_len + 1;
        else
          run_len <= 0;
        end if;
      end if;
    end if;
  end process;

  p_stim : process
    variable v_cycle        : natural;
    variable v_issued_ref   : natural;
    variable v_issued_stall : natural;
    variable v_deficit      : natural;
  begin
    -- Reset
    aresetn       <= '0';
    enable        <= '0';
    req_ready     <= '0';
    cfg_pace      <= (others => '0');
    cfg_pace_init <= (others => '0');
    for i in 1 to 5 loop
      wait until rising_edge(aclk);
    end loop;
    aresetn <= '1';
    wait until rising_edge(aclk);

    ------------------------------------------------------------------
    -- Phase 1: cfg_pace=0 is line rate: a credit every cycle, so the
    -- handshakes run back-to-back.
    ------------------------------------------------------------------
    cfg_pace      <= x"00000000";
    cfg_pace_init <= x"00000000";
    aperture      <= '1';
    enable        <= '0';
    for i in 1 to 4 loop
      wait until rising_edge(aclk);
    end loop;
    cnt_rst <= '1';
    wait until rising_edge(aclk);
    cnt_rst <= '0';
    req_ready <= '1';
    enable    <= '1';
    for i in 1 to 40 loop
      wait until rising_edge(aclk);
    end loop;
    assert issued >= 35
      report "P1: line rate did not reach ~1 request per cycle"
      severity failure;
    assert run_max >= 30
      report "P1: handshakes were not back-to-back at line rate"
      severity failure;
    report "P1 line rate: issued=" & integer'image(issued) &
           " run_max=" & integer'image(run_max) severity note;

    ------------------------------------------------------------------
    -- Phase 2: paced grid.  cfg_pace=3 -> one credit every 4 cycles, so
    -- consecutive handshakes are exactly 4 cycles apart and no two are
    -- ever back-to-back.
    ------------------------------------------------------------------
    enable <= '0';                       -- close the gate to re-arm
    for i in 1 to 4 loop
      wait until rising_edge(aclk);
    end loop;
    cfg_pace      <= x"00000003";
    cfg_pace_init <= x"00000000";
    req_ready     <= '1';
    cnt_rst <= '1';
    wait until rising_edge(aclk);
    cnt_rst <= '0';
    enable  <= '1';
    for i in 1 to 200 loop
      wait until rising_edge(aclk);
    end loop;
    -- 200 gated cycles / 4 cycles per credit = 50 requests (+/- 1).
    assert issued >= 48 and issued <= 51
      report "P2: paced rate is not 1 request per cfg_pace+1 cycles, issued=" &
             integer'image(issued) severity failure;
    assert run_max = 1
      report "P2: paced handshakes were not spaced" severity failure;
    report "P2 paced pace=3: issued=" & integer'image(issued) severity note;

    ------------------------------------------------------------------
    -- Phase 3: cfg_pace_init is the phase offset.  With cfg_pace_init=5
    -- the first credit is minted on the 6th gated cycle and the request
    -- is registered, so the first handshake is at gated cycle 7.
    ------------------------------------------------------------------
    enable <= '0';
    for i in 1 to 4 loop
      wait until rising_edge(aclk);
    end loop;
    cfg_pace      <= x"00000003";
    cfg_pace_init <= x"00000005";
    req_ready     <= '1';
    cnt_rst <= '1';
    wait until rising_edge(aclk);
    cnt_rst <= '0';
    enable  <= '1';
    v_cycle := 0;
    loop
      wait until rising_edge(aclk);
      v_cycle := v_cycle + 1;
      exit when req_valid = '1' and req_ready = '1';
      assert v_cycle < 100
        report "P3: first request never arrived" severity failure;
    end loop;
    assert v_cycle >= 6 and v_cycle <= 9
      report "P3: first request not at cfg_pace_init+1 credits, cycle=" &
             integer'image(v_cycle) severity failure;
    report "P3 init=5: first handshake at gated cycle " &
           integer'image(v_cycle) severity note;

    ------------------------------------------------------------------
    -- Phase 4: debt accumulation and saturation.  Stall the consumer for
    -- 1300 cycles while cfg_pace=3 mints one credit every 4 cycles: far
    -- more than the 8-bit bucket can hold, so it must saturate at 255.
    -- On release the generator spends the debt back-to-back.
    ------------------------------------------------------------------
    enable <= '0';
    for i in 1 to 4 loop
      wait until rising_edge(aclk);
    end loop;
    cfg_pace      <= x"00000003";
    cfg_pace_init <= x"00000000";
    req_ready     <= '1';
    cnt_rst <= '1';
    wait until rising_edge(aclk);
    cnt_rst <= '0';
    enable  <= '1';
    for i in 1 to 100 loop
      wait until rising_edge(aclk);
    end loop;
    req_ready <= '0';                    -- stall (> 255 * 4 cycles)
    for i in 1 to 1300 loop
      wait until rising_edge(aclk);
    end loop;
    req_ready <= '1';                    -- release: spend the debt
    for i in 1 to 600 loop
      wait until rising_edge(aclk);
    end loop;
    enable <= '0';
    assert run_max >= 330 and run_max <= 350
      report "P4: catch-up burst is not the saturated-bucket fixed point " &
             "(255 + burst/cfg_pace+1 = 340), run_max=" &
             integer'image(run_max) severity failure;
    report "P4 catch-up: run_max=" & integer'image(run_max) severity note;

    ------------------------------------------------------------------
    -- Phase 5: pace is a bandwidth requirement.  Two identical 4000-cycle
    -- windows, the second containing a 1300-cycle stall.  The divider
    -- keeps minting during the stall and the debt is repaid afterwards,
    -- so the only lost bandwidth is the overflow the 8-bit bucket could
    -- not hold:
    --     mints during the stall = 1300 / (cfg_pace+1) = 325
    --     bucket ceiling         = 255
    --     expected loss          = 325 - 255 = 70
    -- A divider that paused during the stall would lose far more, and a
    -- bucket that never saturated would lose far less.
    ------------------------------------------------------------------
    enable <= '0';
    for i in 1 to 4 loop
      wait until rising_edge(aclk);
    end loop;
    cfg_pace      <= x"00000003";
    cfg_pace_init <= x"00000000";
    req_ready     <= '1';
    cnt_rst <= '1';
    wait until rising_edge(aclk);
    cnt_rst <= '0';
    enable  <= '1';
    for i in 1 to 4000 loop
      wait until rising_edge(aclk);
    end loop;
    v_issued_ref := issued;

    enable <= '0';
    for i in 1 to 4 loop
      wait until rising_edge(aclk);
    end loop;
    req_ready <= '1';
    cnt_rst <= '1';
    wait until rising_edge(aclk);
    cnt_rst <= '0';
    enable  <= '1';
    for i in 1 to 1000 loop
      wait until rising_edge(aclk);
    end loop;
    req_ready <= '0';                    -- 1300-cycle stall mid-window
    for i in 1 to 1300 loop
      wait until rising_edge(aclk);
    end loop;
    req_ready <= '1';
    for i in 1 to 1700 loop
      wait until rising_edge(aclk);
    end loop;
    v_issued_stall := issued;
    enable <= '0';

    report "P5 windows: no-stall issued=" & integer'image(v_issued_ref) &
           " with-stall issued=" & integer'image(v_issued_stall)
      severity note;
    -- Swept window: exactly one credit per cfg_pace+1 cycles.
    assert v_issued_ref >= 999 and v_issued_ref <= 1001
      report "P5: swept window did not issue 4000/(cfg_pace+1) requests, issued=" &
             integer'image(v_issued_ref) severity failure;
    v_deficit := v_issued_ref - v_issued_stall;
    assert v_deficit <= 73
      report "P5: bandwidth loss exceeded the bucket ceiling - is the divider pausing?" &
             " deficit=" & integer'image(v_deficit) severity failure;
    assert v_deficit >= 65
      report "P5: bandwidth loss below the saturated-bucket prediction (no overflow)" &
             " deficit=" & integer'image(v_deficit) severity failure;

    report "ALL REQ GEN PACE/CREDIT CHECKS PASSED" severity note;
    sim_done <= true;
    wait;
  end process p_stim;

end architecture sim;
