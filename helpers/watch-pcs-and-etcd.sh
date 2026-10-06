#!/usr/bin/env bash
# Continuously display the PCS status and the Etcd memberlist by switching between available nodes.
# Assumes you have passwordless sudo configured for the user running this script
# or are running as root.

trap 'echo "Interrupted. Exiting..."; exit 0' SIGINT

# Node discovery functions
get_nodes_from_inventory() {
	local inventory_file="inventory.ini"
	if [ ! -f "$inventory_file" ]; then
		return 1
	fi
	
	# Parse ansible inventory for nodes in cluster_nodes section
	awk '
	/^\[cluster_nodes\]$/ { in_section=1; next }
	/^\[/ { in_section=0 }
	in_section && /^core@[0-9]/ {
		# Extract core@IP from lines like: core@192.168.111.20 ansible_ssh_extra_args=...
		split($1, parts, " ")
		print parts[1]
	}
	in_section && /^[0-9]/ {
		# Handle lines like: 192.168.111.20 ansible_user=core
		split($1, ip, " ")
		print "core@" ip[1]
	}
	' "$inventory_file"
}

get_nodes_from_virsh() {
	set -x
	# Get VM IPs from virsh - dynamically discover running VMs
	local nodes=()
	
	# Get list of running VMs
	local vms
	if ! mapfile -t vms< <(virsh list --state-running --name 2>/dev/null); then
		return 1
	fi
	
	# For each running VM, try to get its IP
	for vm in "${vms[@]}"; do
		[ -n "$vm" ] || continue  # Skip empty lines
		
		local ip
		local vm_ip_found=false
		
		# First try domifaddr (works with default network DHCP)
		if ip=$(virsh domifaddr "$vm" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | head -1); then
			if [ -n "$ip" ]; then
				nodes+=("core@$ip")
				vm_ip_found=true
			fi
		fi
		
		# If domifaddr fails or no IP found yet, try ARP for custom bridge networks
		if [ "$vm_ip_found" = false ]; then
			# Get MAC addresses for the tnfbm bridge network, which dev-scripts usually creates
			if ! mac=$(virsh domiflist "$vm" 2>/dev/null | awk '/tnfbm/ {print $5}'); then
				# could not get interface
				break
			elif [ -z "$mac" ]; then
				# could not get MAC address
				break
			else
				# Look up IP via ARP table using MAC address
				if ip=$(arp -a | grep -i "$mac" | awk '{print $2}' | tr -d '()' | head -1); then
					if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
						# Validate that this IP is actually reachable and belongs to a CoreOS node
						if timeout 3 ssh -o ConnectTimeout=2 -o BatchMode=yes "core@$ip" -- echo "ping" >/dev/null 2>&1; then
							nodes+=("core@$ip")
						fi
					fi
				fi
			fi
		fi
	done
	
	if [ ${#nodes[@]} -gt 0 ]; then
		printf '%s\n' "${nodes[@]}"
	else
		return 1
	fi
}

discover_nodes() {
	# Try inventory file first, then virsh, then fallback to hostnames
	if get_nodes_from_inventory 2>/dev/null; then
		echo "# Using nodes from inventory.ini" >&2
	elif get_nodes_from_virsh 2>/dev/null; then
		echo "# Using nodes discovered via virsh" >&2
	else
		echo "! Could not discover nodes" >&2
		exit 1
	fi
}

# Initialize nodes array
echo "Discovering cluster nodes..."
mapfile -t NODES < <(discover_nodes)
echo "Found ${#NODES[@]} nodes: ${NODES[*]}"
working_node="${NODES[0]}"

get_other_node() {
	local current=$1
	for i in "${!NODES[@]}"; do
		if [ "${NODES[i]}" = "$current" ]; then
			local next_index=$(( (i + 1) % ${#NODES[@]} ))
			echo "${NODES[next_index]}"
			return 0
		fi
	done
	# Fallback if not found
	echo "${NODES[0]}"
}

test_etcdctl_command() {
	local node=$1
	local timeout=3
	
	# Test if etcdctl command works on this node
	timeout "$timeout" ssh -o ConnectTimeout=2 "$node" -- \
		sudo podman exec etcd etcdctl member list --command-timeout=1s >/dev/null 2>&1
	return $?
}

watch_cluster() {
	local retry_count=0
	local max_retries=6
	local max_failures=3
	
	while true; do
		echo "Getting Etcd member list from $working_node..."
		
		# We try to use the node where Etcdctl is able to respond
		if test_etcdctl_command "$working_node"; then
			echo "Starting watch on $working_node (press Ctrl+C to exit)..."
			
			# Cannot use `watch`, it won't be able to detect some command failures and it will
			# make us stuck instead than move to the other node.
			while true; do
				# Capture output first to minimize screen flashing
				local output_etcd
				local header_etcd
				local output_pcs
				local header_pcs
				local separator="========================================"

				header_etcd="Etcd member list from $working_node ($(date)):"
				header_pcs="Pacemaker status from $working_node ($(date)):"

				if ! output_pcs=$(ssh -o ConnectTimeout=3 "$working_node" -- sudo pcs status 2>/dev/null); then
					clear
					echo "$header_pcs: Command failed on $working_node, switching nodes..."
					break
				fi

				if ! output_etcd=$(ssh -o ConnectTimeout=3 "$working_node" -- \
					sudo podman exec etcd etcdctl member list "$@" --command-timeout=2s 2>/dev/null); then
					clear
					echo "$header_etcd: Command failed on $working_node, switching nodes..."
					break
				fi
				# Success - quickly clear and display
				clear

				echo -e "\n$header_pcs"
				echo "$separator"
				echo -e "$output_pcs\n"

				echo -e "\n$header_etcd"
				echo "$separator"
				echo "$output_etcd"

				sleep 5
			done
		else
			echo "Command test failed on $working_node, switching to other node..."
		fi
		
		# Switch to other node
		working_node=$(get_other_node "$working_node")
		retry_count=$((retry_count + 1))
		
		if [ $retry_count -ge $max_retries ]; then
			echo "All nodes failed after $max_retries attempts. Waiting 10 seconds before retrying..."
			sleep 10
			retry_count=0
		else
			sleep 1
		fi
	done
}

# Run the watch function
watch_cluster "$*"
