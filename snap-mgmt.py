#!/usr/bin/env python3
"""
SnapD Snapshot Management Tool

This script manages and analyzes PowerScale snapshots by reading saved verbose
snapshot listings and categorizing the information. It provides capabilities for:
- Assessing current snapshot state
- Grouping snapshots by name prefix or path
- Sorting and filtering snapshots
- Searching for specific snapshots
- Exporting data in multiple formats
- Threshold-based alerting
- Date/time filtering

Author: Elie Koivunen (Elie.Koivunen@Dell.com)
Version: 1.0.0
License: MIT
"""

import argparse
from collections import defaultdict
from operator import itemgetter
import sys
import os
import subprocess
from datetime import datetime, timedelta
import socket
import textwrap
import re
import json
import csv
import logging
from typing import Dict, List, Tuple, Optional, Any
from dataclasses import dataclass
from pathlib import Path
from enum import Enum


# ============================================================================
# Configuration and Metadata
# ============================================================================

class ScriptConfig:
    """Script configuration and metadata."""
    
    NAME = "snap-mgmt"
    AUTHOR = "Elie.Koivunen@Dell.com"
    CONTRIBUTORS = ""
    VERSION = "1.0.0"
    HOSTNAME = socket.gethostname()
    PUBLISH_DATE = "2024-05-24"
    
    # License text (MIT License)
    LICENSE = (
        "Copyright 2024 Dell. Permission is hereby granted, free of charge, to any "
        "person obtaining a copy of this software and associated documentation files "
        "(the Software), to deal in the Software without restriction, including "
        "without limitation the rights to use, copy, modify, merge, publish, distribute, "
        "sublicense, and/or sell copies of the Software, and to permit persons to whom "
        "the Software is furnished to do so, subject to the following conditions: "
        "The above copyright notice and this permission notice shall be included in all "
        "copies or substantial portions of the Software. All changes should be shared back."
    )
    
    # Disclaimer
    WARNING = (
        "THE SOFTWARE IS PROVIDED AS-IS, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR "
        "IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, "
        "FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE "
        "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER "
        "LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, "
        "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN "
        "THE SOFTWARE."
    )
    
    # Usage instructions
    HOWTO = (
        "This script reads the saved verbose snapshot listing and categorizes the "
        "information accordingly. First you would run --snapshot-assess to collect "
        "information of the currently existing snapshots on the system. This info would "
        "be saved into a snapshot-info-<timestamp>.src file. Having this feature gives "
        "the chance to capture point in time snapshot statistics for more extensive "
        "analysis. Once you have a source file, you can list grouped information of "
        "snapshots based on the designated absolute path or a grouping based on the "
        "prefix of a snapshot schedule name. You have the option of sorting the output "
        "based on entries, state, size, name or path in an ascending or descending "
        "order. With the search switch, you have the option of searching based on "
        "absolute path or a snapshot schedule name prefix."
    )


class OutputFormat(Enum):
    """Supported output formats."""
    TABLE = "table"
    CSV = "csv"
    JSON = "json"


# ============================================================================
# Logging Setup
# ============================================================================

def setup_logging(log_file: Optional[str] = None, verbose: bool = False) -> None:
    """
    Configure logging for the script.
    
    Args:
        log_file: Optional path to log file. If None, logs to console only.
        verbose: If True, set log level to DEBUG; otherwise INFO.
    """
    log_level = logging.DEBUG if verbose else logging.INFO
    log_format = '%(asctime)s - %(levelname)s - %(message)s'
    
    handlers = [logging.StreamHandler(sys.stdout)]
    if log_file:
        handlers.append(logging.FileHandler(log_file))
    
    logging.basicConfig(
        level=log_level,
        format=log_format,
        handlers=handlers
    )


# ============================================================================
# Utility Functions
# ============================================================================

def format_text_width(input_string: str, width: int = 78) -> str:
    """
    Format text to wrap at specified width without splitting words.
    
    Args:
        input_string: The text to format.
        width: Maximum line width (default: 78).
        
    Returns:
        Formatted text with line breaks.
    """
    return textwrap.fill(input_string, width)


