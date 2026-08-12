-----------------------------------------------------------------------
--Filename         : axis_upsizer_tb.vhd
--Description      : Self-checking testbench for axis_upsizer.
--                 :  - Phase A: LINE-RATE - continuous narrow beats in,
--                 :    wide beats out with no bubble; every wide beat is
--                 :    verified against the LSB-first packing and tlast.
--                 :  - Phase B: destination backpressure (ready 3 of 4).
--                 :  - Phase C: source valid gaps (1 cycle in 4).
--                 :  - Phase D: COMBINED stress - source gaps AND
--                 :    destination burst backpressure simultaneously. The
--                 :    destination drops ready for 10 cycles after every
--                 :    even output group, which (a) holds every tlast/rresp
--                 :    beat through a multi-cycle stall (packet-boundary
--                 :    stall) and (b) backs up both the accumulator and the
--                 :    output stage so the release forces drain+transfer+
--                 :    accept in one cycle.
--                 :  - Phase E: mid-stream reset - aresetn pulses low while
--                 :    data is in flight; verifies clean recovery and a
--                 :    correct post-reset stream.
--                 :  - Hard line-rate assertion in phase A: any input bubble
--                 :    fails the run (bandwidth regression guard).
--                 :  - Packets of 2 groups so m_axis_tlast is exercised
--                 :    on every 2nd output beat.
--                 :  - AXI R channel: rresp is driven on every beat and
--                 :    verified on every matching output beat; rid is
--                 :    constant per packed group and verified throughout.
--                 :  - Watchdog to catch deadlocks instead of hanging.
--                 :  - Generic width/ratio so the same file runs the
--                 :    default 128 -> 512-bit (4:1) configuration.
--Author           : Rune Baeverrud
--Current Revision : 1.20
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity axis_upsizer_tb is
  generic (
    GC_S_WIDTH    : positive := 128;  -- narrow input width under test
    GC_RATIO      : positive := 4;    -- upsize ratio under test
    GC_ID_WIDTH   : positive := 4;    -- AXI R ID width under test
    GC_CLK_PERIOD : time := 4 ns      -- 250 MHz
  );
end entity;

architecture sim of axis_upsizer_tb is

  constant C_M_WIDTH : positive := GC_S_WIDTH * GC_RATIO;

  -- Width of the data-mismatch hex dump (kept within the bus width so the
  -- diagnostic is valid for any GC_S_WIDTH/GC_RATIO configuration).
  constant C_DIAG_W : positive := minimum(64, C_M_WIDTH);

  -- Wide-group counts per phase. Deriving narrow-word counts from these
  -- constants keeps every phase ratio-aligned for any tested GC_RATIO.
  constant C_GROUPS_A : natural := 128;                    -- phase A (line rate)
  constant C_GROUPS_B : natural := 64;                     -- phase B (backpressure)
  constant C_GROUPS_C : natural := 32;                     -- phase C (source gaps)
  constant C_GROUPS_D : natural := 64;                     -- phase D (combined stress)
  constant C_GROUPS_E : natural := 32;                     -- phase E (mid-stream reset)
  constant C_N_A      : natural := C_GROUPS_A * GC_RATIO;
  constant C_N_B      : natural := C_GROUPS_B * GC_RATIO;
  constant C_N_C      : natural := C_GROUPS_C * GC_RATIO;
  constant C_N_D      : natural := C_GROUPS_D * GC_RATIO;
  constant C_N_E      : natural := C_GROUPS_E * GC_RATIO;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal s_tdata  : std_logic_vector(GC_S_WIDTH-1 downto 0) := (others => '0');
  signal s_tlast  : std_logic := '0';
  signal s_rresp  : std_logic_vector(1 downto 0) := (others => '0');
  signal s_rid    : std_logic_vector(GC_ID_WIDTH-1 downto 0) := (others => '0');
  signal s_tvalid : std_logic := '0';
  signal s_tready : std_logic;

  signal m_tdata  : std_logic_vector(C_M_WIDTH-1 downto 0);
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
  signal phase_b       : std_logic := '0';
  signal phase_c       : std_logic := '0';
  signal phase_d       : std_logic := '0';
  signal phase_e       : std_logic := '0';
  signal phase_e_ready : std_logic := '0';
  signal phase_e_done  : std_logic := '0';

  signal sim_done : boolean := false;

  -- Expected narrow word i: binary counter, truncated only when the
  -- configured data width cannot represent the complete value.
  function f_word(i : natural) return std_logic_vector is
    variable v : std_logic_vector(GC_S_WIDTH-1 downto 0) := (others => '0');
    variable n : natural := i;
  begin
    for b in 0 to GC_S_WIDTH-1 loop
      if (n mod 2) = 1 then
        v(b) := '1';
      end if;
      n := n / 2;
    end loop;
    return v;
  end function;

  -- Expected wide word for group g: LSB-first packing of the GC_RATIO
  -- narrow words [R*g .. R*g+R-1] (word R*g in the low bits).
  function f_pack(g : natural) return std_logic_vector is
    variable v : std_logic_vector(C_M_WIDTH-1 downto 0) := (others => '0');
  begin
    for k in 0 to GC_RATIO-1 loop
      v((k+1)*GC_S_WIDTH-1 downto k*GC_S_WIDTH) := f_word(g*GC_RATIO + k);
    end loop;
    return v;
  end function;

  -- tlast on the last narrow word of every 2-group packet.
  function f_tlast(i : natural) return std_logic is
  begin
    if (i mod (2*GC_RATIO)) = (2*GC_RATIO - 1) then
      return '1';
    else
      return '0';
    end if;
  end function;

  -- Expected AXI R response for packet p (packet = 2 groups). Cycles so a
  -- mis-routed rresp is caught.
  function f_resp(p : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(p mod 4, 2));
  end function;

  -- Expected AXI R ID for packet p (constant per burst).
  function f_rid(p : natural) return std_logic_vector is
    variable v : std_logic_vector(GC_ID_WIDTH-1 downto 0) := (others => '0');
    variable n : natural := p;
  begin
    for b in 0 to GC_ID_WIDTH-1 loop
      if (n mod 2) = 1 then
        v(b) := '1';
      end if;
      n := n / 2;
    end loop;
    return v;
  end function;

