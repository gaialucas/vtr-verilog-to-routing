#!/usr/bin/env bash
SHELL=$(type -P bash)
FAILURE=0

THIS_SCRIPT_PATH=$(readlink -f "$0")
THIS_DIR=$(dirname "${THIS_SCRIPT_PATH}")
VTR_DIR=$(readlink -f "${THIS_DIR}/..")
REGRESSION_DIR="${THIS_DIR}/regression_test"
REG_LIB="${REGRESSION_DIR}/.library"
PARSER_DIR="${REGRESSION_DIR}/parse_result"
PARSER_EXEC="${PARSER_DIR}/parse_result.py"
ELABORATOR_YOSYS="--elaborator yosys"

source "${REG_LIB}/handle_exit.sh"
source "${REG_LIB}/helper.sh"
source "${REG_LIB}/conf_generate.sh"

export EXIT_NAME="$0"

##############################################
# grab the input args
INPUT="$*"

# disable stdin
exec 0<&-

WRAPPER_EXEC="${THIS_DIR}/exec_wrapper.sh"
ODIN_EXEC="${THIS_DIR}/odin_II"


BENCHMARK_DIR="${REGRESSION_DIR}/benchmark"

VTR_REG_PREFIX="vtr::"
VTR_REG_DIR="${VTR_DIR}/vtr_flow/tasks/regression_tests"

SUITE_DIR="${BENCHMARK_DIR}/suite"
RELAPATH_SUITE_DIR=$(realapath_from "${SUITE_DIR}" "${PWD}")

TASK_DIR="${BENCHMARK_DIR}/task"
RELAPATH_TASK_DIR=$(realapath_from "${TASK_DIR}" "${PWD}")

RTL_REG_PREFIX="rtl_reg"

PREVIOUS_RUN_DIR=""
NEW_RUN_DIR="${REGRESSION_DIR}/run001/"

global_failure="test_failures.log"

##############
# defaults
_TEST_INPUT_LIST=()
_SUBTEST_LIST=()
_NUMBER_OF_PROCESS="1"
_RUN_DIR_OVERRIDE=""
_EXTRA_CONFIG=""

_OVERRIDE_CONFIG="off"
_GENERATE_BENCH="off"
_GENERATE_OUTPUT="off"
_GENERATE_CONFIG="off"
_FORCE_SIM="off"
_DRY_RUN="off"
_RANDOM_DRY_RUN="off"
_GENERATE_BLIF="off"
_REGENERATE_BLIF="off"
_REGENERATE_EXPECTATION="off"
_GENERATE_EXPECTATION="off"
_CONTINUE="off"
_REPORT="on"
_STATUS_ONLY="off"
_RUN_YOSYS_ARGS=""

##############################################
# Exit Functions
function exit_program() {

	FAIL_COUNT="0"
	if [ -f "${NEW_RUN_DIR}/${global_failure}" ]; then
		FAIL_COUNT=$(wc -l "${NEW_RUN_DIR}/${global_failure}" | cut -d ' ' -f 1)
	fi

	FAILURE=$(( FAIL_COUNT ))

	if [ "_${_REPORT}" == "_on" ]
	then
		if [ "_${FAILURE}" != "_0" ]
		then
			echo "Failed ${FAILURE} benchmarks"
			echo ""
			cat "${NEW_RUN_DIR}/${global_failure}"
			echo ""
			echo "View Failure log in ${NEW_RUN_DIR}/${global_failure}"

		else
			echo "no run failure!"
		fi
	fi

	exit ${FAILURE}
}

##############################################
# Help Print helper
_prt_cur_arg() {
	arg="[ $1 ]"
	line="                      "
	printf "%s%s" "${arg}" "${line:${#arg}}"
}

function help() {

printf "Called program with $INPUT
	Usage: 
		$0 [ OPTIONS / FLAGS ] [ SUBTEST_LIST ... ]

	SUBTEST_LIST
		should be a list of the form < task_name/test_file_name/architecture_file_name >
		passing this in will limit a task to a subset of test
		current: $(_prt_cur_arg ${_SUBTEST_LIST[*]})

	FLAGS
		-g|--generate_bench             $(_prt_cur_arg ${_GENERATE_BENCH}) Generate input and output vector for test
		-o|--generate_output            $(_prt_cur_arg ${_GENERATE_OUTPUT}) Generate output vector for test given its input vector
		-b|--build_config               $(_prt_cur_arg ${_GENERATE_CONFIG}) Generate a config file for a given directory
		-c|--clean                      $(_prt_cur_arg off ) Clean temporary directory
		-f|--force_simulate             $(_prt_cur_arg ${_FORCE_SIM}) Force the simulation to be executed regardless of the config
		--override						$(_prt_cur_arg ${_OVERRIDE_CONFIG}) if a config file is passed in, override arguments rather than append
		--dry_run                       $(_prt_cur_arg ${_DRY_RUN}) performs a dry run to check the validity of the task and flow 
		--randomize                     $(_prt_cur_arg ${_RANDOM_DRY_RUN}) performs a dry run randomly to check the validity of the task and flow 
		--generate_blif                 $(_prt_cur_arg ${_GENERATE_BLIF}) generate the missing blifs of verilog files located in benchmark/_BLIF
		--regenerate_blif               $(_prt_cur_arg ${_REGENERATE_BLIF}) regenerate the blifs of verilog files located in benchmark/_BLIF
		--regenerate_expectation        $(_prt_cur_arg ${_REGENERATE_EXPECTATION}) regenerate the expectation and overrides the expected value mismatches only
		--generate_expectation          $(_prt_cur_arg ${_GENERATE_EXPECTATION}) generate the expectation and overrides the expectation file
		--continue						$(_prt_cur_arg ${_CONTINUE}) continue running test in the same directory as the last run
		--no_report						printing report is: $(_prt_cur_arg ${_REPORT})
		--status_only					$(_prt_cur_arg ${_STATUS_ONLY}) print the report and exit
	OPTIONS
		-h|--help                       $(_prt_cur_arg off) print this
		-j|--nb_of_process < N >        $(_prt_cur_arg ${_NUMBER_OF_PROCESS}) Number of process requested to be used
		-d|--output_dir < /abs/path >   $(_prt_cur_arg ${_RUN_DIR_OVERRIDE}) Change the run directory output
		-C|--config <path/to/config>	$(_prt_cur_arg ${_EXTRA_CONFIG}) Add a config file to append to the config for the tests
		-t|--test < test name >         $(_prt_cur_arg ${_TEST_INPUT_LIST[*]}) Test name is either a absolute or relative path to 
		                                                       a directory containing a task.conf, task_list.conf 
		                                                       (see CONFIG FILE HELP) or one of the following predefined test

	AVAILABLE_TEST:
"

printf "\n\t\t%s\n" "${RELAPATH_SUITE_DIR}/"
for bm in "${SUITE_DIR}"/*; do printf "\t\t\t%s\n" "$(basename "${bm}")"; done

printf "\n\t\t%s\n" "${RELAPATH_TASK_DIR}/"
for bm in "${TASK_DIR}"/*; do printf "\t\t\t%s\n" "$(basename "${bm}")"; done

printf "\n\t\t%s\n" "${VTR_REG_PREFIX}"
for bm in "${VTR_REG_DIR}/${VTR_REG_PREFIX}"*; do printf "\t\t\t%s\n" "$(basename "${bm}" | sed "s+${VTR_REG_PREFIX}++g")"; done

printf "\n\t\t%s\n" "${RTL_REG_PREFIX}"

echo "CONFIG FILE HELP:"

config_help

}

###############################################
# Time Helper Functions
function get_current_time() {
	date +%s%3N
}

# needs start time $1
function print_time_since() {
	BEGIN="$1"
	NOW=$(get_current_time)
	TIME_TO_RUN=$(( NOW - BEGIN ))

	Mili=$(( TIME_TO_RUN %1000 ))
	Sec=$(( ( TIME_TO_RUN /1000 ) %60 ))
	Min=$(( ( ( TIME_TO_RUN /1000 ) /60 ) %60 ))
	Hour=$(( ( ( TIME_TO_RUN /1000 ) /60 ) /60 ))

	echo "ran test in: $Hour:$Min:$Sec.$Mili"
}

TMP_BENCH_FIND_ARRAY=()
function find_in_bench() {
	# sort the output alphabeticaly
	mapfile -t TMP_BENCH_FIND_ARRAY < <(echo "$1"/*/*/"$2" | tr -s '[:space:]' '\n' | sort)
	if [ "_${TMP_BENCH_FIND_ARRAY[*]}" == "_" ] \
	|| [ "_${TMP_BENCH_FIND_ARRAY[0]}" == "_" ]\
	|| [ ! -f "${TMP_BENCH_FIND_ARRAY[0]}" ]
	then
		TMP_BENCH_FIND_ARRAY=()
	fi
}

