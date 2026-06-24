#!/bin/bash
# Interactive demo framework for guided step-by-step presentations.
#
# Source this file in your demo script. Each step shows a description,
# GUI/CLI options, and lets the presenter choose:
#   [a] Auto-run the CLI command
#   [m] Manual — I'll do it in the GUI, script waits and validates
#   [s] Skip this step
#
# DEMO_MODE=auto    — run all steps without prompting (batch/CI)
# DEMO_MODE=guided  — interactive per-step (default in a terminal)
#
# Usage:
#   source scripts/demo-lib.sh
#   demo_section "Section C: Lifecycle"
#   demo_step "Create lifecycle environments" \
#     --gui "Content → Lifecycle Environments → Create" \
#     --cmd-satellite 'hammer lifecycle-environment create --name Dev ...' \
#     --validate-satellite 'hammer lifecycle-environment list | grep -q Dev'

# --- Colors ---
if [[ -t 1 ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_CYAN='\033[1;36m'
  C_YELLOW='\033[0;33m'
  C_GREEN='\033[0;32m'
  C_RED='\033[0;31m'
  C_DIM='\033[2m'
  C_WHITE='\033[1;37m'
else
  C_RESET='' C_BOLD='' C_CYAN='' C_YELLOW='' C_GREEN='' C_RED='' C_DIM='' C_WHITE=''
fi

# --- Mode ---
: "${DEMO_MODE:=guided}"
if [[ ! -t 0 ]]; then
  DEMO_MODE=auto
fi

_STEP_NUM=0

# Print a section header
demo_section() {
  local title="$1"
  local width=60
  echo ""
  printf "${C_CYAN}"
  printf '%.0s━' $(seq 1 $width)
  echo ""
  echo "  ${title}"
  printf '%.0s━' $(seq 1 $width)
  printf "${C_RESET}\n"
  echo ""
  _STEP_NUM=0
}

# Print informational text (no action, no prompt)
demo_info() {
  printf "${C_DIM}  %s${C_RESET}\n" "$1"
}

# Run a command silently — no prompt, no choice. For setup/plumbing.
demo_exec() {
  eval "$1"
}

# Run a command on satellite silently
demo_exec_satellite() {
  run_on_vm satellite "sudo bash -c '$1'" 2>/dev/null
}

# Core interactive step function.
# Arguments:
#   $1             — step description (required)
#   --gui "..."    — GUI path to show the presenter
#   --cmd "..."    — local shell command to run
#   --cmd-satellite "..." — command to run on satellite via run_on_vm
#   --cmd-vm NAME "..."   — command to run on a specific VM
#   --validate "..."      — local validation command (exit 0 = pass)
#   --validate-satellite "..." — validation run on satellite
demo_step() {
  local description="$1"
  shift

  local gui_text="" cmd="" cmd_sat="" cmd_vm_name="" cmd_vm="" validate="" validate_sat=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gui) gui_text="$2"; shift 2 ;;
      --cmd) cmd="$2"; shift 2 ;;
      --cmd-satellite) cmd_sat="$2"; shift 2 ;;
      --cmd-vm)  cmd_vm_name="$2"; cmd_vm="$3"; shift 3 ;;
      --validate) validate="$2"; shift 2 ;;
      --validate-satellite) validate_sat="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  (( _STEP_NUM++ ))

  # --- Display ---
  echo ""
  printf "${C_CYAN}${C_BOLD}  Step %d: %s${C_RESET}\n" "$_STEP_NUM" "$description"
  echo ""

  if [[ -n "$gui_text" ]]; then
    printf "${C_YELLOW}  GUI: %s${C_RESET}\n" "$gui_text"
  fi

  local display_cmd=""
  if [[ -n "$cmd_sat" ]]; then
    display_cmd="$cmd_sat"
  elif [[ -n "$cmd_vm" ]]; then
    display_cmd="[${cmd_vm_name}] ${cmd_vm}"
  elif [[ -n "$cmd" ]]; then
    display_cmd="$cmd"
  fi

  if [[ -n "$display_cmd" ]]; then
    echo ""
    printf "${C_GREEN}  CLI: "
    echo "$display_cmd" | head -5 | while IFS= read -r line; do
      printf "${C_GREEN}  %s${C_RESET}\n" "$line"
    done
    local total_lines
    total_lines=$(echo "$display_cmd" | wc -l)
    if [[ $total_lines -gt 5 ]]; then
      printf "${C_DIM}  ... (%d more lines)${C_RESET}\n" $((total_lines - 5))
    fi
  fi
  echo ""

  # --- Choice ---
  local choice="a"
  if [[ "$DEMO_MODE" == "guided" ]]; then
    local has_cmd=false
    [[ -n "$cmd" || -n "$cmd_sat" || -n "$cmd_vm" ]] && has_cmd=true

    if $has_cmd; then
      printf "${C_WHITE}  [a] Auto-run (CLI)  [m] I'll do it (GUI)  [s] Skip${C_RESET}\n"
      printf "  > "
      read -r -n1 choice < /dev/tty
      echo ""
    else
      printf "${C_WHITE}  [enter] Continue  [s] Skip${C_RESET}\n"
      printf "  > "
      read -r -n1 choice < /dev/tty
      echo ""
      [[ "$choice" != "s" ]] && choice="m"
    fi
  fi

  # --- Execute ---
  case "$choice" in
    s|S)
      printf "${C_DIM}  (skipped)${C_RESET}\n"
      return 0
      ;;
    m|M)
      printf "${C_YELLOW}  Do it manually, then press ENTER when done...${C_RESET}"
      read -r < /dev/tty
      ;;
    *)
      if [[ -n "$cmd_sat" ]]; then
        run_on_vm satellite "sudo bash -c '${cmd_sat}'" 2>/dev/null || true
      elif [[ -n "$cmd_vm" ]]; then
        run_on_vm_sudo "${cmd_vm_name}" "${cmd_vm}" || true
      elif [[ -n "$cmd" ]]; then
        eval "$cmd" || true
      fi
      ;;
  esac

  # --- Validate ---
  local val_cmd=""
  if [[ -n "$validate_sat" ]]; then
    val_cmd="run_on_vm satellite \"sudo bash -c '${validate_sat}'\" 2>/dev/null"
  elif [[ -n "$validate" ]]; then
    val_cmd="$validate"
  fi

  if [[ -n "$val_cmd" ]]; then
    if eval "$val_cmd" > /dev/null 2>&1; then
      printf "${C_GREEN}  ✓ Validated${C_RESET}\n"
    else
      printf "${C_RED}  ✗ Validation failed${C_RESET}\n"
      if [[ "$DEMO_MODE" == "guided" ]]; then
        printf "${C_YELLOW}  [r] Retry validation  [c] Continue anyway${C_RESET}\n"
        printf "  > "
        read -r -n1 retry_choice < /dev/tty
        echo ""
        if [[ "$retry_choice" == "r" ]]; then
          if eval "$val_cmd" > /dev/null 2>&1; then
            printf "${C_GREEN}  ✓ Validated${C_RESET}\n"
          else
            printf "${C_RED}  ✗ Still failing — continuing${C_RESET}\n"
          fi
        fi
      fi
    fi
  fi
}