begin

  u_dut : entity work.axis_upsizer
    generic map (
      GC_S_TDATA_WIDTH => GC_S_WIDTH,
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

    -- Hold the destination while the source fills the output stage,
    -- accumulator, and one-beat skid register, then reset in flight.
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
    variable v_sent   : natural := 0;
    variable v_cycles : natural := 0;
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

    -- Phase A: continuous streaming (input line rate).
    v_sent   := 0;
    v_cycles := 0;
    s_tvalid <= '1';
    while v_sent < C_N_A loop
      s_tdata <= f_word(v_sent);
      s_tlast <= f_tlast(v_sent);
      s_rid   <= f_rid(v_sent / (2*GC_RATIO));
      s_rresp <= f_resp(v_sent / (2*GC_RATIO));
      wait until rising_edge(aclk);
      if s_tready = '1' then
        v_sent := v_sent + 1;
      end if;
      v_cycles := v_cycles + 1;
    end loop;
    s_tvalid <= '0';
    s_tlast  <= '0';
    -- Hard line-rate guard: any input bubble fails (bandwidth regression).
    -- Assert form (not a bare report in an if) so XSim static elaboration
    -- does not fire it against the variable's initial value; the runtime
    -- check and diagnostic are unchanged.
    if v_cycles /= C_N_A then
      write(l, string'("FAIL: phase A line rate not sustained: " &
                       integer'image(v_sent) & " words in " &
                       integer'image(v_cycles) & " cycles"));
      writeline(output, l);
    end if;
    assert v_cycles = C_N_A
      report "line rate violation in phase A"
      severity failure;
    write(l, string'("Stim: phase A sent " & integer'image(v_sent) &
                     " words in " & integer'image(v_cycles) & " cycles"));
    writeline(output, l);

    -- Phase B: continue the sequence under destination backpressure.
    wait until phase_b = '1';
    wait until rising_edge(aclk);
    v_sent := C_N_A;
    s_tvalid <= '1';
    while v_sent < C_N_A + C_N_B loop
      s_tdata <= f_word(v_sent);
      s_tlast <= f_tlast(v_sent);
      s_rid   <= f_rid(v_sent / (2*GC_RATIO));
      s_rresp <= f_resp(v_sent / (2*GC_RATIO));
      wait until rising_edge(aclk);
      if s_tready = '1' then
        v_sent := v_sent + 1;
      end if;
    end loop;
    s_tvalid <= '0';
    s_tlast  <= '0';
    write(l, string'("Stim: phase B sent " & integer'image(v_sent) & " words"));
    writeline(output, l);

    -- Phase C: restart a fresh sequence with source valid gaps (1 in 4).
    wait until phase_c = '1';
    wait until rising_edge(aclk);
    v_sent := 0;
    v_gap  := 0;
    s_tvalid <= '1';
    while v_sent < C_N_C loop
      s_tdata <= f_word(v_sent);
      s_tlast <= f_tlast(v_sent);
      s_rid   <= f_rid(v_sent / (2*GC_RATIO));
      s_rresp <= f_resp(v_sent / (2*GC_RATIO));
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
    write(l, string'("Stim: phase C sent " & integer'image(v_sent) & " words with gaps"));
    writeline(output, l);

    -- Phase D: fresh sequence with source gaps AND destination burst
    -- backpressure simultaneously (combined stress).
    wait until phase_d = '1';
    wait until rising_edge(aclk);
    v_sent := 0;
    v_gap  := 0;
    s_tvalid <= '1';
    while v_sent < C_N_D loop
      s_tdata <= f_word(v_sent);
      s_tlast <= f_tlast(v_sent);
      s_rid   <= f_rid(v_sent / (2*GC_RATIO));
      s_rresp <= f_resp(v_sent / (2*GC_RATIO));
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
                     " words under combined stress"));
    writeline(output, l);

    -- Phase E: stream across a mid-stream reset pulse. The DUT is wiped
    -- by the reset, so restart the countable sequence after release.
    wait until phase_e = '1';
    wait until rising_edge(aclk);
    v_sent := 0;
    s_tvalid <= '1';
    while v_sent < C_N_E loop
      s_tdata <= f_word(v_sent);
      s_tlast <= f_tlast(v_sent);
      s_rid   <= f_rid(v_sent / (2*GC_RATIO));
      s_rresp <= f_resp(v_sent / (2*GC_RATIO));
      wait until rising_edge(aclk);
      if aresetn = '0' then
        -- Mid-stream reset hit: drop valid so no stale word is presented
        -- to the just-released DUT (s_tdata still holds the pre-reset
        -- beat), wait for release, then restart from word 0.
        s_tvalid <= '0';
        wait until aresetn = '1';
        wait until rising_edge(aclk);
        v_sent := 0;
        s_tvalid <= '1';
        s_tdata  <= f_word(0);
        s_tlast  <= f_tlast(0);
        s_rresp  <= f_resp(0);
        s_rid    <= f_rid(0);
      elsif s_tready = '1' then
        v_sent := v_sent + 1;
      end if;
    end loop;
    s_tvalid <= '0';
    s_tlast  <= '0';
    write(l, string'("Stim: phase E sent " & integer'image(v_sent) &
                     " words after mid-stream reset"));
    writeline(output, l);

    wait until phase_e_done = '1';
    sim_done <= true;
    wait;
  end process;

  -- Destination backpressure generator. Phase B: ready 3 of 4. Phase D:
  -- after accepting every even output group (the beat before a tlast beat)
  -- drop ready for 10 cycles, which holds each tlast/rresp beat through a
  -- multi-cycle stall (packet-boundary stall) and backs up both pipeline
  -- stages so the release forces drain+transfer+accept in one cycle.
  -- Always ready otherwise (phases A, C, E).
  p_backpressure : process(aclk)
    variable v_cnt   : natural := 0;  -- phase B cycle counter
    variable v_g     : natural := 0;  -- phase D accepted-beat counter
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
            -- Just accepted an even group; next beat (odd index) is tlast.
            if (v_g mod 2) = 1 then
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

  -- Destination checker: verify every wide beat (data + tlast) and drive
  -- the phase transitions. The group counter is continuous across phases
  -- A and B (the source sequence is continuous) and resets for phase C.
  p_check : process(aclk)
    variable v_g            : natural := 0;      -- output group counter
    variable v_phase_c_prev : std_logic := '0';
    variable v_phase_d_prev : std_logic := '0';
    variable v_phase_e_prev : std_logic := '0';
    variable v_m_stalled    : boolean := false;
    variable v_m_data  : std_logic_vector(C_M_WIDTH-1 downto 0);
    variable v_m_tlast : std_logic;
    variable v_m_rresp : std_logic_vector(1 downto 0);
    variable v_m_rid   : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    variable v_s_stalled : boolean := false;
    variable v_s_data  : std_logic_vector(GC_S_WIDTH-1 downto 0);
    variable v_s_tlast : std_logic;
    variable v_s_rresp : std_logic_vector(1 downto 0);
    variable v_s_rid   : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    variable l         : line;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        v_g := 0;
        v_phase_c_prev := '0';
        v_phase_d_prev := '0';
        v_phase_e_prev := '0';
        v_m_stalled := false;
        v_s_stalled := false;
      else
        -- Reset the group counter when a phase starts a fresh source
        -- sequence (phases C, D and E restart the word count).
        if (v_phase_c_prev = '0') and (phase_c = '1') then
          v_g := 0;
        end if;
        v_phase_c_prev := phase_c;
        if (v_phase_d_prev = '0') and (phase_d = '1') then
          v_g := 0;
        end if;
        v_phase_d_prev := phase_d;
        if (v_phase_e_prev = '0') and (phase_e = '1') then
          v_g := 0;
        end if;
        v_phase_e_prev := phase_e;

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

        -- Verify order, data and tlast on every accepted wide beat.
        if (m_tvalid = '1') and (m_tready = '1') then
          if m_tdata /= f_pack(v_g) then
            write(l, string'("FAIL: output group " & integer'image(v_g) &
                             " data mismatch (phD=" & std_logic'image(phase_d) &
                             " phE=" & std_logic'image(phase_e) & ")"));
            writeline(output, l);
            write(l, string'("  got low" & integer'image(C_DIAG_W) & "="));
            hwrite(l, m_tdata(C_DIAG_W-1 downto 0));
            writeline(output, l);
            write(l, string'("  exp low" & integer'image(C_DIAG_W) & "="));
            hwrite(l, f_pack(v_g)(C_DIAG_W-1 downto 0));
            writeline(output, l);
            report "data mismatch" severity failure;
          end if;
          if m_tlast /= f_tlast(v_g*GC_RATIO + GC_RATIO - 1) then
            write(l, string'("FAIL: output group " & integer'image(v_g) &
                             " tlast mismatch"));
            writeline(output, l);
            report "tlast mismatch" severity failure;
          end if;
          -- AXI R channel: rid and rresp are checked on every output beat.
          if m_rid /= f_rid(v_g / 2) then
            write(l, string'("FAIL: output group " & integer'image(v_g) &
                             " rid mismatch"));
            writeline(output, l);
            report "rid mismatch" severity failure;
          end if;
          if m_rresp /= f_resp(v_g / 2) then
            write(l, string'("FAIL: output group " & integer'image(v_g) &
                             " rresp mismatch"));
            writeline(output, l);
            report "rresp mismatch" severity failure;
          end if;
          v_g := v_g + 1;
        end if;

        -- Phase A completion.
        if (phase_a_done = '0') and (v_g = C_N_A / GC_RATIO) then
          phase_a_done <= '1';
          write(l, string'("Check: phase A received " & integer'image(v_g) &
                           " wide beats (line rate, no loss)"));
          writeline(output, l);
        end if;

        -- Phase B completion.
        if (phase_b_done = '0') and (v_g = (C_N_A + C_N_B) / GC_RATIO) then
          phase_b_done <= '1';
          write(l, string'("Check: phase B received " & integer'image(v_g) &
                           " wide beats under backpressure"));
          writeline(output, l);
        end if;

        -- Phase C completion.
        if (phase_c_done = '0') and (phase_c = '1') and
           (v_g = C_N_C / GC_RATIO) then
          phase_c_done <= '1';
          write(l, string'("Check: phase C received " & integer'image(v_g) &
                           " wide beats with source gaps"));
          writeline(output, l);
        end if;

        -- Phase D completion.
        if (phase_d_done = '0') and (phase_d = '1') and
           (v_g = C_N_D / GC_RATIO) then
          phase_d_done <= '1';
          write(l, string'("Check: phase D received " & integer'image(v_g) &
                           " wide beats under combined stress"));
          writeline(output, l);
        end if;

        -- Phase E completion -> success.
        if (phase_e_done = '0') and (phase_e = '1') and
           (v_g = C_N_E / GC_RATIO) then
          phase_e_done <= '1';
          write(l, string'("Check: phase E received " & integer'image(v_g) &
                           " wide beats after mid-stream reset"));
          writeline(output, l);
          report "ALL UPSIZER CHECKS PASSED";
        end if;
      end if;
    end if;
  end process;

  -- Watchdog (prevents a deadlock from hanging the batch run).
  p_watchdog : process
  begin
    wait for 1 ms;
    if not sim_done then
      report "FAIL: watchdog timeout (possible upsizer deadlock)" severity failure;
    end if;
    wait;
  end process;

end architecture;
