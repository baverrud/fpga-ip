-----------------------------------------------------------------------
--Filename         : mem_image.vhd
--Description      : File backed memory image store for simulation.
--                 :
--                 : Reads an Intel HEX file at time zero and serves the
--                 : image as a simple read port.  The file's own records
--                 : decide where the image lives: how many regions it has,
--                 : where they start and how large they are.  No address
--                 : is compiled into this entity.
--                 :
--                 : Records that are separated by more than GC_GAP_BYTES
--                 : unloaded addresses become separate regions; records
--                 : that are closer than that are merged into one region
--                 : (the space between them then reads as zero).  Raise
--                 : GC_GAP_BYTES above the spacing between records to
--                 : model one sparse region instead of several dense ones.
--                 :
--                 : A read is a hit when every byte of it lies inside one
--                 : region.  Addresses outside every region are a miss, and
--                 : GC_OUTSIDE selects what a miss drives:
--                 :   "fail"   - stop the simulation, naming the address
--                 :   "poison" - drive the poison word (0xDEADBEEF)
--                 :   "zero"   - drive all zeros
--                 :
--                 : The store is a plain array variable, one slice of
--                 : GC_REGION_WORDS words per region, rather than an access
--                 : type: allocating an unconstrained array dynamically is
--                 : not portable (XSim 2023.2 mis-sizes it, or stops the
--                 : compiler).  GC_REGION_WORDS is therefore the one
--                 : capacity limit, and it is a generic.
--                 :
--                 : This entity is for simulation only: it uses textio,
--                 : which cannot be synthesised.  There is deliberately no
--                 : synthesis wrapper (see the README).
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.mem_image_pkg.all;

entity mem_image is
  generic (
    -- Bytes served per read (4 for 32 bit data, 16 for a 128 bit bus).
    GC_DATA_BYTES   : positive := 16;
    -- Width of the read address (byte address).
    GC_ADDR_WIDTH   : positive := 32;
    -- Image file.  Resolved against the run directory and its parents,
    -- so both a path relative to the IP and an absolute path work.
    GC_FILE         : string   := "";
    -- Loaded records beyond this many separate regions are an error.
    GC_MAX_REGIONS  : positive := 4;
    -- Unloaded address span that still counts as one region.
    GC_GAP_BYTES    : natural  := 4096;
    -- Capacity of one region, in 32 bit words (16384 = 64 KiB).  A region
    -- larger than this is an error: raise it and accept the extra
    -- simulation memory (GC_MAX_REGIONS * GC_REGION_WORDS * 4 bytes).
    GC_REGION_WORDS : positive := 16384;
    -- What a read outside the image drives: "fail", "poison" or "zero".
    GC_OUTSIDE      : string   := "fail"
  );
  port (
    read_en : in  std_logic;
    addr    : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    data    : out std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    hit     : out std_logic;
    ready   : out std_logic
  );
end entity;

