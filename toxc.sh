#!/usr/bin/env bash

# ==============================================================================
#
#          Run tox tests in specified conda environments
#
# ==============================================================================

# --- Strict Mode ---
# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error when substituting.
# Pipestatus is the last command to exit with a non-zero status.
set -euo pipefail

# --- Constants ---
readonly SCRIPT_VERSION="1.0.1"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_PIP_VERBOSITY="q"
readonly DEFAULT_TOX_VERBOSITY="0"
readonly PYTHON_ENV_PATTERN="^py([0-9])([0-9]+)$"
readonly MAX_PARALLEL_JOBS=8
readonly TEMP_DIR_PREFIX="conda_tox_$$"

# Color constants
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BRIGHT_YELLOW='\033[1;33m'
readonly C_BLUE='\033[0;34m'
readonly C_MAGENTA='\033[0;35m'
readonly C_CYAN='\033[0;36m'

# --- Global Variables ---
declare parallel_execution=false
declare recreate_tox_env=false
declare force_recreate_conda=false
declare dry_run=false
declare max_parallel_jobs="$MAX_PARALLEL_JOBS"
declare -a envs_to_test=()
declare -a tox_posargs=()
declare -a failed_envs=()
declare temp_dir=""

# --- Helper Functions ---

# Logging functions with consistent formatting
log() {
    local level="$1"
    local color="$2"
    local message="$3"
    # Use echo -e for better color support across different terminals
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${color}[${level}]${C_RESET} ${message}" >&2
}

log_pass() { log "PASS" "$C_GREEN" "$1"; }
log_fail() { log "FAIL" "$C_RED" "$1"; }
log_warn() { log "WARN" "$C_YELLOW" "$1"; }
log_info() { log "INFO" "$C_BLUE" "$1"; }
log_debug() { 
    if [[ "${DEBUG:-}" == "1" ]]; then
        log "DEBUG" "$C_MAGENTA" "$1"
    fi
}

# Enhanced error handling with context
die() {
    local exit_code="${2:-1}"
    log_fail "$1"
    cleanup_on_exit
    exit "$exit_code"
}

# Cleanup function for proper resource management
cleanup_on_exit() {
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        log_debug "Cleaning up temporary directory: $temp_dir"
        rm -rf "$temp_dir" || log_warn "Failed to clean up temp directory: $temp_dir" 2>/dev/null || true
    fi
}

# Signal handlers for graceful shutdown
setup_signal_handlers() {
    trap 'handle_interrupt' INT TERM
    trap 'cleanup_on_exit' EXIT
}

# Handle interrupts by killing background jobs
handle_interrupt() {
    # Immediately redirect all output to suppress tox noise
    exec >/dev/null 2>/dev/null
    
    # Kill all background jobs and their children immediately and silently
    local job_pids
    job_pids=$(jobs -p 2>/dev/null || true)
    
    if [[ -n "$job_pids" ]]; then
        # Kill background jobs and their children
        for pid in $job_pids; do
            # Kill the process group to catch all children
            pkill -KILL -P "$pid" 2>/dev/null || true
            kill -KILL "$pid" 2>/dev/null || true
        done
    fi
    
    # Also kill any tox processes that might still be running
    pkill -KILL -f "tox.*run.*-e" 2>/dev/null || true
    pkill -KILL -f "conda.*run.*tox" 2>/dev/null || true
    
    # Brief pause to let processes die completely
    sleep 0.5
    
    # Restore stderr and show simple message
    exec 2>/dev/tty
    log_info "User terminated / interrupted execution."
    
    cleanup_on_exit
    exit 130
}

# Show version information
show_version() {
    echo -e "${C_YELLOW}$SCRIPT_VERSION${C_RESET}"
    exit 0
}

