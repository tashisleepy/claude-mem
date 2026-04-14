#!/usr/bin/env bash
# claude-mem - Date-Range Activity Report Generator
# Generates work reports from claude-mem SQLite database filtered by date range.
#
# Usage:
#   ./scripts/date-report.sh --week        Last 7 days
#   ./scripts/date-report.sh --month       Last 30 days
#   ./scripts/date-report.sh --quarter     Last 90 days
#   ./scripts/date-report.sh --since 2026-04-01
#   ./scripts/date-report.sh --between 2026-04-01 2026-04-14
#   ./scripts/date-report.sh --project myproject --month
#
# Reads from: ~/.claude-mem/claude-mem.db
# Output: Markdown report to stdout

set -euo pipefail

DB_PATH="${CLAUDE_MEM_DB:-$HOME/.claude-mem/claude-mem.db}"

if [[ ! -f "$DB_PATH" ]]; then
  echo "ERROR: claude-mem database not found at $DB_PATH" >&2
  echo "Set CLAUDE_MEM_DB env var or install claude-mem first." >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "ERROR: sqlite3 not found. Install via: brew install sqlite (macOS)" >&2
  exit 1
fi

START_DATE=""
END_DATE="$(date '+%Y-%m-%d')"
PROJECT_FILTER=""
LABEL=""

usage() {
  cat <<'EOF'
claude-mem Date-Range Activity Report

Usage:
  ./scripts/date-report.sh [TIME_RANGE] [OPTIONS]

Time Range (pick one):
  --week                Last 7 days
  --month               Last 30 days
  --quarter             Last 90 days
  --year                Last 365 days
  --since YYYY-MM-DD    Since specific date
  --between START END   Between two dates (inclusive)

Options:
  --project NAME        Filter by project name
  --format FORMAT       Output format: markdown (default) | csv | json
  --help                Show this message

Examples:
  ./scripts/date-report.sh --week
  ./scripts/date-report.sh --month --project myproject
  ./scripts/date-report.sh --since 2026-04-01
  ./scripts/date-report.sh --between 2026-01-01 2026-03-31 --format csv

Output: Markdown formatted report to stdout (or CSV/JSON if specified).
EOF
}

FORMAT="markdown"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --week)
      START_DATE="$(date -v-7d '+%Y-%m-%d' 2>/dev/null || date -d '7 days ago' '+%Y-%m-%d')"
      LABEL="Last 7 Days"
      shift
      ;;
    --month)
      START_DATE="$(date -v-30d '+%Y-%m-%d' 2>/dev/null || date -d '30 days ago' '+%Y-%m-%d')"
      LABEL="Last 30 Days"
      shift
      ;;
    --quarter)
      START_DATE="$(date -v-90d '+%Y-%m-%d' 2>/dev/null || date -d '90 days ago' '+%Y-%m-%d')"
      LABEL="Last 90 Days"
      shift
      ;;
    --year)
      START_DATE="$(date -v-365d '+%Y-%m-%d' 2>/dev/null || date -d '365 days ago' '+%Y-%m-%d')"
      LABEL="Last 365 Days"
      shift
      ;;
    --since)
      START_DATE="$2"
      LABEL="Since $2"
      shift 2
      ;;
    --between)
      START_DATE="$2"
      END_DATE="$3"
      LABEL="$2 to $3"
      shift 3
      ;;
    --project)
      PROJECT_FILTER="$2"
      shift 2
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$START_DATE" ]]; then
  echo "ERROR: Specify a time range. Use --help for options." >&2
  exit 1
fi

# Build WHERE clause
WHERE="DATE(created_at) >= '$START_DATE' AND DATE(created_at) <= '$END_DATE'"
if [[ -n "$PROJECT_FILTER" ]]; then
  WHERE="$WHERE AND project = '$PROJECT_FILTER'"
fi

