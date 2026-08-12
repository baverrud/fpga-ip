-----------------------------------------------------------------------
--Filename         : axi_r_demux_small_tb.vhd
--Description      : Generic-safe small-client testbench for axi_r_demux.
--                 : Covers one, two, and three client configurations:
--                 :  - Round-robin one-beat-per-cycle input acceptance.
--                 :  - Per-client output ordering and data integrity.
--                 :  - FIFO depth plus skid fill and ordered drain.
--                 :  - Reset and watchdog behavior.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;  -- slv_array_t, slv2_array_t

entity axi_r_demux_small_tb is
  generic (
    GC_NUM_CLIENTS : positive := 1;
    GC_DATA_BYTES  : positive := 4;
    GC_ID_WIDTH    : positive := 1;
    GC_FIFO_DEPTH  : positive := 4;
    GC_CLK_PERIOD  : time := 4 ns
  );
end entity;

architecture sim of axi_r_demux_small_tb is

  constant C_DATA_BITS : positive := 8 * GC_DATA_BYTES;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal r_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0) := (others => '0');
  signal r_data  : std_logic_vector(C_DATA_BITS-1 downto 0) := (others => '0');
  signal r_resp  : std_logic_vector(1 downto 0) := (others => '0');
  signal r_last  : std_logic := '0';
  signal r_valid : std_logic := '0';
  signal r_ready   : std_logic;
  signal rsp_data  : slv_array_t(0 to GC_NUM_CLIENTS-1)(C_DATA_BITS-1 downto 0);
  signal rsp_resp  : slv2_array_t(0 to GC_NUM_CLIENTS-1);
  signal rsp_last  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal rsp_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal rsp_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1) := (others => '0');
  signal r_pop : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal sim_done : boolean := false;

  function f_word(c : natural; b : natural) return std_logic_vector is
    constant C_HALF : positive := C_DATA_BITS / 2;
  begin
    return std_logic_vector(to_unsigned(c mod 16, C_HALF)) &
           std_logic_vector(to_unsigned(b mod 16, C_HALF));
  end function;

begin

  u_dut : entity work.axi_r_demux
    generic map (
      GC_NUM_CLIENTS => GC_NUM_CLIENTS,
      GC_DATA_BYTES  => GC_DATA_BYTES,
      GC_ID_WIDTH    => GC_ID_WIDTH,
      GC_FIFO_DEPTH  => GC_FIFO_DEPTH
    )
    port map (
      aclk      => aclk,
      aresetn   => aresetn,
      r_id      => r_id,
      r_data    => r_data,
      r_resp    => r_resp,
      r_last    => r_last,
      r_valid   => r_valid,
      r_ready   => r_ready,
      rsp_data  => rsp_data,
      rsp_resp  => rsp_resp,
      rsp_last  => rsp_last,
      rsp_valid => rsp_valid,
      rsp_ready => rsp_ready,
      r_pop     => r_pop
    );

  p_clk : process
  begin
    aclk <= '0';
    wait for GC_CLK_PERIOD * 2;
    loop
      if sim_done then
        aclk <= '0';
        wait;
      end if;
      aclk <= not aclk;
      wait for GC_CLK_PERIOD / 2;
    end loop;
  end process;

  p_watchdog : process
  begin
    wait for 1 ms;
    if not sim_done then
      report "FAIL: small-client watchdog timeout" severity failure;
    end if;
    wait;
  end process;

  p_stim : process
    variable expected_beat : integer_vector(0 to GC_NUM_CLIENTS-1) := (others => 0);
    variable client_idx : natural;
  begin
    -- Reset.
    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);
    assert r_ready = '1'
      report "FAIL: small-client r_ready not restored after reset" severity failure;

    -- Round-robin line-rate input. Every client is ready, so the shared
    -- input must accept one beat per clock without a bubble.
    rsp_ready <= (others => '1');
    for b in 0 to 31 loop
      client_idx := b mod GC_NUM_CLIENTS;
      r_id    <= std_logic_vector(to_unsigned(client_idx, GC_ID_WIDTH));
      r_data  <= f_word(client_idx, b);
      r_resp  <= "00";
      r_last  <= '1';
      r_valid <= '1';
      wait until rising_edge(aclk);
      assert r_ready = '1'
        report "FAIL: small-client r_ready dropped at input beat " &
               integer'image(b) severity failure;
      for i in 0 to GC_NUM_CLIENTS-1 loop
        if rsp_valid(i) = '1' then
          assert rsp_data(i) = f_word(i, i + expected_beat(i) * GC_NUM_CLIENTS)
            report "FAIL: small-client round-robin data mismatch" severity failure;
          expected_beat(i) := expected_beat(i) + 1;
        end if;
      end loop;
    end loop;
    r_valid <= '0';

    -- Drain and check the tail of the line-rate stream.
    for k in 0 to GC_FIFO_DEPTH + 4 loop
      wait until rising_edge(aclk);
      for i in 0 to GC_NUM_CLIENTS-1 loop
        if rsp_valid(i) = '1' then
          assert rsp_data(i) = f_word(i, i + expected_beat(i) * GC_NUM_CLIENTS)
            report "FAIL: small-client tail data mismatch" severity failure;
          expected_beat(i) := expected_beat(i) + 1;
        end if;
      end loop;
    end loop;
    assert rsp_valid = (0 to GC_NUM_CLIENTS-1 => '0')
      report "FAIL: small-client line-rate stream did not drain" severity failure;

    -- Reset between scenarios, then fill client 0 to FIFO depth plus skid.
    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    rsp_ready <= (others => '0');
    for b in 0 to GC_FIFO_DEPTH loop
      r_id    <= (others => '0');
      r_data  <= f_word(0, b);
      r_resp  <= "01";
      r_last  <= '1';
      r_valid <= '1';
      while r_ready /= '1' loop
        wait until rising_edge(aclk);
      end loop;
      wait until rising_edge(aclk);
      r_valid <= '0';
    end loop;
    wait until rising_edge(aclk);
    assert r_ready = '0'
      report "FAIL: small-client skid did not assert backpressure" severity failure;

    -- Drain all stored beats in order, including the skid beat.
    for b in 0 to GC_FIFO_DEPTH loop
      wait until rising_edge(aclk);
      assert rsp_valid(0) = '1' and rsp_data(0) = f_word(0, b)
        report "FAIL: small-client FIFO order mismatch at beat " &
               integer'image(b) severity failure;
      rsp_ready(0) <= '1';
      wait until rising_edge(aclk);
      rsp_ready(0) <= '0';
    end loop;
    wait until rising_edge(aclk);
    assert rsp_valid(0) = '0'
      report "FAIL: small-client FIFO did not empty after drain" severity failure;

    report "ALL SMALL R-DEMUX CHECKS PASSED";
    sim_done <= true;
    wait;
  end process;

end architecture;
