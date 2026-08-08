#!/usr/bin/env python3
"""hdl-formatter.py - whitespace-only formatter for VHDL / SystemVerilog.

Guarantee:
    This tool ONLY inserts/removes spaces and blank lines.  It never
    reorders, renames, or rewrites any token, so the compiled design is
    identical.  A self-check asserts that, per line, the sequence of
    non-whitespace characters is unchanged.

Targets:
    - *_top.vhd / *_top.sv synthesis wrappers
    - VHDL / SystemVerilog code blocks inside README.md files
      (only fenced blocks tagged vhdl / systemverilog are touched)
    - raw code blocks piped on stdin (--stdin)

Style `extreme` (see fpga-rules/hdl_coding_rules.md - Column Alignment):
    - Align repeated columns within a block: identifiers, ':', direction,
      type/range ('to'/'downto' and '[...:...]'), ':=', '=>', '=', ',',
      ';', ')', ']' and inline comments.
    - Right-align numbers/expressions before 'to'/'downto' (VHDL) and
      before/after ':' inside vector ranges (SV).
    - Right-align ':= value' / '= value' columns.
    - Align trailing ';' and ',' punctuation in a stable block column.
    - Collapse runs of 2+ blank lines into one and strip trailing
      whitespace (disable with --no-collapse-blank).

Style `moderate`:
        - Align outer declaration/map columns while keeping declaration
            punctuation attached to the preceding type, value, or name.
        - Keep type and range expressions natural; do not right-align indices.
        - Keep generic/parameter values and map expressions left-aligned and
            compact.

Style `collapsed`:
        - Preserve indentation and logical blank lines without block-wide padding.
        - Use natural type/range spacing and compact operator/punctuation spacing.

Usage:
    python tools/hdl-formatter.py <file> [<file> ...] [options]
    python tools/hdl-formatter.py --stdin --lang vhdl < block.txt

    --style {extreme,moderate,collapsed}
                            alignment profile (default: moderate)
    --lang {vhdl,sv,auto}   force language (default: auto-detect)
    --check                 exit 1 if any file would change (for CI)
    --dry-run               print a unified diff without writing
    --no-collapse-blank     keep blank lines as-is
"""

import re
import sys
import difflib
import argparse


# ---------------------------------------------------------------------------
# Line classification helpers
# ---------------------------------------------------------------------------

def split_comment(line, comment_prefix):
    """Split a code line into (body, comment).

    comment_prefix is '--' for VHDL or '//' for SystemVerilog.  The
    returned comment includes the leading whitespace, so it can be padded
    to a fixed column.  Returns (body_without_comment, comment_or_None).
    """
    idx = line.find(comment_prefix)
    if idx < 0:
        return line.rstrip(), None
    body = line[:idx].rstrip()
    cmt = line[idx:]
    return body, cmt


def non_ws(line):
    """All non-whitespace characters in a line, in order."""
    return "".join(ch for ch in line if not ch.isspace())


def _align_inline_comments(rows):
    """Align inline comments while keeping comment-free lines compact."""
    if not any(comment is not None for _, comment in rows):
        return [line.rstrip() for line, _ in rows]
    comment_col = max(len(line) for line, _ in rows) + 2
    return [line.ljust(comment_col) + comment.strip()
            if comment is not None else line.rstrip()
            for line, comment in rows]


def _compact_inline_comments(rows):
    """Keep inline comments close without aligning their columns."""
    return [line.rstrip() if comment is None
            else line.rstrip() + "  " + comment.strip()
            for line, comment in rows]


# ---------------------------------------------------------------------------
# VHDL
# ---------------------------------------------------------------------------

# [constant|signal|variable] name : [dir] type ;|,
_VHD_DECL_RE = re.compile(
    r"^(?P<ind>\s*)"
    r"(?:(?P<kind>constant|signal|variable)\s+)?"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
    r"(?:(?P<dir>in|out|inout)\s+)?"
    r"(?P<type>.*?)(?P<tail>[;,]?)\s*$"
)

