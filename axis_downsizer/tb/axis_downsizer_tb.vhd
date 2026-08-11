-----------------------------------------------------------------------
--Filename         : axis_downsizer_tb.vhd
--Description      : Self-checking testbench for axis_downsizer.
--                 :  - Phase A: OUTPUT LINE-RATE - continuous wide beats
--                 :    in, back-to-back narrow beats out with no bubble;
--                 :    every narrow beat verified against the LSB-first
--                 :    unpacking, tlast, rresp and rid. A hard assertion
--                 :    fails the run on any output bubble.
--                 :  - Phase B: destination backpressure (ready 3 of 4).
--                 :  - Phase C: source valid gaps (1 cycle in 4).
--                 :  - Phase D: COMBINED stress - source gaps AND
--                 :    destination burst backpressure simultaneously.
--                 :  - Phase E: mid-stream reset - aresetn pulses low while
--                 :    data is in flight; verifies clean recovery.
--                 :  - AXI R channel: rresp and rid are uniform per wide
--                 :    group and verified on every narrow output beat.
--                 :  - Payload/sideband stability checked while either
--                 :    side is stalled; watchdog catches deadlocks.
--                 :  - Generic width/ratio so the same file runs the
--                 :    default 512 -> 128-bit (4:1) configuration.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity axis_downsizer_tb is
  generic (
    GC_M_WIDTH    : positive := 128;  -- narrow output width under test
    GC_RATIO      : positive := 4;    -- downsize ratio under test
    GC_ID_WIDTH   : positive := 4;    -- AXI R ID width under test
    GC_CLK_PERIOD : time := 4 ns      -- 250 MHz
  );
end entity;

architecture sim of axis_downsizer_tb is

  constant C_M_WIDTH : positive := GC_M_WIDTH * GC_RATIO;  -- wide input width

  -- Width of the data-mismatch hex dump (kept within the bus width so the
  -- diagnostic is valid for any GC_M_WIDTH/GC_RATIO configuration).
  constant C_DIAG_W : positive := minimum(64, GC_M_WIDTH);

  -- Wide-beat counts per phase. Output narrow words per phase are
  -- C_N_* * GC_RATIO.
  constant C_N_A : natural := 128;  -- phase A (output line rate)
  constant C_N_B : natural := 64;   -- phase B (backpressure)
  constant C_N_C : natural := 32;   -- phase C (source gaps)
  constant C_N_D : natural := 64;   -- phase D (combined stress)
  constant C_N_E : natural := 32;   -- phase E (mid-stream reset)

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal s_tdata  : std_logic_vector(C_M_WIDTH-1 downto 0) := (others => '0');
  signal s_tlast  : std_logic := '0';
  signal s_rresp  : std_logic_vector(1 downto 0) := (others => '0');
  signal s_rid    : std_logic_vector(GC_ID_WIDTH-1 downto 0) := (others => '0');
  signal s_tvalid : std_logic := '0';
  signal s_tready : std_logic;

  signal m_tdata  : std_logic_vector(GC_M_WIDTH-1 downto 0);
  signal m_tlast  : std_logic;
  signal m_rresp  : std_logic_vector(1 downto 0);
  signal m_rid    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal m_tvalid : std_logic;
  signal m_tready : std_logic := '0';

  -- Phase control (see p_reset_ctrl / p_check).
  signal phase_a_done  : std_logic := '0';
  signal phase_b_done  : std_logic := '0';
  signal phase_c_done  : std_logic := '0';
  signal phase_d_done  : std_logic := '0';
  signal phase_e_done  : std_logic := '0';
  signal phase_b       : std_logic := '0';
  signal phase_c       : std_logic := '0';
  signal phase_d       : std_logic := '0';
  signal phase_e       : std_logic := '0';
  signal phase_e_ready : std_logic := '0';

  signal sim_done : boolean := false;

  -- Expected narrow word n: binary counter, truncated only when the
  -- configured data width cannot represent the complete value.
  function f_word(n : natural) return std_logic_vector is
    variable v : std_logic_vector(GC_M_WIDTH-1 downto 0) := (others => '0');
    variable m : natural := n;
  begin
    for b in 0 to GC_M_WIDTH-1 loop
      if (m mod 2) = 1 then
        v(b) := '1';
      end if;
      m := m / 2;
    end loop;
    return v;
  end function;

  -- Wide word for group g: LSB-first packing of the GC_RATIO narrow words
  -- [R*g .. R*g+R-1] (word R*g in the low bits).
  function f_pack(g : natural) return std_logic_vector is
    variable v : std_logic_vector(C_M_WIDTH-1 downto 0) := (others => '0');
  begin
    for k in 0 to GC_RATIO-1 loop
      v((k+1)*GC_M_WIDTH-1 downto k*GC_M_WIDTH) := f_word(g*GC_RATIO + k);
    end loop;
    return v;
  end function;

  -- tlast on the input wide beat: packet end on every odd group (packets
  -- of 2 groups).
  function f_tlast_in(g : natural) return std_logic is
  begin
    if (g mod 2) = 1 then
      return '1';
    else
      return '0';
    end if;
  end function;

  -- Expected tlast on output narrow word n: the last slice of an odd group.
  function f_tlast_out(n : natural) return std_logic is
  begin
    if (n mod (2*GC_RATIO)) = (2*GC_RATIO - 1) then
      return '1';
    else
      return '0';
    end if;
  end function;

  -- Expected AXI R response for group g (uniform across the group).
  function f_resp(g : natural) return std_logic_vector is
    variable v : std_logic_vector(1 downto 0) := (others => '0');
    variable m : natural := g;
  begin
    for b in 0 to 1 loop
      if (m mod 2) = 1 then
        v(b) := '1';
      end if;
      m := m / 2;
    end loop;
    return v;
  end function;

  -- Expected AXI R ID for group g.
  function f_rid(g : natural) return std_logic_vector is
    variable v : std_logic_vector(GC_ID_WIDTH-1 downto 0) := (others => '0');
    variable m : natural := g;
  begin
    for b in 0 to GC_ID_WIDTH-1 loop
      if (m mod 2) = 1 then
        v(b) := '1';
      end if;
      m := m / 2;
    end loop;
    return v;
  end function;