def get_prefix(name: str) -> str:
    """
    Extract the prefix from a snapshot name by removing the last segment.
    
    Example: 'daily-20240524' -> 'daily'
    
    Args:
        name: The snapshot name.
        
    Returns:
        The prefix part of the name.
    """
    parts = name.split('-')
    if len(parts) > 1:
        return '-'.join(parts[:-1])
    return name


def parse_size(size_str: str) -> float:
    """
    Parse a size string with unit suffix to bytes.
    
    Supports: K, M, G, T (case-insensitive).
    
    Args:
        size_str: Size string (e.g., '10G', '500M', '1.5T').
        
    Returns:
        Size in bytes as a float.
        
    Raises:
        ValueError: If the size string is invalid.
    """
    size_str = size_str.lower().strip()
    
    # Extract numeric part and unit
    match = re.match(r'^([\d.]+)([kmgt]?)$', size_str)
    if not match:
        raise ValueError(f"Invalid size format: {size_str}")
    
    value = float(match.group(1))
    unit = match.group(2) or ''
    
    multipliers = {
        '': 1,
        'k': 1024,
        'm': 1024 ** 2,
        'g': 1024 ** 3,
        't': 1024 ** 4
    }
    
    if unit not in multipliers:
        raise ValueError(f"Unknown size unit: {unit}")
    
    return value * multipliers[unit]


def convert_to_human_readable(size_in_bytes: float, unit: str = 'TB') -> str:
    """
    Convert bytes to human-readable format.
    
    Args:
        size_in_bytes: Size in bytes.
        unit: Target unit (B, KB, MB, GB, TB). Default is TB.
        
    Returns:
        Formatted string with unit.
    """
    multipliers = {
        'B': 1,
        'KB': 1024,
        'MB': 1024 ** 2,
        'GB': 1024 ** 3,
        'TB': 1024 ** 4
    }
    
    if unit not in multipliers:
        raise ValueError(f"Unknown unit: {unit}")
    
    converted = size_in_bytes / multipliers[unit]
    
    # Format with appropriate precision
    if converted < 0.01:
        return f"{converted:.6f} {unit}"
    elif converted < 1:
        return f"{converted:.4f} {unit}"
    else:
        return f"{converted:.2f} {unit}"


# ============================================================================
# Data Structures
# ============================================================================

@dataclass
class SnapshotEntry:
    """Represents a single snapshot entry."""
    id: str
    name: str
    path: str
    size: float  # in bytes
    state: str
    locked: bool
    created: Optional[str] = None
    expires: Optional[str] = None


@dataclass
class GroupedEntry:
    """Represents a grouped snapshot entry."""
    key: str  # Either prefix or path
    state: str
    count: int
    total_size: float  # in bytes
    path: str  # Associated path


# ============================================================================
# File Parsing
# ============================================================================

def parse_snapshot_line(line: str) -> Optional[SnapshotEntry]:
    """
    Parse a single line from the isi snapshot list output.
    
    Uses regex to handle variable spacing and extract fields reliably.
    
    Args:
        line: A line from the snapshot list output.
        
    Returns:
        SnapshotEntry object if parsing succeeds, None otherwise.
    """
    # Skip header and separator lines
    if line.startswith('-') or line.startswith('Total:') or line.startswith('ID'):
        return None
    
    # Regex pattern to match the isi snapshot table format
    # Expected format: ID Name Path ... Size ... State Locked
    # This is a more robust approach than space-based splitting
    pattern = r'^\s*(\S+)\s+(\S+)\s+(\S+)\s+(?:\S+\s+){5}(\S+[KMGT]?)\s+(?:\S+\s+){2}(\S+)\s+(\S+)\s*$'
    
    match = re.match(pattern, line)
    if not match:
        logging.debug(f"Failed to parse line: {line}")
        return None
    
    try:
        return SnapshotEntry(
            id=match.group(1),
            name=match.group(2),
            path=match.group(3),
            size=parse_size(match.group(4)),
            state=match.group(5),
            locked=match.group(6).lower() == 'yes'
        )
    except ValueError as e:
        logging.warning(f"Error parsing size in line: {line} - {e}")
        return None