# [constant|signal|variable] name : type := value ;|,
_VHD_GEN_RE = re.compile(
    r"^(?P<ind>\s*)"
    r"(?:(?P<kind>constant|signal|variable)\s+)?"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
    r"(?P<type>.*?)\s*:=\s*"
    r"(?P<value>.*?)(?P<tail>[;,]?)\s*$"
)

# name => expr ,|
_VHD_MAP_RE = re.compile(
    r"^(?P<ind>\s*)"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=>\s*"
    r"(?P<expr>.*?)(?P<tail>,?)\s*$"
)

# split a type expression at its range keyword: "...lo downto hi"
_VHD_RANGE_RE = re.compile(r"^(?P<pre>.*?)\s+(?P<kw>downto|to)\s+(?P<post>.*)$")


def _vhd_type_cells(type_str):
    """Split a VHDL type into (head, range_kw, range_tail)."""
    m = _VHD_RANGE_RE.match(type_str)
    if m:
        return m.group("pre"), m.group("kw"), m.group("post")
    return type_str, None, None


def _vhd_head_split(head):
    """Split a range head like 'std_logic_vector(31' into (prefix, index).

    The index (right-aligned) is the part after the last '('.  If there is
    no '(', prefix is the whole head and the index is empty.
    """
    m = re.match(r"^(?P<pre>.*\()(?P<idx>[^()]*)$", head)
    if m:
        return m.group("pre"), m.group("idx")
    return head, ""


def _vhd_decl_cells(body, cmt):
    """Parse a VHDL generic/port/signal declaration into cells."""
    m = _VHD_GEN_RE.match(body)
    if m:
        return {"is_gen": True, "ind": m.group("ind"),
            "kind": m.group("kind") or "", "name": m.group("name"),
                "dir": "", "type": m.group("type").strip(),
                "value": m.group("value").strip(), "tail": m.group("tail"),
                "cmt": cmt}
    m = _VHD_DECL_RE.match(body)
    if m:
        return {"is_gen": False, "ind": m.group("ind"),
            "kind": m.group("kind") or "", "name": m.group("name"),
                "dir": m.group("dir") or "", "type": m.group("type").strip(),
                "value": "", "tail": m.group("tail"), "cmt": cmt}
    return None


def _align_vhd_decl(lines):
    """Align VHDL generic/port/signal declarations.

    Columns: name, ':', direction, type head, 'to'/'downto' keyword, range
    index (right-aligned), ':=' value (right-aligned), trailing ';'/','.

    The trailing punctuation shares a column across the block; only lines
    with a range participate in 'to'/'downto' alignment.
    """
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "--")
        c = _vhd_decl_cells(body, cmt)
        if c is None:
            return lines  # not a uniform block; leave untouched
        c["head"], c["kw"], c["post"] = _vhd_type_cells(c["type"])
        c["prefix"], c["idx"] = _vhd_head_split(c["head"])
        parsed.append(c)
    if any(p["is_gen"] != parsed[0]["is_gen"] or
           p["kind"] != parsed[0]["kind"] for p in parsed):
        return lines

    gens = parsed[0]["is_gen"]
    name_w = max(len(p["name"]) for p in parsed)
    has_dir = (not gens) and all(p["dir"] for p in parsed)
    dir_w = max(len(p["dir"]) for p in parsed) if has_dir else 0

    ranged = [p for p in parsed if p["kw"]]
    has_kw = bool(ranged)
    prefix_w = max(len(p["prefix"]) for p in ranged) if has_kw else 0
    idx_w = max(len(p["idx"]) for p in ranged) if has_kw else 0
    kw_w = max(len(p["kw"]) for p in ranged) if has_kw else 0
    post_w = max(len(p["post"]) for p in ranged) if has_kw else 0
    value_w = max(len(p["value"]) for p in parsed) if gens else 0

    out = []
    for p in parsed:
        decl_kind = (p["kind"] + " ") if p["kind"] else ""
        line = p["ind"] + decl_kind + p["name"].ljust(name_w) + " : "
        if has_dir:
            line += p["dir"].ljust(dir_w) + " "
        if p["kw"]:
            line += p["prefix"].ljust(prefix_w) + p["idx"].rjust(idx_w)
            line += " " + p["kw"].ljust(kw_w) + " " + p["post"].ljust(post_w)
        else:
            line += p["head"]
        if gens:
            line += " := " + p["value"].rjust(value_w)
        cores.append((line, p["tail"], p["cmt"]))

    tail_col = max(len(line) for line, _, _ in cores)
    out = []
    for line, tail, cmt in cores:
        if tail:
            line = line.ljust(tail_col) + tail
        out.append((line, cmt))
    return _align_inline_comments(out)