case "$FORMAT" in
  markdown|md)
    echo "# claude-mem Activity Report"
    echo "## Period: $LABEL ($START_DATE to $END_DATE)"
    if [[ -n "$PROJECT_FILTER" ]]; then
      echo "## Project Filter: $PROJECT_FILTER"
    fi
    echo ""
    echo "Generated: $(date '+%Y-%m-%d %H:%M')"
    echo ""
    echo "---"
    echo ""

    # Summary stats
    echo "## Summary Stats"
    echo ""
    SESSION_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT memory_session_id) FROM observations WHERE $WHERE" 2>/dev/null || echo "0")
    OBS_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM observations WHERE $WHERE" 2>/dev/null || echo "0")
    PROJECT_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT project) FROM observations WHERE $WHERE" 2>/dev/null || echo "0")
    echo "- **Sessions:** $SESSION_COUNT"
    echo "- **Observations:** $OBS_COUNT"
    echo "- **Projects touched:** $PROJECT_COUNT"
    echo ""

    # By project
    echo "## Activity By Project"
    echo ""
    echo "| Project | Sessions | Observations |"
    echo "|---------|----------|--------------|"
    sqlite3 -separator '|' "$DB_PATH" "
      SELECT project,
             COUNT(DISTINCT memory_session_id),
             COUNT(*)
      FROM observations
      WHERE $WHERE
      GROUP BY project
      ORDER BY COUNT(*) DESC
    " 2>/dev/null | sed 's/^/| /;s/|/| /g;s/$/ |/' || echo "| (no data) | - | - |"
    echo ""

    # Recent sessions (top 30)
    # Schema: session_summaries has request/investigated/learned/completed columns (no 'title')
    # Use TAB separator to avoid IFS multi-char issues with bash read
    echo "## Recent Sessions"
    echo ""
    sqlite3 -separator $'\t' "$DB_PATH" "
      SELECT DATE(s.created_at) as date,
             s.project,
             SUBSTR(COALESCE(s.request, 'Untitled'), 1, 120) as request,
             (SELECT COUNT(*) FROM observations o WHERE o.memory_session_id = s.memory_session_id) as obs_count
      FROM session_summaries s
      WHERE DATE(s.created_at) >= '$START_DATE' AND DATE(s.created_at) <= '$END_DATE'
      ${PROJECT_FILTER:+AND s.project = '$PROJECT_FILTER'}
      ORDER BY s.created_at DESC
      LIMIT 30
    " 2>/dev/null | while IFS=$'\t' read -r date project request obs; do
      [[ -z "$date" ]] && continue
      echo "### $date - $project ($obs obs)"
      echo "$request"
      echo ""
    done

    echo "---"
    echo ""
    echo "Tip: Use --project NAME to filter by project. Use --format csv for CSV output."
    ;;

  csv)
    echo "date,project,request,observations"
    sqlite3 -separator ',' "$DB_PATH" "
      SELECT DATE(s.created_at),
             s.project,
             '\"' || REPLACE(SUBSTR(COALESCE(s.request, 'Untitled'), 1, 200), '\"', '\"\"') || '\"',
             (SELECT COUNT(*) FROM observations o WHERE o.memory_session_id = s.memory_session_id)
      FROM session_summaries s
      WHERE DATE(s.created_at) >= '$START_DATE' AND DATE(s.created_at) <= '$END_DATE'
      ${PROJECT_FILTER:+AND s.project = '$PROJECT_FILTER'}
      ORDER BY s.created_at DESC
    " 2>/dev/null
    ;;

  json)
    sqlite3 "$DB_PATH" "
      SELECT json_group_array(json_object(
        'date', DATE(s.created_at),
        'project', s.project,
        'request', SUBSTR(COALESCE(s.request, 'Untitled'), 1, 200),
        'observations', (SELECT COUNT(*) FROM observations o WHERE o.memory_session_id = s.memory_session_id)
      ))
      FROM (
        SELECT * FROM session_summaries
        WHERE DATE(created_at) >= '$START_DATE' AND DATE(created_at) <= '$END_DATE'
        ${PROJECT_FILTER:+AND project = '$PROJECT_FILTER'}
        ORDER BY created_at DESC
      ) s
    " 2>/dev/null
    ;;

  *)
    echo "ERROR: Unknown format '$FORMAT'. Use: markdown, csv, or json" >&2
    exit 1
    ;;
esac
