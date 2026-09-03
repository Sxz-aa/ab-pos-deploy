#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly network="${1:-${NETWORK:-testnet}}"
readonly share_dir="${root_dir}/abpos/${network}/share"
readonly devp2p_bin="${DEVP2P_BIN:-devp2p}"
readonly timeout_seconds="${BOOTNODE_TIMEOUT_SECONDS:-10}"
readonly -a network_timeout=(timeout --foreground --kill-after=2s "${timeout_seconds}s")

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

failure_count=0
failure_messages=()

function node_failure() {
    failure_messages+=("$*")
    failure_count=$((failure_count + 1))
}

function clean_output() {
    sed -e 's/\r$//' -e '/^[[:space:]]*$/d'
}

function last_output_line() {
    clean_output | tail -n 1
}

function read_data_lines() {
    sed -e 's/\r$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "$1"
}

[[ "${network}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "Invalid network name: ${network}"
[[ -d "${share_dir}" ]] || fail "Network share directory not found: ${share_dir}"
[[ -x "${devp2p_bin}" ]] || fail "devp2p is not executable: ${devp2p_bin}"
command -v timeout >/dev/null 2>&1 || fail "timeout is required"
[[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || fail "BOOTNODE_TIMEOUT_SECONDS must be a positive integer"

readonly consensus_file="${share_dir}/bootstrap_nodes.txt"
readonly execution_file="${share_dir}/bootstrap_nodes_execution.txt"
[[ -s "${consensus_file}" ]] || fail "Consensus bootstrap node list is empty: ${consensus_file}"
[[ -s "${execution_file}" ]] || fail "Execution bootstrap node list is empty: ${execution_file}"

mapfile -t consensus_nodes < <(read_data_lines "${consensus_file}")
mapfile -t execution_nodes < <(read_data_lines "${execution_file}")
(( ${#consensus_nodes[@]} > 0 )) || fail "Consensus bootstrap node list has no data lines"
(( ${#execution_nodes[@]} > 0 )) || fail "Execution bootstrap node list has no data lines"

consensus_ips=()
consensus_udp_results=()
consensus_tcp_results=()
execution_endpoints=()
execution_hosts=()
execution_udp_results=()
execution_tcp_results=()

printf 'Verifying %d consensus bootstrap node(s).\n' "${#consensus_nodes[@]}"
for index in "${!consensus_nodes[@]}"; do
    enr="${consensus_nodes[index]}"
    label="consensus bootstrap node $((index + 1))"
    consensus_ips[index]="unknown"
    consensus_udp_results[index]="- ❌"
    consensus_tcp_results[index]="- ❌"

    printf '  Checking consensus node %d/%d.\n' "$((index + 1))" "${#consensus_nodes[@]}"
    if ! dump_output="$("${devp2p_bin}" enrdump "${enr}" 2>&1)"; then
        node_failure "Unable to decode ${label}: ${dump_output:-no error details}"
        continue
    fi
    if grep -q 'INVALID:' <<<"${dump_output}"; then
        node_failure "Invalid signed ENR for ${label}: $(grep 'INVALID:' <<<"${dump_output}" | head -n 1)"
        continue
    fi
    enr_ip="$(awk '$1 == "\"ip\"" { print $2; exit }' <<<"${dump_output}")"
    enr_udp_port="$(awk '$1 == "\"udp\"" { print $2; exit }' <<<"${dump_output}")"
    enr_tcp_port="$(awk '$1 == "\"tcp\"" { print $2; exit }' <<<"${dump_output}")"
    consensus_ips[index]="${enr_ip:-unknown}"
    consensus_udp_results[index]="${enr_udp_port:--} ❌"
    consensus_tcp_results[index]="${enr_tcp_port:--} ❌"
    if [[ -z "${enr_ip}" ]]; then
        node_failure "${label} must advertise an IPv4 address"
        continue
    fi

    if [[ -z "${enr_udp_port}" ]]; then
        node_failure "${label} (${enr_ip}) must advertise a UDP port"
    else
        udp_endpoint="${enr_ip}:${enr_udp_port}/UDP"
        if ! ping_output="$("${network_timeout[@]}" "${devp2p_bin}" discv5 ping "${enr}" 2>&1)"; then
            node_failure "Discovery v5 ping failed for ${label} (${udp_endpoint}): $(last_output_line <<<"${ping_output}")"
        else
            ping_result="$(last_output_line <<<"${ping_output}")"
            if [[ "${ping_result}" == "RPC timeout" ]]; then
                node_failure "Discovery v5 ping timed out for ${label} (${udp_endpoint}). Check the advertised UDP port and its firewall or cloud security rules."
            elif [[ "${ping_result}" != "<nil>" ]]; then
                node_failure "Discovery v5 ping failed for ${label} (${udp_endpoint}): ${ping_result:-no response}"
            else
                consensus_udp_results[index]="${enr_udp_port} ✅"
                if ! resolved_enr="$("${network_timeout[@]}" "${devp2p_bin}" discv5 resolve "${enr}" 2>&1)"; then
                    node_failure "Unable to resolve ${label} (${udp_endpoint}): $(last_output_line <<<"${resolved_enr}")"
                else
                    resolved_enr="$(last_output_line <<<"${resolved_enr}")"
                    if [[ ! "${resolved_enr}" =~ ^enr:[A-Za-z0-9_-]+$ ]]; then
                        node_failure "Discovery v5 returned an invalid ENR for ${label}: ${resolved_enr:-empty}"
                    elif [[ "${resolved_enr}" != "${enr}" ]]; then
                        node_failure "${label} published a newer ENR. Replace the list entry with: ${resolved_enr}"
                    fi
                fi
            fi
        fi
    fi

    if [[ -z "${enr_tcp_port}" ]]; then
        node_failure "${label} (${enr_ip}) must advertise a TCP port"
    elif "${network_timeout[@]}" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "${enr_ip}" "${enr_tcp_port}" 2>/dev/null; then
        consensus_tcp_results[index]="${enr_tcp_port} ✅"
    else
        node_failure "TCP connection failed for ${label} (${enr_ip}:${enr_tcp_port}/TCP)"
    fi
done

printf 'Verifying %d execution bootstrap node(s).\n' "${#execution_nodes[@]}"
for index in "${!execution_nodes[@]}"; do
    enode="${execution_nodes[index]}"
    label="execution bootstrap node $((index + 1))"
    endpoint="${enode##*@}"
    execution_endpoints[index]="${endpoint}"
    execution_host="${endpoint%:*}"
    execution_port="${endpoint##*:}"
    execution_hosts[index]="${execution_host}"
    execution_udp_results[index]="${execution_port} ❌"
    execution_tcp_results[index]="${execution_port} ❌"

    printf '  Checking execution node %d/%d.\n' "$((index + 1))" "${#execution_nodes[@]}"
    if ! discv4_output="$("${network_timeout[@]}" "${devp2p_bin}" discv4 ping "${enode}" 2>&1)"; then
        node_failure "Discovery v4 ping failed for ${label} (${execution_host}:${execution_port}/UDP): $(last_output_line <<<"${discv4_output}")"
    else
        execution_udp_results[index]="${execution_port} ✅"
    fi
    if ! rlpx_output="$("${network_timeout[@]}" "${devp2p_bin}" rlpx ping "${enode}" 2>&1)"; then
        node_failure "RLPx handshake failed for ${label} (${endpoint}/TCP): $(last_output_line <<<"${rlpx_output}")"
        continue
    fi
    execution_tcp_results[index]="${execution_port} ✅"
done

declare -A execution_udp_by_host=()
declare -A execution_tcp_by_host=()
for index in "${!execution_nodes[@]}"; do
    execution_host="${execution_hosts[index]}"
    if [[ -n "${execution_udp_by_host[${execution_host}]:-}" ]]; then
        execution_udp_by_host[${execution_host}]+=", ${execution_udp_results[index]}"
        execution_tcp_by_host[${execution_host}]+=", ${execution_tcp_results[index]}"
    else
        execution_udp_by_host[${execution_host}]="${execution_udp_results[index]}"
        execution_tcp_by_host[${execution_host}]="${execution_tcp_results[index]}"
    fi
done

declare -A displayed_execution_hosts=()
printf '\nBootstrap nodes:\n'
printf '%-18s %-16s %-16s %-16s %-22s\n' \
    "IP" "Consensus UDP" "Consensus TCP" "Execution UDP" "Execution TCP"
for index in "${!consensus_nodes[@]}"; do
    consensus_ip="${consensus_ips[index]}"
    execution_udp_result="${execution_udp_by_host[${consensus_ip}]:--}"
    execution_tcp_result="${execution_tcp_by_host[${consensus_ip}]:--}"
    printf '%-18s %-16s %-16s %-16s %-22s\n' \
        "${consensus_ip}" \
        "${consensus_udp_results[index]}" \
        "${consensus_tcp_results[index]}" \
        "${execution_udp_result}" \
        "${execution_tcp_result}"
    displayed_execution_hosts[${consensus_ip}]=1
done

for index in "${!execution_nodes[@]}"; do
    execution_host="${execution_hosts[index]}"
    [[ -z "${displayed_execution_hosts[${execution_host}]:-}" ]] || continue
    printf '%-18s %-16s %-16s %-16s %-22s\n' \
        "${execution_host}" "-" "-" \
        "${execution_udp_by_host[${execution_host}]}" \
        "${execution_tcp_by_host[${execution_host}]}"
    displayed_execution_hosts[${execution_host}]=1
done

if (( failure_count > 0 )); then
    printf '\nFailures:\n'
    for failure_message in "${failure_messages[@]}"; do
        printf '  - %s\n' "${failure_message}"
    done
    printf '\nERROR: %d bootstrap node check(s) failed for %s.\n' \
        "${failure_count}" "${network}"
    exit 1
fi
printf 'Verified all %s bootstrap nodes.\n' "${network}"