def _align_vhd_map(lines):
    """Align VHDL generic/port maps ('name => expr')."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "--")
        m = _VHD_MAP_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("name"), m.group("expr").strip(),
                       m.group("tail"), cmt))
    name_w = max(len(p[1]) for p in parsed)
    expr_w = max(len(p[2]) for p in parsed)
    out = []
    for ind, name, expr, tail, cmt in parsed:
        line = ind + name.ljust(name_w) + " => " + expr.ljust(expr_w) + tail
        out.append((line, cmt))
    return _align_inline_comments(out)


def _normalize_vhdl_type(type_str):
    """Return a VHDL type with natural internal spacing."""
    head, keyword, post = _vhd_type_cells(type_str.strip())
    if keyword:
        head = re.sub(r"\s+", " ", head).strip()
        head = re.sub(r"\(\s+", "(", head)
        post = re.sub(r"\s+", " ", post).strip()
        return head + " " + keyword + " " + post
    return re.sub(r"\s+", " ", type_str.strip())


def _align_vhd_decl_moderate(lines):
    """Align VHDL declarations without padding ranges or values."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "--")
        c = _vhd_decl_cells(body, cmt)
        if c is None:
            return lines
        parsed.append(c)
    if any(p["is_gen"] != parsed[0]["is_gen"] or
           p["kind"] != parsed[0]["kind"] for p in parsed):
        return lines

    gens = parsed[0]["is_gen"]
    name_w = max(len(p["name"]) for p in parsed)
    has_dir = (not gens) and all(p["dir"] for p in parsed)
    dir_w = max(len(p["dir"]) for p in parsed) if has_dir else 0
    out = []
    for p in parsed:
        decl_kind = (p["kind"] + " ") if p["kind"] else ""
        line = p["ind"] + decl_kind + p["name"].ljust(name_w) + " : "
        if has_dir:
            line += p["dir"].ljust(dir_w) + " "
        line += _normalize_vhdl_type(p["type"])
        if gens:
            line += " := " + p["value"].strip()
        out.append((line + p["tail"], p["cmt"]))
    return _align_inline_comments(out)


def _align_vhd_map_moderate(lines):
    """Align VHDL map names while keeping expressions and commas compact."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "--")
        m = _VHD_MAP_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("name"),
                       m.group("expr").strip(), m.group("tail"), cmt))
    name_w = max(len(p[1]) for p in parsed)
    out = []
    for ind, name, expr, tail, cmt in parsed:
        line = ind + name.ljust(name_w) + " => " + expr + tail
        out.append((line, cmt))
    return _align_inline_comments(out)


def _align_vhd_decl_collapsed(lines):
    """Format VHDL declarations without block-wide column padding."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "--")
        c = _vhd_decl_cells(body, cmt)
        if c is None:
            return lines
        parsed.append(c)
    if any(p["is_gen"] != parsed[0]["is_gen"] or
           p["kind"] != parsed[0]["kind"] for p in parsed):
        return lines

    gens = parsed[0]["is_gen"]
    out = []
    for p in parsed:
        decl_kind = (p["kind"] + " ") if p["kind"] else ""
        line = p["ind"] + decl_kind + p["name"] + " : "
        if p["dir"]:
            line += p["dir"] + " "
        line += _normalize_vhdl_type(p["type"])
        if gens:
            line += " := " + p["value"].strip()
        out.append((line + p["tail"], p["cmt"]))
    return _compact_inline_comments(out)


