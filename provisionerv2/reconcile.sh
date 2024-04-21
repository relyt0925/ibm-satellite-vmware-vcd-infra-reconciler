#!/usr/bin/env bash
# ASSUMES LOGGED INTO APPROPRIATE IBM CLOUD ACCOUNT: TO DO THAT AUTOMATICALLY
# ibmcloud login -a https://cloud.ibm.com --apikey XXXX -r us-south
set +x
source config.env
set -x
core_machinegroup_reconcile() {
	export INSTANCE_DATA=/tmp/instancedata.txt
	rm -f "$INSTANCE_DATA"
	touch "$INSTANCE_DATA"
	if ! pwsh -f get_infra.ps1; then
		return
	fi
	if ! grep "success" "$INSTANCE_DATA"; then
		return
	fi
	VAPP_FILTER_PREFIX_1=$(echo "$HOST_LABELS" | awk -F '=' '{print $2}')
	VAPP_FILTER_PREFIX="${VAPP_FILTER_PREFIX_1}-${ZONE}"
	TOTAL_INSTANCES=$(grep "$VAPP_FILTER_PREFIX" "$INSTANCE_DATA" | wc -l)
	if ((COUNT > TOTAL_INSTANCES)); then
		NUMBER_TO_SCALE=$((COUNT - TOTAL_INSTANCES))
		if [[ -n "$HOST_LINK_AGENT_ENDPOINT" ]]; then
			IGN_FILE_PATH=$(bx sat host attach --location "$LOCATION_ID" --operating-system "RHCOS" --host-label "$HOST_LABELS" --host-label "zone=$ZONE" --host-link-agent-endpoint "$HOST_LINK_AGENT_ENDPOINT" | grep "register-host")
		else
			IGN_FILE_PATH=$(bx sat host attach --location "$LOCATION_ID" --operating-system "RHCOS" --host-label "$HOST_LABELS" --host-label "zone=$ZONE" | grep "register-host")
		fi
		if [[ "$IGN_FILE_PATH" != *".ign" ]]; then
			continue
		fi
		for i in $(seq 1 $NUMBER_TO_SCALE); do
			export VAPP_NAME="${VAPP_FILTER_PREFIX}-$(date +%s)"
			export VAPP_NAME_64=$(gprintf $VAPP_NAME | base64 -w 0)
			export IGN_FILE_PATH_WITH_HOSTNAME_64=/tmp/ignitionwithhostname.b64
			jq --arg injecthost "$VAPP_NAME_64" '.storage.files = [{"path": "/etc/hostname", "mode": 420, "contents": { "source": ("data:text/plain;charset=utf-8;base64," + $injecthost) }}] + .storage.files' "$IGN_FILE_PATH" | base64 -w 0 >"$IGN_FILE_PATH_WITH_HOSTNAME_64"
			if ! pwsh -f create_machine.ps1; then
				continue
			fi
		done
	fi
}

reconcile_cp_nodes() {
	export CPU=8
	export MEM_MB=32768
	export DISK_1_SIZE=100G
	unset DISK_2_SIZE
	unset DISK_3_SIZE
	unset DISK_4_SIZE
	unset DISK_5_SIZE
	export CP_WORKER_ZONE_FILE=/tmp/cp-worker-zones.txt
	jq -r '.workerZones[]' "$LOCATION_DATA_FILE" >"$CP_WORKER_ZONE_FILE"
	ROKS_CLUSTER_COUNT=$(grep "Red Hat OpenShift" "$SERVICES_DATA_FILE" | wc -l)
	export COUNT=0
	if ((ROKS_CLUSTER_COUNT <= 1)); then
		COUNT=2
	elif ((ROKS_CLUSTER_COUNT <= 6)); then
		COUNT=4
	elif ((ROKS_CLUSTER_COUNT <= 12)); then
		COUNT=8
	else
		COUNT=16
	fi
	while read -r zoneraw; do
		export ZONE="$zoneraw"
		export HOST_LABELS="worker-pool=${LOCATION_ID}-cp"
		core_machinegroup_reconcile
		while true; do
			if ! bx sat host assign --location "$LOCATION_ID" --zone "$ZONE" --host-label os=RHCOS --host-label zone="$ZONE" --host-label "$HOST_LABELS"; then
				break
			fi
			sleep 5
			continue
		done
	done <"$CP_WORKER_ZONE_FILE"
}

