#!/usr/bin/env bash
# ASSUMES LOGGED INTO APPROPRIATE IBM CLOUD ACCOUNT: TO DO THAT AUTOMATICALLY
# ibmcloud login -a https://cloud.ibm.com --apikey XXXX -r us-south
set +x
source config.env
set -x
export LOCATION_ID=vmware-demo-1
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
	VAPP_FILTER_PREFIX=$(echo "$HOST_LABELS" | awk -F '=' '{print $2}')
	TOTAL_INSTANCES=$(grep "$VAPP_FILTER_PREFIX" "$INSTANCE_DATA" | wc -l)
	if ((COUNT > TOTAL_INSTANCES)); then
		NUMBER_TO_SCALE=$((COUNT - TOTAL_INSTANCES))
		if [[ -n "$HOST_LINK_AGENT_ENDPOINT" ]]; then
			IGN_FILE_PATH=$(bx sat host attach --location "$LOCATION_ID" --operating-system "RHCOS" --host-label "$HOST_LABELS" --host-link-agent-endpoint "$HOST_LINK_AGENT_ENDPOINT" | grep "register-host")
		else
			IGN_FILE_PATH=$(bx sat host attach --location "$LOCATION_ID" --operating-system "RHCOS" --host-label "$HOST_LABELS" | grep "register-host")
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
	export LOCATION_LIST_FILE=/tmp/location-lists.txt
	export HOSTS_DATA_FILE=/tmp/${LOCATION_ID}-hosts-data.txt
	export SERVICES_DATA_FILE=/tmp/${LOCATION_ID}-services-data.txt
	if ! bx sat locations >$LOCATION_LIST_FILE; then
		continue
	fi
	if ! grep "$LOCATION_ID" /tmp/location-lists.txt; then
		bx sat location create --name "$LOCATION_ID" --coreos-enabled --managed-from wdc
	fi
	if ! bx sat hosts --location $LOCATION_ID --output json >$HOSTS_DATA_FILE; then
		continue
	fi
	if ! bx sat services --location $LOCATION_ID >$SERVICES_DATA_FILE; then
		continue
	fi
	remove_dead_machines
	for FILE in worker-pool-metadata/*/*; do
		CLUSTERID=$(echo ${FILE} | awk -F '/' '{print $(NF-1)}')
		if [[ "$FILE" == *"control-plane"* ]]; then
			source $FILE
			core_machinegroup_reconcile
			# ensure machines assigned
			while true; do
				if ! bx sat host assign --location "$LOCATION_ID" --zone "$ZONE" --host-label os=RHCOS --host-label "$HOST_LABELS"; then
					break
				fi
				sleep 5
				continue
			done
		else
			CLUSTERID=$(echo ${FILE} | awk -F '/' '{print $(NF-1)}')
			WORKER_POOL_NAME=$(echo ${FILE} | awk -F '/' '{print $NF}' | awk -F '.' '{print $1}')
			source $FILE
			if ! grep $CLUSTERID $SERVICES_DATA_FILE; then
				if ! bx cs cluster create satellite --name $CLUSTERID --location "$LOCATION_ID" --version 4.10_openshift --operating-system RHCOS --enable-config-admin; then
					continue
				fi
			fi
			WORKER_POOL_FILE=/tmp/worker-pool-info.txt
			if ! bx cs worker-pools --cluster $CLUSTERID >$WORKER_POOL_FILE; then
				continue
			fi
			if ! grep "$WORKER_POOL_NAME" $WORKER_POOL_FILE; then
				bx cs worker-pool create satellite --name $WORKER_POOL_NAME --cluster $CLUSTERID --zone ${ZONE} --size-per-zone "$COUNT" --host-label "$HOST_LABELS" --operating-system RHCOS
			fi
			if ! bx cs worker-pool resize --cluster $CLUSTERID --worker-pool $WORKER_POOL_NAME --size-per-zone "$COUNT"; then
				continue
			fi
			core_machinegroup_reconcile
			while true; do
				if ! bx sat host assign --location "$LOCATION_ID" --cluster "$CLUSTERID" --host-label os=RHCOS --host-label "$HOST_LABELS"; then
					break
				fi
				sleep 5
				continue
			done
		fi
	done
done
