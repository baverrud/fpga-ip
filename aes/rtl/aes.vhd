-----------------------------------------------------------------------
--Filename         : aes.vhd
--Description      : Configurable AXI-Stream AES encryption core.
--                 : GC_PIPELINE_STAGES=0 uses an iterative round engine.
--                 : Positive values partition rounds across pipeline stages.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;
use work.aes_pkg.all;

entity aes is
  generic (
    GC_KEY_BITS          : positive range 128 to 256 := 128;
    GC_PIPELINE_STAGES   : natural range 0 to 14     := 0
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Slave AXI-Stream for the cipher key. One beat loads the key schedule.
    s_axis_key_tdata  : in  std_logic_vector(GC_KEY_BITS - 1 downto 0);
    s_axis_key_tlast  : in  std_logic;
    s_axis_key_tvalid : in  std_logic;
    s_axis_key_tready : out std_logic;

    -- Slave AXI-Stream for 128-bit plaintext blocks.
    s_axis_tdata  : in  std_logic_vector(C_AES_BLOCK_BITS - 1 downto 0);
    s_axis_tlast  : in  std_logic;
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;

    -- Master AXI-Stream for 128-bit ciphertext blocks.
    m_axis_tdata  : out std_logic_vector(C_AES_BLOCK_BITS - 1 downto 0);
    m_axis_tlast  : out std_logic;
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic
  );
end entity;

architecture rtl of aes is

  -- AES uses four 32-bit key words for AES-128, six for AES-192, and
  -- eight for AES-256. The corresponding cipher has 10, 12, or 14 rounds.
  constant C_KEY_WORDS : positive := aes_key_words(GC_KEY_BITS);
  constant C_AES_ROUNDS : positive := aes_rounds(GC_KEY_BITS);

  -- The complete expanded key is cached once per accepted key beat and is
  -- shared by either implementation. This favors block throughput and simple
  -- round-key lookup over a smaller, iterative key-expansion datapath.
  signal r_key_schedule : aes_key_schedule_t := (others => (others => '0'));
  signal r_key_valid    : std_logic := '0';