# Improved usage function with better formatting
usage() {
    echo -e "${C_CYAN}USAGE:${C_RESET}"
    echo -e "    $SCRIPT_NAME [OPTIONS] [python_env...] [-- pytest_args...]"
    echo -e ""
    echo -e "${C_CYAN}DESCRIPTION:${C_RESET}"
    echo -e "    Run tox tests in specified conda environments with enhanced features and"
    echo -e "    parallel execution support."
    echo -e ""
    echo -e "${C_CYAN}OPTIONS:${C_RESET}"
    echo -e "    ${C_YELLOW}-p, --parallel${C_RESET}        Run tests in parallel for each environment."
    echo -e "    ${C_YELLOW}-j, --jobs N${C_RESET}          Maximum number of parallel jobs (default: $MAX_PARALLEL_JOBS)."
    echo -e "    ${C_YELLOW}-r, --recreate${C_RESET}        Force recreation of tox environments."
    echo -e "    ${C_YELLOW}-f, --force-conda${C_RESET}     Force recreation of conda environments."
    echo -e "    ${C_YELLOW}-n, --dry-run${C_RESET}         Show what would be done without executing."
    echo -e "    ${C_YELLOW}-V, --verbose${C_RESET}         Enable verbose output (sets DEBUG=1)."
    echo -e "    ${C_YELLOW}-v, --version${C_RESET}         Show version information and exit."
    echo -e "    ${C_YELLOW}-h, --help${C_RESET}            Display this help message and exit."
    echo -e ""
    echo -e "${C_CYAN}ARGUMENTS:${C_RESET}"
    echo -e "    ${C_YELLOW}python_env${C_RESET}    One or more conda environments to test."
    echo -e "                    If not provided, tests will be run for all environments"
    echo -e "                    discovered from tox.ini."
    echo -e "    ${C_YELLOW}pytest_args${C_RESET}   Arguments to pass to pytest. Must be specified after '--'."
    echo -e ""
    echo -e "${C_CYAN}ENVIRONMENT VARIABLES:${C_RESET}"
    echo -e "    ${C_YELLOW}CONDA_TOX_PIP_VERBOSITY${C_RESET}   Set pip verbosity level (v/q/qq/qqq). Default: $DEFAULT_PIP_VERBOSITY."
    echo -e "    ${C_YELLOW}CONDA_TOX_VERBOSITY${C_RESET}       Set tox verbosity level (-1 to 3). Default: $DEFAULT_TOX_VERBOSITY."
    echo -e "    ${C_YELLOW}DEBUG${C_RESET}                     Enable debug output (1 or 0)."
    echo -e ""
    echo -e "${C_CYAN}EXAMPLES:${C_RESET}"
    echo -e "    $SCRIPT_NAME py39 py310              # Test specific environments"
    echo -e "    $SCRIPT_NAME --parallel              # Test all environments in parallel"
    echo -e "    $SCRIPT_NAME py39 -- -v --tb=short   # Pass arguments to pytest"
    echo -e "    $SCRIPT_NAME --dry-run --verbose     # Preview actions with debug output"
    echo -e ""
    exit 0
}

# --- Validation Functions ---

validate_python_version() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        die "Invalid Python version format: '$version'. Expected format: X.Y (e.g., 3.9)"
    fi
    
    # Check if version is supported (Python 3.7+)
    local major minor
    IFS='.' read -r major minor <<< "$version"
    if (( major < 3 || (major == 3 && minor < 7) )); then
        die "Unsupported Python version: $version. Minimum supported version is 3.7"
    fi
}

validate_max_jobs() {
    local jobs="$1"
    if [[ ! "$jobs" =~ ^[0-9]+$ ]] || (( jobs < 1 || jobs > 32 )); then
        die "Invalid number of parallel jobs: '$jobs'. Must be between 1 and 32"
    fi
}

