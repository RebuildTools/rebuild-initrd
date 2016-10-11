#!/bin/bash
#
# Rebuild Agent - Build Script
# ============================
#
# This rebuild script is a simple
# way of building the Rebuild Agent
# without having to manually run every
# command required to produce the final
# ramdisk
#
# Author: Liam Haworth <liam@haworth.id.au>
#

#####
## Load dependencies and define global variables
#####
. initrd_src/lib/rebuild/functions

pushd `dirname $0` > /dev/null
SCRIPTPATH=`pwd`
popd > /dev/null

## Global
[ -z "${OUTPUT_DIR}" ] && OUTPUT_DIRECTORY=${SCRIPTPATH}/output
[ -z "${TEMP_DIR}" ] && TEMP_DIR=/tmp/rebuild_agent_tmp

## Task: packageInitrd
[ -z "${INITRD_SRC}" ] && INITRD_SRC=${SCRIPTPATH}/initrd_src

## Task: buildAgent
[ -z "${INITRD_AGENT_SRC}" ] && INITRD_AGENT_SRC=${SCRIPTPATH}/agent_src

## Task prepareBuild
#// Dependency format: DEPENDENCY_NAME = SOURCE_URL % VERSION % DOWNLOAD_TYPE % BUILD_METHOD % CONFIGURE_FLAGS
INITRD_DEPENDENCIES=(\
	"glibc       = https://ftp.gnu.org/gnu/glibc/glibc-2.24.tar.gz % glibc-2.24 % tar_gz % configure_subdir_noflags % --disable-sanity-checks"\
	"libevent    = https://github.com/libevent/libevent % master % git % autogen_configure"\
	"coreutils   = http://git.savannah.gnu.org/cgit/coreutils.git % v8.25 % git % bootstrap_configure"\
	"bash        = http://git.savannah.gnu.org/cgit/bash.git % bash-4.4 % git % configure"\ 
	"dhcp        = https://github.com/marschap/debian-isc-dhcp % upstream % git % configure"\
	"iproute2    = git://git.kernel.org/pub/scm/linux/kernel/git/shemminger/iproute2.git % v4.4.0 % git % configure"\
	"ncurses     = https://ftp.gnu.org/pub/gnu/ncurses/ncurses-6.0.tar.gz % ncurses-6.0 % tar_gz % configure"\
	"util-linux  = git://git.kernel.org/pub/scm/utils/util-linux/util-linux.git % stable/v2.28 % git % autogen_configure % --disable-makeinstall-chown"\
	"gawk        = http://git.savannah.gnu.org/cgit/gawk.git % gawk-4.1.4 % git % configure" \
	"grep        = http://git.savannah.gnu.org/r/grep.git % v2.26 % git % bootstrap_configure" \
	"tmux        = https://github.com/tmux/tmux.git % 2.3 % git % autogen_configure" \
)

## Task: buildKernel
KERNEL_SRC_GIT="https://github.com/torvalds/linux.git"
KERNEL_TMP_DIR=${TEMP_DIR}/linux_kernel
[ -z "${KERNEL_BUILD_CONFIG}" ] && KERNEL_BUILD_CONFIG=${SCRIPTPATH}/linux-kernel.config
[ -z "${KERNEL_VERSION_TAG}" ] && KERNEL_VERSION_TAG="v4.8"

#####
## Script Helper Functions
#####

#// Checks if the provided name
#// is a delcared function in this
#// script.
#//
#// PARAMS:
#//   $1 String - The name of the function
#//
#// RETURNS: Boolean - Returns true if the function is declared
isAFunction() {
	type $1 2>&1 | grep "is a function" 1>/dev/null 2>&1
}

#// Checks if the provided name
#// is an executable binary in
#// the systems path.
#//
#// PARAMS:
#//   $1 String - The name of the binary
#//
#// RETURNS:  Boolean - Returns true if the binary exists
binaryExists() {
	if hash $1 2>/dev/null; then
		return 0
	else
		return 1
	fi
}