def read_snapshot_file(file_path: str) -> List[SnapshotEntry]:
    """
    Read and parse a snapshot info file.
    
    Args:
        file_path: Path to the snapshot info file.
        
    Returns:
        List of SnapshotEntry objects.
        
    Raises:
        FileNotFoundError: If the file doesn't exist.
        IOError: If the file cannot be read.
    """
    path = Path(file_path)
    if not path.exists():
        raise FileNotFoundError(f"Snapshot file not found: {file_path}")
    
    entries = []
    with open(file_path, 'r') as file:
        lines = file.readlines()
        
        for line_num, line in enumerate(lines, 1):
            entry = parse_snapshot_line(line)
            if entry:
                entries.append(entry)
            elif line.strip():  # Non-empty line that failed to parse
                logging.debug(f"Skipped line {line_num}: {line.strip()}")
    
    logging.info(f"Read {len(entries)} snapshot entries from {file_path}")
    return entries


# ============================================================================
# Grouping Functions
# ============================================================================

def group_by_name(entries: List[SnapshotEntry]) -> Tuple[Dict[Tuple[str, str], Dict[str, Any]], Dict[str, str]]:
    """
    Group snapshot entries by name prefix and state.
    
    Args:
        entries: List of SnapshotEntry objects.
        
    Returns:
        Tuple of (grouped_entries_dict, paths_dict) where:
        - grouped_entries_dict: Keys are (prefix, state) tuples, values contain count and size
        - paths_dict: Maps prefix to path
    """
    grouped = defaultdict(lambda: defaultdict(int))
    paths = defaultdict(str)
    
    for entry in entries:
        prefix = get_prefix(entry.name)
        key = (prefix, entry.state)
        
        grouped[key]['count'] += 1
        grouped[key]['size'] += entry.size
        paths[prefix] = entry.path
    
    logging.info(f"Grouped entries by name: {len(grouped)} groups")
    return grouped, paths


def group_by_path(entries: List[SnapshotEntry]) -> Tuple[Dict[Tuple[str, str], Dict[str, Any]], Dict[str, str]]:
    """
    Group snapshot entries by path and state.
    
    Args:
        entries: List of SnapshotEntry objects.
        
    Returns:
        Tuple of (grouped_entries_dict, paths_dict) where:
        - grouped_entries_dict: Keys are (path, state) tuples, values contain count and size
        - paths_dict: Maps path to itself
    """
    grouped = defaultdict(lambda: defaultdict(int))
    paths = defaultdict(str)
    
    for entry in entries:
        key = (entry.path, entry.state)
        
        grouped[key]['count'] += 1
        grouped[key]['size'] += entry.size
        paths[entry.path] = entry.path
    
    logging.info(f"Grouped entries by path: {len(grouped)} groups")
    return grouped, paths


# ============================================================================
# Filtering Functions
# ============================================================================

def filter_by_locks(entries_list: List[Tuple]) -> List[Tuple]:
    """
    Filter entries to show only locked snapshots.
    
    Args:
        entries_list: List of entry tuples.
        
    Returns:
        Filtered list containing only locked entries.
    """
    # Entry tuple structure: (count, size, state, prefix, path)
    # State is at index 2
    return [entry for entry in entries_list if entry[2] == 'Yes']


def filter_by_age(entries: List[SnapshotEntry], max_age_days: int) -> List[SnapshotEntry]:
    """
    Filter entries by maximum age in days.
    
    Args:
        entries: List of SnapshotEntry objects.
        max_age_days: Maximum age in days.
        
    Returns:
        Filtered list of entries.
    """
    cutoff_date = datetime.now() - timedelta(days=max_age_days)
    filtered = []
    
    for entry in entries:
        if entry.created:
            try:
                created_date = datetime.strptime(entry.created, '%Y-%m-%d')
                if created_date >= cutoff_date:
                    filtered.append(entry)
            except ValueError:
                logging.warning(f"Could not parse creation date: {entry.created}")
                filtered.append(entry)  # Include if we can't parse
        else:
            filtered.append(entry)  # Include if no date
    
    return filtered


