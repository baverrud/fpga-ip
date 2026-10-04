-----------------------------------------------------------------------
--Filename         : axi_mem_store_tb.vhd
--Description      : Self-checking testbench for axi_mem_store.
--                 : Covers byte population, real data reads, boundary
--                 : errors, reset preservation, backpressure, R-side latency
--                 : control, the write-error pulse and wrapping bursts.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axis_bfm_pkg.all;

entity axi_mem_store_tb is
end entity;

architecture sim of axi_mem_store_tb is

  constant C_CLK_PERIOD : time := 10 ns;
  constant C_ADDR_WIDTH : positive := 16;
  constant C_ID_WIDTH   : positive := 6;  -- Holds every test ID (largest is 27)
  constant C_TIMER_WIDTH : positive := 8;
  constant C_MEM_BYTES  : positive := 64;

  signal aclk : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal sim_done : boolean := false;

  -- Packed write stream used by axis_bfm_pkg.  The DUT port map below
  -- connects its address and data slices directly to mem_wr_* ports.
  signal mem_wr_tdata  : std_logic_vector(C_ADDR_WIDTH+7 downto 0) :=
    (others => '0');
  signal mem_wr_tvalid : std_logic := '0';
  signal mem_wr_tready : std_logic;
  signal mem_wr_error  : std_logic;

  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0) := (others => '0');
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal ar_len   : std_logic_vector(7 downto 0) := (others => '0');
  signal ar_valid : std_logic := '0';
  signal ar_ready : std_logic;

  signal r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data  : std_logic_vector(31 downto 0);
  signal r_resp  : std_logic_vector(1 downto 0);
  signal r_last  : std_logic;
  signal r_valid : std_logic;
  signal r_ready : std_logic := '0';

  signal ar_base_enable   : std_logic := '0';
  signal ar_jitter_enable : std_logic := '0';
  signal r_base_enable    : std_logic := '0';
  signal r_jitter_enable  : std_logic := '0';
  signal base_latency     : std_logic_vector(C_TIMER_WIDTH-1 downto 0) := (others => '0');
  signal base_beat_gap    : std_logic_vector(C_TIMER_WIDTH-1 downto 0) := (others => '0');

  -- Second DUT: the core used directly, without the latency wrapper.  It runs
  -- at the minimum legal address width for its memory (log2ceil(64) = 6),
  -- which is the configuration the relaxed address-width check must allow,
  -- and it exposes the core's own ar_ready for the handshake checks.
  constant C_CORE_ADDR_WIDTH : positive := 6;

  signal c_aresetn : std_logic := '0';

  signal c_mem_wr_addr  : std_logic_vector(C_CORE_ADDR_WIDTH-1 downto 0) :=
    (others => '0');
  signal c_mem_wr_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal c_mem_wr_valid : std_logic := '0';
  signal c_mem_wr_ready : std_logic;
  signal c_mem_wr_error : std_logic;

  signal c_ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0) := (others => '0');
  signal c_ar_addr  : std_logic_vector(C_CORE_ADDR_WIDTH-1 downto 0) :=
    (others => '0');
  signal c_ar_len   : std_logic_vector(7 downto 0) := (others => '0');
  signal c_ar_valid : std_logic := '0';
  signal c_ar_ready : std_logic;

  signal c_r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal c_r_data  : std_logic_vector(31 downto 0);
  signal c_r_resp  : std_logic_vector(1 downto 0);
  signal c_r_last  : std_logic;
  signal c_r_valid : std_logic;
  signal c_r_ready : std_logic := '0';

  function expected_byte(addr : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((addr * 3 + 5) mod 256, 8));
  end function;