def _align_vhd_map_collapsed(lines):
    """Format VHDL maps without block-wide column padding."""
    out = []
    for ln in lines:
        body, cmt = split_comment(ln, "--")
        m = _VHD_MAP_RE.match(body)
        if not m:
            return lines
        line = (m.group("ind") + m.group("name") + " => " +
                m.group("expr").strip() + m.group("tail"))
        out.append((line, cmt))
    return _compact_inline_comments(out)


# ---------------------------------------------------------------------------
# SystemVerilog
# ---------------------------------------------------------------------------

# parameter/localparam <type> <name> = <value> ,
_SV_PARAM_RE = re.compile(
    r"^(?P<ind>\s*)(?P<kind>parameter|localparam)\s+"
    r"(?P<type>[^=]*?)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r"(?P<value>.*?)(?P<tail>,?)\s*$"
)

# input|output|inout <type> <name> ,
_SV_PORT_RE = re.compile(
    r"^(?P<ind>\s*)(?P<dir>input|output|inout)\s+"
    r"(?P<type>.*?)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?P<tail>,?)\s*$"
)

# logic|wire|reg <type> <name> ;
_SV_DECL_RE = re.compile(
    r"^(?P<ind>\s*)(?P<kind>logic|wire|reg)\s+"
    r"(?P<type>.*?)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?P<tail>;?)\s*$"
)

# .name ( expr ) ,
_SV_MAP_RE = re.compile(
    r"^(?P<ind>\s*)(?P<name>\.\w+)\s*\(\s*"
    r"(?P<expr>.*?)\s*\)\s*(?P<tail>,?)\s*$"
)

# vector type: "logic [<lo>:<hi>]"
_SV_VEC_RE = re.compile(r"^(?P<pre>[^[]*\[)(?P<lo>[^:]*):(?P<hi>[^\]]*)\]$")


def _sv_type_fields(typ):
    """Split an SV type into (pre, lo, hi, is_vector).

    'logic [A:B]' -> ('logic [', 'A', 'B', True); anything else returns
    the whole type as 'pre' with is_vector=False.
    """
    m = _SV_VEC_RE.match(typ)
    if m:
        return m.group("pre"), m.group("lo").strip(), m.group("hi").strip(), True
    return typ, "", "", False


def _sv_type_aligner(types):
    """Return an emit(typ) function that aligns types in a block.

    The vector range parts before/after ':' are right-aligned separately
    so the ':' lines up; the whole type column is padded so following
    names stay aligned.
    """
    fields = [_sv_type_fields(t) for t in types]
    pre_w = max(len(f[0]) for f in fields)
    vecs = [f for f in fields if f[3]]
    lo_w = max(len(f[1]) for f in vecs) if vecs else 0
    hi_w = max(len(f[2]) for f in vecs) if vecs else 0
    type_w = max((pre_w + lo_w + 1 + hi_w + 1 if f[3] else len(f[0]))
                 for f in fields)

    def emit(typ):
        pre, lo, hi, isvec = _sv_type_fields(typ)
        if isvec:
            s = pre.ljust(pre_w) + lo.rjust(lo_w) + ":" + hi.rjust(hi_w) + "]"
        else:
            s = pre
        return s.ljust(type_w)

    return emit


def _align_sv_params(lines):
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_PARAM_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("kind"), m.group("type").strip(),
                       m.group("name"),
                       m.group("value").strip(), m.group("tail"), cmt))
    emit_type = _sv_type_aligner([p[2] for p in parsed])
    kind_w = max(len(p[1]) for p in parsed)
    name_w = max(len(p[3]) for p in parsed)
    value_w = max(len(p[4]) for p in parsed)
    tail_w = max(len(p[5]) for p in parsed)
    out = []
    for ind, kind, typ, name, value, tail, cmt in parsed:
        line = ind + kind.ljust(kind_w) + " " + emit_type(typ) + " " + name.ljust(name_w)
        line += " = " + value.rjust(value_w) + (tail or "").ljust(tail_w)
        out.append((line, cmt))
    return _align_inline_comments(out)