begin

  u_dut : entity work.axis_downsizer
    generic map (
      GC_M_TDATA_WIDTH => GC_M_WIDTH,
      GC_RATIO         => GC_RATIO,
      GC_ID_WIDTH      => GC_ID_WIDTH
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => s_tdata,
      s_axis_tlast  => s_tlast,
      s_axis_rresp  => s_rresp,
      s_axis_rid    => s_rid,
      s_axis_tvalid => s_tvalid,
      s_axis_tready => s_tready,
      m_axis_tdata  => m_tdata,
      m_axis_tlast  => m_tlast,
      m_axis_rresp  => m_rresp,
      m_axis_rid    => m_rid,
      m_axis_tvalid => m_tvalid,
      m_axis_tready => m_tready
    );

  -- Clock generator: hold the clock low before the first rising edge, then
  -- stop it once the stimulus process marks the simulation complete.
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

  -- Reset release + phase orchestration.
  p_reset_ctrl : process
  begin
    aresetn <= '0';
    phase_b <= '0';
    phase_c <= '0';
    phase_d <= '0';
    phase_e <= '0';
    phase_e_ready <= '0';
    for i in 1 to 5 loop
      wait until rising_edge(aclk);
    end loop;
    aresetn <= '1';

    wait until phase_a_done = '1';
    phase_b <= '1';               -- enable destination backpressure

    wait until phase_b_done = '1';
    phase_b <= '0';
    phase_c <= '1';               -- allow phase C (source gaps)

    wait until phase_c_done = '1';
    phase_c <= '0';
    phase_d <= '1';               -- allow phase D (combined stress)

    wait until phase_d_done = '1';
    phase_d <= '0';
    phase_e <= '1';               -- allow phase E (mid-stream reset)

    -- Hold the destination while the source fills the pipeline, then reset
    -- in flight.
    for i in 1 to (2*GC_RATIO + 3) loop
      wait until rising_edge(aclk);
    end loop;
    aresetn <= '0';
    for i in 1 to 3 loop
      wait until rising_edge(aclk);
    end loop;
    aresetn <= '1';
    phase_e_ready <= '1';
    wait;
  end process;

  -- Source stimulus.
  p_stim : process
    variable v_sent   : natural := 0;  -- wide beats sent
    variable v_cycles : natural := 0;  -- phase A input cycles
    variable v_gap    : natural := 0;
    variable l : line;
  begin
    s_tvalid <= '0';
    s_tdata  <= (others => '0');
    s_tlast  <= '0';
    s_rresp  <= (others => '0');
    s_rid    <= (others => '0');
    wait until aresetn = '1';
    wait until rising_edge(aclk);

    -- Phase A: continuous wide beats (input paced by the DUT at one beat
    -- every GC_RATIO output cycles).
    v_sent   := 0;
    v_cycles := 0;
    s_tvalid <= '1';
    while v_sent < C_N_A loop
      s_tdata <= f_pack(v_sent);
      s_tlast <= f_tlast_in(v_sent);
      s_rresp <= f_resp(v_sent);
      s_rid   <= f_rid(v_sent);
      wait until rising_edge(aclk);
      if s_tready = '1' then
        v_sent := v_sent + 1;
      end if;
      v_cycles := v_cycles + 1;
    end loop;
    s_tvalid <= '0';
    s_tlast  <= '0';
    write(l, string'("Stim: phase A sent " & integer'image(v_sent) &
                     " wide beats in " & integer'image(v_cycles) & " cycles"));
    writeline(output, l);

    -- Phase B: continue under destination backpressure.
    wait until phase_b = '1';
    wait until rising_edge(aclk);
    v_sent := C_N_A;
    s_tvalid <= '1';
    while v_sent < C_N_A + C_N_B loop
      s_tdata <= f_pack(v_sent);
      s_tlast <= f_tlast_in(v_sent);
      s_rresp <= f_resp(v_sent);
      s_rid   <= f_rid(v_sent);
      wait until rising_edge(aclk);
      if s_tready = '1' then
        v_sent := v_sent + 1;
      end if;
    end loop;
    s_tvalid <= '0';
    s_tlast  <= '0';
    write(l, string'("Stim: phase B sent " & integer'image(v_sent) & " wide beats"));
    writeline(output, l);

    -- Phase C: restart a fresh sequence with source valid gaps (1 in 4).
    wait until phase_c = '1';
    wait until rising_edge(aclk);
    v_sent := 0;
    v_gap  := 0;
    s_tvalid <= '1';
    while v_sent < C_N_C loop
      s_tdata <= f_pack(v_sent);
      s_tlast <= f_tlast_in(v_sent);
      s_rresp <= f_resp(v_sent);
      s_rid   <= f_rid(v_sent);
      wait until rising_edge(aclk);
      if (s_tvalid = '1') and (s_tready = '1') then
        v_sent := v_sent + 1;
      end if;
      v_gap := v_gap + 1;
      if (v_gap mod 4) = 3 then
        s_tvalid <= '0';
      else
        s_tvalid <= '1';
      end if;
    end loop;
    s_tvalid <= '0';
    s_tlast  <= '0';
    write(l, string'("Stim: phase C sent " & integer'image(v_sent) & " wide beats with gaps"));
    writeline(output, l);

    -- Phase D: fresh sequence with source gaps AND destination burst
    -- backpressure simultaneously (combined stress).
    wait until phase_d = '1';
    wait until rising_edge(aclk);
    v_sent := 0;
    v_gap  := 0;
    s_tvalid <= '1';
    while v_sent < C_N_D loop
      s_tdata <= f_pack(v_sent);
      s_tlast <= f_tlast_in(v_sent);
      s_rresp <= f_resp(v_sent);
      s_rid   <= f_rid(v_sent);
      wait until rising_edge(aclk);
      if (s_tvalid = '1') and (s_tready = '1') then
        v_sent := v_sent + 1;
      end if;
      v_gap := v_gap + 1;
      if (v_gap mod 4) = 3 then
        s_tvalid <= '0';
      else
        s_tvalid <= '1';
      end if;
    end loop;
    s_tvalid <= '0';
    s_tlast  <= '0';
    write(l, string'("Stim: phase D sent " & integer'image(v_sent) &
                     " wide beats under combined stress"));
    writeline(output, l);

    -- Phase E: stream across a mid-stream reset pulse. The DUT is wiped
    -- by the reset, so restart the countable sequence after release.
    wait until phase_e = '1';
    wait until rising_edge(aclk);
    v_sent := 0;
    s_tvalid <= '1';
    while v_sent < C_N_E loop
      s_tdata <= f_pack(v_sent);
      s_tlast <= f_tlast_in(v_sent);
      s_rresp <= f_resp(v_sent);
      s_rid   <= f_rid(v_sent);
      wait until rising_edge(aclk);
      if aresetn = '0' then
        -- Mid-stream reset hit: drop valid so no stale word is presented
        -- to the just-released DUT, wait for release, then restart.
        s_tvalid <= '0';
        wait until aresetn = '1';
        wait until rising_edge(aclk);
        v_sent := 0;
        s_tvalid <= '1';
        s_tdata  <= f_pack(0);
        s_tlast  <= f_tlast_in(0);
        s_rresp  <= f_resp(0);
        s_rid    <= f_rid(0);
      elsif s_tready = '1' then
        v_sent := v_sent + 1;
      end if;
    end loop;
    s_tvalid <= '0';
    s_tlast  <= '0';
    write(l, string'("Stim: phase E sent " & integer'image(v_sent) &
                     " wide beats after mid-stream reset"));
    writeline(output, l);

    wait until phase_e_done = '1';
    sim_done <= true;
    wait;
  end process;

  -- Destination backpressure generator. Phase B: ready 3 of 4. Phase D:
  -- after every even output group drop ready for 10 cycles (backs up the
  -- pipeline and holds output beats through a multi-cycle stall). Phase E:
  -- hold ready low until the mid-stream reset completes. Always ready
  -- otherwise (phases A, C).
  p_backpressure : process(aclk)
    variable v_cnt   : natural := 0;  -- phase B cycle counter
    variable v_g     : natural := 0;  -- phase D accepted-group counter
    variable v_burst : natural := 0;  -- phase D burst-stall remaining
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        v_cnt   := 0;
        v_g     := 0;
        v_burst := 0;
        m_tready <= '0';
      else
        if phase_b = '1' then
          if (v_cnt mod 4) = 3 then
            m_tready <= '0';
          else
            m_tready <= '1';
          end if;
          v_cnt := v_cnt + 1;
        elsif phase_d = '1' then
          if (m_tvalid = '1') and (m_tready = '1') then
            v_g := v_g + 1;
            -- Just accepted the last slice of an even group; next group is
            -- a tlast group. Stall for 10 cycles.
            if (v_g mod GC_RATIO) = 0 then
              v_burst := 10;
            end if;
          end if;
          if v_burst > 0 then
            v_burst := v_burst - 1;
            m_tready <= '0';
          else
            m_tready <= '1';
          end if;
        elsif (phase_e = '1') and (phase_e_ready = '0') then
          m_tready <= '0';
        else
          m_tready <= '1';
        end if;
      end if;
    end if;
  end process;

  -- Destination checker: verify every narrow output beat (data, tlast,
  -- rresp, rid) and drive the phase transitions. v_w counts narrow output
  -- words; it resets for phases C, D and E which restart the sequence.
  p_check : process(aclk)
    variable v_w            : natural := 0;      -- narrow output word counter
    variable v_a_started    : boolean := false;  -- phase A first word seen
    variable v_phase_c_prev : std_logic := '0';
    variable v_phase_d_prev : std_logic := '0';
    variable v_phase_e_prev : std_logic := '0';
    variable v_m_stalled    : boolean := false;
    variable v_m_data  : std_logic_vector(GC_M_WIDTH-1 downto 0);
    variable v_m_tlast : std_logic;
    variable v_m_rresp : std_logic_vector(1 downto 0);
    variable v_m_rid   : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    variable v_s_stalled : boolean := false;
    variable v_s_data  : std_logic_vector(C_M_WIDTH-1 downto 0);
    variable v_s_tlast : std_logic;
    variable v_s_rresp : std_logic_vector(1 downto 0);
    variable v_s_rid   : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    variable l         : line;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        v_w            := 0;
        v_a_started    := false;
        v_phase_c_prev := '0';
        v_phase_d_prev := '0';
        v_phase_e_prev := '0';
        v_m_stalled    := false;
        v_s_stalled    := false;
      else
        -- Reset the word counter when a phase starts a fresh source
        -- sequence (phases C, D and E restart the count).
        if (v_phase_c_prev = '0') and (phase_c = '1') then
          v_w := 0;
        end if;
        v_phase_c_prev := phase_c;
        if (v_phase_d_prev = '0') and (phase_d = '1') then
          v_w := 0;
        end if;
        v_phase_d_prev := phase_d;
        if (v_phase_e_prev = '0') and (phase_e = '1') then
          v_w := 0;
        end if;
        v_phase_e_prev := phase_e;

        -- Hard line-rate guard: in phase A, once the first output word has
        -- appeared, every cycle must produce a word (any bubble fails).
        if (phase_a_done = '0') and (v_a_started) then
          if not ((m_tvalid = '1') and (m_tready = '1')) then
            report "FAIL: phase A output bubble (line rate lost)"
              severity failure;
          end if;
        end if;

        -- AXI stability checks while either side is stalled.
        if (m_tvalid = '1') and (m_tready = '0') then
          if v_m_stalled then
            assert m_tdata = v_m_data and m_tlast = v_m_tlast and
                   m_rresp = v_m_rresp and m_rid = v_m_rid
              report "master payload changed while m_axis_tready was low"
              severity failure;
          else
            v_m_data  := m_tdata;
            v_m_tlast := m_tlast;
            v_m_rresp := m_rresp;
            v_m_rid   := m_rid;
          end if;
          v_m_stalled := true;
        else
          v_m_stalled := false;
        end if;

        if (s_tvalid = '1') and (s_tready = '0') then
          if v_s_stalled then
            assert s_tdata = v_s_data and s_tlast = v_s_tlast and
                   s_rresp = v_s_rresp and s_rid = v_s_rid
              report "slave payload changed while s_axis_tready was low"
              severity failure;
          else
            v_s_data  := s_tdata;
            v_s_tlast := s_tlast;
            v_s_rresp := s_rresp;
            v_s_rid   := s_rid;
          end if;
          v_s_stalled := true;
        else
          v_s_stalled := false;
        end if;

        -- Verify every accepted narrow output word.
        if (m_tvalid = '1') and (m_tready = '1') then
          if m_tdata /= f_word(v_w) then
            write(l, string'("FAIL: output word " & integer'image(v_w) &
                             " data mismatch"));
            writeline(output, l);
            write(l, string'("  got low" & integer'image(C_DIAG_W) & "="));
            hwrite(l, m_tdata(C_DIAG_W-1 downto 0));
            writeline(output, l);
            write(l, string'("  exp low" & integer'image(C_DIAG_W) & "="));
            hwrite(l, f_word(v_w)(C_DIAG_W-1 downto 0));
            writeline(output, l);
            report "data mismatch" severity failure;
          end if;
          if m_tlast /= f_tlast_out(v_w) then
            write(l, string'("FAIL: output word " & integer'image(v_w) &
                             " tlast mismatch"));
            writeline(output, l);
            report "tlast mismatch" severity failure;
          end if;
          -- AXI R channel: rresp and rid are uniform per group (group =
          -- v_w / GC_RATIO).
          if m_rresp /= f_resp(v_w / GC_RATIO) then
            write(l, string'("FAIL: output word " & integer'image(v_w) &
                             " rresp mismatch"));
            writeline(output, l);
            report "rresp mismatch" severity failure;
          end if;
          if m_rid /= f_rid(v_w / GC_RATIO) then
            write(l, string'("FAIL: output word " & integer'image(v_w) &
                             " rid mismatch"));
            writeline(output, l);
            report "rid mismatch" severity failure;
          end if;
          v_w := v_w + 1;
          if (phase_a_done = '0') and (not v_a_started) then
            v_a_started := true;
          end if;
        end if;

        -- Phase A completion.
        if (phase_a_done = '0') and (v_w = C_N_A * GC_RATIO) then
          phase_a_done <= '1';
          write(l, string'("Check: phase A received " & integer'image(v_w) &
                           " narrow words (output line rate, no loss)"));
          writeline(output, l);
        end if;

        -- Phase B completion.
        if (phase_b_done = '0') and (v_w = (C_N_A + C_N_B) * GC_RATIO) then
          phase_b_done <= '1';
          write(l, string'("Check: phase B received " & integer'image(v_w) &
                           " narrow words under backpressure"));
          writeline(output, l);
        end if;

        -- Phase C completion.
        if (phase_c_done = '0') and (phase_c = '1') and
           (v_w = C_N_C * GC_RATIO) then
          phase_c_done <= '1';
          write(l, string'("Check: phase C received " & integer'image(v_w) &
                           " narrow words with source gaps"));
          writeline(output, l);
        end if;

        -- Phase D completion.
        if (phase_d_done = '0') and (phase_d = '1') and
           (v_w = C_N_D * GC_RATIO) then
          phase_d_done <= '1';
          write(l, string'("Check: phase D received " & integer'image(v_w) &
                           " narrow words under combined stress"));
          writeline(output, l);
        end if;

        -- Phase E completion -> success.
        if (phase_e_done = '0') and (phase_e = '1') and
           (v_w = C_N_E * GC_RATIO) then
          phase_e_done <= '1';
          write(l, string'("Check: phase E received " & integer'image(v_w) &
                           " narrow words after mid-stream reset"));
          writeline(output, l);
          report "ALL DOWNSIZER CHECKS PASSED";
        end if;
      end if;
    end if;
  end process;

  -- Watchdog (prevents a deadlock from hanging the batch run).
  p_watchdog : process
  begin
    wait for 1 ms;
    if not sim_done then
      report "FAIL: watchdog timeout (possible downsizer deadlock)" severity failure;
    end if;
    wait;
  end process;

end architecture;
