#!/usr/bin/env python3
"""Tests for tools/hdl-format.py - the whitespace-only HDL formatter.

The formatter's contract is that it only inserts/removes spaces and blank
lines: the per-line sequence of non-whitespace characters is unchanged.

These tests lock in exact per-kind/per-style output (golden), plus the
invariant and idempotence properties, so a refactor cannot silently change
behavior.

Run from the fpga-ip repo root:
    python -m unittest discover -s tests -v
"""

import importlib.util
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[1]
TOOL_PATH = REPO_ROOT / "tools" / "hdl-format.py"

spec = importlib.util.spec_from_file_location("fpga_ip_hdl_format", TOOL_PATH)
fmt = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = fmt
spec.loader.exec_module(fmt)


# ---------------------------------------------------------------------------
# Golden outputs (verified against the reference tool, 2026-08-08)
# ---------------------------------------------------------------------------

VHD_DECL_IN = [
    "signal a : std_logic;",
    "signal b : std_logic_vector(7 downto 0);",
    "signal ccc : std_logic_vector(31 downto 0);",
]

VHD_GEN_IN = [
    "constant WIDTH : integer := 32;",
    'constant ADDR : std_logic_vector(3 downto 0) := "0000";',
]

VHD_MAP_IN = [
    "A_WIDTH => 32,",
    'B_ADDR => X"0000",',
    'C => "11",',
    "DUMMY => (others => '0')",
]

SV_PARAM_IN = [
    "parameter integer A_WIDTH = 32,",
    "parameter integer B_ADDR = 16,",
    "localparam logic [3:0] MASK = 4'hf,",
]

SV_PORT_IN = [
    "input  logic        clk,",
    "output logic [31:0] data,",
    "input  wire  [7:0]  mask,",
]

SV_DECL_IN = [
    "logic       clk;",
    "logic [31:0] data;",
    "wire  [7:0]  mask;",
]

SV_MAP_IN = [
    ".clk   (clk),",
    ".data_i(data),",
    ".mask  (mask),",
]

GOLDEN = {
    ("vhd_decl", "extreme"): [
        "signal a   : std_logic                    ;",
        "signal b   : std_logic_vector( 7 downto 0);",
        "signal ccc : std_logic_vector(31 downto 0);",
    ],
    ("vhd_decl", "moderate"): [
        "signal a   : std_logic;",
        "signal b   : std_logic_vector(7 downto 0);",
        "signal ccc : std_logic_vector(31 downto 0);",
    ],
    ("vhd_decl", "collapsed"): [
        "signal a : std_logic;",
        "signal b : std_logic_vector(7 downto 0);",
        "signal ccc : std_logic_vector(31 downto 0);",
    ],
    ("vhd_gen", "extreme"): [
        "constant WIDTH : integer :=     32                     ;",
        'constant ADDR  : std_logic_vector(3 downto 0) := "0000";',
    ],
    ("vhd_gen", "moderate"): [
        "constant WIDTH : integer := 32;",
        'constant ADDR  : std_logic_vector(3 downto 0) := "0000";',
    ],
    ("vhd_gen", "collapsed"): [
        "constant WIDTH : integer := 32;",
        "constant ADDR : std_logic_vector(3 downto 0) := \"0000\";",
    ],
    ("vhd_map", "extreme"): [
        "A_WIDTH => 32             ,",
        'B_ADDR  => X"0000"        ,',
        'C       => "11"           ,',
        "DUMMY   => (others => '0')",
    ],
    ("vhd_map", "moderate"): [
        "A_WIDTH => 32,",
        'B_ADDR  => X"0000",',
        'C       => "11",',
        "DUMMY   => (others => '0')",
    ],
    ("vhd_map", "collapsed"): [
        "A_WIDTH => 32,",
        'B_ADDR => X"0000",',
        'C => "11",',
        "DUMMY => (others => '0')",
    ],
    ("sv_param", "extreme"): [
        "parameter  integer     A_WIDTH =   32,",
        "parameter  integer     B_ADDR  =   16,",
        "localparam logic [3:0] MASK    = 4'hf,",
    ],
    ("sv_param", "moderate"): [
        "parameter  integer     A_WIDTH = 32,",
        "parameter  integer     B_ADDR  = 16,",
        "localparam logic [3:0] MASK    = 4'hf,",
    ],
    ("sv_param", "collapsed"): [
        "parameter integer A_WIDTH = 32,",
        "parameter integer B_ADDR = 16,",
        "localparam logic [3:0] MASK = 4'hf,",
    ],
    ("sv_port", "extreme"): [
        "input  logic        clk ,",
        "output logic [31:0] data,",
        "input  wire  [ 7:0] mask,",
    ],
    ("sv_port", "moderate"): [
        "input  logic        clk,",
        "output logic [31:0] data,",
        "input  wire [7:0]   mask,",
    ],
    ("sv_port", "collapsed"): [
        "input logic clk,",
        "output logic [31:0] data,",
        "input wire [7:0] mask,",
    ],
    ("sv_decl", "extreme"): [
        "logic        clk ;",
        "logic [31:0] data;",
        "wire [ 7:0] mask;",
    ],
    ("sv_decl", "moderate"): [
        "logic        clk;",
        "logic [31:0] data;",
        "wire  [7:0]  mask;",
    ],
    ("sv_decl", "collapsed"): [
        "logic  clk;",
        "logic [31:0] data;",
        "wire [7:0] mask;",
    ],
    ("sv_map", "extreme"): [
        ".clk    (clk ),",
        ".data_i (data),",
        ".mask   (mask),",
    ],
    ("sv_map", "moderate"): [
        ".clk    (clk),",
        ".data_i (data),",
        ".mask   (mask),",
    ],
    ("sv_map", "collapsed"): [
        ".clk (clk),",
        ".data_i (data),",
        ".mask (mask),",
    ],
}