def _align_sv_ports(lines):
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_PORT_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("dir"), m.group("type").strip(),
                       m.group("name"), m.group("tail"), cmt))
    dir_w = max(len(p[1]) for p in parsed)
    emit_type = _sv_type_aligner([p[2] for p in parsed])
    name_w = max(len(p[3]) for p in parsed)
    tail_w = max(len(p[4]) for p in parsed)
    out = []
    for ind, d, typ, name, tail, cmt in parsed:
        line = ind + d.ljust(dir_w) + " " + emit_type(typ) + " " + name.ljust(name_w)
        line += (tail or "").ljust(tail_w)
        out.append((line, cmt))
    return _align_inline_comments(out)


def _align_sv_decls(lines):
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_DECL_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("kind"), m.group("type").strip(),
                       m.group("name"), m.group("tail"), cmt))
    emit_type = _sv_type_aligner([p[2] for p in parsed])
    name_w = max(len(p[3]) for p in parsed)
    tail_w = max(len(p[4]) for p in parsed)
    out = []
    for ind, kind, typ, name, tail, cmt in parsed:
        line = ind + kind + " " + emit_type(typ) + " " + name.ljust(name_w)
        line += (tail or "").ljust(tail_w)
        out.append((line, cmt))
    return _align_inline_comments(out)


def _align_sv_maps(lines):
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_MAP_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("name"), m.group("expr").strip(),
                       m.group("tail"), cmt))
    name_w = max(len(p[1]) for p in parsed)
    expr_w = max(len(p[2]) for p in parsed)
    tail_w = max(len(p[3]) for p in parsed)
    out = []
    for ind, name, expr, tail, cmt in parsed:
        line = ind + name.ljust(name_w) + " (" + expr.ljust(expr_w) + ")"
        line += (tail or "").ljust(tail_w)
        out.append((line, cmt))
    return _align_inline_comments(out)


def _normalize_sv_type(type_str):
    """Return a SystemVerilog type with natural internal spacing."""
    pre, lo, hi, is_vector = _sv_type_fields(type_str.strip())
    if is_vector:
        pre = re.sub(r"\s+", " ", pre).strip()
        return pre + lo + ":" + hi + "]"
    return re.sub(r"\s+", " ", type_str.strip())


def _sv_moderate_type_aligner(types):
    """Return an emitter that pads only the outer type column."""
    type_w = max(len(_normalize_sv_type(typ)) for typ in types)

    def emit(typ):
        return _normalize_sv_type(typ).ljust(type_w)

    return emit


def _align_sv_params_moderate(lines):
    """Align SV parameter names and '=' without padding values."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_PARAM_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("kind"), m.group("type").strip(),
                       m.group("name"), m.group("value").strip(),
                       m.group("tail"), cmt))
    emit_type = _sv_moderate_type_aligner([p[2] for p in parsed])
    kind_w = max(len(p[1]) for p in parsed)
    name_w = max(len(p[3]) for p in parsed)
    out = []
    for ind, kind, typ, name, value, tail, cmt in parsed:
        line = ind + kind.ljust(kind_w) + " " + emit_type(typ) + " "
        line += name.ljust(name_w) + " = " + value + tail
        out.append((line, cmt))
    return _align_inline_comments(out)


def _align_sv_ports_moderate(lines):
    """Align SV port columns without padding vector ranges."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_PORT_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("dir"), m.group("type").strip(),
                       m.group("name"), m.group("tail"), cmt))
    dir_w = max(len(p[1]) for p in parsed)
    emit_type = _sv_moderate_type_aligner([p[2] for p in parsed])
    out = []
    for ind, direction, typ, name, tail, cmt in parsed:
        line = ind + direction.ljust(dir_w) + " " + emit_type(typ) + " "
        line += name + tail
        out.append((line, cmt))
    return _align_inline_comments(out)


