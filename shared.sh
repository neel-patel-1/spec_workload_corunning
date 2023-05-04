#!/bin/bash

export TEST="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
export SPEC_ROOT=/home/n869p538/spec
export SPEC_OUTPUT=$TEST/spec_out
export SPEC_CORE_OUTPUT=$TEST/spec_out/spec_cores
export BACKGROUND_OUTPUT=$TEST/spec_out/spec_background
export REPORTABLE=0

SPEC_CORES=( 10 )
BENCHS=( "mcf_s" )
export COMP_CORES=( "0" "4" "6" "9" )

export SPEC_LOG=spec_log.txt
export MON_LOG=mon_log.txt

export ANTAGONIST=$TEST/antagonist.sh
export ANTAGONIST_OUTPUT=$TEST/antagonist_output

export MON_CORE="0" #only check for workload completion and handle experiment termination

build_bench(){
	runcpu --action runsetup --output-root $SPEC_OUTPUT $1
}
clear_build(){
	go $1
	rm -rf build
}

build_all(){
	uniq_benchs=( `printf "%s\n"  "${BENCHS[@]}" | sort | uniq` )
	for bench in "${uniq_benchs[@]}"; do
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

uniq_spec_pids_aliases(){
	rs=()
	for i in ${BENCH_ALIASES[@]}; do 
		[ ! -z "$(pgrep $i)" ] && rs+=( $(pgrep $i) ) 
	done
	for i in ${BENCH_IDS[@]}; do 
		[ ! -z "$(pgrep $i)" ] && rs+=( $(pgrep $i) ) 
	done
	uniq_pids=( `printf "%s\n"  "${rs[@]}" | sort | uniq` )
	echo "${uniq_pids[*]}"
}

launch_reportable_specs(){
	[ "$REPORTABLE" = "1" ] && wall "*** Experiment Starting in ~2min ***"
	for ((i=0;i<${#SPEC_CORES[@]};++i)); do
		bench=${BENCHS[i]}
		core=${SPEC_CORES[i]}
		taskset -c $core runcpu --nobuild --action run --output-root $SPEC_OUTPUT $bench 2>&1 | tee -a $SPEC_CORE_OUTPUT/spec_reportable_core_$core &
		echo "taskset -c $core runcpu --nobuild --action run --output-root $SPEC_OUTPUT $bench 2>&1 | tee -a $SPEC_CORE_OUTPUT/spec_reportable_core_$core &" | tee -a $MON_LOG
	done
}
launch_workload_replicators(){
	# 1 - wait for all benchmarks to launch
	if [ ! -z "${BENCH_ALIASES[0]}" ]; then
		uniq_pids=( $(uniq_spec_pids_aliases) )
		while [ "${#uniq_pids[@]}" -lt "${#BENCHS[@]}" ]; do
			sleep 2
			uniq_pids=( $( uniq_spec_pids_aliases ) )
			echo "Waiting for all spec benchs to start ${#uniq_pids[@]}/${#BENCHS[@]}" | tee -a $MON_LOG
		done
	else
		uniq_pids=( $( uniq_spec_pids ) )
		while [ "${#uniq_pids[@]}" -lt "${#BENCHS[@]}" ]; do
			sleep 2
			uniq_pids=( $( uniq_spec_pids ) )
			echo "Waiting for all spec benchs to start ${#uniq_pids[@]}/${#BENCHS[@]}" | tee -a $MON_LOG
		done
	fi

	# 2 - assign workload replicators to relaunch benchmarks on the same core after reportable run termination
	if [ ! -z "${BENCH_ALIASES[0]}" ]; then
		uniq_benchs=( `printf "%s %s\n"  "${BENCH_ALIASES[@]}" | sort | uniq` )
	else
		uniq_benchs=( `printf "%s %s\n"  "${BENCHS[@]}" | sort | uniq` )
	fi
	for i in "${uniq_benchs[@]}"; do
		rem_pids=( $(pgrep $i) )
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

				echo "taskset -c $MON_CORE ./workload_replicator.sh $core $bench $pid 2>&1 1>$SPEC_CORE_OUTPUT/workload_rep_core_$core &" | tee -a $MON_LOG
				taskset -c $MON_CORE ./workload_replicator.sh $core $bench $pid 2>&1 1>$SPEC_CORE_OUTPUT/workload_rep_core_$core &
				
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
launch_antagonist_threads(){
	echo "stdbuf -o0 taskset -c $(echo ${COMP_CORES[*]} | sed -e 's/ /,/g' -e 's/,$//') $ANTAGONIST 2>&1 1>$ANTAGONIST_OUTPUT/antagonist_log.txt &" | tee -a $MON_LOG
	stdbuf -o0 taskset -c $(echo ${COMP_CORES[*]} | sed -e 's/ /,/g' -e 's/,$//') $ANTAGONIST 2>&1 1>$ANTAGONIST_OUTPUT/antagonist_log.txt &
	while [ -z "$(pgrep lzbench)" ]; do
		echo "waiting on antagonist threads" | tee -a $MON_LOG
		sleep 2
	done
}

run_all_spec_no_replacement(){
	echo > $SPEC_LOG
	echo > $MON_LOG
	launch_antagonist_threads
	launch_reportable_specs
	sleep 10
	taskset -c $MON_CORE ./experiment_terminator.sh
}
run_all_spec_no_replacement_no_antagonist(){
	echo > $SPEC_LOG
	echo > $MON_LOG
	launch_reportable_specs
	sleep 10
	taskset -c $MON_CORE ./experiment_terminator.sh
}
run_all_spec_no_antagonist(){
	echo > $SPEC_LOG
	echo > $MON_LOG
	launch_reportable_specs
	sleep 10
	launch_workload_replicators
	taskset -c $MON_CORE ./experiment_terminator.sh
}
run_all_spec_with_antagonist(){
	echo > $SPEC_LOG
	echo > $MON_LOG
	launch_antagonist_threads
	launch_reportable_specs
	sleep 10
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
	uniq_benchs=( `printf "%s %s %s\n"  "${BENCHS[@]}" "${BENCH_IDS[@]}" "${BENCH_ALIASES[@]}" | sort | uniq` )
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