validate_environment_name() {
    local env="$1"
    if [[ ! "$env" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        die "Invalid environment name: '$env'. Must start with a letter and contain only letters, numbers, hyphens, and underscores"
    fi
}

# --- Prerequisite Checks ---

check_dependencies() {
    local missing_deps=()
    
    # Anaconda / Miniconda
    if ! command -v conda &>/dev/null; then
        die "Conda is not found. Please install Anaconda or Miniconda first."
    fi

    if [[ -z "${CONDA_DEFAULT_ENV:-}" ]] && ! conda info &>/dev/null; then
        die "Conda is not properly initialized. Run 'conda init' or source conda activation script."
    fi
    
    # tox
    if ! command -v tox &>/dev/null; then
        log_warn "tox is not found. Will install in conda environments as needed."
    fi

    # Other dependencies (none yet, future proofing)
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        die "Missing required dependencies: ${missing_deps[*]}. Please install them first."
    fi
}

check_tox_config() {
    if [[ ! -f "tox.ini" ]]; then
        die "tox.ini not found in current directory. Please run from project root or specify environments manually."
    fi
    
    # Validate tox.ini syntax
    if ! tox config &>/dev/null; then
        die "Invalid tox.ini configuration. Please check your tox.ini file."
    fi
}

# --- Environment Management ---

get_conda_base_path() {
    local conda_base
    conda_base="$(conda info --base)" || die "Failed to get conda base path"
    echo "$conda_base"
}

get_conda_environments() {
    local available_envs
    available_envs=$(conda info --envs 2>/dev/null | awk 'NF>1 && !/^#/ && $1!="*" {print $1}') \
        || die "Failed to list conda environments"
    echo "$available_envs"
}

infer_python_version() {
    local env="$1"
    local python_version
    
    if [[ "$env" =~ $PYTHON_ENV_PATTERN ]]; then
        python_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    else
        die "Cannot infer Python version from environment name: '$env'. Name must be in 'pyXY' or 'pyXYZ' format (e.g., py39, py310)."
    fi
    
    validate_python_version "$python_version"
    echo "$python_version"
}

create_conda_env() {
    local env="$1"
    local python_version
    
    validate_environment_name "$env"
    python_version=$(infer_python_version "$env")

    log_info "Conda environment '${C_YELLOW}$env${C_RESET}' does not exist. Creating it..."
    log_info "Using Python version ${C_YELLOW}$python_version${C_RESET} for new environment."
    
    if [[ "$dry_run" == "true" ]]; then
        log_info "${C_BRIGHT_YELLOW}[DRY RUN]${C_RESET} Would create: conda create -n '$env' python='$python_version' -y"
        return 0
    fi
    
    if conda create -n "$env" python="$python_version" -y --quiet; then
        log_info "Successfully created conda environment: $env"
    else
        die "Failed to create conda environment: $env"
    fi
}

remove_conda_env() {
    local env="$1"
    
    log_info "Removing existing conda environment: $env"
    
    if [[ "$dry_run" == "true" ]]; then
        log_info "${C_BRIGHT_YELLOW}[DRY RUN]${C_RESET} Would remove: conda env remove -n '$env' -y"
        return 0
    fi
    
    if conda env remove -n "$env" -y --quiet; then
        log_info "Successfully removed conda environment: $env"
    else
        log_fail "Failed to remove conda environment: $env"
        return 1
    fi
}

# --- Test Execution ---

get_verbosity_flags() {
    local pip_verbosity_flag tox_verbosity_flag
    
    case "${CONDA_TOX_PIP_VERBOSITY:-$DEFAULT_PIP_VERBOSITY}" in
        v) pip_verbosity_flag="--verbose" ;;
        q) pip_verbosity_flag="--quiet" ;;
        qq) pip_verbosity_flag="--quiet --quiet" ;;
        qqq) pip_verbosity_flag="--quiet --quiet --quiet" ;;
        *) log_warn "Invalid CONDA_TOX_PIP_VERBOSITY (valid: v, q, qq, qqq). Using default 'quiet'."
           pip_verbosity_flag="--quiet" ;;
    esac

    local tox_verbosity="${CONDA_TOX_VERBOSITY:-$DEFAULT_TOX_VERBOSITY}"
    if (( tox_verbosity < 0 )); then
        tox_verbosity_flag="-q"
    elif (( tox_verbosity > 0 )); then
        # Limit verbosity to avoid excessive output
        local limited_verbosity=$((tox_verbosity > 3 ? 3 : tox_verbosity))
        tox_verbosity_flag="-$(printf 'v'%.0s $(seq 1 "$limited_verbosity"))"
    else
        tox_verbosity_flag=""
    fi
    
    echo "$pip_verbosity_flag" "$tox_verbosity_flag"
}