INPUTS = {
    "vhd_decl": VHD_DECL_IN,
    "vhd_gen": VHD_GEN_IN,
    "vhd_map": VHD_MAP_IN,
    "sv_param": SV_PARAM_IN,
    "sv_port": SV_PORT_IN,
    "sv_decl": SV_DECL_IN,
    "sv_map": SV_MAP_IN,
}

LANG = {
    "vhd_decl": "vhdl",
    "vhd_gen": "vhdl",
    "vhd_map": "vhdl",
    "sv_param": "sv",
    "sv_port": "sv",
    "sv_decl": "sv",
    "sv_map": "sv",
}


class GoldenTests(unittest.TestCase):
    """Exact output must match the reference tool for every kind and style."""

    def test_golden_outputs(self):
        for (kind, style), expected in GOLDEN.items():
            with self.subTest(kind=kind, style=style):
                out = fmt.prettify_code(list(INPUTS[kind]), LANG[kind], style)
                self.assertEqual(out, expected)


class PropertyTests(unittest.TestCase):
    """Invariant and idempotence hold across all styles."""

    REAL_BLOCK = [
        "  signal a      : std_logic;",
        "  signal b      : std_logic_vector(7 downto 0);  -- data bus",
        "  signal ccc    : std_logic;",
    ]

    def test_invariant_holds(self):
        for kind, lines in INPUTS.items():
            for style in ("extreme", "moderate", "collapsed"):
                with self.subTest(kind=kind, style=style):
                    out = fmt.prettify_code(list(lines), LANG[kind], style)
                    self.assertTrue(fmt._check_invariant(lines, out),
                                    "non-whitespace content changed")

    def test_invariant_holds_on_realistic_block(self):
        for style in ("extreme", "moderate", "collapsed"):
            with self.subTest(style=style):
                out = fmt.prettify_code(list(self.REAL_BLOCK), "vhdl", style)
                self.assertTrue(fmt._check_invariant(self.REAL_BLOCK, out))

    def test_idempotent(self):
        for kind, lines in INPUTS.items():
            for style in ("extreme", "moderate", "collapsed"):
                with self.subTest(kind=kind, style=style):
                    once = fmt.prettify_code(list(lines), LANG[kind], style)
                    twice = fmt.prettify_code(once, LANG[kind], style)
                    self.assertEqual(twice, once)

    def test_non_uniform_block_left_unchanged(self):
        lines = ["  signal a : std_logic;",
                 "  variable b : std_logic;"]
        out = fmt.prettify_code(lines, "vhdl", "moderate")
        self.assertEqual(out, [ln.rstrip() for ln in lines])

    def test_single_line_and_comment_block(self):
        lines = ["  signal a : std_logic;",
                 "  -- just a comment",
                 "  signal b : std_logic;"]
        out = fmt.prettify_code(lines, "vhdl", "moderate")
        self.assertEqual(out, [ln.rstrip() for ln in lines])

    def test_variable_assignment_untouched(self):
        """A 'name := value' assignment must never be split into ': ='."""
        lines = [
            "    v := r_s;  -- default: hold current state",
            "    v_accept := (a = '1') and (b = '0');",
        ]
        for style in ("extreme", "moderate", "collapsed"):
            with self.subTest(style=style):
                out = fmt.prettify_code(list(lines), "vhdl", style)
                self.assertNotIn(": =", "\n".join(out))
                self.assertTrue(fmt._check_invariant(lines, out),
                                "assignment token stream changed")


class MarkdownTests(unittest.TestCase):
    """Only vhdl/systemverilog fenced blocks are touched."""

    MD_IN = ("# Title\n"
             "\n"
             "```vhdl\n"
             "signal   x : std_logic;\n"
             "signal yyy : std_logic;\n"
             "```\n"
             "\n"
             "Some text ``` not vhdl ``` stays.\n")

    MD_EXPECTED = ("# Title\n"
                   "\n"
                   "```vhdl\n"
                   "signal x   : std_logic;\n"
                   "signal yyy : std_logic;\n"
                   "```\n"
                   "\n"
                   "Some text ``` not vhdl ``` stays.\n")

    def test_only_fenced_blocks_rewritten(self):
        self.assertEqual(fmt.prettify_text(self.MD_IN, True, style="moderate"),
                         self.MD_EXPECTED)

    def test_raw_vhdl_passthrough(self):
        self.assertEqual(
            fmt.prettify_text("\n".join(VHD_DECL_IN) + "\n", False,
                              lang="vhdl", style="moderate"),
            "\n".join(GOLDEN[("vhd_decl", "moderate")]) + "\n")


class CliTests(unittest.TestCase):
    """End-to-end behavior of main()."""

    def test_stdin_stdout(self):
        text = "signal a : std_logic;\nsignal b : std_logic_vector(7 downto 0);\n"
        buf = io.StringIO()
        with patch("sys.stdin", io.StringIO(text)), redirect_stdout(buf):
            rc = fmt.main(["--stdin", "--lang", "vhdl", "--style", "moderate"])
        self.assertEqual(rc, 0)
        self.assertEqual(buf.getvalue(),
                         fmt.prettify_text(text, False, lang="vhdl",
                                           style="moderate"))

    def test_check_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "block.vhd"
            path.write_text("signal   a   :   std_logic   ;\n", encoding="utf-8")
            # would change -> check reports, exit 1
            self.assertEqual(fmt.main([str(path), "--check"]), 1)
            # write the file -> exit 0
            self.assertEqual(fmt.main([str(path)]), 0)
            # now clean -> check exit 0
            self.assertEqual(fmt.main([str(path), "--check"]), 0)


if __name__ == "__main__":
    unittest.main()