# generate blif files of verilog files in benchmark/blif/_VERILOGS
function generate_blifs() {
    
    BENCHMARK="$1"
    BENCH_NAME=$(echo ${BENCHMARK} | sed 's/.*\(_BLIF\)/\1/g' )

    if [ _${_GENERATE_BLIF} = "_on" ]; then
        echo "Generating missed BLIF files for benchmarks in ${REGRESSION_DIR}/benchmark/_VERILOG/${BENCH_NAME}"
    elif [ _${_REGENERATE_BLIF} = "_on" ]; then
        _RUN_YOSYS_ARGS+=" --regenerate_blif "
        echo "Regenerating BLIF files for benchmarks in ${REGRESSION_DIR}/benchmark/_VERILOG/${BENCH_NAME}"
    fi

    RUN_YOSYS_SCRIPT_PARAMS=" -t ${BENCHMARK} "
    RUN_YOSYS_SCRIPT_PARAMS+="${_RUN_YOSYS_ARGS}"

    ${REGRESSION_DIR}/tools/run_yosys.sh  ${RUN_YOSYS_SCRIPT_PARAMS}
    _RUN_YOSYS_ARGS=""
}
    

################################################
# Init Directories and cleanup
function init_temp() {
	OUTPUT_DIRECTORY=${REGRESSION_DIR}
	if [ "_${_RUN_DIR_OVERRIDE}" != "_" ] && [ -d "${_RUN_DIR_OVERRIDE}" ]
	then
		OUTPUT_DIRECTORY=${_RUN_DIR_OVERRIDE}
	fi

	PREVIOUS_RUN_DIR=$(find ${OUTPUT_DIRECTORY}/run* -maxdepth 0 -type d 2>/dev/null | tail -1 )
	n="1"
	if [ "_${PREVIOUS_RUN_DIR}" != "_" ]
	then
		n=$(echo "${PREVIOUS_RUN_DIR##${OUTPUT_DIRECTORY}/run}" | awk '{print $0 + 1}')
		if [ "_${_CONTINUE}" == "_on" ]
		then
			n=$(( n - 1 ))
		fi
	fi

	NEW_RUN_DIR=${OUTPUT_DIRECTORY}/run$(printf "%03d" "${n}")
	echo "Benchmark result location: ${NEW_RUN_DIR}"
}

function create_temp() {
	if [ ! -d "${NEW_RUN_DIR}" ]; then
		mkdir -p "${NEW_RUN_DIR}"

		unlink "${REGRESSION_DIR}/latest" &> /dev/null || /bin/true
		rm -Rf "${REGRESSION_DIR}/latest" || /bin/true

		ln -s "${NEW_RUN_DIR}" "${REGRESSION_DIR}/latest"

		# put in the passed parameter for keepsake 
		echo "${_TEST_INPUT_LIST[@]}" | xargs -n 1 -I {} echo {} > "${NEW_RUN_DIR}/cmd.task"
		echo "========="
		echo "$0 ${INPUT}" >> "${NEW_RUN_DIR}/cmd.task"
	fi
}

function cleanup_temp() {
	OUTPUT_DIRECTORY=${REGRESSION_DIR}
	if [ "_${_RUN_DIR_OVERRIDE}" != "_" ]
	then
		OUTPUT_DIRECTORY=${_RUN_DIR_OVERRIDE}
	fi

	for runs in "${OUTPUT_DIRECTORY}"/run*
	do 
		rm -Rf "${runs}"
	done

	if [ -e "${REGRESSION_DIR}/latest" ]; then
		unlink "${REGRESSION_DIR}/latest" || /bin/true
		rm -Rf "${REGRESSION_DIR}/latest" || /bin/true
	fi

}

function disable_failed_bm() {

	failed_dir=$1
	bench_name="$2"

	if [ "_${failed_dir}" != "_" ] && [ "_${bench_name}" != "_" ]
	then

		find_in_bench "${NEW_RUN_DIR}/${bench_name}" "failure"
		for failed_benchmark in "${TMP_BENCH_FIND_ARRAY[@]}"
		do
			failed_benchmark="$(dirname "${failed_benchmark}")"
			for cmd_params in "${failed_benchmark}"/*_wrapper_*
			do
				[ "_${cmd_params}" != "_" ] && [ -f "${cmd_params}"  ] && mv "${cmd_params}" "${cmd_params}_disabled"
			done

			failed_benchmark_relapath="$(realapath_from "${failed_benchmark}" "${NEW_RUN_DIR}")"
			target="${failed_dir}/${failed_benchmark_relapath}"
			target_dir=$(dirname "${target}")

			if [ ! -L "${target}" ]
			then
				mkdir -p "${target_dir}"
				ln -s "${failed_benchmark}" "${target}"
			fi

		done
	fi
}

function parse_args() {
	PARSE_SUBTEST="off"
	while [ "_$*" != "_" ]
	do 
		if [ ${PARSE_SUBTEST} == "on" ];
		then
		# parse subtest
			_SUBTEST_LIST+=( "$1" )
			shift
		else
		# parse [ OPTIONS / FLAGS ] 
			case $1 in 

			# Help Desk
				-h|--help)
					echo "Printing Help information"
					help
					_exit_with_code "0"

				
			## directory in benchmark
				;;-t|--test)
					# this is handled down stream
					if [ "_$2" == "_" ]
					then 
						echo "empty argument for $1"
						_exit_with_code "-1"
					fi
					# concat tests
					_TEST_INPUT_LIST+=( "$2" )
					shift

				;;-d|--output_dir)

					if [ "_$2" == "_" ]
					then 
						echo "empty argument for $1"
						_exit_with_code "-1"
					fi
					
					_RUN_DIR_OVERRIDE=$2

					if [ ! -d "${_RUN_DIR_OVERRIDE}" ]
					then
						echo "Directory ${_RUN_DIR_OVERRIDE} does not exist"
						_exit_with_code "-1"
					fi

					shift

				;;-C|--config)

					if [ "_$2" == "_" ]
					then 
						echo "empty argument for $1"
						_exit_with_code "-1"
					fi
					
					_EXTRA_CONFIG=$2
					echo "Reading extra config directive from ${_EXTRA_CONFIG}"

					shift

			## number
				;;-j|--nb_of_process)
					_NUMBER_OF_PROCESS=$(_flag_is_number "$1" "$2")
					echo "Using [$2] processors for this benchmarking suite"
					shift

			# Boolean flags
				;;-g|--generate_bench)		
					_GENERATE_BENCH="on"
					echo "generating output vector for test given predefined input"

				;;-o|--generate_output)		
					_GENERATE_OUTPUT="on"
					echo "generating input and output vector for test"

				;;-b|--build_config)		
					_GENERATE_CONFIG="on"
					echo "generating a config file for test directory"

				;;-c|--clean)				
					echo "Cleaning temporary run in directory"
					cleanup_temp

				;;-f|--force_simulate)   
					_FORCE_SIM="on"
					echo "Forcing Simulation"   

				;;--override)
					_OVERRIDE_CONFIG="on"
					echo "Forcing override of config"    

				;;--dry_run)
					_DRY_RUN="on"
					echo "Performing a dry run"

				;;--randomize)
					_RANDOM_DRY_RUN="on"
					echo "random dry run"

				;;--generate_blif)
					_GENERATE_BLIF="on"
                    _RUN_YOSYS_ARGS+=""
					echo "generating missed blifs of benchmark/_BLIF"
				
                ;;--regenerate_blif)
					_REGENERATE_BLIF="on"
					echo "regenerating blifs of benchmark/_BLIF"
				
                ;;--regenerate_expectation)
					_REGENERATE_EXPECTATION="on"
					echo "regenerating expected values for changes outside the defined ranges"

				;;--generate_expectation)
					_GENERATE_EXPECTATION="on"
					echo "generating new expected values"

				;;--no_report)
					_REPORT="off"
					echo "don't generate the report at the end"

				;;--continue)
					_CONTINUE="on"
					echo "run this test in the same directory as the previous test"

				;;--status_only)
					_STATUS_ONLY="on"
					_CONTINUE="on"
					echo "print the previous test report"

				;;*) 
					PARSE_SUBTEST="on"
			esac

			# keep the subtest in case we caught the end of options and flags
			[ ${PARSE_SUBTEST} != "on" ] && shift
		fi
	done
}

function format_line() {
	echo "$@" \
		| cut -d '#' -f 1	`# trim the # signs` \
		| sed 's/\s+/ /g'	`# trim duplicate whitespace` \
		| sed 's/\s*$//g'	`# trim the tail end whitespace` \
		| sed 's/^\s*//g'	`# trim the front white space`
}