#// Leverages #binaryExists to check
#// for a binary but adds debug logging
#// and error throwing (If the binary doesn't
#// exist).
#//
#// PARAMS:
#//   $1 String - The name of the binary
checkForBinary() {
	logDebug "Checking for [${1}] binary"

	if binaryExists "${1}"; then
		return 0
	else
		logFatal "The binary [${1}] doesn't exist, please install it!"
	fi
}

#// Counts the number of CPU cores
#// available on the machine this
#// script is run on
getCpuCount() {
	 cat /proc/cpuinfo | awk '/^processor/{print $3}' | wc -l
}

#// Looks up and copies shared
#// objects (a.k.a libraries) for
#// binaries into a specified root
#// under the same folder structure.
#//
#// PARAMS:
#//   $1 String - Path to binary or path to folder to search for executables
#//   $2 String - The "root" under which the libraries should be copied to
copyShareObjects() {
    [ ! -d $2 ] && logFatal "The root given [${2}] isn't a directory!"

    if [ -f $1 ]; then
        for sharedLibrary in $(ldd $1 | awk '/=> \//{print $3}; /ld-linux/{print $1}'); do
            logDebug "Copying library [${sharedLibrary}] for [${1}]"
            mkdir -p ${2}$(dirname ${sharedLibrary})
            \cp -f ${sharedLibrary} ${2}$(dirname ${sharedLibrary})/
        done
    elif [ -d $1 ]; then
        for sharedLibrary in $(for binFile in $(find ${2} -executable -type f); do ldd ${binFile}; done | awk '/=> \//{print $3}; /ld-linux/{print $1}' | sort -u); do
            logDebug "Copying library [${sharedLibrary}]"
            mkdir -p ${2}$(dirname ${sharedLibrary})
            \cp -f ${sharedLibrary} ${2}$(dirname ${sharedLibrary})/
	    done
    fi
}

#// Runs a shell command and captures
#// stderr & stdout, once the command 
#// finishes running it checks the exit
#// code to see if the command exited with
#// errors (and if those errors are allowed)
#//
#// PARAMS:
#//   $1 String - The info box message to show while running the command
#//   $2 String - The command to run
#//   $3 String - (Optional) A comma seperated list of acceptable non-zero exit codes
runCmd() {
	logDebug "${1}"
        local cmd_output; cmd_output=$($2 2>&1)
        local cmd_exitcode=$?

        if [ ${cmd_exitcode} -gt 0 ]; then
                local isGoodCode=false

                if [ ! -z "${3}" ]; then
                        for allowedCode in $(echo "${3}" | sed 's/,/ /g'); do
                                [ ${allowedCode} == ${cmd_exitcode} ] && isGoodCode=true
                        done
                fi

                if ! ${isGoodCode}; then
                        logPanic "Command exited with a non-zero code [${cmd_exitcode}] when \"${1}\""
                        logPanic "Command run: ${2}"
                        logFatal "Command output:\n\n${cmd_output}"
                fi
        fi  
}

#####
## Script Tasks
#####

#// Compiles the Linux Kernel
#// from source with the Kernel
#// settings provided in directory
#// that holds this script
buildKernel() {
	logInfo "Building the Linux Kernel"

	checkForBinary "git"
	checkForBinary "make"
	
	[ -d ${KERNEL_TMP_DIR} ] && logWarn "Temporary build directory for kernel exists, clearing it" && rm -rf ${KERNEL_TMP_DIR}

	runCmd "Cloning Linux Kernel source" "git clone --branch ${KERNEL_VERSION_TAG} --depth 1 ${KERNEL_SRC_GIT} ${KERNEL_TMP_DIR}"

	logDebug "Copying kernel build config to source directory"
	\cp -f ${KERNEL_BUILD_CONFIG} ${KERNEL_TMP_DIR}/.config

	logDebug "Changing directory to source"
	cd ${KERNEL_TMP_DIR}

	local buildCoreUse=$(getCpuCount)
	runCmd "Compiling kernel with [${buildCoreUse}] CPUs" "make -j${buildCoreUse}"

	logDebug "Changing back to the previous directory"
	cd - >/dev/null

	logDebug "Checking for destination directory: ${OUTPUT_DIRECTORY}"
	[ ! -d ${OUTPUT_DIRECTORY} ] && logWarn "The output directory [${OUTPUT_DIRECTORY}] doesn't exist, making it" && mkdir -p ${OUTPUT_DIRECTORY}

	logDebug "Copying compiled kernel to output directory"
	\cp -f ${KERNEL_TMP_DIR}/arch/x86/boot/bzImage ${OUTPUT_DIRECTORY}/linux-kernel

	logInfo "Finished building the Linux Kernel, final output file: ${OUTPUT_DIRECTORY}/linux-kernel"
}