begin

  assert GC_KEY_BITS = 128 or GC_KEY_BITS = 192 or GC_KEY_BITS = 256
    report "GC_KEY_BITS must be 128, 192, or 256" severity failure;
  assert GC_PIPELINE_STAGES = 0 or GC_PIPELINE_STAGES <= C_AES_ROUNDS
    report "GC_PIPELINE_STAGES must be zero or no greater than the AES round count"
    severity failure;

  g_iterative : if GC_PIPELINE_STAGES = 0 generate

    -- The iterative engine stores one 128-bit state and applies one complete
    -- AES round per clock. r_round identifies the round executed next.
    signal r_busy        : std_logic := '0';
    signal r_round       : natural range 1 to 14 := 1;
    signal r_state       : aes_state_t;
    signal r_input_last  : std_logic := '0';
    signal r_output      : aes_block_t := (others => '0');
    signal r_output_last : std_logic := '0';
    signal r_output_valid : std_logic := '0';

    signal key_accept  : std_logic;
    signal data_accept : std_logic;
    signal output_take : std_logic;

  begin

    -- A key may be replaced only while no block or held output is active.
    -- Data is inhibited while key valid is asserted so a simultaneous key
    -- and plaintext request cannot use the previous key schedule.
    s_axis_key_tready <= not r_busy and not r_output_valid;
    s_axis_tready <= r_key_valid and not r_busy and
                     (not r_output_valid or m_axis_tready) and
                     not s_axis_key_tvalid;

    key_accept  <= s_axis_key_tvalid and s_axis_key_tready;
    data_accept <= s_axis_tvalid and s_axis_tready;
    output_take <= r_output_valid and m_axis_tready;

    m_axis_tdata  <= r_output;
    m_axis_tlast  <= r_output_last;
    m_axis_tvalid <= r_output_valid;

    p_iterative : process(aclk)
      variable next_state : aes_state_t;
    begin
      if rising_edge(aclk) then
        if aresetn = '0' then
          r_key_schedule <= (others => (others => '0'));
          r_key_valid    <= '0';
          r_busy         <= '0';
          r_round        <= 1;
          r_state        <= (others => (others => (others => '0')));
          r_input_last   <= '0';
          r_output       <= (others => '0');
          r_output_last  <= '0';
          r_output_valid <= '0';
        else
          if key_accept then
            r_key_schedule <= aes_expand_key(s_axis_key_tdata, GC_KEY_BITS);
            r_key_valid    <= '1';
          end if;

          if output_take then
            r_output_valid <= '0';
          end if;

          if data_accept then
            -- The initial AddRoundKey is performed when the input block is
            -- accepted. Subsequent clocks execute rounds 1 through Nr.
            r_state <= aes_add_round_key(
              aes_block_to_state(s_axis_tdata), r_key_schedule, 0);
            r_input_last <= s_axis_tlast;
            r_round      <= 1;
            r_busy       <= '1';
          elsif r_busy = '1' then
            next_state := r_state;
            if r_round < C_AES_ROUNDS then
              -- All non-final rounds include MixColumns.
              next_state := aes_sub_bytes(next_state);
              next_state := aes_shift_rows(next_state);
              next_state := aes_mix_columns(next_state);
              next_state := aes_add_round_key(next_state, r_key_schedule, r_round);
              r_state <= next_state;
              r_round <= r_round + 1;
            else
              -- The final AES round intentionally omits MixColumns.
              next_state := aes_sub_bytes(next_state);
              next_state := aes_shift_rows(next_state);
              next_state := aes_add_round_key(next_state, r_key_schedule, r_round);
              r_output       <= aes_state_to_block(next_state);
              r_output_last  <= r_input_last;
              r_output_valid <= '1';
              r_busy         <= '0';
            end if;
          end if;
        end if;
      end if;
    end process;

  end generate;

  g_pipeline : if GC_PIPELINE_STAGES > 0 generate

    -- Positive stage counts select a spatially unrolled implementation.
    -- Every AES round exists in hardware; the generic controls how many
    -- consecutive rounds are placed between stage registers.
    constant C_PIPE_STAGES : positive := GC_PIPELINE_STAGES;

    type state_array_t is array (natural range <>) of aes_state_t;

    signal r_valid : std_logic_vector(0 to C_PIPE_STAGES - 1) := (others => '0');
    signal r_last  : std_logic_vector(0 to C_PIPE_STAGES - 1) := (others => '0');
    signal r_state : state_array_t(0 to C_PIPE_STAGES - 1);

    signal v_valid : std_logic_vector(0 to C_PIPE_STAGES - 1);
    signal v_last  : std_logic_vector(0 to C_PIPE_STAGES - 1);
    signal v_state : state_array_t(0 to C_PIPE_STAGES - 1);

    signal stage_ready : std_logic_vector(0 to C_PIPE_STAGES - 1);
    signal key_accept   : std_logic;
    signal data_accept  : std_logic;

    function aes_pipeline_rounds(
      input_state  : aes_state_t;
      key_schedule : aes_key_schedule_t;
      stage_index  : natural
    ) return aes_state_t is
      variable result      : aes_state_t := input_state;
      variable first_round : natural;
      variable last_round  : natural;
    begin
      -- Integer division partitions Nr rounds as evenly as possible. For
      -- example, 10 rounds over 3 stages produces groups of 3, 3, and 4.
      -- stage_index is static per generated datapath, so synthesis removes
      -- loop iterations outside this stage's [first_round, last_round] range.
      first_round := (stage_index * C_AES_ROUNDS) / C_PIPE_STAGES + 1;
      last_round  := ((stage_index + 1) * C_AES_ROUNDS) / C_PIPE_STAGES;
      for round_index in 1 to C_AES_ROUNDS loop
        if round_index >= first_round and round_index <= last_round then
          result := aes_sub_bytes(result);
          result := aes_shift_rows(result);
          if round_index < C_AES_ROUNDS then
            result := aes_mix_columns(result);
          end if;
          result := aes_add_round_key(result, key_schedule, round_index);
        end if;
      end loop;
      return result;
    end function;

  begin

    m_axis_tdata  <= aes_state_to_block(r_state(C_PIPE_STAGES - 1));
    m_axis_tlast  <= r_last(C_PIPE_STAGES - 1);
    m_axis_tvalid <= r_valid(C_PIPE_STAGES - 1);

    p_pipeline_comb : process(all)
      variable ready      : std_logic_vector(0 to C_PIPE_STAGES - 1);
      variable next_valid : std_logic_vector(0 to C_PIPE_STAGES - 1);
      variable next_last  : std_logic_vector(0 to C_PIPE_STAGES - 1);
      variable next_state : state_array_t(0 to C_PIPE_STAGES - 1);
      variable state      : aes_state_t;
      variable stage_index : natural;
    begin
      -- Elastic ready propagation permits each register to advance when it
      -- is empty or when every downstream stage through the output can move.
      ready(C_PIPE_STAGES - 1) := not r_valid(C_PIPE_STAGES - 1) or m_axis_tready;
      if C_PIPE_STAGES > 1 then
        for offset in 0 to C_PIPE_STAGES - 2 loop
          stage_index := C_PIPE_STAGES - 2 - offset;
        ready(stage_index) := not r_valid(stage_index) or ready(stage_index + 1);
        end loop;
      end if;
      stage_ready <= ready;

      next_valid := r_valid;
      next_last  := r_last;
      next_state := r_state;

      for stage_index in 0 to C_PIPE_STAGES - 1 loop
        if ready(stage_index) then
          if stage_index = 0 then
            -- Stage zero performs the initial AddRoundKey before its assigned
            -- group of normal/final AES rounds.
            next_valid(stage_index) := data_accept;
            if data_accept then
              state := aes_add_round_key(
                aes_block_to_state(s_axis_tdata), r_key_schedule, 0);
              next_state(stage_index) := aes_pipeline_rounds(
                state, r_key_schedule, stage_index);
              next_last(stage_index) := s_axis_tlast;
            end if;
          else
            -- Later stages consume only registered state from the preceding
            -- stage, preserving state, valid, and tlast under backpressure.
            next_valid(stage_index) := r_valid(stage_index - 1);
            if r_valid(stage_index - 1) then
              next_state(stage_index) := aes_pipeline_rounds(
                r_state(stage_index - 1), r_key_schedule, stage_index);
              next_last(stage_index) := r_last(stage_index - 1);
            end if;
          end if;
        end if;
      end loop;
      v_valid <= next_valid;
      v_last  <= next_last;
      v_state <= next_state;
    end process;

    -- Re-keying is allowed only when all pipeline stages are empty. Existing
    -- blocks therefore always finish with the schedule under which they were
    -- accepted.
    s_axis_key_tready <= '1' when r_valid = std_logic_vector(to_unsigned(0, r_valid'length)) else '0';
    s_axis_tready <= r_key_valid and stage_ready(0) and not s_axis_key_tvalid;
    key_accept <= s_axis_key_tvalid and s_axis_key_tready;
    data_accept <= s_axis_tvalid and s_axis_tready;

    p_pipeline_reg : process(aclk)
    begin
      if rising_edge(aclk) then
        if aresetn = '0' then
          r_key_schedule <= (others => (others => '0'));
          r_key_valid    <= '0';
          r_valid        <= (others => '0');
          r_last         <= (others => '0');
        else
          if key_accept then
            r_key_schedule <= aes_expand_key(s_axis_key_tdata, GC_KEY_BITS);
            r_key_valid    <= '1';
          end if;
          r_valid <= v_valid;
          r_last  <= v_last;
          r_state <= v_state;
        end if;
      end if;
    end process;

  end generate;

end architecture;