def _align_sv_decls_moderate(lines):
    """Align SV declaration columns without padding vector ranges."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_DECL_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("kind"), m.group("type").strip(),
                       m.group("name"), m.group("tail"), cmt))
    emit_type = _sv_moderate_type_aligner([p[2] for p in parsed])
    kind_w = max(len(p[1]) for p in parsed)
    out = []
    for ind, kind, typ, name, tail, cmt in parsed:
        line = ind + kind.ljust(kind_w) + " " + emit_type(typ) + " "
        line += name + tail
        out.append((line, cmt))
    return _align_inline_comments(out)


def _align_sv_maps_moderate(lines):
    """Align SV map names while keeping expressions and commas compact."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_MAP_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("name"),
                       m.group("expr").strip(), m.group("tail"), cmt))
    name_w = max(len(p[1]) for p in parsed)
    out = []
    for ind, name, expr, tail, cmt in parsed:
        line = ind + name.ljust(name_w) + " (" + expr + ")" + tail
        out.append((line, cmt))
    return _align_inline_comments(out)


def _align_sv_params_collapsed(lines):
    """Format SV parameters without block-wide column padding."""
    out = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_PARAM_RE.match(body)
        if not m:
            return lines
        line = (m.group("ind") + m.group("kind") + " " +
                _normalize_sv_type(m.group("type")) + " " +
                m.group("name") + " = " + m.group("value").strip() +
                m.group("tail"))
        out.append((line, cmt))
    return _compact_inline_comments(out)


def _align_sv_ports_collapsed(lines):
    """Format SV ports without block-wide column padding."""
    out = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_PORT_RE.match(body)
        if not m:
            return lines
        line = (m.group("ind") + m.group("dir") + " " +
                _normalize_sv_type(m.group("type")) + " " +
                m.group("name") + m.group("tail"))
        out.append((line, cmt))
    return _compact_inline_comments(out)


def _align_sv_decls_collapsed(lines):
    """Format SV declarations without block-wide column padding."""
    out = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_DECL_RE.match(body)
        if not m:
            return lines
        line = (m.group("ind") + m.group("kind") + " " +
                _normalize_sv_type(m.group("type")) + " " +
                m.group("name") + m.group("tail"))
        out.append((line, cmt))
    return _compact_inline_comments(out)


def _align_sv_maps_collapsed(lines):
    """Format SV maps without block-wide column padding."""
    out = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_MAP_RE.match(body)
        if not m:
            return lines
        line = (m.group("ind") + m.group("name") + " (" +
                m.group("expr").strip() + ")" + m.group("tail"))
        out.append((line, cmt))
    return _compact_inline_comments(out)


# ---------------------------------------------------------------------------
# Block segmentation and dispatch
# ---------------------------------------------------------------------------

def _classify_vhdl(body):
    if "=>" in body and _VHD_MAP_RE.match(body):
        return "vhd_map"
    if _VHD_GEN_RE.match(body):
        return "vhd_gen"
    if ":" in body and _VHD_DECL_RE.match(body):
        return "vhd_decl"
    return None


def _classify_sv(body):
    if re.match(r"^\s*(parameter|localparam)\b", body):
        return "sv_param"
    if _SV_MAP_RE.match(body):
        return "sv_map"
    if re.match(r"^\s*(input|output|inout)\b", body):
        return "sv_port"
    if re.match(r"^\s*(logic|wire|reg)\b", body):
        return "sv_decl"
    return None


_ALIGNERS = {
    "vhd_decl": _align_vhd_decl,
    "vhd_gen": _align_vhd_decl,
    "vhd_map": _align_vhd_map,
    "sv_param": _align_sv_params,
    "sv_port": _align_sv_ports,
    "sv_decl": _align_sv_decls,
    "sv_map": _align_sv_maps,
}