function warn_is_defined() {
	[ "_$1" != "_" ] && echo "Specifying more than one ${2} in config file"
}

_regression_params=""
_script_synthesis_params=""
_script_techmap_params=""
_script_simulation_params=""
_synthesis_parse_file=""
_techmap_parse_file=""
_simulation_parse_file=""
_synthesis_params=""
_techmap_params=""
_simulation_params=""
_circuit_list=()
_arch_list=()

function config_help() {
printf "
	*.conf is a list of key=value set
	'#' are used for comments

	the following key=value, ... are available:

			circuits_dir             = < path/to/circuit/dir >
			circuit_list_add         = < circuit file path relative to [circuits_dir] >
			archs_dir                = < path/to/arch/dir >
			arch_list_add            = < architecture file path relative to [archs_dir] >
			synthesis_parse_file 	 = < path/to/parse/file >
			techmap_parse_file 	     = < path/to/parse/file >
			simulation_parse_file 	 = < path/to/parse/file >
			script_synthesis_params  = [see exec_wrapper.sh options]
			script_techmap_params    = [see exec_wrapper.sh options]
			script_simulation_params = [see exec_wrapper.sh options]
			synthesis_params         = [see Odin options]	
			techmap_params           = [see Odin options]	
			simulation_params        = [see Odin options]
			regression_params        = 
			{
				--verbose                # display error logs after batch of tests
				--concat_circuit_list    # concatenate the circuit list and pass it straight through to odin
				--generate_bench         # generate input and output vectors from scratch
				--generate_output        # generate output vectors only if input vectors already exist
				--enable_techmap         # enable the technology mapping for this task (only coarsen blif files should pass)
				--disable_simulation     # disable the simulation for this task
				--disable_parallel_jobs  # disable running circuit/task pairs in parralel
				--include_default_arch   # run odin also without architecture file
			}

"
}

init_args_for_test() {
	_regression_params=""
	_script_synthesis_params=""
	_script_techmap_params=""
	_script_simulation_params=""
	_synthesis_parse_file=""
	_techmap_parse_file=""
	_simulation_parse_file=""
	_synthesis_params=""
	_techmap_params=""
	_simulation_params=""
	_circuit_list=()
	_arch_list=()
}