begin

  aclk <= not aclk after C_CLK_PERIOD / 2 when not sim_done else '0';

  p_watchdog : process
  begin
    wait for 50 us;
    assert sim_done report "axi_mem_store_tb timeout" severity failure;
    wait;
  end process;

  u_dut : entity work.axi_mem_store
    generic map (
      GC_DATA_BYTES     => 4,
      GC_ADDR_WIDTH     => C_ADDR_WIDTH,
      GC_ID_WIDTH       => C_ID_WIDTH,
      GC_TIMER_WIDTH    => C_TIMER_WIDTH,
      GC_AR_FIFO_DEPTH  => 4,
      GC_R_FIFO_DEPTH   => 8,
      GC_MEM_SIZE_BYTES => C_MEM_BYTES
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      ar_base_enable    => ar_base_enable,
      ar_jitter_enable  => ar_jitter_enable,
      r_base_enable     => r_base_enable,
      r_jitter_enable   => r_jitter_enable,
      base_latency      => base_latency,
      base_beat_gap     => base_beat_gap,
      mem_wr_addr       => mem_wr_tdata(C_ADDR_WIDTH+7 downto 8),
      mem_wr_data       => mem_wr_tdata(7 downto 0),
      mem_wr_valid      => mem_wr_tvalid,
      mem_wr_ready      => mem_wr_tready,
      mem_wr_error      => mem_wr_error,
      ar_id             => ar_id,
      ar_addr           => ar_addr,
      ar_len            => ar_len,
      ar_valid          => ar_valid,
      ar_ready          => ar_ready,
      r_id              => r_id,
      r_data            => r_data,
      r_resp            => r_resp,
      r_last            => r_last,
      r_valid           => r_valid,
      r_ready           => r_ready
    );

  u_core : entity work.axi_mem_store_core
    generic map (
      GC_DATA_BYTES     => 4,
      -- Minimum legal width for a 64-byte memory.  This is exactly the
      -- configuration that the relaxed address-width check must allow.
      GC_ADDR_WIDTH     => C_CORE_ADDR_WIDTH,
      GC_ID_WIDTH       => C_ID_WIDTH,
      GC_MEM_SIZE_BYTES => C_MEM_BYTES
    )
    port map (
      aclk         => aclk,
      aresetn      => c_aresetn,
      mem_wr_addr  => c_mem_wr_addr,
      mem_wr_data  => c_mem_wr_data,
      mem_wr_valid => c_mem_wr_valid,
      mem_wr_ready => c_mem_wr_ready,
      mem_wr_error => c_mem_wr_error,
      ar_id        => c_ar_id,
      ar_addr      => c_ar_addr,
      ar_len       => c_ar_len,
      ar_valid     => c_ar_valid,
      ar_ready     => c_ar_ready,
      r_id         => c_r_id,
      r_data       => c_r_data,
      r_resp       => c_r_resp,
      r_last       => c_r_last,
      r_valid      => c_r_valid,
      r_ready      => c_r_ready
    );

  p_test : process
    -- Two delta cycles settle a clocked internal flag and its concurrent
    -- output assignment without advancing simulation time.
    procedure wait_for_dut_update is
    begin
      wait for 0 ns;
      wait for 0 ns;
    end procedure;

    -- Drive one byte through the testbench population stream.  This is a
    -- helper for mem_wr_*, not a full AXI write-channel procedure.
    procedure mem_wr(addr : natural; data : std_logic_vector(7 downto 0)) is
      variable v_write : std_logic_vector(C_ADDR_WIDTH+7 downto 0);
    begin
      v_write := std_logic_vector(to_unsigned(addr, C_ADDR_WIDTH)) & data;
      axis_write(aclk, mem_wr_tdata, mem_wr_tvalid,
             mem_wr_tready, v_write);
    end procedure;

    -- Write selected bytes from a little-endian 32-bit word.  Strobe bit b
    -- controls data byte b at address addr+b.
    procedure mem_wr_word(
      addr : natural;
      data : std_logic_vector(31 downto 0);
      strb : std_logic_vector(3 downto 0) := x"F") is
    begin
      for byte_idx in 0 to 3 loop
        if strb(byte_idx) = '1' then
          mem_wr(addr + byte_idx,
                 data(8*byte_idx+7 downto 8*byte_idx));
        end if;
      end loop;
    end procedure;

    procedure send_ar(
      id : natural; addr : natural; beats : natural) is
    begin
      ar_id    <= std_logic_vector(to_unsigned(id, C_ID_WIDTH));
      ar_addr  <= std_logic_vector(to_unsigned(addr, C_ADDR_WIDTH));
      ar_len   <= std_logic_vector(to_unsigned(beats - 1, 8));
      ar_valid <= '1';
      loop
        wait until rising_edge(aclk);
        exit when ar_ready = '1';
      end loop;
      ar_valid <= '0';
    end procedure;

    procedure read_burst(
      id : natural; addr : natural; beats : natural;
      expected_resp : std_logic_vector(1 downto 0);
      check_pattern : boolean) is
      variable got_beat : boolean;
      variable byte_addr : natural;
      variable expected_last : std_logic;
    begin
      send_ar(id, addr, beats);
      r_ready <= '0';

      for beat_idx in 0 to beats-1 loop
        got_beat := false;
        for timeout_idx in 0 to 200 loop
          wait until rising_edge(aclk);
          if r_valid = '1' then
            got_beat := true;
            exit;
          end if;
        end loop;
        assert got_beat
          report "timeout waiting for RVALID" severity failure;

        expected_last := '0';
        if beat_idx = beats-1 then
          expected_last := '1';
        end if;
        assert r_id = std_logic_vector(to_unsigned(id, C_ID_WIDTH))
          report "R ID mismatch" severity failure;
        assert r_last = expected_last
          report "R LAST mismatch" severity failure;
        assert r_resp = expected_resp
          report "R RESP mismatch" severity failure;

        -- AXI byte lanes: every beat is the aligned 4-byte window.
        byte_addr := (addr - addr mod 4) + beat_idx * 4;
        if check_pattern then
          for byte_idx in 0 to 3 loop
            assert r_data(8*byte_idx+7 downto 8*byte_idx) =
                   expected_byte(byte_addr + byte_idx)
              report "stored byte data mismatch" severity failure;
          end loop;
        elsif expected_resp = "10" then
          assert r_data = x"00000000"
            report "SLVERR data was not zero" severity failure;
        end if;

        r_ready <= '1';
        wait until rising_edge(aclk);
        r_ready <= '0';
      end loop;
      r_ready <= '1';
    end procedure;

    procedure check_one_response(
      id : natural; expected_data : std_logic_vector(31 downto 0);
      expected_resp : std_logic_vector(1 downto 0)) is
      variable got_beat : boolean := false;
    begin
      r_ready <= '0';
      for timeout_idx in 0 to 200 loop
        wait until rising_edge(aclk);
        if r_valid = '1' then
          got_beat := true;
          exit;
        end if;
      end loop;
      assert got_beat report "timeout waiting for single R response"
        severity failure;
      assert r_id = std_logic_vector(to_unsigned(id, C_ID_WIDTH))
        report "single R response ID mismatch" severity failure;
      assert r_data = expected_data
        report "single R response data mismatch" severity failure;
      assert r_resp = expected_resp
        report "single R response RESP mismatch" severity failure;
      assert r_last = '1'
        report "single R response LAST mismatch" severity failure;
      r_ready <= '1';
      wait until rising_edge(aclk);
      r_ready <= '0';
    end procedure;

    procedure read_one_expected(
      id : natural; addr : natural;
      expected_data : std_logic_vector(31 downto 0);
      expected_resp : std_logic_vector(1 downto 0)) is
    begin
      send_ar(id, addr, 1);
      check_one_response(id, expected_data, expected_resp);
    end procedure;

    procedure measure_response_latency(
      id : natural; addr : natural;
      variable ar_accept_time : out time;
      variable r_valid_time   : out time) is
    begin
      ar_id    <= std_logic_vector(to_unsigned(id, C_ID_WIDTH));
      ar_addr  <= std_logic_vector(to_unsigned(addr, C_ADDR_WIDTH));
      ar_len   <= x"00";
      ar_valid <= '1';
      loop
        wait until rising_edge(aclk);
        if ar_ready = '1' then
          ar_accept_time := now;
          exit;
        end if;
      end loop;
      ar_valid <= '0';
      r_ready  <= '0';
      for timeout_idx in 0 to 1000 loop
        wait until rising_edge(aclk);
        if r_valid = '1' then
          r_valid_time := now;
          exit;
        end if;
        assert timeout_idx < 1000
          report "latency measurement timed out" severity failure;
      end loop;
      r_ready <= '1';
      wait until rising_edge(aclk);
      r_ready <= '0';
    end procedure;

    procedure check_latency_controls is
      variable base_ar_time    : time;
      variable base_r_time    : time;
      variable delayed_ar_time : time;
      variable delayed_r_time : time;
      variable jitter_ar_time : time;
      variable jitter_r_time  : time;
      variable jitter_min     : time := time'high;
      variable jitter_max     : time := 0 ns;
      variable measured_delay : time;
    begin
      aresetn <= '0';
      wait for C_CLK_PERIOD * 3;
      aresetn <= '1';
      wait for C_CLK_PERIOD * 2;

      ar_base_enable   <= '0';
      ar_jitter_enable <= '0';
      r_base_enable    <= '0';
      r_jitter_enable  <= '0';
      base_latency     <= (others => '0');
      base_beat_gap    <= (others => '0');
      measure_response_latency(20, 0, base_ar_time, base_r_time);

      aresetn <= '0';
      wait for C_CLK_PERIOD * 3;
      aresetn <= '1';
      wait for C_CLK_PERIOD * 2;
      ar_base_enable <= '1';
      r_base_enable  <= '1';
      base_latency   <= std_logic_vector(to_unsigned(3, C_TIMER_WIDTH));
      base_beat_gap  <= std_logic_vector(to_unsigned(2, C_TIMER_WIDTH));
      measure_response_latency(21, 0, delayed_ar_time, delayed_r_time);

      assert (delayed_r_time - delayed_ar_time) >
             (base_r_time - base_ar_time)
        report "configured AR/R base delays did not increase latency"
        severity failure;

      aresetn <= '0';
      wait for C_CLK_PERIOD * 3;
      aresetn <= '1';
      wait for C_CLK_PERIOD * 2;
      ar_base_enable   <= '0';
      ar_jitter_enable <= '1';
      r_base_enable    <= '0';
      r_jitter_enable  <= '1';
      base_latency     <= (others => '0');
      base_beat_gap    <= (others => '0');
      for sample in 0 to 3 loop
        measure_response_latency(24 + sample, 0,
                                 jitter_ar_time, jitter_r_time);
        measured_delay := jitter_r_time - jitter_ar_time;
        if measured_delay < jitter_min then
          jitter_min := measured_delay;
        end if;
        if measured_delay > jitter_max then
          jitter_max := measured_delay;
        end if;
      end loop;
      assert jitter_max > jitter_min
        report "enabled jitter did not vary measured latency"
        severity failure;

      ar_base_enable   <= '0';
      ar_jitter_enable <= '0';
      r_base_enable    <= '0';
      r_jitter_enable  <= '0';
    end procedure;

    procedure check_stalled_response(id : natural; addr : natural;
                                     stall_cycles : positive := 3) is
      variable saved_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
      variable saved_data  : std_logic_vector(31 downto 0);
      variable saved_resp  : std_logic_vector(1 downto 0);
      variable saved_last  : std_logic;
      variable got_beat    : boolean := false;
    begin
      send_ar(id, addr, 1);
      r_ready <= '0';
      for timeout_idx in 0 to 200 loop
        wait until rising_edge(aclk);
        if r_valid = '1' then
          got_beat := true;
          exit;
        end if;
      end loop;
      assert got_beat report "timeout waiting for stalled R response"
        severity failure;
      saved_id   := r_id;
      saved_data := r_data;
      saved_resp := r_resp;
      saved_last := r_last;
      for stall_idx in 1 to stall_cycles loop
        wait until rising_edge(aclk);
        assert r_valid = '1' and r_id = saved_id and
               r_data = saved_data and r_resp = saved_resp and
               r_last = saved_last
          report "R response changed during backpressure after " &
                 integer'image(stall_idx) & " stall cycles" severity failure;
      end loop;
      r_ready <= '1';
      wait until rising_edge(aclk);
      r_ready <= '0';
    end procedure;

    procedure read_mixed_boundary(id : natural) is
      variable got_beat : boolean;
      variable expected_resp : std_logic_vector(1 downto 0);
      variable expected_last : std_logic;
    begin
      -- Beat 0 covers addresses 60..63; beat 1 covers 64..67 and is invalid.
      send_ar(id, 60, 2);
      r_ready <= '0';
      for beat_idx in 0 to 1 loop
        got_beat := false;
        for timeout_idx in 0 to 200 loop
          wait until rising_edge(aclk);
          if r_valid = '1' then
            got_beat := true;
            exit;
          end if;
        end loop;
        assert got_beat report "timeout waiting for mixed boundary response"
          severity failure;
        if beat_idx = 0 then

      -- Minimum-width address coverage: the first aligned beat at address 60
      -- is valid, while the next beat at address 64 must remain SLVERR rather
      -- than wrapping to address zero.
      c_ar_id    <= std_logic_vector(to_unsigned(8, C_ID_WIDTH));
      c_ar_addr  <= std_logic_vector(to_unsigned(60, C_CORE_ADDR_WIDTH));
      c_ar_len   <= std_logic_vector(to_unsigned(1, 8));
      c_ar_valid <= '1';
      c_r_ready  <= '0';
      loop
        wait until rising_edge(aclk);
        exit when c_ar_ready = '1';
      end loop;
      c_ar_valid <= '0';
      wait for 1 ns;
      assert c_r_valid = '1' and c_r_resp = "00" and c_r_last = '0'
        report "minimum-width boundary first beat mismatch" severity failure;
      c_r_ready <= '1';
      wait until rising_edge(aclk);
      c_r_ready <= '0';
      wait for 1 ns;
      assert c_r_valid = '1' and c_r_resp = "10" and c_r_last = '1' and
             c_r_data = x"00000000"
        report "minimum-width boundary overflow beat mismatch" severity failure;
      c_r_ready <= '1';
      wait until rising_edge(aclk);
      c_r_ready <= '0';
      wait for 1 ns;
          expected_resp := "00";
          expected_last := '0';
          -- The valid beat must return the populated bytes, not zeros.
          for byte_idx in 0 to 3 loop
            assert r_data(8*byte_idx+7 downto 8*byte_idx) =
                   expected_byte(60 + byte_idx)
              report "mixed boundary stored byte mismatch" severity failure;
          end loop;
        else
          expected_resp := "10";
          expected_last := '1';
          assert r_data = x"00000000"
            report "mixed boundary SLVERR data was not zero" severity failure;
        end if;
        assert r_resp = expected_resp
          report "mixed boundary R RESP mismatch" severity failure;
        assert r_last = expected_last
          report "mixed boundary R LAST mismatch" severity failure;
        r_ready <= '1';
        wait until rising_edge(aclk);
        r_ready <= '0';
      end loop;
      r_ready <= '1';
    end procedure;

    -- Wrapper-level check: the AR latency FIFO may accept and queue several
    -- ARs while the first R beat is stalled. The held R payload must remain
    -- stable, and queued responses must preserve order and IDs.
    procedure check_pending_ar_buffering is
      variable saved_id   : std_logic_vector(C_ID_WIDTH-1 downto 0);
      variable saved_data : std_logic_vector(31 downto 0);
      variable saved_resp : std_logic_vector(1 downto 0);
      variable saved_last : std_logic;
    begin
      r_ready <= '0';
      send_ar(12, 0, 1);
      while r_valid = '0' loop
        wait until rising_edge(aclk);
      end loop;

      saved_id   := r_id;
      saved_data := r_data;
      saved_resp := r_resp;
      saved_last := r_last;

      -- Present two more ARs while the first R beat is stalled. The wrapper
      -- may buffer them in the AR latency FIFO; the held R beat must not
      -- change.
      ar_id    <= std_logic_vector(to_unsigned(13, C_ID_WIDTH));
      ar_addr  <= std_logic_vector(to_unsigned(4, C_ADDR_WIDTH));
      ar_len   <= (others => '0');
      ar_valid <= '1';
      loop
        wait until rising_edge(aclk);
        exit when ar_ready = '1';
      end loop;
      ar_valid <= '0';
      ar_id    <= std_logic_vector(to_unsigned(14, C_ID_WIDTH));
      ar_addr  <= std_logic_vector(to_unsigned(8, C_ADDR_WIDTH));
      ar_valid <= '1';
      loop
        wait until rising_edge(aclk);
        exit when ar_ready = '1';
      end loop;
      ar_valid <= '0';
      for stall_idx in 1 to 2 loop
        wait until rising_edge(aclk);
        assert r_valid = '1' and r_id = saved_id and
               r_data = saved_data and r_resp = saved_resp and
               r_last = saved_last
          report "stalled R payload changed while ARs were queued"
          severity failure;
      end loop;
      assert r_valid = '1'
        report "final R beat was not held while a pending AR was present"
        severity failure;

      r_ready <= '1';
      wait until rising_edge(aclk);
      r_ready <= '0';
      check_one_response(13, x"1A171411", "00");
      check_one_response(14, x"2623201D", "00");
    end procedure;

    -- Exercise ARLEN=255. With a 64-byte memory and 32-bit beats, the first
    -- 16 beats are valid and the remaining 240 beats are deterministic
    -- SLVERR responses; the final beat must still carry r_last.
    procedure read_max_burst is
      variable expected_resp : std_logic_vector(1 downto 0);
      variable expected_last : std_logic;
    begin
      send_ar(18, 0, 256);
      r_ready <= '0';
      for beat_idx in 0 to 255 loop
        for timeout_idx in 0 to 200 loop
          wait until rising_edge(aclk);
          exit when r_valid = '1';
        end loop;
        assert r_valid = '1'
          report "maximum-length burst response timeout" severity failure;
        expected_resp := "00";
        if beat_idx >= 16 then
          expected_resp := "10";
        end if;
        expected_last := '0';
        if beat_idx = 255 then
          expected_last := '1';
        end if;
        assert r_id = std_logic_vector(to_unsigned(18, C_ID_WIDTH))
          report "maximum-length burst ID mismatch" severity failure;
        assert r_resp = expected_resp and r_last = expected_last
          report "maximum-length burst response fields mismatch"
          severity failure;
        if expected_resp = "10" then
          assert r_data = x"00000000"
            report "maximum-length SLVERR data was not zero" severity failure;
        end if;
        r_ready <= '1';
        wait until rising_edge(aclk);
        r_ready <= '0';
      end loop;
      r_ready <= '1';
    end procedure;

  begin
    wait for C_CLK_PERIOD * 3;
    aresetn <= '1';
    c_aresetn <= '1';
    wait for C_CLK_PERIOD * 2;
    assert mem_wr_tready = '1'
      report "memory write port did not become ready" severity failure;

    -- An accepted write at the first address outside memory pulses error for
    -- one clock and does not alter any stored byte.
    mem_wr_tdata  <= std_logic_vector(to_unsigned(C_MEM_BYTES, C_ADDR_WIDTH)) &
                     x"EE";
    mem_wr_tvalid <= '1';
    wait until rising_edge(aclk);
    mem_wr_tvalid <= '0';
    wait_for_dut_update;
    assert mem_wr_error = '1'
      report "invalid memory write did not pulse mem_wr_error" severity failure;
    wait until rising_edge(aclk);
    wait_for_dut_update;
    assert mem_wr_error = '0'
      report "mem_wr_error was not one clock wide" severity failure;

    -- Populate a distinct byte pattern so address-derived data cannot pass.
    for addr in 0 to 15 loop
      mem_wr(addr, expected_byte(addr));
    end loop;

    -- Populate the final valid native beat so boundary reads check real data.
    for addr in 56 to 63 loop
      mem_wr(addr, expected_byte(addr));
    end loop;

    -- The last accepted write to a byte is the value returned by later reads.
    mem_wr(20, x"AA");
    mem_wr(20, x"55");
    read_one_expected(14, 20, x"00000055", "00");

    -- Exercise the little-endian word helper and byte strobes.
    mem_wr_word(24, x"44332211", "1011");
    read_one_expected(0, 24, x"44002211", "00");

    -- Aligned and unaligned real-data reads. The unaligned burst from
    -- address 1 must return the aligned windows 0..3 and 4..7 (AXI lanes).
    read_burst(1, 0, 1, "00", true);
    read_burst(2, 1, 2, "00", true);
    read_burst(17, 6, 3, "00", true);

    -- A complete beat at the final aligned address is valid and returns data.
    read_burst(3, 60, 1, "00", true);

    -- An unaligned beat near the top reads its aligned window 60..63, which
    -- is wholly inside memory, so it is OKAY.
    read_burst(4, 62, 1, "00", true);

    -- The first beat above memory returns zero data and SLVERR.
    read_burst(13, 64, 1, "10", false);

    -- Address arithmetic must not wrap a top-of-address-space read into the
    -- valid low memory range.
    read_burst(11, 16#FFFF#, 1, "10", false);

    -- A multi-beat burst that starts out of range must stay SLVERR even after
    -- the beat address wraps past the top of the address space.
    read_burst(12, 16#FFFC#, 3, "10", false);

    -- A burst can contain both a valid and an invalid native data beat.
    read_mixed_boundary(8);

    -- Maximum ARLEN coverage.
    read_max_burst;

    -- R payload fields must remain stable while the consumer is stalled.
    check_stalled_response(9, 0);

    -- A stall longer than half the 8-bit latency timer (128 cycles) must
    -- not drop RVALID: AXI requires it to stay high until the handshake.
    check_stalled_response(16, 0, 300);

    -- A pending AR is buffered by the wrapper without disturbing a stalled
    -- final R beat.  The core's own same-cycle acceptance is checked against
    -- the direct core instance at the end of this sequence.
    check_pending_ar_buffering;

    -- Verify the runtime timing controls independently of response data.
    check_latency_controls;

    -- Exercise the existing R-side per-entry latency controls.
    r_base_enable   <= '1';
    r_jitter_enable <= '0';
    base_beat_gap   <= std_logic_vector(to_unsigned(2, C_TIMER_WIDTH));
    read_burst(5, 0, 3, "00", true);

    -- Jitter remains enabled for all output transfers in this mode.
    r_jitter_enable <= '1';
    base_beat_gap   <= std_logic_vector(to_unsigned(2, C_TIMER_WIDTH));
    read_burst(6, 0, 4, "00", true);

    -- Reset during an active response clears protocol state without emitting
    -- an orphaned beat afterward.
    send_ar(10, 0, 4);
    r_ready <= '0';
    while r_valid = '0' loop
      wait until rising_edge(aclk);
    end loop;
    aresetn <= '0';
    wait for C_CLK_PERIOD * 3;
    assert r_valid = '0'
      report "RVALID survived an active-transaction reset" severity failure;

    -- Reset clears protocol state but preserves populated memory.  A write
    -- presented during reset must not modify the stored byte.
    mem_wr_tdata <= std_logic_vector(to_unsigned(21, C_ADDR_WIDTH)) &
                    x"CC";
    mem_wr_tvalid <= '1';
    wait until rising_edge(aclk);
    assert mem_wr_tready = '0'
      report "memory write port was ready during reset" severity failure;
    assert mem_wr_error = '0'
      report "mem_wr_error was asserted during reset" severity failure;
    mem_wr_tvalid <= '0';
    r_base_enable   <= '0';
    r_jitter_enable <= '0';
    aresetn <= '1';
    wait for C_CLK_PERIOD * 2;
    read_burst(7, 0, 1, "00", true);
    -- Byte 21 (lane 1 of the aligned word at 20) must still be zero: the
    -- write presented during reset was not stored.
    read_one_expected(15, 21, x"00000055", "00");

    -- ------------------------------------------------------------------
    -- Core-level checks.  The direct core instance has no latency FIFO, so
    -- these observe the core's own ar_ready, and it runs at the minimum
    -- legal address width for its 64-byte memory.
    -- A short delay after a clock edge lets the registered outputs settle.
    -- ------------------------------------------------------------------

    -- Every representable write address must be accepted.  Before the
    -- exclusive memory limit was widened, a power-of-two memory size
    -- truncated that limit to zero, so every one of these writes would have
    -- been reported as out of range.
    for addr in 0 to C_MEM_BYTES-1 loop
      c_mem_wr_addr  <= std_logic_vector(to_unsigned(addr, C_CORE_ADDR_WIDTH));
      c_mem_wr_data  <= expected_byte(addr);
      c_mem_wr_valid <= '1';
      loop
        wait until rising_edge(aclk);
        exit when c_mem_wr_ready = '1';
      end loop;
      wait for 1 ns;
      assert c_mem_wr_error = '0'
        report "minimum-width write was reported out of range"
        severity failure;
    end loop;
    c_mem_wr_valid <= '0';

    -- Read the first four beats straight from the core and compare every
    -- byte against the populated pattern.
    c_ar_id    <= std_logic_vector(to_unsigned(5, C_ID_WIDTH));
    c_ar_addr  <= (others => '0');
    c_ar_len   <= std_logic_vector(to_unsigned(3, 8));
    c_ar_valid <= '1';
    c_r_ready  <= '0';
    loop
      wait until rising_edge(aclk);
      exit when c_ar_ready = '1';
    end loop;
    c_ar_valid <= '0';
    wait for 1 ns;

    for beat_idx in 0 to 3 loop
      assert c_r_valid = '1'
        report "core did not present an R beat" severity failure;
      assert c_r_id = std_logic_vector(to_unsigned(5, C_ID_WIDTH))
        report "core R ID mismatch" severity failure;
      assert c_r_resp = "00"
        report "core R RESP mismatch" severity failure;
      if beat_idx = 3 then
        assert c_r_last = '1'
          report "core R LAST mismatch on the final beat" severity failure;
      else
        assert c_r_last = '0'
          report "core R LAST asserted before the final beat"
          severity failure;
      end if;
      for byte_idx in 0 to 3 loop
        assert c_r_data(8*byte_idx+7 downto 8*byte_idx) =
               expected_byte(beat_idx * 4 + byte_idx)
          report "core stored byte mismatch" severity failure;
      end loop;
      c_r_ready <= '1';
      wait until rising_edge(aclk);
      c_r_ready <= '0';
      wait for 1 ns;
    end loop;

    -- Core handshake contract: a new AR must not be accepted while an R beat
    -- is stalled, and must be accepted on the very cycle that the final R
    -- beat of the current burst is consumed.
    c_ar_id    <= std_logic_vector(to_unsigned(6, C_ID_WIDTH));
    c_ar_addr  <= (others => '0');
    c_ar_len   <= std_logic_vector(to_unsigned(1, 8));   -- two beats
    c_ar_valid <= '1';
    loop
      wait until rising_edge(aclk);
      exit when c_ar_ready = '1';
    end loop;
    c_ar_valid <= '0';
    wait for 1 ns;
    assert c_r_valid = '1' and c_r_last = '0'
      report "core did not present the first R beat" severity failure;

    -- Present the next AR while a non-final R beat is stalled.
    c_ar_id    <= std_logic_vector(to_unsigned(7, C_ID_WIDTH));
    c_ar_addr  <= std_logic_vector(to_unsigned(8, C_CORE_ADDR_WIDTH));
    c_ar_len   <= (others => '0');
    c_ar_valid <= '1';
    wait until rising_edge(aclk);
    wait for 1 ns;
    assert c_ar_ready = '0'
      report "core accepted an AR while a non-final R beat was stalled"
      severity failure;

    -- Consume the first beat; the second beat is now the final one.
    c_r_ready <= '1';
    wait until rising_edge(aclk);
    c_r_ready <= '0';
    wait for 1 ns;
    assert c_r_valid = '1' and c_r_last = '1'
      report "core did not present the final R beat" severity failure;
    assert c_ar_ready = '0'
      report "core accepted an AR while the final R beat was stalled"
      severity failure;

    -- The lookahead is combinational, so the pending AR is accepted on the
    -- same cycle in which the final R beat is consumed.
    c_r_ready <= '1';
    wait for 1 ns;
    assert c_ar_ready = '1'
      report "core did not accept the next AR on the final R handshake"
      severity failure;
    wait until rising_edge(aclk);
    c_r_ready  <= '0';
    c_ar_valid <= '0';
    wait for 1 ns;
    assert c_r_valid = '1'
      report "core did not start the pending burst in the same cycle"
      severity failure;
    assert c_r_id = std_logic_vector(to_unsigned(7, C_ID_WIDTH))
      report "core pending burst ID mismatch" severity failure;
    assert c_r_last = '1'
      report "core pending burst LAST mismatch" severity failure;
    for byte_idx in 0 to 3 loop
      assert c_r_data(8*byte_idx+7 downto 8*byte_idx) =
             expected_byte(8 + byte_idx)
        report "core pending burst data mismatch" severity failure;
    end loop;

    -- Drain the pending burst so the core is left idle.
    c_r_ready <= '1';
    wait until rising_edge(aclk);
    c_r_ready <= '0';
    wait for 1 ns;

    report "axi_mem_store_tb: all tests passed" severity note;
    sim_done <= true;
    wait;
  end process;

end architecture;