reconcile_cluster_wp_nodes() {
	export ROKS_CLUSTER_LIST_FILE=/tmp/roks-cluster-list
	grep "Red Hat OpenShift" "$SERVICES_DATA_FILE" >"$ROKS_CLUSTER_LIST_FILE"
	while read -r line; do
		CLUSTER_ID="$(echo $line | awk '{print $2}')"
		export CLUSTER_WORKER_POOL_INFO_FILE=/tmp/roks-cluster-workerpools.json
		bx cs worker-pools --cluster "$CLUSTER_ID" --output json >"$CLUSTER_WORKER_POOL_INFO_FILE"
		for row in $(cat "$CLUSTER_WORKER_POOL_INFO_FILE" | jq -r '.[] | @base64'); do
			_jq() {
				# shellcheck disable=SC2086
				echo "${row}" | base64 --decode | jq -r ${1}
			}
			export COUNT=$(_jq '.workerCount')
			export CPU=$(_jq '.labels["ibm-cloud.kubernetes.io/reconciler-cpu"]')
			export MEM_MB=$(_jq '.labels["ibm-cloud.kubernetes.io/reconciler-memmb"]')
			export DISK_1_SIZE=$(_jq '.labels["ibm-cloud.kubernetes.io/reconciler-disk1-size"]')
			export DISK_2_SIZE=$(_jq '.labels["ibm-cloud.kubernetes.io/reconciler-disk2-size"]')
			export DISK_3_SIZE=$(_jq '.labels["ibm-cloud.kubernetes.io/reconciler-disk3-size"]')
			export DISK_4_SIZE=$(_jq '.labels["ibm-cloud.kubernetes.io/reconciler-disk4-size"]')
			export DISK_5_SIZE=$(_jq '.labels["ibm-cloud.kubernetes.io/reconciler-disk5-size"]')
			if [[ "$CPU" == "null" ]] || [[ "$CPU" == "" ]]; then
				echo "bad cpu value"
				continue
			fi
			if [[ "$MEM_MB" == "null" ]] || [[ "$MEM_MB" == "" ]]; then
				echo "bad mem value"
				continue
			fi
			if [[ "$DISK_1_SIZE" == "null" ]] || [[ "$DISK_1_SIZE" == "" ]]; then
				echo "bad disk value"
				continue
			fi
			if [[ "$DISK_2_SIZE" == "null" ]] || [[ "$DISK_2_SIZE" == "" ]]; then
				unset DISK_2_SIZE
			fi
			if [[ "$DISK_3_SIZE" == "null" ]] || [[ "$DISK_3_SIZE" == "" ]]; then
				unset DISK_3_SIZE
			fi
			if [[ "$DISK_4_SIZE" == "null" ]] || [[ "$DISK_4_SIZE" == "" ]]; then
				unset DISK_4_SIZE
			fi
			if [[ "$DISK_5_SIZE" == "null" ]] || [[ "$DISK_5_SIZE" == "" ]]; then
				unset DISK_5_SIZE
			fi
			HOST_LABEL_VALUE=$(_jq '.hostLabels["worker-pool"]')
			OPERATING_SYS=$(_jq '.operatingSystem')
			if [[ "$OPERATING_SYS" != "RHCOS" ]]; then
			  echo "bad operating system"
			  continue
			fi
			if [[ "$HOST_LABEL_VALUE" == "null" ]] || [[ "$HOST_LABEL_VALUE" == "" ]]; then
			  echo "bad host label"
			  continue
			fi
			export HOST_LABELS="worker-pool=${HOST_LABEL_VALUE}"
			zones_in_pool=$(_jq '.zones[]')
			zones_in_pool_file=/tmp/zones-in-pool
			echo "$zones_in_pool" >"$zones_in_pool_file"
			for zonerawinfo in $(cat "$zones_in_pool_file" | jq -r '. | @base64'); do
			  _jq_zonerawinfo() {
          # shellcheck disable=SC2086
          echo "${zonerawinfo}" | base64 --decode | jq -r ${1}
        }
				export ZONE=$(_jq_zonerawinfo '.id')
				core_machinegroup_reconcile
				while true; do
					if ! bx sat host assign --location "$LOCATION_ID" --cluster "$CLUSTER_ID" --host-label os=RHCOS --host-label "$HOST_LABELS"; then
						break
					fi
					sleep 5
					continue
				done
			done <"$zones_in_pool_file"
		done
	done<"$ROKS_CLUSTER_LIST_FILE"
}

remove_dead_machines() {
	for row in $(cat "$HOSTS_DATA_FILE" | jq -r '.[] | @base64'); do
		_jq() {
			# shellcheck disable=SC2086
			echo "${row}" | base64 --decode | jq -r ${1}
		}
		HEALTH_STATE=$(_jq '.health.status')
		NAME=$(_jq '.name')
		if [[ "$HEALTH_STATE" == "reload-required" ]]; then
			export VAPP_NAME="$NAME"
			if ! pwsh -f delete_infra.ps1; then
				continue
			fi
			ibmcloud sat host rm --location "$LOCATION_ID" --host "$NAME" -f
		fi
	done
}

while true; do
	sleep 10
	echo "reconcile workload"
	export LOCATION_DATA_FILE=/tmp/location-data.json
	export HOSTS_DATA_FILE=/tmp/${LOCATION_ID}-hosts-data.txt
	export SERVICES_DATA_FILE=/tmp/${LOCATION_ID}-services-data.txt
	if ! bx sat location get --location $LOCATION_ID --output json >$LOCATION_DATA_FILE; then
		continue
	fi
	if ! bx sat hosts --location $LOCATION_ID --output json >$HOSTS_DATA_FILE; then
		continue
	fi
	if ! bx sat services --location $LOCATION_ID >$SERVICES_DATA_FILE; then
		continue
	fi
	remove_dead_machines
	reconcile_cp_nodes
	reconcile_cluster_wp_nodes
done