function populate_arg_from_file() {

	_circuits_dir=""
	_archs_dir=""
	_circuit_list_add=()
	_arch_list_add=()
	_local_synthesis_parse_file=""
	_local_techmap_parse_file=""
	_local_simulation_parse_file=""
	_local_script_synthesis_params=""
	_local_script_techmap_params=""
	_local_script_simulation_params=""
	_local_synthesis_params=""
	_local_techmap_params=""
	_local_simulation_params=""
	_local_regression_params=""

	if [ "_$1" == "_" ] || [ ! -f "$1" ]
	then
		echo "Config file $1 does not exist"
	else
		OLD_IFS=${IFS}
		while IFS="" read -r current_line || [ -n "${current_line}" ]
		do
			formatted_line=$(format_line "${current_line}")

			_key="$(echo "${formatted_line}" | cut -d '=' -f1 )"
			_value="$(echo "${formatted_line}" | cut -d '=' -f2 )"

			if [ "_${_key}" != "_" ] && [ "_${_value}" == "_" ] 
			then
				echo "Specifying empty value for ${_key}, skipping assignment"
			elif [ "_${_key}" == "_" ] && [ "_${_value}" != "_" ] 
			then
				echo "Specifying empty key for value: ${_value}, skipping assignment"
			elif [ "_${_key}" != "_" ] && [ "_${_value}" != "_" ] 
			then
				case _${_key} in

					_circuits_dir)
						if [ ! -d "${_value}" ]
						then
							_value=${THIS_DIR}/${_value}
						fi
						_circuits_dir="${_value}"

					;;_circuit_list_add)
						# glob the value
						_circuit_list_add+=( "${_circuits_dir}"/${_value} )	    

					;;_archs_dir)
						if [ ! -d "${_value}" ]
						then
							_value=${THIS_DIR}/${_value}
						fi
						_archs_dir="${_value}"

					;;_arch_list_add)
						# glob the value
						_arch_list_add+=( "${_archs_dir}"/${_value} )

					;;_script_synthesis_params)
						_local_script_synthesis_params="${_local_script_synthesis_params} ${_value}"

                    ;;_script_techmap_params)
						_local_script_techmap_params="${_local_script_techmap_params} ${_value}"

					;;_script_simulation_params)
						_local_script_simulation_params="${_local_script_simulation_params} ${_value}"

					;;_simulation_parse_file)
						_local_simulation_parse_file="${_value}"

					;;_techmap_parse_file)
						_local_techmap_parse_file="${_value}"

                    ;;_synthesis_parse_file)
						_local_synthesis_parse_file="${_value}"

					;;_synthesis_params)
						_local_synthesis_params="${_local_synthesis_params} ${_value}"

                    ;;_techmap_params)
						_local_techmap_params="${_local_techmap_params} ${_value}"					
						
					;;_simulation_params)
						_local_simulation_params="${_local_simulation_params} ${_value}"

					;;_regression_params)
						_local_regression_params="${_local_regression_params} ${_value}"

					;;_)
						echo "skip" > /dev/null

					;;*)
						echo "Unsupported value: ${_key} ${_value}, skipping"

				esac
			fi
		done < "$1"
		IFS=${OLD_IFS}
	fi

	if [ "${_OVERRIDE_CONFIG}" == "on" ];
	then
		_regression_params="${_local_regression_params}"
		_script_simulation_params="${_local_script_simulation_params}"
		_script_techmap_params="${_local_script_techmap_params}"
		_script_synthesis_params="${_local_script_synthesis_params}"
		_synthesis_params="${_local_synthesis_params}"
		_techmap_params="${_local_techmap_params}"
		_simulation_params="${_local_simulation_params}"
	else
		_regression_params="${_local_regression_params} ${_regression_params}"
		_script_simulation_params="${_local_script_simulation_params} ${_script_simulation_params}"
		_script_techmap_params="${_local_script_techmap_params} ${_script_techmap_params}"
		_script_synthesis_params="${_local_script_synthesis_params} ${_script_synthesis_params}"
		_synthesis_params="${_local_synthesis_params} ${_synthesis_params}"
		_techmap_params="${_local_techmap_params} ${_techmap_params}"
		_simulation_params="${_local_simulation_params} ${_simulation_params}"
	fi

	if [ "_${_local_synthesis_parse_file}" != "_" ]
	then
		if [ ! -f "${_local_synthesis_parse_file}" ]
		then
			_local_synthesis_parse_file="${THIS_DIR}/${_local_synthesis_parse_file}"
		fi
	fi

	if [ "_${_local_synthesis_parse_file}" != "_" ]
	then
		if [ ! -f "${_local_synthesis_parse_file}" ]
		then
			echo "file ${_local_synthesis_parse_file} not found, skipping"
		else
			_synthesis_parse_file="${_local_synthesis_parse_file}"
		fi
	fi

    if [ "_${_local_techmap_parse_file}" != "_" ]
	then
		if [ ! -f "${_local_techmap_parse_file}" ]
		then
			_local_techmap_parse_file="${THIS_DIR}/${_local_techmap_parse_file}"
		fi
	fi

	if [ "_${_local_techmap_parse_file}" != "_" ]
	then
		if [ ! -f "${_local_techmap_parse_file}" ]
		then
			echo "file ${_local_techmap_parse_file} not found, skipping"
		else
			_techmap_parse_file="${_local_techmap_parse_file}"
		fi
	fi

	if [ "_${_local_simulation_parse_file}" != "_" ]
	then
		if [ ! -f "${_local_simulation_parse_file}" ]
		then
			_local_simulation_parse_file="${THIS_DIR}/${_local_simulation_parse_file}"
		fi
	fi

	if [ "_${_local_simulation_parse_file}" != "_" ]
	then
		if [ ! -f "${_local_simulation_parse_file}" ]
		then
			echo "file ${_local_simulation_parse_file} not found, skipping"
		else
			_simulation_parse_file="${_local_simulation_parse_file}"
		fi
	fi

	
	for circuit_list_item in "${_circuit_list_add[@]}"
	do
		if [ ! -f "${circuit_list_item}" ]
		then
            echo "file ${circuit_list_item} not found, skipping"
		else
			_circuit_list+=( "${circuit_list_item}" )
		fi
	done

	if [ "_${#_circuit_list[*]}" == "_" ]
	then
		echo "Passed a config file with no circuit to test"
		_exit_with_code "-1"
	fi
	

	for arch_list_item in "${_arch_list_add[@]}"
	do
		if [ ! -f "${arch_list_item}" ]
		then
			echo "file ${arch_list_item} not found, skipping"
		else
			_arch_list+=( "${arch_list_item}" )
		fi
	done

	if [ "_${#_arch_list[*]}" == "_" ]
	then
		echo "Passed a config file with no architecture, defaulting to no_arch"
		_arch_list+=( "no_arch" )
	fi

}
function odin_file_type_arg() {
	###############################
	# return Odin-II arg specified 
	# by the input file extension
	basename=$(basename "$1")
	extension=$(echo ${basename##*.} | tr '[:upper:]' '[:lower:]')
	case ${extension} in
		v|vh)
			echo "-v"
		;;sv|svh)
			echo "-s"
		;;uhdm)
			echo "-u"
		;;blif)
			echo "-b"
		;;*)
			echo "Invalid input file type (${extenstion}), supported file types are { .v .vh .sv .svh .uhdm .blif }"
			_exit_with_code "-1"

	esac
}


function header() {
	echo " ========= $*"
}