architecture rtl of mem_image is

  -- A read outside the image drives this word under the poison policy.
  constant C_POISON_WORD : word_t := x"DEADBEEF";

  -- Longest Intel HEX line: ':' + LL + AAAA + TT + 255 payload + CC.
  constant C_LINE_MAX : positive := 600;

  -- Longest resolved file name, prefix included.
  constant C_NAME_MAX : positive := 512;

  -- Directory prefixes prepended to GC_FILE, tried in order until a file
  -- opens.  Space padded to a common length to keep the type simple.
  type prefix_array_t is array (natural range <>) of string(1 to 12);
  constant C_PREFIXES : prefix_array_t := (
    "            ",
    "../         ",
    "../../      ",
    "../../../   ",
    "../../../../"
  );

  -- Number of characters of use in a space padded prefix.
  function prefix_len(s : string) return natural is
    variable v_len : natural := 0;
  begin
    for i in s'range loop
      if s(i) /= ' ' then
        v_len := i - s'left + 1;
      end if;
    end loop;
    return v_len;
  end function;

  -- Two address ranges belong to the same region when neither gap exceeds
  -- GC_GAP_BYTES.  Both addends of + are byte_addr_t: a mixed
  -- unsigned/integer operator has a tool dependent result width.
  function ranges_merge(
    constant lo_a, hi_a, lo_b, hi_b : in byte_addr_t) return boolean is
    constant C_GAP : byte_addr_t := to_unsigned(GC_GAP_BYTES + 1, 64);

    function ranges_close(
      constant first : in byte_addr_t;
      constant second : in byte_addr_t) return boolean is
    begin
      if first <= second then
        return true;
      end if;
      return first - second <= C_GAP;
    end function;
  begin
    return ranges_close(lo_a, hi_b) and ranges_close(lo_b, hi_a);
  end function;

  function make_poison return std_logic_vector is
    variable v_data : std_logic_vector(8*GC_DATA_BYTES-1 downto 0) :=
                     (others => '0');
  begin
    if GC_DATA_BYTES < 4 then
      v_data := (others => '1');
    else
      for byte_idx in 0 to GC_DATA_BYTES - 1 loop
        v_data(8*byte_idx + 7 downto 8*byte_idx) :=
          C_POISON_WORD(8*(byte_idx mod 4) + 7 downto 8*(byte_idx mod 4));
      end loop;
    end if;
    return v_data;
  end function;

  -- Copy one line and drop the trailing line ends / blanks.  A line object
  -- is an access type, so the parameter has to be of class variable.
  procedure trim_line(
    variable src : in    line;
    variable buf : out   string(1 to C_LINE_MAX);
    variable len : out   natural) is
    variable v_len : natural := 0;
  begin
    for i in src'range loop
      if src(i) > ' ' then
        v_len := i - src'left + 1;
      end if;
    end loop;
    buf := (others => ' ');
    if v_len > 0 then
      buf(1 to v_len) := src(src'left to src'left + v_len - 1);
    end if;
    len := v_len;
  end procedure;

  signal ready_i : std_logic := '0';
  signal hit_i   : std_logic := '0';

