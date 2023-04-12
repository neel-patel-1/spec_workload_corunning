#!/bin/bash

export TEST="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
export SPEC_ROOT=/home/n869p538/spec
export SPEC_OUTPUT=$TEST/spec_out
export BACKGROUND_OUTPUT=$TEST/spec_background

SPEC_CORES=( 1 2 3 5 6 7 9 10 11 )
BENCHS=( "lbm_s" "mcf_s" "fotonik3d_s" "lbm_s" "mcf_s" "fotonik3d_s" "lbm_s" "mcf_s" "fotonik3d_s" ) #memory intensive workloads
#SPEC_CORES+=( `seq 12 18` )
#BENCHS+=( "lbm_s" "mcf_s" "omnetpp_s" "gcc_r" "cactuBSSN_s" "fotonik3d_s" "perlbench_s" ) #memory intensive workloads

export SPEC_LOG=spec_log.txt
export MON_LOG=mon_log.txt

export ANTAGONIST=$TEST/antagonist.sh
export ANTAGONIST_OUTPUT=$TEST/antagonist
export COMP_CORES=( "1" "9" "11" "19"  )

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

uniq_spec_pids(){
	rs=()
	for i in ${BENCHS[@]}; do 
		[ ! -z "$(pgrep $i)" ] && rs+=( $(pgrep $i) ) 
	done
	for i in ${BENCH_IDS[@]}; do 
		[ ! -z "$(pgrep $i)" ] && rs+=( $(pgrep $i) ) 
	done
	uniq_pids=( `printf "%s\n"  "${rs[@]}" | sort | uniq` )
	echo "${uniq_pids[*]}"
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
	uniq_pids=( $( uniq_spec_pids ) )
	while [ "${#uniq_pids[@]}" -lt "${#BENCHS[@]}" ]; do
		sleep 2
		uniq_pids=( $( uniq_spec_pids ) )
		echo "Waiting for all spec benchs to start ${#uniq_pids[@]}/${#BENCHS[@]}" | tee -a $MON_LOG
	done

	# 2 - assign workload replicators to relaunch benchmarks on the same core after reportable run termination
	ID_itr=0
	uniq_benchs=( `printf "%s %s\n"  "${BENCHS[@]}" | sort | uniq` )
	for i in "${uniq_benchs[@]}"; do
		rem_pids=( $(pgrep $i) )
		[ -z "$rem_pids" ] && rem_pids=( $(pgrep ${BENCH_IDS[$ID_itr]}) ) && ID_itr=$(( $ID_itr + 1 ))
		[ -z "$rem_pids" ] && echo "pids for $i not found" | tee -a $MON_LOG && return -1
		for ((j=0;j<${#BENCHS[@]};++j)); do
			bench=${BENCHS[j]}
			core=${SPEC_CORES[j]}
			if [ "$i" == "$bench" ]; then
				echo "remaining $i pids for assignment : ${rem_pids[*]}" | tee -a $MON_LOG
				pid=${rem_pids[0]}
				rem_pids=( ${rem_pids[@]/$pid/} )
				echo "assigning workload_replicator for $bench with pid $pid to core $core" | tee -a $MON_LOG
				[ -z "$pid" ] && echo "pid for $bench on core $core not found" | tee -a $MON_LOG && return -1

				echo "taskset -c $MON_CORE ./workload_replicator.sh $core $bench $pid 2>&1 1>$SPEC_OUTPUT/workload_rep_core_$core &" | tee -a $MON_LOG
				taskset -c $MON_CORE ./workload_replicator.sh $core $bench $pid 2>&1 1>$SPEC_OUTPUT/workload_rep_core_$core &
				
			fi
		done
	done
}
launch_antagonists(){
	for ((i=0;i<${#COMP_CORES[@]};++i)); do
		core=${COMP_CORES[i]}
		taskset -c $core $ANTAGONIST 2>&1 1>$ANTAGONIST_OUTPUT/antagonist_stats_core_$core &
	done
}

run_all_spec_no_antagonist(){
	echo > $SPEC_LOG
	echo > $MON_LOG
	launch_reportable_specs
	launch_workload_replicators
	taskset -c $MON_CORE ./experiment_terminator.sh
}
run_all_spec_with_antagonist(){
	echo > $SPEC_LOG
	echo > $MON_LOG
	launch_antagonists
	launch_reportable_specs
	launch_workload_replicators
	taskset -c $MON_CORE ./experiment_terminator.sh
}

function kill_bench {
    pid=`pgrep $1`
	echo "killing $1: $pid" | tee -a $MON_LOG
    if [ -n "$pid" ]; then
	{ sudo kill $pid && sudo wait $pid; } 2>/dev/null
    fi
}
function kill_all_bench {
	uniq_benchs=( `printf "%s %s\n"  "${BENCHS[@]}" "${BENCH_IDS[@]}" | sort | uniq` )
	for i in "${uniq_benchs[@]}"; do
		bench=$i
		kill_bench $bench
	done
}
function kill_antagonist {
	sudo kill `pgrep antagonist` >& /dev/null
	sudo kill `pgrep "lzbench"`  >& /dev/null
}
function kill_workload_replicator {
	sudo kill `pgrep workload_rep` >& /dev/null #TODO: why does pgrep only return pids for truncated script name
}
function kill_experiment {
	kill_workload_replicator
	kill_antagonist
	kill_all_bench
}

cd $SPEC_ROOT
source shrc
cd $TEST