_MODERATE_ALIGNERS = {
    "vhd_decl": _align_vhd_decl_moderate,
    "vhd_gen": _align_vhd_decl_moderate,
    "vhd_map": _align_vhd_map_moderate,
    "sv_param": _align_sv_params_moderate,
    "sv_port": _align_sv_ports_moderate,
    "sv_decl": _align_sv_decls_moderate,
    "sv_map": _align_sv_maps_moderate,
}

_COLLAPSED_ALIGNERS = {
    "vhd_decl": _align_vhd_decl_collapsed,
    "vhd_gen": _align_vhd_decl_collapsed,
    "vhd_map": _align_vhd_map_collapsed,
    "sv_param": _align_sv_params_collapsed,
    "sv_port": _align_sv_ports_collapsed,
    "sv_decl": _align_sv_decls_collapsed,
    "sv_map": _align_sv_maps_collapsed,
}

_ALIGNERS_BY_STYLE = {
    "extreme": _ALIGNERS,
    "moderate": _MODERATE_ALIGNERS,
    "collapsed": _COLLAPSED_ALIGNERS,
}


def prettify_code(lines, language, style="moderate"):
    """Align a list of code lines (whitespace-only)."""
    if style not in _ALIGNERS_BY_STYLE:
        raise ValueError(f"unsupported alignment style: {style}")
    aligners = _ALIGNERS_BY_STYLE[style]
    classify = _classify_vhdl if language == "vhdl" else _classify_sv
    out = []
    i = 0
    n = len(lines)
    while i < n:
        ln = lines[i]
        body, _ = split_comment(ln, "--" if language == "vhdl" else "//")
        kind = classify(body) if body.strip() else None
        if kind is None:
            out.append(ln.rstrip())
            i += 1
            continue
        # gather a run of consecutive same-kind lines
        j = i
        while j < n:
            b2, _ = split_comment(lines[j], "--" if language == "vhdl" else "//")
            k2 = classify(b2) if b2.strip() else None
            if k2 != kind:
                break
            j += 1
        block = lines[i:j]
        aligned = aligners[kind](block)
        if aligned is None:
            aligned = [l.rstrip() for l in block]
        out.extend(aligned)
        i = j
    return out


def _finish(out, collapse_blank):
    """Strip trailing whitespace; optionally collapse blank-line runs."""
    if collapse_blank:
        return normalize_blank_lines(out)
    return [l.rstrip() for l in out]


def normalize_blank_lines(lines):
    """Collapse runs of 2+ blank lines into a single blank line and strip
    trailing whitespace from every line."""
    out = []
    prev_blank = False
    for ln in lines:
        if not ln.strip():
            if prev_blank:
                continue
            prev_blank = True
            out.append("")
        else:
            prev_blank = False
            out.append(ln.rstrip())
    # drop a trailing blank line at end of file
    while out and not out[-1].strip():
        out.pop()
    return out


# ---------------------------------------------------------------------------
# File-level processing
# ---------------------------------------------------------------------------

_VHDL_FENCE = re.compile(r"^\s*```(vhdl|systemverilog|verilog)\s*$", re.IGNORECASE)
_CODE_FENCE = re.compile(r"^\s*```\s*$")


def prettify_text(text, is_markdown, lang=None, collapse_blank=True,
                  style="moderate"):
    """Prettify file text.  For markdown, only fenced code blocks are touched."""
    src = text.splitlines()
    if not is_markdown:
        l = lang or ("vhdl" if _looks_vhdl(src) else "sv")
        out = prettify_code(src, l, style)
        return "\n".join(_finish(out, collapse_blank)) + "\n"

    # markdown: rewrite only inside vhdl/systemverilog fenced blocks
    out = []
    in_code = False
    code_lang = None
    code_buf = []
    for ln in src:
        if in_code and _CODE_FENCE.match(ln):
            # end of code block
            pretty = prettify_code(code_buf,
                                   "vhdl" if code_lang == "vhdl" else "sv",
                                   style)
            out.extend(_finish(pretty, collapse_blank))
            out.append(ln)
            in_code = False
            code_lang = None
            code_buf = []
            continue
        if not in_code:
            m = _VHDL_FENCE.match(ln)
            if m and m.group(1).lower() in ("vhdl", "systemverilog", "verilog"):
                in_code = True
                code_lang = "vhdl" if m.group(1).lower() == "vhdl" else "sv"
                out.append(ln)
                continue
            out.append(ln.rstrip())
        else:
            code_buf.append(ln)
    # unterminated code block: flush remaining
    if code_buf:
        pretty = prettify_code(code_buf,
                       "vhdl" if code_lang == "vhdl" else "sv",
                       style)
        out.extend(_finish(pretty, collapse_blank))
    return "\n".join(out) + "\n"