function run_cmd_file_in_parallel() {
	hdr="$1"
	thread_count="$2"
	cmd_list=( "${@:3}" )

	if (( ${#cmd_list[@]} > 0 ))
	then
		header "${hdr}"
		#run the simulation in parallel
		echo "${cmd_list[@]}" | xargs -n1 | sort | xargs -P"${thread_count}" -I{} "${SHELL}" -c '$(cat {})'
	fi
}

function move_vector() {
	file_dir="$1"
	file_name="$2"
	replacement_suffix="$3"

	find_in_bench  "${file_dir}" "${file_name}" 
	# move the output vectors
	for sim_vectors in "${TMP_BENCH_FIND_ARRAY[@]}"
	do
		[ -d "${file_dir}/vectors" ] || mkdir -p "${file_dir}/vectors"
		BM_DIR=$(dirname "${sim_vectors}")
		BM_NAME="$(basename "$(readlink -f "${BM_DIR}/..")")${replacement_suffix}"

		cp "${sim_vectors}" "${file_dir}/vectors/${BM_NAME}"
		mv "${sim_vectors}" "${BM_DIR}/${BM_NAME}"

	done
}

function sim() {

	benchmark_dir="$1"

	###########################################
	# find the benchmark
	if [ "_${benchmark_dir}" == "_" ] || [ ! -d "${benchmark_dir}" ]
	then
		echo "invalid benchmark directory parameter passed: ${benchmark_dir}"
		_exit_with_code "-1"
	elif [ ! -f "${benchmark_dir}/task.conf" ]
	then
		echo "invalid benchmark directory parameter passed: ${benchmark_dir}, contains no task.conf file, see CONFIG_HELP in --help"
		_exit_with_code "-1"
	fi

	benchmark_dir=$(readlink -f "${benchmark_dir}")
	bench_name=$(basename "${benchmark_dir}")
	##########################################
	# check if we only run some subtask
	run_subtest_only=""
	if [ "_${_SUBTEST_LIST[*]}" != "_" ];
	then
		run_subtest_only="--subset"
	fi


	echo "Task is: ${bench_name}"

	##########################################
	# setup the parameters

	init_args_for_test
	populate_arg_from_file "${benchmark_dir}/task.conf"

	##########################################
	# use the overrides from the user
	if [ "_${_EXTRA_CONFIG}" != "_" ]
	then
		_EXTRA_CONFIG=$(readlink -f "${_EXTRA_CONFIG}")
		if [ ! -f "${_EXTRA_CONFIG}" ]
		then
			echo "Passed in an invalid global configuration file ${_EXTRA_CONFIG}"
			_exit_with_code "-1"
		else
			populate_arg_from_file "${_EXTRA_CONFIG}"
		fi
	fi

	####################################
	# parse the function commands passed
	_threads=${_NUMBER_OF_PROCESS}
	_generate_bench="${_GENERATE_BENCH}"
	_generate_output="${_GENERATE_OUTPUT}"
	_concat_circuit_list="off"
	_synthesis="on"
    _techmap="off"
	_simulation="on"
	_verbose_failures="off"
	_disable_color=""

	##########################################
	# populate the wrapper command using the configs
	for _regression_param in ${_regression_params}
	do
		case ${_regression_param} in

			--concat_circuit_list)
				_concat_circuit_list="on"
				;;

			--generate_bench)
				echo "This test will have the input and output regenerated"
				_generate_bench="on"
				;;

			--generate_output)
				echo "This test will have the output regenerated"
				_generate_output="on"
				;;

            --enable_techmap)
				echo "This test will only be technology mapped"
				_techmap="on"
				_synthesis="off"
				;;

			--disable_simulation)
				echo "This test will not be simulated"
				if [ "_${_FORCE_SIM}" == "_on" ]
				then
					echo "WARNING: This test will be forcefully simulated, unexpected results may occur"
					_simulation="on"
				else
					_simulation="off"
				fi
				;;
			--no_color)
				_disable_color="${_regression_param}"
				;;

			--verbose)
				_verbose_failures="on"
				;;

			--disable_parallel_jobs)
				echo "This test will not be multithreaded"
				_threads="1"
				;;

			--include_default_arch)
				_arch_list+=( "no_arch" )
				;;

			*)
				echo "Unknown internal parameter passed: ${_regression_param}, see CONFIG_HELP in --help"
				_exit_with_code "-1"
				;;
		esac
	done

	##########################################
	# setup defaults

	# synthesis
	synthesis_failure_name="synthesis_failures"
	synthesis_parse_result_file_name="synthesis_result.json"
	synthesis_params_file_name="synthesis_params"
	synthesis_wrapper_file_name="synthesis_wrapper_params"
	synthesis_log_file_name="synthesis.log"

	synthesis_failure="${NEW_RUN_DIR}/${bench_name}/${synthesis_failure_name}"
	synthesis_golden_result_file="${benchmark_dir}/${synthesis_parse_result_file_name}"
	synthesis_failure_log_file="${synthesis_failure}.log"
	synthesis_result_failure_log_file="${synthesis_failure}_result.log"

    # techmap
    techmap_pass="true"
	techmap_failure_name="techmap_failures"
	techmap_parse_result_file_name="techmap_result.json"
	techmap_params_file_name="techmap_params"
	techmap_wrapper_file_name="techmap_wrapper_params"
	techmap_log_file_name="techmap.log"

	techmap_failure="${NEW_RUN_DIR}/${bench_name}/${techmap_failure_name}"
	techmap_golden_result_file="${benchmark_dir}/${techmap_parse_result_file_name}"
	techmap_failure_log_file="${techmap_failure}.log"
	techmap_result_failure_log_file="${techmap_failure}_result.log"

    # simulation
	simulation_failure_name="simulation_failures"
	simulation_parse_result_file_name="simulation_result.json"
	simulation_params_file_name="simulation_params"
	simulation_wrapper_generate_io_file_name="simulation_wrapper_generate_io_params"
	simulation_wrapper_generate_output_file_name="simulation_wrapper_generate_output_params"
	simulation_wrapper_predefined_io_file_name="simulation_wrapper_predefined_io_params"
	simulation_log_file_name="simulation.log"

	simulation_failure="${NEW_RUN_DIR}/${bench_name}/${simulation_failure_name}"
	simulation_golden_result_file="${benchmark_dir}/${simulation_parse_result_file_name}"
	simulation_failure_log_file="${simulation_failure}.log"
	simulation_result_failure_log_file="${simulation_failure}_result.log"


	circuit_list_temp=""
	if [ ${_concat_circuit_list} == "on" ]
	then
		circuit_list_temp="${_circuit_list[*]}"
		_circuit_list=( "${bench_name}" )
	fi

	for circuit in "${_circuit_list[@]}"
	do
		circuits_dir=$(dirname "${circuit}")
		circuit_file=$(basename "${circuit}")
		input_file=""
        generated_blif_file=""

		case "${circuit_file}" in
			*.blif)
                # disable synthesis for blif files
                _synthesis="off"
                case "${circuit_file}" in
                    # disable techmap for generated blif files
                    *_generated.blif)
                    techmap_pass="false"
                ;;
                *)
                    input_file="${circuit}"
                    techmap_pass="true"
                ;;
                esac
			;;
			*)
				_synthesis="on"
				if [ ${_concat_circuit_list} == "on" ]
				then
					input_file="${circuit_list_temp}"
				else
					input_file="${circuit}"
				fi
			;;
		esac
		circuit_name="${circuit_file%.*}"


        # check if elaborator is yosys, then look up for Yosys sim vectors
        if [[ "$_synthesis_params" == *"$ELABORATOR_YOSYS"* ]]; then
            # lookup for input and output vector files to do comparison
            input_vector_file="${circuits_dir}/${circuit_name}_yosys_input"
            output_vector_file="${circuits_dir}/${circuit_name}_yosys_output"

        # otherwise, Odin-II vectors should be retrieved
        else
            # lookup for input and output vector files to do comparison
            input_vector_file="${circuits_dir}/${circuit_name}_odin_input"
            output_vector_file="${circuits_dir}/${circuit_name}_odin_output"
        fi

		

		for arches in "${_arch_list[@]}"
		do
			arch_cmd=""
			if [ -e "${arches}" ]
			then
				arch_cmd="-a ${arches}"
			fi

			arch_name=$(basename "${arches%.*}")

			TEST_FULL_REF="${bench_name}/${circuit_name}/${arch_name}"

			run_this_test="on"

			if [ "_${_SUBTEST_LIST[*]}" != "_" ]
			then
				run_this_test="off"
				for subtest in "${_SUBTEST_LIST[@]}";
				do
					if echo "_${TEST_FULL_REF}" | grep -E "${subtest}" &> /dev/null
					then
						run_this_test="on"
						break;
					fi
				done
			fi

			if [ -d "${NEW_RUN_DIR}/${TEST_FULL_REF}" ]
			then
				# skip duplicate tests
				run_this_test="off"
			fi

			if [ "${run_this_test}" == "on" ];
			then

				DIR="${NEW_RUN_DIR}/${TEST_FULL_REF}"
				mkdir -p "$DIR"

				###############################
				# Synthesis
				if [ "${_synthesis}" == "on" ]
				then

					# if synthesis was on, we need to specify a blif output name
					generated_blif_file="${DIR}/${circuit_name}_generated.blif"

					wrapper_command="${WRAPPER_EXEC}
										${_disable_color}
										${_script_synthesis_params}
										--log_file ${DIR}/${synthesis_log_file_name}
										--test_name ${TEST_FULL_REF}
										--failure_log ${synthesis_failure_log_file}"

					if [ "_${_RANDOM_DRY_RUN}" == "_on" ] && [ "_0" == "_$(( RANDOM % 2 ))" ] \
					 || [ "_${_DRY_RUN}" == "_on" ]
					then
						wrapper_command="${wrapper_command}
											--dry_run $(( RANDOM % 2 ))"
					fi
					if [ "_${_synthesis_parse_file}" != "_" ]
					then
						wrapper_command="${wrapper_command}
											--parse ${_synthesis_parse_file} ${DIR}/${synthesis_parse_result_file_name}"
					fi

					wrapper_command="${wrapper_command}
										${DIR}/${synthesis_params_file_name}"

					synthesis_command="${ODIN_EXEC}
										${_synthesis_params}
										${arch_cmd}
										$(odin_file_type_arg ${input_file}) ${input_file}
										-o ${generated_blif_file}
										--sim_dir ${DIR}"

					_echo_args "${wrapper_command}"	\
						> "${DIR}/${synthesis_wrapper_file_name}"

					_echo_args "${synthesis_command}; echo \"Odin exited with code: \$?\";" \
						> "${DIR}/${synthesis_params_file_name}"

					chmod +x "${DIR}/${synthesis_params_file_name}"

				fi
                ###############################
				# Techmap
				if [ "${_techmap}" == "on" ] && [ "${techmap_pass}" == "true" ]
				then

					# specifying the outpur blif file name with postfix _techmap
					generated_blif_file="${DIR}/${circuit_name}_generated.blif"

					wrapper_command="${WRAPPER_EXEC}
										${_disable_color}
										${_script_techmap_params}
										--log_file ${DIR}/${techmap_log_file_name}
										--test_name ${TEST_FULL_REF}
										--failure_log ${techmap_failure_log_file}"

					if [ "_${_RANDOM_DRY_RUN}" == "_on" ] && [ "_0" == "_$(( RANDOM % 2 ))" ] \
					 || [ "_${_DRY_RUN}" == "_on" ]
					then
						wrapper_command="${wrapper_command}
											--dry_run $(( RANDOM % 2 ))"
					fi
					if [ "_${_techmap_parse_file}" != "_" ]
					then
						wrapper_command="${wrapper_command}
											--parse ${_techmap_parse_file} ${DIR}/${techmap_parse_result_file_name}"
					fi

					wrapper_command="${wrapper_command}
										${DIR}/${techmap_params_file_name}"


					techmap_command="${ODIN_EXEC}
										${_techmap_params}
										${arch_cmd}
										$(odin_file_type_arg ${input_file}) ${input_file}
										-o ${generated_blif_file}
										--sim_dir ${DIR}"

                    
					_echo_args "${wrapper_command}"	\
						> "${DIR}/${techmap_wrapper_file_name}"

					_echo_args "${techmap_command}; echo \"Odin exited with code: \$?\";" \
						> "${DIR}/${techmap_params_file_name}"

					chmod +x "${DIR}/${techmap_params_file_name}"

				fi
				###############################
				# Simulation
				if [ "${_simulation}" == "on" ]
				then
                    # specifying the outpur blif file name with postfix _techmap
					sim_blif_file="${DIR}/${circuit_name}_generated.blif"

					wrapper_command="${WRAPPER_EXEC}
											${_disable_color}
											${_script_simulation_params}
											--log_file ${DIR}/${simulation_log_file_name}
											--test_name ${TEST_FULL_REF}
											--failure_log ${simulation_failure_log_file}"
					if [ "_${_RANDOM_DRY_RUN}" == "_on" ] && [ "_0" == "_$(( RANDOM % 2 ))" ] \
					 || [ "_${_DRY_RUN}" == "_on" ]
					then
						wrapper_command="${wrapper_command}
											--dry_run $(( RANDOM %2 ))"
					fi
					if [ "_${_simulation_parse_file}" != "_" ]
					then
						wrapper_command="${wrapper_command}
											--parse ${_simulation_parse_file} ${DIR}/${simulation_parse_result_file_name}"
					fi

					wrapper_command="${wrapper_command}
										${DIR}/${simulation_params_file_name}"

					simulation_command="${ODIN_EXEC}
											${_simulation_params}
											${arch_cmd}
											$(odin_file_type_arg ${sim_blif_file}) ${sim_blif_file}
											--sim_dir ${DIR} "

					simulation_wrapper_file_name="${simulation_wrapper_generate_io_file_name}"

					if [ "_${_generate_bench}" == "_off" ] \
					&& [ "_${_generate_output}" == "_off" ] \
					&& [ -f "${input_vector_file}" ] \
					&& [ -f "${output_vector_file}" ]
					then
						simulation_command="${simulation_command} -t ${input_vector_file} -T ${output_vector_file}"
						simulation_wrapper_file_name="${simulation_wrapper_predefined_io_file_name}"
					elif [ "_${_generate_bench}" == "_off" ] \
					&& [ -f "${input_vector_file}" ]
					then
						simulation_command="${simulation_command} -t ${input_vector_file}"
						simulation_wrapper_file_name="${simulation_wrapper_generate_output_file_name}"
					fi

					_echo_args "${wrapper_command}" \
						> "${DIR}/${simulation_wrapper_file_name}"

					_echo_args "${simulation_command}; echo \"Odin exited with code: \$?\";" \
						> "${DIR}/${simulation_params_file_name}"

					chmod +x "${DIR}/${simulation_params_file_name}"
				fi
			fi
		done
	done

	#synthesize the circuits


	find_in_bench "${NEW_RUN_DIR}/${bench_name}" "${synthesis_wrapper_file_name}"
	if [ "${_synthesis}" == "on" ]\
	&& (( ${#TMP_BENCH_FIND_ARRAY[@]} > 0 ))
	then
		run_cmd_file_in_parallel \
			"Synthesis Test" \
			"${_threads}" \
			"${TMP_BENCH_FIND_ARRAY[@]}"

		disable_failed_bm "${synthesis_failure}" "${bench_name}"

		sync

		if [ "_${_synthesis_parse_file}" != "_" ]
		then
			echo " -------- Parsing Synthesis Result --------- "
			find_in_bench "${NEW_RUN_DIR}/${bench_name}" "${synthesis_parse_result_file_name}"
			"${PARSER_EXEC}" join "${_disable_color}" \
				"${_synthesis_parse_file}" \
				"${TMP_BENCH_FIND_ARRAY[@]}" \
				> "${NEW_RUN_DIR}/${bench_name}/${synthesis_parse_result_file_name}"

			if [ "_${synthesis_golden_result_file}" != "_" ] \
			&& [ -f "${synthesis_golden_result_file}" ]
			then
				"${PARSER_EXEC}" compare "${run_subtest_only}" "${_disable_color}" \
					"${_synthesis_parse_file}" \
					"${synthesis_golden_result_file}" \
					"${NEW_RUN_DIR}/${bench_name}/${synthesis_parse_result_file_name}" \
					"${NEW_RUN_DIR}/${bench_name}/${synthesis_parse_result_file_name}.diff" \
						2> "${synthesis_result_failure_log_file}"
			fi

			if [ "_${_GENERATE_EXPECTATION}" == "_on" ]
			then
				if [ -f "${NEW_RUN_DIR}/${bench_name}/${synthesis_parse_result_file_name}" ];
				then
					cat "${NEW_RUN_DIR}/${bench_name}/${synthesis_parse_result_file_name}" \
						> "${synthesis_golden_result_file}"
				fi
			elif [ "_${_REGENERATE_EXPECTATION}" == "_on" ]
			then
				if [ -f "${NEW_RUN_DIR}/${bench_name}/${synthesis_parse_result_file_name}.diff" ];
				then
					cat "${NEW_RUN_DIR}/${bench_name}/${synthesis_parse_result_file_name}.diff" \
						> "${synthesis_golden_result_file}"
				elif [ -f "${NEW_RUN_DIR}/${bench_name}/${synthesis_parse_result_file_name}" ];
				then
					cat "${NEW_RUN_DIR}/${bench_name}/${synthesis_parse_result_file_name}" \
						> "${synthesis_golden_result_file}"
				fi
			fi
		fi

		error_log="${synthesis_failure_log_file}"
		if [ "_${synthesis_golden_result_file}" != "_" ]
		then
			error_log="${synthesis_result_failure_log_file}"
		fi

		if [ "_${error_log}" != "_" ] && [ -f "${error_log}" ]
		then
			cat "${error_log}" >> "${NEW_RUN_DIR}/${global_failure}"
		fi

		# display logs if verbosity is on
		if [ "_${_verbose_failures}" == "_on" ]
		then
			if [ "_${synthesis_failure_log_file}" != "_" ] \
			&& [ -f "${synthesis_failure_log_file}" ]
			then
				if [ "_${synthesis_result_failure_log_file}" != "_" ] \
				&& [ -f "${synthesis_result_failure_log_file}" ]
				then
					for test_failed in $(sort "${synthesis_failure_log_file}" "${synthesis_result_failure_log_file}" | uniq -d)
					do
						printf "\n\n\n ==== LOG %s ====\n\n" "${test_failed}"
						cat "${NEW_RUN_DIR}/${test_failed}/synthesis.log"
					done
					printf "\n\n"
				else
					for test_failed in $(sort "${synthesis_failure_log_file}" | uniq)
					do
						printf "\n\n\n ==== LOG %s ====\n\n" "${test_failed}"
						cat "${NEW_RUN_DIR}/${test_failed}/synthesis.log"
					done
					printf "\n\n"
				fi
			fi
		fi
	fi


    #techmap the circuits

	find_in_bench "${NEW_RUN_DIR}/${bench_name}" "${techmap_wrapper_file_name}"
	if [ "${_techmap}" == "on" ]\
	&& (( ${#TMP_BENCH_FIND_ARRAY[@]} > 0 ))
	then
		run_cmd_file_in_parallel \
			"Techmap Test" \
			"${_threads}" \
			"${TMP_BENCH_FIND_ARRAY[@]}"

		disable_failed_bm "${techmap_failure}" "${bench_name}"

		sync

		if [ "_${_techmap_parse_file}" != "_" ]
		then
			echo " -------- Parsing Techmap Result --------- "
			find_in_bench "${NEW_RUN_DIR}/${bench_name}" "${techmap_parse_result_file_name}"
			"${PARSER_EXEC}" join "${_disable_color}" \
				"${_techmap_parse_file}" \
				"${TMP_BENCH_FIND_ARRAY[@]}" \
				> "${NEW_RUN_DIR}/${bench_name}/${techmap_parse_result_file_name}"

			if [ "_${techmap_golden_result_file}" != "_" ] \
			&& [ -f "${techmap_golden_result_file}" ]
			then
				"${PARSER_EXEC}" compare "${run_subtest_only}" "${_disable_color}" \
					"${_techmap_parse_file}" \
					"${techmap_golden_result_file}" \
					"${NEW_RUN_DIR}/${bench_name}/${techmap_parse_result_file_name}" \
					"${NEW_RUN_DIR}/${bench_name}/${techmap_parse_result_file_name}.diff" \
						2> "${techmap_result_failure_log_file}"
			fi

			if [ "_${_GENERATE_EXPECTATION}" == "_on" ]
			then
				if [ -f "${NEW_RUN_DIR}/${bench_name}/${techmap_parse_result_file_name}" ];
				then
					cat "${NEW_RUN_DIR}/${bench_name}/${techmap_parse_result_file_name}" \
						> "${techmap_golden_result_file}"
				fi
			elif [ "_${_REGENERATE_EXPECTATION}" == "_on" ]
			then
				if [ -f "${NEW_RUN_DIR}/${bench_name}/${techmap_parse_result_file_name}.diff" ];
				then
					cat "${NEW_RUN_DIR}/${bench_name}/${techmap_parse_result_file_name}.diff" \
						> "${techmap_golden_result_file}"
				elif [ -f "${NEW_RUN_DIR}/${bench_name}/${techmap_parse_result_file_name}" ];
				then
					cat "${NEW_RUN_DIR}/${bench_name}/${techmap_parse_result_file_name}" \
						> "${techmap_golden_result_file}"
				fi
			fi
		fi

		error_log="${tehmap_failure_log_file}"
		if [ "_${techmap_golden_result_file}" != "_" ]
		then
			error_log="${techmap_result_failure_log_file}"
		fi

		if [ "_${error_log}" != "_" ] && [ -f "${error_log}" ]
		then
			cat "${error_log}" >> "${NEW_RUN_DIR}/${global_failure}"
		fi

		# display logs if verbosity is on
		if [ "_${_verbose_failures}" == "_on" ]
		then
			if [ "_${techmap_failure_log_file}" != "_" ] \
			&& [ -f "${techmap_failure_log_file}" ]
			then
				if [ "_${techmap_result_failure_log_file}" != "_" ] \
				&& [ -f "${techmap_result_failure_log_file}" ]
				then
					for test_failed in $(sort "${techmap_failure_log_file}" "${techmap_result_failure_log_file}" | uniq -d)
					do
						printf "\n\n\n ==== LOG %s ====\n\n" "${test_failed}"
						cat "${NEW_RUN_DIR}/${test_failed}/techmap.log"
					done
					printf "\n\n"
				else
					for test_failed in $(sort "${techmap_failure_log_file}" | uniq)
					do
						printf "\n\n\n ==== LOG %s ====\n\n" "${test_failed}"
						cat "${NEW_RUN_DIR}/${test_failed}/techmap.log"
					done
					printf "\n\n"
				fi
			fi
		fi
	fi


	find_in_bench "${NEW_RUN_DIR}/${bench_name}" "${simulation_wrapper_generate_io_file_name}"
	simulation_gio_bench_list=( "${TMP_BENCH_FIND_ARRAY[@]}" )

	find_in_bench "${NEW_RUN_DIR}/${bench_name}" "${simulation_wrapper_generate_output_file_name}"
	simulation_go_bench_list=( "${TMP_BENCH_FIND_ARRAY[@]}" )

	find_in_bench "${NEW_RUN_DIR}/${bench_name}" "${simulation_wrapper_predefined_io_file_name}"
	simulation_bench_list=( "${TMP_BENCH_FIND_ARRAY[@]}" )

	sim_total="$(( ${#simulation_gio_bench_list[@]} + ${#simulation_go_bench_list[@]} + ${#simulation_bench_list[@]} ))"
	if (( sim_total > 0 )) \
	&& [ "${_simulation}" == "on" ]
	then
		run_cmd_file_in_parallel \
			"Generate_IO_Simulation Test" \
			"${_threads}" \
			"${simulation_gio_bench_list[@]}"

		run_cmd_file_in_parallel \
			"Generate_Output_Simulation Test" \
			"${_threads}" \
			"${simulation_go_bench_list[@]}"

		run_cmd_file_in_parallel \
			"Predefined_IO_Simulation Test" \
			"${_threads}" \
			"${simulation_bench_list[@]}"

		disable_failed_bm "${simulation_failure}" "${bench_name}"
		move_vector "${NEW_RUN_DIR}/${bench_name}" "input_vectors" "_input"
		move_vector "${NEW_RUN_DIR}/${bench_name}" "output_vectors" "_output"

		sync

		if [ "_${_simulation_parse_file}" != "_" ]
		then
			echo " -------- Parsing Simulation Result --------- "
			find_in_bench "${NEW_RUN_DIR}/${bench_name}" "${simulation_parse_result_file_name}"
			"${PARSER_EXEC}" join "${_disable_color}" \
				"${_simulation_parse_file}" \
				"${TMP_BENCH_FIND_ARRAY[@]}" \
					> "${NEW_RUN_DIR}/${bench_name}/${simulation_parse_result_file_name}"


			if [ "_${simulation_golden_result_file}" != "_" ] \
			&& [ -f "${simulation_golden_result_file}" ]
			then
				"${PARSER_EXEC}" compare "${run_subtest_only}" "${_disable_color}" \
					"${_simulation_parse_file}" \
					"${simulation_golden_result_file}" \
					"${NEW_RUN_DIR}/${bench_name}/${simulation_parse_result_file_name}" \
					"${NEW_RUN_DIR}/${bench_name}/diff_${simulation_parse_result_file_name}" \
						2> "${simulation_result_failure_log_file}"
			fi

			if [ "_${_GENERATE_EXPECTATION}" == "_on" ]
			then
				if [ -f "${NEW_RUN_DIR}/${bench_name}/${simulation_parse_result_file_name}" ];
				then
					cat "${NEW_RUN_DIR}/${bench_name}/${simulation_parse_result_file_name}" \
						> "${simulation_golden_result_file}"
				fi
			elif [ "_${_REGENERATE_EXPECTATION}" == "_on" ]
			then
				if [ -f "${NEW_RUN_DIR}/${bench_name}/diff_${simulation_parse_result_file_name}" ];
				then
					cat "${NEW_RUN_DIR}/${bench_name}/diff_${simulation_parse_result_file_name}" \
						> "${simulation_golden_result_file}"
				elif [ -f "${NEW_RUN_DIR}/${bench_name}/${simulation_parse_result_file_name}" ];
				then
					cat "${NEW_RUN_DIR}/${bench_name}/${simulation_parse_result_file_name}" \
						> "${simulation_golden_result_file}"
				fi
			fi
		fi

		error_log="${simulation_failure_log_file}"
		if [ "_${synthesis_golden_result_file}" != "_" ]
		then
			error_log="${simulation_result_failure_log_file}"
		fi

		if [ "_${error_log}" != "_" ] && [ -f "${error_log}" ]
		then
			cat "${error_log}" >> "${NEW_RUN_DIR}/${global_failure}"
		fi

		# display logs if verbosity is on
		if [ "_${_verbose_failures}" == "_on" ]
		then
			if [ "_${simulation_failure_log_file}" != "_" ] \
			&& [ -f "${simulation_failure_log_file}" ]
			then
				if [ "_${simulation_result_failure_log_file}" != "_" ] \
				&& [ -f "${simulation_result_failure_log_file}" ]
				then
					for test_failed in $(sort "${simulation_failure_log_file}" "${simulation_result_failure_log_file}" | uniq -d)
					do
						printf "\n\n\n ==== LOG %s ====\n\n" "${test_failed}"
						cat "${NEW_RUN_DIR}/${test_failed}/simulation.log"
					done
					printf "\n\n"
				else
					for test_failed in $(sort "${simulation_failure_log_file}" | uniq)
					do
						printf "\n\n\n ==== LOG %s ====\n\n" "${test_failed}"
						cat "${NEW_RUN_DIR}/${test_failed}/simulation.log"
					done
					printf "\n\n"
				fi
			fi
		fi
	fi
}

function run_task() {
	test_dir="$1"

	if [ ! -d "${test_dir}" ]
	then
		echo "${test_dir} Not Found! Skipping this test"
	elif [ ! -f "${test_dir}/task.conf" ] 
	then
		if [ ${_GENERATE_CONFIG} == "on" ]
		then
			new_test_dir="${BENCHMARK_DIR}/task/generated_$(basename "${test_dir}")"
			echo "generating config file for ${test_dir} @ ${new_test_dir}"
			mkdir -p "${new_test_dir}"
			echo_bm_conf "${test_dir}" > "${new_test_dir}/task.conf"
		else
			echo "no config file found in the directory ${test_dir}"
			echo "please make sure a .conf file exist, you can use '--build_config' to generate one, see CONFIG_HELP in --help"
		fi
	else
		create_temp
		sim "${test_dir}"
	fi
}

FILTERED_VTR_TASK_PATH="${NEW_RUN_DIR}/vtr/task_list.txt"
function run_vtr_reg() {
	pushd "${VTR_DIR}"  &> /dev/null
	RELATIVE_PATH_TO_TEST=$(realapath_from "${FILTERED_VTR_TASK_PATH}" "${VTR_REG_DIR}")
	/usr/bin/env perl run_reg_test.py -j "${_NUMBER_OF_PROCESS}" $(dirname ${RELATIVE_PATH_TO_TEST})
    if [ _"$?" != "_0" ]; then
        _exit_with_code "-1"
    fi
	popd  &> /dev/null
}

##########################
# This function filters vtr test to only contain
# tests using verilog files since Odin is unused 
# in blif tests
function filter_vtr_test() {
	# filter test prefix i.e vtr::
	VTR_TEST_NAME="${1/${VTR_REG_PREFIX}/}"
	VTR_TASK_PATH="${VTR_REG_DIR}/${VTR_TEST_NAME}/task_list.txt"

	if [ ! -f "${VTR_TASK_PATH}" ]
	then
		echo "${VTR_TASK_PATH} does not exist, skipping test $1"
	else
		mkdir -p $(dirname ${FILTERED_VTR_TASK_PATH})

		pushd "${VTR_REG_DIR}"  &> /dev/null
		for test in $(cat "${VTR_TASK_PATH}")
		do 
			if grep -E "circuit_list_add=.*\.v" "${VTR_REG_DIR/regression_tests}${test}/config/config.txt" &> "/dev/null"
			then 
				echo $test >> "${FILTERED_VTR_TASK_PATH}"; 
			fi
		done
		popd &> /dev/null
	fi
}

function run_rtl_reg() {
	pushd "${VTR_DIR}/libs/librtlnumber"  &> /dev/null
	./verify_librtlnumber.sh
	popd  &> /dev/null
}

function build_test() {
	pushd "$1"  &> /dev/null
	make -f task.mk build
	popd  &> /dev/null
}

task_list=()
vtr_reg="off"
rtl_lib_test="off"


function run_suite() {
	current_test_list=( "${_TEST_INPUT_LIST[@]}" )
	while [ "_${current_test_list[*]}" != "_" ]
	do
		current_input="${current_test_list[0]}"
		current_test_list=( "${current_test_list[@]:1}" )

		case "_${current_input}" in
			_);;
			_${VTR_REG_PREFIX}*)
				vtr_reg="on"
				filter_vtr_test "${current_input}"
				;;
			_${RTL_REG_PREFIX})
				rtl_lib_test="on"
				;;
			*)
				# try globbing
				current_input_list=( ${current_input} )
				if [ ! -d "${current_input_list[0]}" ]
				then
					# try globbing with absolute
					current_input_list=( "${THIS_DIR}/"${current_input} )
				fi
				# bash expand when possible
				for possible_test in "${current_input_list[@]}"
				do
					if [ ! -d "${possible_test}" ]
					then
						echo "no such Directory for task: ${possible_test}"
					else
						# build test when necessary
						if [ -f "${possible_test}/task.mk" ]
						then
							build_test "${possible_test}"
						fi

						if [ -f "${possible_test}/task_list.conf" ]
						then
							mapfile -t test_list <"${possible_test}/task_list.conf"
							current_test_list+=( "${test_list[@]}" )
							_TEST_INPUT_LIST+=( "${test_list[@]}" )
						elif [ -f "${possible_test}/task.conf" ]
						then
							task_list+=( "${possible_test}" )
						else
							echo "Invalid Directory for task: ${possible_test}"
						fi
					fi
				done
				;;
		esac
	done

	TEST_COUNT="0"

	if [ "_${rtl_lib_test}" == "_on" ];
	then
		run_rtl_reg
		TEST_COUNT=$(( TEST_COUNT + 1 ))
	fi

	for (( i = 0; i < ${#task_list[@]}; i++ ));
	do
         # check if blif generting flags are active
        if [ "_${_GENERATE_BLIF}" == "_on" ] || [ "_${_REGENERATE_BLIF}" == "_on" ]; then
            generate_blifs "${task_list[$i]}"
        fi
        run_task "${task_list[$i]}"
		TEST_COUNT=$(( TEST_COUNT + 1 ))
	done

	if [ "_${vtr_reg}" == "_on" ];
	then
		run_vtr_reg
		TEST_COUNT=$(( TEST_COUNT + 1 ))
	fi

	if [ "_${TEST_COUNT}" == "_0" ];
	then
		echo "No test is passed in must pass a test directory containing either a task_list.conf or a task.conf, see --help"
		_exit_with_code "-1"
	fi
}
#########################################################
#	START HERE

START=$(get_current_time)

parse_args "$@"

init_temp

if [ "${_STATUS_ONLY}" == "off" ]
then
	if [ ! -x "${ODIN_EXEC}" ]
	then
		echo "Unable to find ${ODIN_EXEC}"
		_exit_with_code "-1"
	fi

	if [ ! -x "${WRAPPER_EXEC}" ]
	then
		echo "Unable to find ${WRAPPER_EXEC}"
		_exit_with_code "-1"
	fi

	echo "Task: ${_TEST_INPUT_LIST[*]}"

	run_suite

	print_time_since "${START}"
fi

exit_program
### end here