def filter_by_size(entries: List[SnapshotEntry], min_size_gb: float = 0, max_size_gb: float = float('inf')) -> List[SnapshotEntry]:
    """
    Filter entries by size range.
    
    Args:
        entries: List of SnapshotEntry objects.
        min_size_gb: Minimum size in GB.
        max_size_gb: Maximum size in GB.
        
    Returns:
        Filtered list of entries.
    """
    min_bytes = min_size_gb * 1024 ** 3
    max_bytes = max_size_gb * 1024 ** 3
    
    return [e for e in entries if min_bytes <= e.size <= max_bytes]


# ============================================================================
# Sorting Functions
# ============================================================================

def sort_entries(
    entries: Dict[Tuple[str, str], Dict[str, Any]],
    paths: Dict[str, str],
    sort_by: str,
    sort_type: str
) -> List[Tuple]:
    """
    Sort grouped entries by specified column.
    
    Args:
        entries: Dictionary of grouped entries.
        paths: Dictionary mapping keys to paths.
        sort_by: Column to sort by ('entries', 'size', 'state', 'name', 'path').
        sort_type: Sort order ('asc' or 'desc').
        
    Returns:
        Sorted list of entry tuples.
    """
    sort_column_map = {
        "entries": 0,
        "size": 1,
        "state": 2,
        "name": 3,
        "path": 4
    }
    
    sort_index = sort_column_map.get(sort_by, 4)
    
    # Convert to list of tuples: (count, size, state, prefix, path)
    entries_list = [
        (
            data['count'],
            convert_to_human_readable(data['size']),
            state,
            prefix,
            paths[prefix]
        )
        for (prefix, state), data in entries.items()
    ]
    
    entries_list.sort(key=itemgetter(sort_index), reverse=(sort_type == "desc"))
    
    logging.info(f"Sorted {len(entries_list)} entries by {sort_by} ({sort_type})")
    return entries_list


# ============================================================================
# Output Functions
# ============================================================================

def print_table(entries_list: List[Tuple], group_by_path: bool = False) -> None:
    """
    Print entries in table format.
    
    Args:
        entries_list: List of entry tuples.
        group_by_path: If True, use path-based table format; otherwise name-based.
    """
    if group_by_path:
        # Path-based format
        print("{:<10}{:<20}{:<10}{:<100}".format("Entries", "Total Size", "State", "Path"))
        print("-" * 140)
        for entry in entries_list:
            cleaned = [str(field).strip() for field in entry]
            print("{:<10}{:<20}{:<10}{:<100}".format(
                cleaned[0], cleaned[1], cleaned[2], cleaned[4]
            ))
    else:
        # Name-based format
        print("{:<10}{:<20}{:<10}{:<50}{:<100}".format(
            "Entries", "Total Size", "State", "Name Prefix", "Path"
        ))
        print("-" * 140)
        for entry in entries_list:
            cleaned = [str(field).strip() for field in entry]
            print("{:<10}{:<20}{:<10}{:<50}{:<100}".format(*cleaned))