ensure_tox_in_env() {
    local env="$1"
    local pip_verbosity_flag="$2"
    
    log_debug "Checking for tox in environment: $env"
    
    # More robust check for tox installation
    if ! conda run -n "$env" python -c "import tox" &>/dev/null; then
        log_info "Installing tox in environment: ${C_YELLOW}$env${C_RESET}"
        
        if [[ "$dry_run" == "true" ]]; then
            log_info "${C_BRIGHT_YELLOW}[DRY RUN]${C_RESET} Would install: conda run -n '$env' pip install $pip_verbosity_flag tox"
            return 0
        fi
        
        if ! conda run --no-capture-output -n "$env" pip install $pip_verbosity_flag tox; then
            die "Failed to install tox in environment: $env"
        fi
    else
        log_debug "tox already available in environment: $env"
    fi
}

run_test_in_env() {
    local env="$1"
    local recreate_flag="$2"
    shift 2
    local posargs=("$@")
    
    log_info "Starting tests in environment: ${C_YELLOW}$env${C_RESET}"
    
    # Get verbosity flags (validate even in dry-run mode)
    local verbosity_flags
    read -ra verbosity_flags <<< "$(get_verbosity_flags)"
    local pip_verbosity_flag="${verbosity_flags[0]}"
    local tox_verbosity_flag="${verbosity_flags[1]:-}"
    
    if [[ "$dry_run" == "true" ]]; then
        log_info "${C_BRIGHT_YELLOW}[DRY RUN]${C_RESET} Would run: tox -e '$env' $recreate_flag -- ${posargs[*]}"
        return 0
    fi
    
    # Use conda run instead of subshell activation for better reliability
    ensure_tox_in_env "$env" "$pip_verbosity_flag"
    
    log_info "Running tox for env: ${C_YELLOW}$env${C_RESET} with posargs: ${posargs[*]}"
    
    local tox_cmd=(conda run --no-capture-output -n "$env")
    
    # Set pip install arguments for tox to use quiet mode
    if [[ "$pip_verbosity_flag" == *"--quiet"* ]]; then
        # Set environment variables to make pip quiet
        tox_cmd+=(env)
        tox_cmd+=(PIP_QUIET=1)
        tox_cmd+=(PIP_DISABLE_PIP_VERSION_CHECK=1)
        tox_cmd+=(PIP_NO_WARN_SCRIPT_LOCATION=1)
        tox_cmd+=(TOX_QUIET_INTERRUPT=1)
    fi
    
    tox_cmd+=(tox run -e "$env")
    [[ -n "$recreate_flag" ]] && tox_cmd+=("$recreate_flag")
    [[ -n "$tox_verbosity_flag" ]] && tox_cmd+=("$tox_verbosity_flag")
    tox_cmd+=(-- "${posargs[@]}")
    
    log_debug "Executing command: ${tox_cmd[*]}"
    
    # Execute with stderr redirection in quiet modes to suppress interrupt noise
    if [[ "$pip_verbosity_flag" == *"--quiet"* ]]; then
        if "${tox_cmd[@]}" 2>/dev/null; then
            log_pass "Tests passed in environment: ${C_YELLOW}$env${C_RESET}"
            return 0
        else
            local exit_code=$?
            if (( exit_code == 130 )); then
                # Interrupted - don't log failure message
                return $exit_code
            fi
            log_fail "Tests failed in environment: ${C_YELLOW}$env${C_RESET}"
            return 1
        fi
    else
        if "${tox_cmd[@]}"; then
            log_pass "Tests passed in environment: ${C_YELLOW}$env${C_RESET}"
            return 0
        else
            local exit_code=$?
            if (( exit_code == 130 )); then
                # Interrupted - don't log failure message
                return $exit_code
            fi
            log_fail "Tests failed in environment: ${C_YELLOW}$env${C_RESET}"
            return 1
        fi
    fi
}