begin

  ready <= ready_i;
  hit   <= hit_i;

  -- One process, two phases: the image is loaded once at time zero, then
  -- the same variables serve the read port on every address change.
  p_store : process

    -- Image file.  A file object has to be a file declaration, not a
    -- variable (VHDL requires file types to be of class file).
    file v_file : text;

    -- The loaded image.  Region r owns the slice starting at
    -- r*GC_REGION_WORDS, so only the region extents are remembered here.
    -- These are process variables, so they keep their values across the
    -- wait statement in the read phase below.
    variable v_store    : word_array_t(0 to GC_MAX_REGIONS*GC_REGION_WORDS - 1)
                          := (others => C_WORD_ZERO);
    variable v_extents  : extent_array_t(0 to GC_MAX_REGIONS-1) :=
                          (others => C_EXTENT_EMPTY);
    variable v_nregions : natural := 0;

    -- Loader
    variable v_stat    : file_open_status;
    variable v_l       : line := new string(1 to C_LINE_MAX);
    variable v_len     : natural;
    variable v_ok      : boolean := false;
    variable v_name    : string(1 to C_NAME_MAX) := (others => ' ');
    variable v_namelen : natural := 0;
    variable v_buf     : string(1 to C_LINE_MAX);
    variable v_plen    : natural;
    variable v_rec     : hex_rec_t;
    variable v_upper   : byte_addr_t := (others => '0');
    variable v_merged  : boolean;
    variable v_lo      : byte_addr_t;
    variable v_hi      : byte_addr_t;
    variable v_words   : natural;
    variable v_bytes   : natural := 0;

    -- Filler / reader
    variable v_addr_b : byte_addr_t;
    variable v_rel    : byte_addr_t;
    variable v_idx    : natural;
    variable v_lane   : natural;
    variable v_old    : word_t;

    -- Read port
    variable v_ra     : byte_addr_t;
    variable v_rdata  : std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    variable v_rhit   : boolean;

  begin

    assert GC_ADDR_WIDTH <= 64
      report "mem_image: GC_ADDR_WIDTH must be at most 64"
      severity failure;
    assert GC_OUTSIDE = "fail" or GC_OUTSIDE = "poison" or
           GC_OUTSIDE = "zero"
      report "mem_image: GC_OUTSIDE must be ""fail"", ""poison"" or ""zero"""
      severity failure;

    -- ----------------------------------------------------------------
    -- Phase 1: load the image
    -- ----------------------------------------------------------------
    if GC_FILE'length > 0 then
      for p in C_PREFIXES'range loop
        exit when v_ok;
        v_plen    := prefix_len(C_PREFIXES(p));
        v_namelen := v_plen + GC_FILE'length;
        v_name    := (others => ' ');
        if v_plen > 0 then
          v_name(1 to v_plen) := C_PREFIXES(p)(1 to v_plen);
        end if;
        v_name(v_plen + 1 to v_namelen) := GC_FILE;
        file_open(v_stat, v_file, v_name(1 to v_namelen), read_mode);
        v_ok := (v_stat = open_ok);
      end loop;

      assert v_ok
        report "mem_image: cannot open image file '" & GC_FILE & "': tried " &
               "the run directory and its four parents"
        severity failure;

      -- Pass 1: work out the region extents.  v_upper carries the extended
      -- address across records, so it starts at zero for every pass.
      v_upper := (others => '0');
      while not endfile(v_file) loop
        readline(v_file, v_l);
        trim_line(v_l, v_buf, v_len);
        if v_len >= 11 and v_buf(1) = ':' then
          parse_hex_record(v_buf(1 to v_len), v_upper, v_rec);
          if v_rec.valid and v_rec.rtype = 0 and v_rec.count > 0 then
            v_lo := v_rec.addr;
            v_hi := v_rec.addr + to_unsigned(v_rec.count - 1, 64);
            v_bytes := v_bytes + v_rec.count;

            -- Extend the first region this record touches, if any.
            v_merged := false;
            for r in 0 to v_nregions - 1 loop
              if not v_merged and
                 ranges_merge(v_extents(r).lo, v_extents(r).hi, v_lo, v_hi) then
                if v_lo < v_extents(r).lo then
                  v_extents(r).lo := v_lo;
                end if;
                if v_hi > v_extents(r).hi then
                  v_extents(r).hi := v_hi;
                end if;
                v_merged := true;
              end if;
            end loop;

            if not v_merged then
              assert v_nregions < GC_MAX_REGIONS
                report "mem_image: '" & GC_FILE & "' has more than " &
                       integer'image(GC_MAX_REGIONS) &
                       " separate regions (raise GC_MAX_REGIONS, or raise " &
                       "GC_GAP_BYTES to merge nearby records)"
                severity failure;
              v_extents(v_nregions).lo := v_lo;
              v_extents(v_nregions).hi := v_hi;
              v_nregions := v_nregions + 1;
            end if;

            -- A record can be the bridge between two regions, so keep
            -- merging until a sweep changes nothing.
            loop
              v_merged := false;
              merge_scan : for i in 0 to v_nregions - 1 loop
                for j in i + 1 to v_nregions - 1 loop
                  if ranges_merge(v_extents(i).lo, v_extents(i).hi,
                                  v_extents(j).lo, v_extents(j).hi) then
                    if v_extents(j).lo < v_extents(i).lo then
                      v_extents(i).lo := v_extents(j).lo;
                    end if;
                    if v_extents(j).hi > v_extents(i).hi then
                      v_extents(i).hi := v_extents(j).hi;
                    end if;
                    -- Drop region j by moving the last one into its slot.
                    v_nregions := v_nregions - 1;
                    v_extents(j) := v_extents(v_nregions);
                    v_merged := true;
                    exit merge_scan;
                  end if;
                end loop;
              end loop;
              exit when not v_merged;
            end loop;
          end if;
        end if;
      end loop;
      file_close(v_file);

      -- The store is statically sized, so check that every region fits.
      for r in 0 to v_nregions - 1 loop
        v_words := to_integer(shift_right(v_extents(r).hi - v_extents(r).lo +
                             to_unsigned(C_WORD_BYTES - 1, 64), 2));
        assert v_words <= GC_REGION_WORDS
          report "mem_image: region " & integer'image(r) & " of '" & GC_FILE &
                 "' needs " & integer'image(v_words) & " words, but " &
                 "GC_REGION_WORDS is " & integer'image(GC_REGION_WORDS)
          severity failure;
      end loop;

      -- Pass 2: copy the payload bytes into the words they belong to.
      -- v_upper has to be cleared again: the file is re-read from the
      -- start, so a type 02/04 record left over from pass 1 would move the
      -- records that come before the first such record in the file.
      v_upper := (others => '0');
      file_open(v_stat, v_file, v_name(1 to v_namelen), read_mode);
      assert v_stat = open_ok
        report "mem_image: cannot reopen image file '" & GC_FILE & "'"
        severity failure;

      while not endfile(v_file) loop
        readline(v_file, v_l);
        trim_line(v_l, v_buf, v_len);
        if v_len >= 11 and v_buf(1) = ':' then
          parse_hex_record(v_buf(1 to v_len), v_upper, v_rec);
          if v_rec.valid and v_rec.rtype = 0 and v_rec.count > 0 then
            for b in 0 to v_rec.count - 1 loop
              v_addr_b := v_rec.addr + to_unsigned(b, 64);
              region_found : for r in 0 to v_nregions - 1 loop
                if v_addr_b >= v_extents(r).lo and
                   v_addr_b <= v_extents(r).hi then
                  v_rel  := v_addr_b - v_extents(r).lo;
                  v_idx  := to_integer(shift_right(v_rel, 2));
                  v_lane := to_integer(v_rel and x"0000000000000003");
                  -- Read/modify/write: a record may start mid word.
                  v_old := v_store(r*GC_REGION_WORDS + v_idx);
                  v_old(8*v_lane + 7 downto 8*v_lane) := v_rec.data(b);
                  v_store(r*GC_REGION_WORDS + v_idx) := v_old;
                  exit region_found;
                end if;
              end loop;
            end loop;
          end if;
        end if;
      end loop;
      file_close(v_file);

      report "mem_image: loaded " & integer'image(v_bytes) & " bytes into " &
             integer'image(v_nregions) & " region(s) from '" & GC_FILE & "'"
        severity note;
      for r in 0 to v_nregions - 1 loop
        report "mem_image:   region " & integer'image(r) & " 0x" &
               to_hstring(v_extents(r).lo) & "..0x" &
               to_hstring(v_extents(r).hi)
          severity note;
      end loop;

    else
      report "mem_image: no image file configured (GC_FILE is empty); " &
             "every read is a miss" severity note;
    end if;

    ready_i <= '1';

    -- ----------------------------------------------------------------
    -- Phase 2: serve reads.  Everything below stays combinational from
    -- the outside: the port is updated whenever addr or read_en changes.
    -- ----------------------------------------------------------------
    loop
      v_ra    := resize(unsigned(addr), 64);
      v_rdata := (others => '0');
      v_rhit  := false;

      for r in 0 to v_nregions - 1 loop
        if not v_rhit and
           v_ra >= v_extents(r).lo and
           v_ra <= v_extents(r).hi and
           to_unsigned(GC_DATA_BYTES - 1, 64) <= v_extents(r).hi - v_ra then
          for b in 0 to GC_DATA_BYTES - 1 loop
            v_rel  := v_ra + to_unsigned(b, 64) - v_extents(r).lo;
            v_idx  := to_integer(shift_right(v_rel, 2));
            v_lane := to_integer(v_rel and x"0000000000000003");
            v_rdata(8*b + 7 downto 8*b) :=
              v_store(r*GC_REGION_WORDS + v_idx)(8*v_lane + 7 downto 8*v_lane);
          end loop;
          v_rhit := true;
        end if;
      end loop;

      if not v_rhit then
        if GC_OUTSIDE = "poison" then
          v_rdata := make_poison;
        elsif GC_OUTSIDE = "fail" then
          -- Only a consumed read can fail; a stale address between beats
          -- must stay harmless, or the policy would be unusable.
          assert read_en = '0'
            report "mem_image: read of " & integer'image(GC_DATA_BYTES) &
                   " byte(s) at 0x" & to_hstring(v_ra) & " is outside the " &
                   "loaded image (file '" & GC_FILE & "')"
            severity failure;
        end if;
      end if;

      data  <= v_rdata;
      hit_i <= '1' when v_rhit else '0';

      wait on addr, read_en;
    end loop;

  end process;

end architecture;