#// Prepares a build directory
#// for the initrd by setting up
#// a temporary directory and downloading
#// and building dependencies
prepareBuild() {
	logInfo "Preparing build directory for initrd with dependencies"

	## Check for required tools
	checkForBinary "cpio"
	checkForBinary "gzip"
	checkForBinary "gcc"
	checkForBinary "make"

    ## Setup the directory structure
	local BUILD_DIR=${TEMP_DIR}/initrd_build
	if [ -d ${BUILD_DIR} ]; then
		logWarn "Build directory exists, clearing it"
		rm -rf ${BUILD_DIR}
	fi 
	
	logDebug "Making temporary build directory"
	mkdir -p ${BUILD_DIR}
	
	local DEP_DIR=${TEMP_DIR}/initrd_dep
	if [ -d ${DEP_DIR} ]; then
		logWarn "Dependencies directory exists, clearing it"
		rm -rf ${DEP_DIR}
	fi
	
	logDebug "Making temporary dependencies directory"
	mkdir -p ${DEP_DIR}

	logDebug "Building directory structure"
	pushd ${BUILD_DIR} >/dev/null
	mkdir -p sys dev proc etc lib usr/lib/locale var/db
	[ ! -d bin ] && ln -s usr/bin bin
	[ ! -d sbin ] && ln -s usr/sbin sbin
	[ ! -d lib64 ] && ln -s lib lib64
	popd >/dev/null


	## Build required third-party binaries
	logDebug "Downloading and building dependencies"
	for depString in "${INITRD_DEPENDENCIES[@]}"; do
		local dep=$(echo ${depString} | awk '{split($0,a,"="); gsub(/ /, "", a[1]); print a[1]}')
		local depSource=$(echo ${depString} | awk '{split($0,b,"="); split(b[2],a,"%"); gsub(/ /, "", a[1]); print a[1]}')
		local depVersion=$(echo ${depString} | awk '{split($0,b,"="); split(b[2],a,"%"); gsub(/ /, "", a[2]); print a[2]}')
		local depDownloadMethod=$(echo ${depString} | awk '{split($0,b,"="); split(b[2],a,"%"); gsub(/ /, "", a[3]); print a[3]}')
		local depBuildMethod=$(echo ${depString} | awk '{split($0,b,"="); split(b[2],a,"%"); gsub(/ /, "", a[4]); print a[4]}')
		local depBuildConfigureFlags=$(echo ${depString} | awk '{split($0,b,"="); split(b[2],a,"%"); print a[5]}')

		logDebug "Downloading dependency [${dep} - ${depVersion}]"

		logDebug "Making temporary directory for dependency"
		mkdir -p ${DEP_DIR}/${dep}

		case ${depDownloadMethod} in
			git) 
				runCmd "Downloading dependency with GIT method" "git clone --branch ${depVersion} ${depSource} ${DEP_DIR}/${dep}"
			;;

			tar | tar_gz)
				mkdir -p ${DEP_DIR}/${dep}
				runCmd "Downloading dependency with ARCHIVE method" "wget -qO ${DEP_DIR}/${dep}-download ${depSource}"

				case ${depDownloadMethod} in
					tar) runCmd "Extracting GZiped tarball" "tar -xC ${DEP_DIR}/${dep} $([ ! -z "${depVersion}" ] && echo "--strip-components 1") -f ${DEP_DIR}/${dep}-download $([ ! -z "${depVersion}" ] && echo ${depVersion})";;
					tar_gz) runCmd "Extracting GZiped tarball" "tar -xzC ${DEP_DIR}/${dep} $([ ! -z "${depVersion}" ] && echo "--strip-components 1") -f ${DEP_DIR}/${dep}-download $([ ! -z "${depVersion}" ] && echo ${depVersion})";;
				esac
			;;
				

			*) logFatal "Unsupported download method [${depDownloadMethod}]";;
		esac

		case ${depBuildMethod} in
			*configure*)
				cd ${DEP_DIR}/${dep}
				local makeCores=$(getCpuCount)
				local configureCmd="./configure"

				[[ ${depBuildMethod} == *"subdir"* ]] && logDebug "Making sub directory for build" && mkdir -p ./rebuild_compile_dir && cd ./rebuild_compile_dir && configureCmd="../configure"
				[[ ${depBuildMethod} == *"bootstrap"* ]] && runCmd "Running \"bootstrap\" on dependency sources" "./bootstrap"
				[[ ${depBuildMethod} == *"autogen"* ]] && runCmd "Running \"autogen\" on dependency sources" "./autogen.sh"

				if [[ ${depBuildMethod} != *"noflags"* ]]; then
					export CFLAGS="-Wunused"
					export CPPFLAGS="-P"
				fi

				runCmd "Running \"configure\" on dependency sources" "${configureCmd} --prefix=/usr ${depBuildConfigureFlags}"
				runCmd "Making dependency" "make -j${makeCores}"
				runCmd "Installing compiled dependency" "make -j${makeCores} install DESTDIR=${BUILD_DIR}"

				unset CFLAGS
				unset CPPFLAGS
				cd - >/dev/null
			;;
		
			*) logFatal "Unsupported build method [${depBuildMethod}]";;
			#TODO Implement other methods for building 
		esac

	done

	## Copy dependant libraries for binaries
    copyShareObjects "${BUILD_DIR}" "${BUILD_DIR}"

	## Run final tasks on the file before packaging
	logDebug "Running post-build tasks on files"
	pushd ${BUILD_DIR} >/dev/null
	
	# Extract the UTF-8 character set definition
	gunzip usr/share/i18n/charmaps/UTF-8.gz

	# Remove un-required charmaps
	rm -f usr/share/i18n/charmaps/*.gz

	# Setup symlink for sh to bash
	cd bin
	ln -s bash sh
	cd - >/dev/null

	popd >/dev/null

	logInfo "Finished preparing build directory"
}

#// Compiles the go source
#// that makes the Rebuild Agent
#// and installs the binary and libraries
#// into the build directory
buildAgent() {
	logInfo "Building and installing Rebuild Agent"

    checkForBinary "go"
    checkForBinary "glide"

    logDebug "Checking for source files directory: ${INITRD_AGENT_SRC}"
	[ ! -d ${INITRD_AGENT_SRC} ] && logFatal "The provided source directory [${INITRD_AGENT_SRC}] doesn't exist!"

    local BUILD_DIR=${TEMP_DIR}/initrd_build
    logDebug "Checking for build directory: ${BUILD_DIR}"
	[ ! -d ${BUILD_DIR} ] && logFatal "The output directory [${BUILD_DIR}] doesn't exist, run \"prepareBuild\""

	pushd ${INITRD_AGENT_SRC} >/dev/null
	glide install
	go build -o ${BUILD_DIR}/bin/rebuild-agent rebuild-agent.go
	popd >/dev/null

    copyShareObjects "${BUILD_DIR}/bin/rebuild-agent" "${BUILD_DIR}"

    logInfo "Finished building and installing the Rebuild Agent"
}

#// Builds the final initrd from
#// all the files in the temporary
#// build directory.
packageInitrd() {
	logInfo "Packaging initrd from build directory"

	local BUILD_DIR=${TEMP_DIR}/initrd_build
    logDebug "Checking for build directory: ${BUILD_DIR}"
	[ ! -d ${BUILD_DIR} ] && logFatal "The output directory [${BUILD_DIR}] doesn't exist, run \"prepareBuild\""

	logDebug "Checking for source files directory: ${INITRD_SRC}"
	[ ! -d ${INITRD_SRC} ] && logFatal "The provided source directory [${INITRD_SRC}] doesn't exist!"

	logDebug "Checking for destination directory: ${OUTPUT_DIRECTORY}"
	[ ! -d ${OUTPUT_DIRECTORY} ] && logWarn "The output directory [${OUTPUT_DIRECTORY}] doesn't exist, making it" && mkdir -p ${OUTPUT_DIRECTORY}

	logDebug "Copying initrd sources into build directory" && \cp -rf ${INITRD_SRC}/* ${BUILD_DIR}

	logDebug "Changing directories into initrd build directory" && cd ${BUILD_DIR}

	logDebug "Build CPIO package and compressing to output file"
	find . ! -name '.gitkeep' | cpio -o -R 0:0 -H newc 2>/dev/null | gzip > ${OUTPUT_DIRECTORY}/initrd.gz
	
	logInfo "Finished packaging the RAM disk, final output file: ${OUTPUT_DIRECTORY}/initrd.gz"
}

#####
## Script Help Message
#####

#// Shows the helps message
#// for this build script
#//
#// RETURNS: String - The help message for this script
showHelp() {
	echo -e "Usage: ${0} [TASK ..]\n"

	echo "Rebuild Agent - Build Script"
	echo -e "============================\n"
	echo "This script provide tasks to help with"
	echo -e "compiling of the Rebuild Agent ram disk.\n\n"

	echo "Environment Variables:"

	echo -e "\t=== GLOBAL ==="	
	printf "\t%-20s - %s\n" "LOGLEVEL" "Sets the logging level of the build script (Default: 4 | 1 - PANIC, 2 - FATAL, 3 - WARN, 4 - INFO, 5 - DEBUG)"
	printf "\t%-20s - %s\n" "OUTPUT" "Defines the final output location for compiled/built files (Default: ${SCRIPTPATH}/output)"
	printf "\t%-20s - %s\n" "TEMP_DIR" "Defines the temporary directory the build script can use for storing source files while compiling (Default: /tmp/rebuild_agent_tmp)"

	printf "\n\t=== TASK: %-10s ===\n" "buildKernel"
	printf "\t%-20s - %s\n" "KERNEL_BUILD_CONFIG" "Defines the path to the Linux Kernel build config (Default: ${SCRIPTPATH}/linux-kernel.config)"
	printf "\t%-20s - %s\n" "KERNEL_VERSION_TAG" "Defines the git tag of desired Linux Kernel version (Default: v4.8)"

    printf "\n\t=== TASK: %-10s ===\n" "buildAgent"
	printf "\t%-20s - %s\n" "INITRD_AGENT_SRC" "Defines the location of the agent source files (Default: ${SCRIPTPATH}/agent_src)"

	printf "\n\t=== TASK: %-10s ===\n" "packageInitrd"
	printf "\t%-20s - %s\n" "INITRD_SRC" "Defines the location of the ram disk source files (Default: ${SCRIPTPATH}/initrd_src)"


	echo -e "\nTasks:"
	printf "\t%-20s - %s\n" "showHelp" "Shows this help message"
	printf "\t%-20s - %s\n" "buildKernel" "Downloads and compiles the Linux Kernel with the Rebuild Agent kernel configuration"
	printf "\t%-20s - %s\n" "prepareBuild" "Prepares a build directory and installs dependencies to it"
	printf "\t%-20s - %s\n" "buildAgent" "Compiles the Rebuild Agent sources and installs it into the build directory"
	printf "\t%-20s - %s\n" "packageInitrd" "Packages the ram disk sources into the final ram disk image"

	echo -e "\n\n"
}

#####
## Script Entry Point
#####

logDebug "Detecting my full path as: ${SCRIPTPATH}"

if [ $# == 0 ]; then
	showHelp
else
	logDebug "Checking if all tasks exist before executing"
	for task in $@; do
		logDebug "Checking for task [${task}]"
		if ! isAFunction "${task}"; then
			showHelp
			logFatal "No such task: ${task}"
		fi
	done

	logDebug "All tasks selected exist, running them!"
	logInfo "Starting Rebuild Agent Build Script"

	for task in $@; do
		logDebug "Running task [${task}]"
		${task}
	done

	logInfo "All tasks completed successfully!"
fi