# --- Argument Parsing ---

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                usage
                ;;
            -v|--version)
                show_version
                ;;
            -p|--parallel)
                parallel_execution=true
                shift
                ;;
            -j|--jobs)
                [[ -z "${2:-}" ]] && die "Option $1 requires an argument"
                validate_max_jobs "$2"
                max_parallel_jobs="$2"
                shift 2
                ;;
            -r|--recreate)
                recreate_tox_env=true
                shift
                ;;
            -f|--force-conda)
                force_recreate_conda=true
                shift
                ;;
            -n|--dry-run)
                dry_run=true
                shift
                ;;
            -V|--verbose)
                export DEBUG=1
                shift
                ;;
            --)
                shift
                tox_posargs=("$@")
                break
                ;;
            -*)
                die "Unknown option: $1. Use --help for usage information."
                ;;
            *)
                validate_environment_name "$1"
                envs_to_test+=("$1")
                shift
                ;;
        esac
    done
}

# --- Environment Discovery ---

discover_envs_from_tox() {
    log_info "No specific python environment provided. Detecting environments from tox.ini."
    check_tox_config
    
    local all_tox_envs
    if ! all_tox_envs=($(tox list --quiet 2>/dev/null)); then
        die "Failed to list tox environments. Check your tox.ini configuration."
    fi

    # Filter for python environments only (those starting with 'py')
    local python_envs=()
    for env in "${all_tox_envs[@]}"; do
        if [[ "$env" == py* ]]; then
            python_envs+=("$env")
        fi
    done

    if (( ${#python_envs[@]} == 0 )); then
        die "No python environments (starting with 'py') found in tox.ini envlist."
    fi
    
    envs_to_test=("${python_envs[@]}")
    log_info "Discovered environments: ${C_YELLOW}${envs_to_test[*]}${C_RESET}"
}

# --- Environment Preparation ---

prepare_conda_envs() {
    log_info "Checking conda environments..."
    
    local available_envs missing_envs=()
    available_envs=$(get_conda_environments)
    
    for env in "${envs_to_test[@]}"; do
        if echo "$available_envs" | grep -qw "$env"; then
            if [[ "$force_recreate_conda" == "true" ]]; then
                log_info "Force recreating environment: $env"
                remove_conda_env "$env" || log_warn "Failed to remove $env, will try to create anyway"
                missing_envs+=("$env")
            else
                log_debug "Environment $env already exists"
            fi
        else
            missing_envs+=("$env")
        fi
    done

    if (( ${#missing_envs[@]} > 0 )); then
        log_info "Creating missing environments: ${C_YELLOW}${missing_envs[*]}${C_RESET}"
        for env in "${missing_envs[@]}"; do
            create_conda_env "$env"
        done
    fi
}

# --- Test Execution Orchestration ---

setup_temp_directory() {
    temp_dir=$(mktemp -d -t "${TEMP_DIR_PREFIX}.XXXXXX") || die "Failed to create temporary directory"
    log_debug "Created temporary directory: $temp_dir"
}

execute_tests() {
    local tox_recreate_arg=""
    if [[ "$recreate_tox_env" == "true" ]]; then
        tox_recreate_arg="--recreate"
    fi

    log_info "Configuration:"
    log_info "  Pip verbosity: ${C_YELLOW}${CONDA_TOX_PIP_VERBOSITY:-$DEFAULT_PIP_VERBOSITY}${C_RESET}"
    log_info "  Tox verbosity: ${C_YELLOW}${CONDA_TOX_VERBOSITY:-$DEFAULT_TOX_VERBOSITY}${C_RESET}"
    log_info "  Parallel execution: ${C_YELLOW}$parallel_execution${C_RESET}"
    if [[ "$parallel_execution" == "true" ]]; then
        log_info "  Max parallel jobs: ${C_YELLOW}$max_parallel_jobs${C_RESET}"
    fi
    log_info "  Dry run: ${C_YELLOW}$dry_run${C_RESET}"

    if [[ "$parallel_execution" == "true" ]]; then
        run_tests_parallel "$tox_recreate_arg"
    else
        run_tests_sequential "$tox_recreate_arg"
    fi
}

run_tests_parallel() {
    local recreate_arg="$1"
    local actual_jobs
    
    # Limit parallel jobs to number of environments
    actual_jobs=$((${#envs_to_test[@]} < max_parallel_jobs ? ${#envs_to_test[@]} : max_parallel_jobs))
    
    log_info "Running tests in parallel (max $actual_jobs jobs) for: ${C_YELLOW}${envs_to_test[*]}${C_RESET}"
    
    setup_temp_directory
    
    # Use a semaphore-like approach to limit concurrent jobs
    local job_slots=()
    for ((i=0; i<actual_jobs; i++)); do
        job_slots+=("$i")
    done
    
    for env in "${envs_to_test[@]}"; do
        # Wait for an available slot
        while (( ${#job_slots[@]} == 0 )); do
            # Check if any background jobs have completed
            if ! wait -n 2>/dev/null; then
                # wait -n failed, likely due to no background jobs
                break
            fi
            
            # Collect completed jobs and free up slots
            for ((i=0; i<actual_jobs; i++)); do
                if [[ ! " ${job_slots[*]} " =~ " $i " ]]; then
                    if ! jobs -r | grep -q "%$((i+1))" 2>/dev/null; then
                        job_slots+=("$i")
                    fi
                fi
            done
        done
        
        # Start job in background
        local slot="${job_slots[0]}"
        job_slots=("${job_slots[@]:1}")  # Remove first element
        
        (
            # Set up signal handling in subprocess to exit silently on interrupt
            trap 'exec >/dev/null 2>/dev/null; exit 130' INT TERM
            
            if run_test_in_env "$env" "$recreate_arg" "${tox_posargs[@]}"; then
                touch "$temp_dir/$env.success"
            else
                touch "$temp_dir/$env.failure"
            fi
        ) &
        
        log_debug "Started background job for environment: $env (PID: $!)"
    done
    
    # Wait for all jobs to complete, but allow interruption
    log_debug "Waiting for all background jobs to complete..."
    while jobs -r | grep -q "Running" 2>/dev/null; do
        if ! wait -n 2>/dev/null; then
            # No more jobs or interrupted
            break
        fi
    done
    
    # Collect results
    for env in "${envs_to_test[@]}"; do
        if [[ -f "$temp_dir/$env.failure" ]]; then
            failed_envs+=("$env")
        fi
    done
}

run_tests_sequential() {
    local recreate_arg="$1"
    
    log_info "Running tests sequentially for: ${C_YELLOW}${envs_to_test[*]}${C_RESET}"
    
    for env in "${envs_to_test[@]}"; do
        if ! run_test_in_env "$env" "$recreate_arg" "${tox_posargs[@]}"; then
            failed_envs+=("$env")
        fi
    done
}

# --- Main Function ---

main() {
    setup_signal_handlers
    
    # Parse command line arguments
    parse_args "$@"
    
    # Validate prerequisites
    check_dependencies
    
    # Auto-discover environments if none specified
    if (( ${#envs_to_test[@]} == 0 )); then
        discover_envs_from_tox
    fi
    
    # Show what will be tested
    log_info "Environments to test: ${C_YELLOW}${envs_to_test[*]}${C_RESET}"
    if (( ${#tox_posargs[@]} > 0 )); then
        log_info "Additional pytest arguments: ${C_YELLOW}${tox_posargs[*]}${C_RESET}"
    fi
    
    # Prepare conda environments
    prepare_conda_envs
    
    # Execute tests
    execute_tests
    
    # Report results
    log_info "All test runs completed."
    if (( ${#failed_envs[@]} > 0 )); then
        log_fail "Tests failed in the following environments: ${C_RED}${failed_envs[*]}${C_RESET}"
        exit 1
    else
        log_pass "All tests passed successfully!"
    fi
}

# --- Script Execution ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