def _looks_vhdl(src):
    """Heuristic: a bare file is VHDL if it contains a VHDL entity/library
    marker before any SystemVerilog-only marker."""
    has_vhdl = any(re.search(r"\b(?:entity|architecture|library|signal)\b", l)
                   for l in src[:60])
    has_sv = any(re.search(r"\bmodule\b|^\s*(logic|wire|input|output)\b", l)
                 for l in src[:60])
    return has_vhdl and not has_sv


# ---------------------------------------------------------------------------
# Invariant check
# ---------------------------------------------------------------------------

def _check_invariant(before_lines, after_lines):
    """Assert the tool only changed whitespace (per-line token content)."""
    if len(before_lines) != len(after_lines):
        # blank-line collapse changes line count; compare content stream
        bws = [non_ws(l) for l in before_lines if non_ws(l)]
        aws = [non_ws(l) for l in after_lines if non_ws(l)]
        return bws == aws
    for b, a in zip(before_lines, after_lines):
        if non_ws(b) != non_ws(a):
            return False
    return True


def prettify_file(path, collapse_blank=True, style="moderate"):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    is_md = path.lower().endswith((".md", ".markdown"))
    new_text = prettify_text(text, is_md, collapse_blank=collapse_blank,
                             style=style)
    ok = _check_invariant(text.splitlines(), new_text.splitlines())
    return text, new_text, ok


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv):
    ap = argparse.ArgumentParser(description="Whitespace-only HDL column aligner")
    ap.add_argument("paths", nargs="*", help="files to align")
    ap.add_argument("--style", choices=["extreme", "moderate", "collapsed"], default="moderate",
                    help="alignment profile (default: moderate)")
    ap.add_argument("--stdin", action="store_true",
                    help="read a raw code block from stdin, write result to stdout")
    ap.add_argument("--lang", choices=["vhdl", "sv", "auto"], default="auto",
                    help="language (default: auto-detect from file/stdin)")
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if any file would change (for CI)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print a unified diff without writing")
    ap.add_argument("--no-collapse-blank", action="store_true",
                    help="keep blank lines as-is (do not collapse runs)")
    args = ap.parse_args(argv)
    collapse = not args.no_collapse_blank

    if args.stdin:
        text = sys.stdin.read()
        lang = args.lang
        if lang == "auto":
            lang = "vhdl" if _looks_vhdl(text.splitlines()) else "sv"
        sys.stdout.write(prettify_text(text, False, lang=lang,
                           collapse_blank=collapse,
                           style=args.style))
        return 0

    if not args.paths:
        ap.print_help()
        return 2

    changed_any = False
    for path in args.paths:
        before, after, ok = prettify_file(path, collapse_blank=collapse,
                          style=args.style)
        if not ok:
            print(f"ERROR: {path}: aligner changed non-whitespace content; "
                  f"refusing to write", file=sys.stderr)
            return 3
        if before == after:
            print(f"ok     {path}")
            continue
        changed_any = True
        if args.dry_run:
            sys.stdout.writelines(difflib.unified_diff(
                before.splitlines(keepends=True), after.splitlines(keepends=True),
                fromfile=path, tofile=path + " (aligned)"))
        elif args.check:
            print(f"would change {path}")
        else:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(after)
            print(f"wrote  {path}")
    if args.check and changed_any:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
