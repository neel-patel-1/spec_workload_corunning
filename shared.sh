#!/bin/bash

export TEST="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
export SPEC_ROOT=~/spec
export SPEC_OUTPUT=$TEST/spec_out
export BACKGROUND_OUTPUT=$TEST/spec_background

SPEC_CORES=( `seq 1 3` )
BENCHS=( "lbm_s" "xz_s" "xz_s"  ) #memory intensive workloads
#BENCHS=( "lbm_s" "xz_s" "xz_s"  ) #duplicate workload test
#SPEC_CORES+=( `seq 11 13` )
#BENCHS+=( "lbm_s" "xz_s" "mcf_s"  ) #memory intensive workloads

export SPEC_LOG=spec_log.txt
export MON_LOG=mon_log.txt

export QZ_ROOT=$TEST/../QATzip
export ANTAGONIST=$TEST/../antagonist.sh
export ANTAGONIST_OUTPUT=$TEST/antagonist
export COMP_CORES=(  "0"  )

export MON_CORE="0" #only check for workload completion and handle experiment termination

build_bench(){
	runcpu --action runsetup --output-root $SPEC_OUTPUT $1
}
clear_build(){
	go $1
	rm -rf build
}

build_all(){
	for ((i=0;i<${#BENCHS[@]};++i)); do
		bench=${BENCHS[i]}
		build_bench $bench
	done
}

launch_reportable_specs(){
	for ((i=0;i<${#SPEC_CORES[@]};++i)); do
		bench=${BENCHS[i]}
		core=${SPEC_CORES[i]}
		#2>1 >/dev/null taskset -c $core runcpu --nobuild --action run --output-root $SPEC_OUTPUT $bench &
		taskset -c $core runcpu --nobuild --action run --output-root $SPEC_OUTPUT $bench 2>&1 | tee -a $SPEC_OUTPUT/spec_reportable_core_$core &
		echo "taskset -c $core runcpu --nobuild --action run --output-root $SPEC_OUTPUT $bench 2>&1 | tee -a $SPEC_OUTPUT/spec_reportable_core_$core &" | tee -a $MON_LOG
	done
}
launch_workload_replicators(){
	# 1 - wait for all benchmarks to launch
	while [ `pgrep "$( echo "${BENCHS[*]}" | sed 's/ /|/g')" | wc -l` -lt "${#BENCHS[@]}" ]; do
		sleep 2
		echo "Waiting for all spec benchs to start" | tee -a $MON_LOG
	done

	# 2 - assign workload replicators to relaunch benchmarks on the same core after reportable run termination
	uniq_benchs=( `printf "%s\n"  "${BENCHS[@]}" | uniq` )
	for i in "${uniq_benchs[@]}"; do
		rem_pids=( $(pgrep $i) )
		for ((j=0;j<${#BENCHS[@]};++j)); do
			bench=${BENCHS[j]}
			core=${SPEC_CORES[j]}
			if [ "$i" == "$bench" ]; then
				pid=${rem_pids[0]}
				rem_pids=( ${rem_pids[@]:0} )
				echo "remaining pids for $i : ${rem_pids[*]}" | tee -a $MON_LOG
				[ -z "$pid" ] && echo "pid for $bench on core $core not found" | tee -a $MON_LOG && return -1
				echo "assigning workload_replicator for $bench with pid $pid to core $core" | tee -a $MON_LOG

				echo "taskset -c $MON_CORE ./workload_replicator.sh $core $bench $pid 2>&1 1>$SPEC_OUTPUT/workload_rep_core_$core &" | tee -a $MON_LOG
				taskset -c $MON_CORE ./workload_replicator.sh $core $bench $pid 2>&1 1>$SPEC_OUTPUT/workload_rep_core_$core &
				
			fi
		done
	done
}
launch_antagonists(){
	for ((i=0;i<${#COMP_CORES[@]};++i)); do
		core=${COMP_CORES[i]}
		taskset -c $core $TEST/../antagonist.sh 2>&1 1>$ANTAGONIST_OUTPUT/antagonist_stats_core_$core &
	done
}


run_all(){
	RUNNING_SPECS=()
	echo > $SPEC_LOG
	echo > $MON_LOG


	launch_antagonists

	launch_reportable_specs

	#sleep 10
	launch_workload_replicators

	taskset -c $MON_CORE ./experiment_terminator.sh &

}

function kill_bench {
    pid=`pgrep $1`
	echo "killing $1: $pid" | tee -a $MON_LOG
    if [ -n "$pid" ]; then
	{ sudo kill $pid && sudo wait $pid; } 2>/dev/null
    fi
}
function kill_all_bench {
	for ((i=0;i<${#BENCHS[@]};++i)); do
		bench=${BENCHS[i]}
		kill_bench $bench
	done
}

cd $SPEC_ROOT
source shrc
cd $TEST