def export_to_csv(entries_list: List[Tuple], output_file: str, group_by_path: bool = False) -> None:
    """
    Export entries to CSV format.
    
    Args:
        entries_list: List of entry tuples.
        output_file: Path to output CSV file.
        group_by_path: If True, use path-based headers; otherwise name-based.
    """
    if group_by_path:
        headers = ['Entries', 'Total Size', 'State', 'Path']
        field_indices = [0, 1, 2, 4]
    else:
        headers = ['Entries', 'Total Size', 'State', 'Name Prefix', 'Path']
        field_indices = [0, 1, 2, 3, 4]
    
    with open(output_file, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(headers)
        
        for entry in entries_list:
            row = [str(entry[i]).strip() for i in field_indices]
            writer.writerow(row)
    
    logging.info(f"Exported {len(entries_list)} entries to CSV: {output_file}")


def export_to_json(entries_list: List[Tuple], output_file: str, group_by_path: bool = False) -> None:
    """
    Export entries to JSON format.
    
    Args:
        entries_list: List of entry tuples.
        output_file: Path to output JSON file.
        group_by_path: If True, use path-based structure; otherwise name-based.
    """
    data = []
    
    for entry in entries_list:
        if group_by_path:
            item = {
                'entries': entry[0],
                'total_size': entry[1],
                'state': entry[2],
                'path': entry[4]
            }
        else:
            item = {
                'entries': entry[0],
                'total_size': entry[1],
                'state': entry[2],
                'name_prefix': entry[3],
                'path': entry[4]
            }
        data.append(item)
    
    with open(output_file, 'w') as jsonfile:
        json.dump(data, jsonfile, indent=2)
    
    logging.info(f"Exported {len(entries_list)} entries to JSON: {output_file}")


def check_thresholds(entries: List[SnapshotEntry], size_threshold_tb: float, count_threshold: int) -> List[str]:
    """
    Check if entries exceed specified thresholds.
    
    Args:
        entries: List of SnapshotEntry objects.
        size_threshold_tb: Size threshold in TB.
        count_threshold: Count threshold.
        
    Returns:
        List of alert messages.
    """
    alerts = []
    size_threshold_bytes = size_threshold_tb * 1024 ** 4
    
    # Check total size
    total_size = sum(e.size for e in entries)
    if total_size > size_threshold_bytes:
        alerts.append(
            f"ALERT: Total snapshot size {convert_to_human_readable(total_size)} "
            f"exceeds threshold {convert_to_human_readable(size_threshold_bytes)}"
        )
    
    # Check count
    if len(entries) > count_threshold:
        alerts.append(
            f"ALERT: Snapshot count {len(entries)} exceeds threshold {count_threshold}"
        )
    
    # Check individual snapshot sizes
    for entry in entries:
        if entry.size > size_threshold_bytes:
            alerts.append(
                f"ALERT: Snapshot {entry.name} size {convert_to_human_readable(entry.size)} "
                f"exceeds threshold {convert_to_human_readable(size_threshold_bytes)}"
            )
    
    return alerts


# ============================================================================
# Search Functions
# ============================================================================

def search_entries(entries_list: List[Tuple], search_string: str, is_path_search: bool) -> None:
    """
    Search for entries matching the search string.
    
    Args:
        entries_list: List of entry tuples.
        search_string: String to search for.
        is_path_search: If True, search in path field; otherwise search in all fields.
    """
    if is_path_search:
        print("{:<10}{:<20}{:<10}{:<100}".format("Entries", "Total Size", "State", "Path"))
        print("-" * 140)
        for entry in entries_list:
            cleaned = [str(field).strip() for field in entry]
            if search_string in cleaned[3] or search_string in cleaned[4]:
                print("{:<10}{:<20}{:<10}{:<100}".format(
                    cleaned[0], cleaned[1], cleaned[2], cleaned[4]
                ))
    else:
        print("{:<10}{:<20}{:<10}{:<50}{:<100}".format(
            "Entries", "Total Size", "State", "Name Prefix", "Path"
        ))
        print("-" * 140)
        for entry in entries_list:
            cleaned = [str(field).strip() for field in entry]
            if search_string in cleaned[3] or search_string in cleaned[4]:
                print("{:<10}{:<20}{:<10}{:<50}{:<100}".format(*cleaned))


# ============================================================================
# Snapshot Assessment
# ============================================================================

def snapshots_assess(output_dir: str = ".") -> str:
    """
    Run isi snapshot assessment and save results to file.
    
    Args:
        output_dir: Directory to save the output file.
        
    Returns:
        Path to the generated file.
        
    Raises:
        subprocess.CalledProcessError: If the isi command fails.
    """
    command = ['isi', 'snapshot', 'snapshots', 'list', '--verbose', '--format=table']
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = os.path.join(output_dir, f"snapshots-info_{timestamp}.src")
    
    logging.info(f"Running snapshot assessment: {' '.join(command)}")
    
    try:
        with open(filename, 'w') as file:
            result = subprocess.run(
                command,
                stdout=file,
                stderr=subprocess.PIPE,
                check=True,
                text=True
            )
            if result.stderr:
                logging.warning(f"isi command stderr: {result.stderr}")
    except subprocess.CalledProcessError as e:
        logging.error(f"isi snapshot command failed: {e}")
        if e.stderr:
            logging.error(f"Error output: {e.stderr}")
        raise
    
    logging.info(f"Snapshot assessment saved to: {filename}")
    return filename


# ============================================================================
# Script Information
# ============================================================================

def print_about() -> None:
    """Display script metadata and information."""
    print("\n" + "=" * 80)
    print("\n")
    print(f"Script Name: {ScriptConfig.NAME}")
    print(f"Author: {ScriptConfig.AUTHOR}")
    print(f"Contributors: {ScriptConfig.CONTRIBUTORS}")
    print(f"Version: {ScriptConfig.VERSION}")
    print(f"Current hostname: {ScriptConfig.HOSTNAME}")
    print(f"Publish Date: {ScriptConfig.PUBLISH_DATE}")
    print("\n")
    print(f"License:\n{format_text_width(ScriptConfig.LICENSE)}")
    print("\n")
    print(f"Disclaimer:\n{format_text_width(ScriptConfig.WARNING)}")
    print("\n")
    print(f"Usage:\n{format_text_width(ScriptConfig.HOWTO)}")
    print("\n")
    print("=" * 80)
    print("\n")


# ============================================================================
# Main Function
# ============================================================================

def main() -> None:
    """Main entry point for the script."""
    parser = argparse.ArgumentParser(
        description='Process PowerScale snapshot information and analyze storage usage.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=format_text_width(ScriptConfig.HOWTO)
    )
    
    # Input/Output arguments
    parser.add_argument('--file', help='Path to the snapshot info file to process')
    parser.add_argument('--output', help='Output file path for export formats (CSV/JSON)')
    parser.add_argument('--format', default='table', 
                       choices=['table', 'csv', 'json'],
                       help='Output format (default: table)')
    
    # Grouping arguments
    parser.add_argument('--group-by-name', action='store_true', 
                       help='Group snapshots by name prefix')
    parser.add_argument('--group-by-path', action='store_true', 
                       help='Group snapshots by path')
    
    # Sorting arguments
    parser.add_argument('--sort-by', default='path',
                       choices=['entries', 'state', 'size', 'name', 'path'],
                       help='Sort column (default: path)')
    parser.add_argument('--sort-type', default='asc',
                       choices=['asc', 'desc'],
                       help='Sort order (default: asc)')
    
    # Filtering arguments
    parser.add_argument('--search', help='Search for specific string in name prefix or path')
    parser.add_argument('--locks', action='store_true',
                       help='Show only locked snapshots')
    parser.add_argument('--max-age-days', type=int,
                       help='Filter snapshots older than specified days')
    parser.add_argument('--min-size-gb', type=float, default=0,
                       help='Filter snapshots smaller than specified GB')
    parser.add_argument('--max-size-gb', type=float,
                       help='Filter snapshots larger than specified GB')
    
    # Threshold arguments
    parser.add_argument('--size-threshold-tb', type=float,
                       help='Alert if total size exceeds this threshold (TB)')
    parser.add_argument('--count-threshold', type=int,
                       help='Alert if snapshot count exceeds this threshold')
    
    # Assessment arguments
    parser.add_argument('--snapshots-assess', action='store_true',
                       help='Run snapshot assessment and save to file')
    parser.add_argument('--assess-dir', default='.',
                       help='Directory to save assessment output (default: current)')
    
    # Mode arguments
    parser.add_argument('--dry-run', action='store_true',
                       help='Preview changes without executing')
    
    # Information arguments
    parser.add_argument('--about', action='store_true',
                       help='Display script information')
    parser.add_argument('--verbose', action='store_true',
                       help='Enable verbose logging')
    parser.add_argument('--log-file', help='Path to log file')
    
    args = parser.parse_args()
    
    # Setup logging
    setup_logging(args.log_file, args.verbose)
    
    logging.info(f"SnapD Snapshot Management Tool v{ScriptConfig.VERSION}")
    logging.info(f"Arguments: {vars(args)}")
    
    # Handle --about
    if args.about:
        print_about()
        return
    
    # Handle --snapshots-assess
    if args.snapshots_assess:
        if args.dry_run:
            print("[DRY-RUN] Would run snapshot assessment")
            logging.info("DRY-RUN: Would run snapshot assessment")
        else:
            try:
                output_file = snapshots_assess(args.assess_dir)
                print(f"Snapshot assessment saved to: {output_file}")
            except subprocess.CalledProcessError as e:
                print(f"ERROR: Snapshot assessment failed: {e}")
                sys.exit(1)
        return
    
    # Validate file argument for other operations
    if not args.file:
        print("ERROR: --file argument is required for this operation")
        parser.print_help()
        sys.exit(1)
    
    # Read and parse snapshot file
    try:
        entries = read_snapshot_file(args.file)
    except (FileNotFoundError, IOError) as e:
        print(f"ERROR: {e}")
        sys.exit(1)
    
    # Apply size filters if specified
    if args.min_size_gb > 0 or args.max_size_gb:
        max_gb = args.max_size_gb if args.max_size_gb else float('inf')
        entries = filter_by_size(entries, args.min_size_gb, max_gb)
        logging.info(f"Filtered by size: {len(entries)} entries remaining")
    
    # Determine grouping method
    is_path_search = args.search and '/' in args.search
    if is_path_search or args.group_by_path:
        grouped, paths = group_by_path(entries)
        group_by_path_mode = True
    else:
        grouped, paths = group_by_name(entries)
        group_by_path_mode = False
    
    # Sort entries
    entries_list = sort_entries(grouped, paths, args.sort_by, args.sort_type)
    
    # Apply lock filter
    if args.locks:
        entries_list = filter_by_locks(entries_list)
        logging.info(f"Filtered by locks: {len(entries_list)} entries remaining")
    
    # Check thresholds
    if args.size_threshold_tb or args.count_threshold:
        size_tb = args.size_threshold_tb if args.size_threshold_tb else 0
        count = args.count_threshold if args.count_threshold else 0
        alerts = check_thresholds(entries, size_tb, count)
        if alerts:
            print("\n" + "=" * 80)
            print("THRESHOLD ALERTS:")
            for alert in alerts:
                print(f"  {alert}")
            print("=" * 80 + "\n")
    
    # Handle search
    if args.search:
        search_entries(entries_list, args.search, is_path_search)
    # Handle output formats
    elif args.format == 'csv':
        if not args.output:
            print("ERROR: --output required for CSV format")
            sys.exit(1)
        export_to_csv(entries_list, args.output, group_by_path_mode)
        print(f"Exported to CSV: {args.output}")
    elif args.format == 'json':
        if not args.output:
            print("ERROR: --output required for JSON format")
            sys.exit(1)
        export_to_json(entries_list, args.output, group_by_path_mode)
        print(f"Exported to JSON: {args.output}")
    else:
        # Default table output
        if args.group_by_name:
            print_table(entries_list, group_by_path=False)
        else:
            print_table(entries_list, group_by_path=True)
    
    logging.info("Script completed successfully")


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # Handle broken pipe gracefully (e.g., when piping to head)
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, sys.stdout.fileno())
        sys.exit(0)
    except KeyboardInterrupt:
        print("\nInterrupted by user")
        logging.info("Script interrupted by user")
        sys.exit(130)
    except Exception as e:
        logging.error(f"Unexpected error: {e}", exc_info=True)
        print(f"ERROR: {e}")
        sys.exit(1)
