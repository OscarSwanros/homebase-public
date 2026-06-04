#!/bin/sh
# Claude Code status line -- robbyrussell-inspired, fully loaded
input=$(cat)

# --- Extract all fields from JSON ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // "?"')
model=$(echo "$input" | jq -r '.model.display_name // ""')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
vim_mode=$(echo "$input" | jq -r '.vim.mode // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // empty')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // empty')
rate_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
rate_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

dir=$(basename "$cwd")

# --- Git info (branch + staged/modified counts) ---
branch=""
staged=0
modified=0
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  staged=$(git -C "$cwd" --no-optional-locks diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
  modified=$(git -C "$cwd" --no-optional-locks diff --numstat 2>/dev/null | wc -l | tr -d ' ')
fi

# === LINE 1: directory, git branch, model, context bar, agent status ===
line1=""

# Directory (cyan, bold)
line1="${line1}$(printf '\033[1;36m%s\033[0m' "$dir")"

# Git branch (robbyrussell style)
if [ -n "$branch" ]; then
  line1="${line1} $(printf '\033[1;33mgit:(\033[1;31m%s\033[1;33m)\033[0m' "$branch")"
fi

# Git staged/modified counts
if [ "$staged" -gt 0 ] || [ "$modified" -gt 0 ]; then
  git_stats=""
  if [ "$staged" -gt 0 ]; then
    git_stats="${git_stats}$(printf '\033[1;32m+%s\033[0m' "$staged")"
  fi
  if [ "$modified" -gt 0 ]; then
    [ -n "$git_stats" ] && git_stats="${git_stats} "
    git_stats="${git_stats}$(printf '\033[1;33m~%s\033[0m' "$modified")"
  fi
  line1="${line1} ${git_stats}"
fi

# Model name (dimmed)
if [ -n "$model" ]; then
  line1="${line1} $(printf '\033[2;37m%s\033[0m' "$model")"
fi

# Visual context bar (replaces text-only ctx:N%)
if [ -n "$used" ]; then
  used_int=$(printf '%.0f' "$used")
  if [ "$used_int" -ge 80 ]; then
    bar_color='\033[1;31m'
  elif [ "$used_int" -ge 50 ]; then
    bar_color='\033[1;33m'
  else
    bar_color='\033[1;32m'
  fi
  filled=$((used_int / 10))
  empty=$((10 - filled))
  bar=""
  i=0; while [ "$i" -lt "$filled" ]; do bar="${bar}█"; i=$((i + 1)); done
  i=0; while [ "$i" -lt "$empty" ]; do bar="${bar}░"; i=$((i + 1)); done
  line1="${line1} $(printf "${bar_color}%s\033[0m \033[2;37m%s%%\033[0m" "$bar" "$used_int")"
fi

# Vim mode (only shown when active)
if [ -n "$vim_mode" ]; then
  if [ "$vim_mode" = "NORMAL" ]; then
    line1="${line1} $(printf '\033[1;34m[N]\033[0m')"
  elif [ "$vim_mode" = "INSERT" ]; then
    line1="${line1} $(printf '\033[1;32m[I]\033[0m')"
  fi
fi

# Agent status (from agent-signal.sh)
status_dir="$HOME/.claude/agent-status"
cwd_key=$(echo "$cwd" | tr '/' '-' | sed 's/^-//')
status_file="${status_dir}/${cwd_key}.json"

if [ -f "$status_file" ]; then
  phase=$(jq -r '.phase // empty' "$status_file" 2>/dev/null)
  task=$(jq -r '.task // empty' "$status_file" 2>/dev/null)

  if [ -n "$phase" ]; then
    case "$phase" in
      exploring)    phase_color='\033[1;36m' ;;
      planning)     phase_color='\033[1;34m' ;;
      implementing) phase_color='\033[1;35m' ;;
      testing)      phase_color='\033[1;33m' ;;
      done)         phase_color='\033[1;32m' ;;
      blocked)      phase_color='\033[1;31m' ;;
      *)            phase_color='\033[2;37m' ;;
    esac
    line1="${line1} $(printf "${phase_color}[%s]\033[0m" "$phase")"
    if [ -n "$task" ]; then
      line1="${line1} $(printf '\033[0;37m%s\033[0m' "$task")"
    fi
  fi
fi

printf '%s' "$line1"

# === LINE 2: cost, duration, lines changed, rate limits ===
line2=""

# Session cost
if [ -n "$cost" ]; then
  cost_fmt=$(printf '$%.2f' "$cost")
  line2="${line2}$(printf '\033[2;37m%s\033[0m' "$cost_fmt")"
fi

# Session duration
if [ -n "$duration_ms" ]; then
  duration_int=$(printf '%.0f' "$duration_ms")
  mins=$((duration_int / 60000))
  secs=$(((duration_int % 60000) / 1000))
  [ -n "$line2" ] && line2="${line2} "
  line2="${line2}$(printf '\033[2;37m%dm %ds\033[0m' "$mins" "$secs")"
fi

# Lines added/removed
if [ -n "$lines_added" ] || [ -n "$lines_removed" ]; then
  [ -n "$line2" ] && line2="${line2} "
  if [ -n "$lines_added" ] && [ "$lines_added" != "0" ]; then
    line2="${line2}$(printf '\033[1;32m+%s\033[0m' "$lines_added")"
  fi
  if [ -n "$lines_removed" ] && [ "$lines_removed" != "0" ]; then
    [ -n "$lines_added" ] && [ "$lines_added" != "0" ] && line2="${line2}"
    line2="${line2}$(printf '\033[1;31m-%s\033[0m' "$lines_removed")"
  fi
fi

# Rate limits (5h and 7d)
if [ -n "$rate_5h" ] || [ -n "$rate_7d" ]; then
  [ -n "$line2" ] && line2="${line2} $(printf '\033[2;37m|\033[0m') "
  if [ -n "$rate_5h" ]; then
    rate_5h_int=$(printf '%.0f' "$rate_5h")
    if [ "$rate_5h_int" -ge 80 ]; then
      rl_color='\033[1;31m'
    elif [ "$rate_5h_int" -ge 50 ]; then
      rl_color='\033[1;33m'
    else
      rl_color='\033[2;37m'
    fi
    line2="${line2}$(printf "${rl_color}5h:%s%%\033[0m" "$rate_5h_int")"
  fi
  if [ -n "$rate_7d" ]; then
    rate_7d_int=$(printf '%.0f' "$rate_7d")
    if [ "$rate_7d_int" -ge 80 ]; then
      rl_color='\033[1;31m'
    elif [ "$rate_7d_int" -ge 50 ]; then
      rl_color='\033[1;33m'
    else
      rl_color='\033[2;37m'
    fi
    [ -n "$rate_5h" ] && line2="${line2} "
    line2="${line2}$(printf "${rl_color}7d:%s%%\033[0m" "$rate_7d_int")"
  fi
fi

# Only print line 2 if it has content
if [ -n "$line2" ]; then
  printf '\n%s' "$line2"
fi
