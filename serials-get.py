#!/usr/bin/env python3
import sys, re, argparse, subprocess, csv

HEADER = ["Product:", "NAME:", "DEVID:", "LNN:", "SERNO:", "ChsCode:", "ChsSerN:", "ChsSlot:", "EXT-IP:"]

NOISE_PATTERNS = (
    "cd: no such file or directory",
    "Exception ignored in:",
    "BrokenPipeError:",
)

def is_noise(line: str) -> bool:
    return any(pat in line for pat in NOISE_PATTERNS) or not line.strip()

def parse_block(lines):
    rec = {
        "product": "n/a", "name": "n/a", "devid": "n/a", "lnn": "n/a", "serno": "n/a",
        "chscode": "n/a", "chssern": "n/a", "chsslot": "n/a", "extip": "n/a",
    }
    err = False

    first = lines[0]
    m = re.search(r"NAME:(\S+).*?DEVID:(\S+).*?LNN:(\S+).*?SERNO:(\S+).*?EXT-IP:\s*([0-9.]+)", first)
    if not m:
        return rec, True
    rec["name"], rec["devid"], rec["lnn"], rec["serno"], rec["extip"] = m.groups()
    expect = rec["name"] + ":"

    for s in lines[1:]:
        if not s.startswith(expect):
            err = True
        if "ChsSerN:" in s:
            mm = re.search(r"ChsSerN:\s*(\S+)", s)
            if mm:
                chssern = mm.group(1)
                if chssern == rec["serno"]:
                    rec["chssern"] = "SINGLE-CHASSIS"
                else:
                    rec["chssern"] = chssern
        if "ChsSlot:" in s:
            mm = re.search(r"ChsSlot:\s*(\S+)", s)
            if mm: rec["chsslot"] = mm.group(1)
        if "ChsCode:" in s:
            mm = re.search(r"ChsCode:\s*(\S+)", s)
            if mm: rec["chscode"] = mm.group(1)
        if "Product:" in s:
            rec["product"] = s.split("Product:", 1)[1].strip() or rec["product"]

    return rec, err

def format_columns(rows):
    widths = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    return "\n".join("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)) for row in rows)

def rows_from_text(lines):
    raw = [ln.rstrip("\n") for ln in lines if not is_noise(ln)]
    rows = [HEADER[:]]
    i = 0
    n = len(raw)
    while i < n:
        if not raw[i].startswith("NAME:"):
            i += 1
            continue
        block = raw[i:i+6]
        if len(block) != 6:
            rec = {"product": "OUTPUT-ERROR", "name": "n/a", "devid": "n/a", "lnn": "n/a", "serno": "n/a",
                   "chscode": "n/a", "chssern": "n/a", "chsslot": "n/a", "extip": "n/a"}
        else:
            rec, bad = parse_block(block)
            if bad:
                rec["product"] = "OUTPUT-ERROR"
        rows.append([
            rec["product"], rec["name"], rec["devid"], rec["lnn"], rec["serno"],
            rec["chscode"], rec["chssern"], rec["chsslot"], rec["extip"],
        ])
        i += 6
    return rows

def parse_nodes_spec(spec: str):
    nodes = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            a = int(a); b = int(b)
            if a > b: a, b = b, a
            nodes.update(range(a, b + 1))
        else:
            nodes.add(int(part))
    return sorted(nodes)

def collect_from_cluster(nodes, timeout):
    all_lines = []
    for i in nodes:
        cmd1 = f"isi_nodes -n {i} NAME:%{{node}} DEVID:%{{devid}} LNN:%{{lnn}} SERNO:%{{serialno}} EXT-IP: %{{address4}}"
        cmd2 = f"isi_for_array -n{i} \"isi_hw_status|egrep 'SerNo|ChsSerN|ChsSlot|Product|ChsCode'\""
        for cmd in (cmd1, cmd2):
            try:
                proc = subprocess.run(cmd, shell=True, executable="/bin/sh",
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      text=True, timeout=timeout)
            except subprocess.TimeoutExpired:
                print(f"ERROR: command timed out after {timeout}s: {cmd}", file=sys.stderr)
                continue
            except Exception as e:
                print(f"ERROR: failed to run: {cmd}\n{e}", file=sys.stderr)
                continue
            if proc.returncode != 0 and proc.stderr:
                err = proc.stderr.strip().splitlines()[0]
                print(f"WARN (node {i}): {err}", file=sys.stderr)
            if proc.stdout:
                all_lines.extend(proc.stdout.splitlines(True))
    return all_lines

def sort_rows(rows, sortby, sorttype):
    if not sortby:
        return rows
    header_lower_map = {col.lower().rstrip(":"): idx for idx, col in enumerate(rows[0])}
    keyname = sortby.lower().rstrip(":")
    if keyname not in header_lower_map:
        valid = ", ".join(header_lower_map.keys())
        print(f"ERROR: Invalid sortby '{sortby}'. Valid options: {valid}", file=sys.stderr)
        return rows
    idx = header_lower_map[keyname]
    header = rows[0]
    body = rows[1:]
    reverse = (sorttype.lower() == "desc")
    body_sorted = sorted(body, key=lambda r: r[idx], reverse=reverse)
    return [header] + body_sorted

def main():
    valid_sort_fields = ", ".join(h.rstrip(":") for h in HEADER)
    ap = argparse.ArgumentParser(
        description="Run Isilon/PowerScale commands, parse 6-line datasets, and output aligned table or CSV."
    )
    ap.add_argument(
        "--nodes", default="1-3",
        help="Node IDs to query, e.g. '1-3' or '1,2,5' or '1-3,6'. Default: 1-3"
    )
    ap.add_argument(
        "--timeout", type=int, default=30,
        help="Per-command timeout in seconds (default: 30)"
    )
    ap.add_argument(
        "--csv", nargs="?", const="-",
        help="Output CSV instead of aligned text. With no value, writes to stdout; provide a filename to write to a file."
    )
    ap.add_argument(
        "--sortby",
        help=f"Column name to sort by (case-insensitive, with or without colon). Valid options: {valid_sort_fields}"
    )
    ap.add_argument(
        "--sorttype", default="asc", choices=["asc", "desc"],
        help="Sort order: asc (default) or desc"
    )
    args = ap.parse_args()

    nodes = parse_nodes_spec(args.nodes)
    if not nodes:
        print("ERROR: no nodes selected (check --nodes)", file=sys.stderr)
        sys.exit(1)

    lines = collect_from_cluster(nodes, args.timeout)
    rows = rows_from_text(lines)
    rows = sort_rows(rows, args.sortby, args.sorttype)

    if args.csv is not None:
        outfh = sys.stdout
        close_needed = False
        if args.csv not in (None, "-"):
            outfh = open(args.csv, "w", newline="", encoding="utf-8")
            close_needed = True
        w = csv.writer(outfh)
        for row in rows:
            w.writerow(row)
        if close_needed:
            outfh.close()
    else:
        print(format_columns(rows))

if __name__ == "__main__":
    main()
