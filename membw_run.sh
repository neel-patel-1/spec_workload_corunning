#!/bin/bash

source shared.sh

mkdir -p $SPEC_OUTPUT
mkdir -p $SPEC_CORE_OUTPUT
mkdir -p $BACKGROUND_OUTPUT
mkdir -p $ANTAGONIST_OUTPUT

STRESS_CORES=( "1" "5" "9" "14" "19" )
STRESS_CORES=( "0" "1" "2" "5" "7" "9" "14" "19" "25" )
STRESS_CORES=( "0" "1" "2" "5" "7" "9" "14" "17" "19" )
STRESS_CORES=( `seq 0 19` )
STRESS_CORES=( "9" )
STRESS_CORES=( "0" "1" "2" "5" "7" "9" "14" "17" "19" )
STRESS_CORES=( "0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "11" "12" "13" "14" "15" "16" "17" "18" "19" )

SPEC_CORES=( 10 )
BENCHS=( "lbm_s" )

test_n=lbm_x${#SPEC_CORES[@]}_membw_x${#STRESS_CORES[@]}
PQOS_OUTPUT=$test_n/pqos/
SPEC_TEST_OUTPUT=$test_n/spec/
mkdir -p $PQOS_OUTPUT
mkdir -p $SPEC_TEST_OUTPUT

build_all

# start stressors
taskset -c $( echo ${STRESS_CORES[@]} | sed -e 's/ /,/g' -e 's/,$//g') stress-ng --memrate ${#STRESS_CORES[@]} --memrate-wr 50000 --memrate-rd 50000 &
stress_pid=$!

# start membw monitoring
sudo pqos -r -t 2
sudo pqos -m "all:[$( echo ${STRESS_CORES[@]} | sed -e 's/ /,/g' -e 's/,$//g')]" -o $PQOS_OUTPUT/${test_n}_${#STRESS_CORES[@]}cores_bandwidth.mon  &
pqos_pid=$!

# start spec workloads
run_all_spec_no_replacement_no_antagonist

sudo kill -KILL $pqos_pid $stress_pid

mkdir -p $test_n
cp -r $SPEC_OUTPUT/result/* $SPEC_TEST_OUTPUT
