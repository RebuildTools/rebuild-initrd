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
[ -z "${OUTPUT_DIR}" ] && OUTPUT_DIRECTORY=$SCRIPTPATH/output
[ -z "${TEMP_DIR}" ] && TEMP_DIR=/tmp/rebuild_agent_tmp

## Task: prepareStagingInitrd
GLIBC_SRC_GIT="git://sourceware.org/git/glibc.git"
GLIBC_TMP_DIR=$TEMP_DIR/glibc
[ -z "${STAGING_GLIBC_VER}" ] && STAGING_GLIBC_VER="glibc-2.24"
[ -z "${STAGING_DIR}" ] && STAGING_DIR=$SCRIPTPATH/initrd_staging

## Task: buildInitrd
[ -z "${INITRD_SRC}" ] && INITRD_SRC=$SCRIPTPATH/initrd_src

#// Dependency format: SOURCE_URL % VERSION % DOWNLOAD_TYPE % BUILD_METHOD % CONFIGURE_FLAGS
declare -A INITRD_DEPENDENCIES=(\
	[coreutils]="http://git.savannah.gnu.org/cgit/coreutils.git % v8.25 % git % bootstrap_configure"\
	[bash]="http://git.savannah.gnu.org/cgit/bash.git % bash-4.4 % git % configure"\ 
	[dhcp]="https://github.com/marschap/debian-isc-dhcp % upstream % git % configure"\
	[iproute2]="git://git.kernel.org/pub/scm/linux/kernel/git/shemminger/iproute2.git % v4.4.0 % git % configure"\
	[ncurses]="https://ftp.gnu.org/pub/gnu/ncurses/ncurses-6.0.tar.gz % ncurses-6.0 % tar_gz % configure"\
	[util-linux]="git://git.kernel.org/pub/scm/utils/util-linux/util-linux.git % stable/v2.28 % git % autogen_configure % --disable-makeinstall-chown"\
	[gawk]="http://git.savannah.gnu.org/cgit/gawk.git % gawk-4.1.4 % git % configure" \
	[grep]="http://git.savannah.gnu.org/r/grep.git % v2.26 % git % bootstrap_configure"
)

## Task: buildKernel
KERNEL_SRC_GIT="https://github.com/torvalds/linux.git"
KERNEL_TMP_DIR=$TEMP_DIR/linux_kernel
[ -z "${KERNEL_BUILD_CONFIG}" ] && KERNEL_BUILD_CONFIG=$SCRIPTPATH/linux-kernel.config
[ -z "${KERNEL_VERSION_TAG}" ] && KERNEL_VERSION_TAG="v4.8"

#####
## Script Helper Functions
#####

#// Checks if the provided name
#// is a delcared function in this
#// script.
#//
#// PARAMS:
#//   $1 - The name of the function
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
#//   $1 - The name of the binary
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
#//   $1 - The name of the binary
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

        if [ $cmd_exitcode -gt 0 ]; then
                local isGoodCode=false

                if [ ! -z "${3}" ]; then
                        for allowedCode in $(echo "${3}" | sed 's/,/ /g'); do
                                [ $allowedCode == $cmd_exitcode ] && isGoodCode=true
                        done
                fi

                if ! $isGoodCode; then
                        logPanic "Command exited with a non-zero code [$cmd_exitcode] when \"${1}\""
			logPanic "Command run: ${2}"
			logFatal "Command output:\n\n${cmd_output}"
                fi
        fi  
}

#####
## Script Tasks
#####

buildKernel() {
	logInfo "Building the Linux Kernel"

	checkForBinary "git"
	checkForBinary "make"
	
	[ -d $KERNEL_TMP_DIR ] && logWarn "Temporary build directory for kernel exists, clearing it" && rm -rf $KERNEL_TMP_DIR

	runCmd "Cloning Linux Kernel source" "git clone --branch ${KERNEL_VERSION_TAG} --depth 1 ${KERNEL_SRC_GIT} ${KERNEL_TMP_DIR}"

	logDebug "Copying kernel build config to source directory"
	\cp -f $KERNEL_BUILD_CONFIG $KERNEL_TMP_DIR/.config

	logDebug "Changing directory to source"
	cd $KERNEL_TMP_DIR

	local buildCoreUse=$(getCpuCount)
	runCmd "Compiling kernel with [${buildCoreUse}] CPUs" "make -j${buildCoreUse}"

	logDebug "Changing back to the previous directory"
	cd - >/dev/null

	logDebug "Checking for destination directory: ${OUTPUT_DIRECTORY}"
	[ ! -d $OUTPUT_DIRECTORY ] && logWarn "The output directory [${OUTPUT_DIRECTORY}] doesn't exist, making it" && mkdir -p ${OUTPUT_DIRECTORY}

	logDebug "Copying compiled kernel to output directory"
	\cp -f $KERNEL_TMP_DIR/arch/x86/boot/bzImage $OUTPUT_DIRECTORY/linux-kernel

	logInfo "Finished building the Linux Kernel, final output file: ${OUTPUT_DIRECTORY}/linux-kernel"
}

#// Packages the intird source into
#// gzip compressed CPIO archive that
#// can be unpacked and executed by the
#// Linux Kernel
buildInitrd() {
	logInfo "Building RAM disk image"

	## Check for required tools
	checkForBinary "cpio"
	checkForBinary "gzip"
	checkForBinary "gcc"
	checkForBinary "make"


	## Check and build directories
	logDebug "Checking for source files directory: ${INITRD_SRC}"
	[ ! -d $INITRD_SRC ] && logFatal "The provided source directory [${INITRD_SRC}] doesn't exist!"

	logDebug "Checking for destination directory: ${OUTPUT_DIRECTORY}"
	[ ! -d $OUTPUT_DIRECTORY ] && logWarn "The output directory [${OUTPUT_DIRECTORY}] doesn't exist, making it" && mkdir -p ${OUTPUT_DIRECTORY}

	local BUILD_DIR=$TEMP_DIR/initrd_build
	if [ -d $BUILD_DIR ]; then
		logWarn "Build directory exists, clearing it"
		rm -rf $BUILD_DIR
	fi 
	
	logDebug "Making temporary build directory"
	mkdir -p $BUILD_DIR
	
	local DEP_DIR=$TEMP_DIR/initrd_dep
	if [ -d $DEP_DIR ]; then
		logWarn "Dependencies directory exists, clearing it"
		rm -rf $DEP_DIR
	fi
	
	logDebug "Making temporary dependencies directory"
	mkdir -p $DEP_DIR

	logDebug "Building directory structure"
	pushd $BUILD_DIR >/dev/null
	mkdir -p {sys,dev,proc,etc,lib,usr/local/bin}
	[ ! -d sbin ] && ln -s usr/local/bin bin
	[ ! -d sbin ] && ln -s usr/local/sbin sbin
	[ ! -d lib64 ] && ln -s lib lib64
	popd >/dev/null


	## Build required third-party binaries
	logDebug "Downloading and building dependencies"
	for dep in ${!INITRD_DEPENDENCIES[@]}; do
		local depString=${INITRD_DEPENDENCIES[$dep]}
		local depSource=$(echo $depString | awk '{split($0,a,"%"); gsub(/ /, "", a[1]); print a[1]}')
		local depVersion=$(echo $depString | awk '{split($0,a,"%"); gsub(/ /, "", a[2]); print a[2]}')
		local depDownloadMethod=$(echo $depString | awk '{split($0,a,"%"); gsub(/ /, "", a[3]); print a[3]}')
		local depBuildMethod=$(echo $depString | awk '{split($0,a,"%"); gsub(/ /, "", a[4]); print a[4]}')
		local depBuildConfigureFlags=$(echo $depString | awk '{split($0,a,"%"); print a[5]}')

		logDebug "Downloading dependency [${dep} - ${depVersion}]"

		logDebug "Making temporary directory for dependency"
		mkdir -p $DEP_DIR/$dep

		case $depDownloadMethod in
			git) 
				runCmd "Downloading dependency with GIT method" "git clone --branch ${depVersion} ${depSource} ${DEP_DIR}/${dep}"
			;;

			tar | tar_gz)
				mkdir -p ${DEP_DIR}/${dep}
				runCmd "Downloading dependency with ARCHIVE method" "wget -qO ${DEP_DIR}/${dep}-download ${depSource}"

				case $depDownloadMethod in
					tar) runCmd "Extracting GZiped tarball" "tar -xC ${DEP_DIR}/${dep} $([ ! -z "${depVersion}" ] && echo "--strip-components 1") -f ${DEP_DIR}/${dep}-download $([ ! -z "${depVersion}" ] && echo $depVersion)";;
					tar_gz) runCmd "Extracting GZiped tarball" "tar -xzC ${DEP_DIR}/${dep} $([ ! -z "${depVersion}" ] && echo "--strip-components 1") -f ${DEP_DIR}/${dep}-download $([ ! -z "${depVersion}" ] && echo $depVersion)";;
				esac
			;;
				

			*) logFatal "Unsupport download method [${depDownloadMethod}]";;
		esac

		case $depBuildMethod in
			configure | bootstrap_configure | autogen_configure)
				cd ${TEMP_DIR}/initrd_dep/${dep}
				local makeCores=$(getCpuCount)

				[ "${depBuildMethod}" == "bootstrap_configure" ] && runCmd "Running \"bootstrap\" on dependancy sources" "./bootstrap"
				[ "${depBuildMethod}" == "autogen_configure" ] && runCmd "Running \"autogen\" on dependancy sources" "./autogen.sh"

				export CFLAGS="-Wunused"
				export CPPFLAGS="-P"
				runCmd "Running \"configure\" on dependancy sources" "./configure ${depBuildConfigureFlags}"
				runCmd "Making dependancy" "make -j${makeCores}"
				runCmd "Installing compiled dependancy" "make -j ${makeCores} install DESTDIR=${BUILD_DIR}"
			;;
		
			*) logFatal "Unsupported build method [${depbuildMethod}]";;	
			#TODO Implement other methods for building 
		esac

	done

	## Copy dependant libraries for binaries
	for sharedLibrary in $(for binFile in $(find $BUILD_DIR -executable -type f); do ldd $binFile; done | awk '/=> \//{print $3}; /ld-linux/{print $1}' | sort -u); do
		logDebug "Copying library [${sharedLibrary}]"
		mkdir -p $BUILD_DIR$(dirname $sharedLibrary)
		\cp -f $sharedLibrary $BUILD_DIR$(dirname $sharedLibrary)/
	done

	## Copy Rebuild Agent initrd sources into build directory
	logDebug "Copying initrd sources into build directory" && \cp -rf $INITRD_SRC/* $BUILD_DIR

	## Package initrd
	logDebug "Changing directories into initrd build directory" && cd $BUILD_DIR

	logDebug "Build CPIO package and compressing to output file"
	find . ! -name '.gitkeep' | cpio -o -R 0:0 -H newc 2>/dev/null | gzip > ${OUTPUT_DIRECTORY}/initrd.gz

	logInfo "Finished building the RAM disk, final output file: ${OUTPUT_DIRECTORY}/initrd.gz"
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

	printf "\n\t=== TASK: %-10s ===\n" "buildInitrd"
	printf "\t%-20s - %s\n" "INITRD_SRC" "Defines the location of the ram disk source files (Default: ${SCRIPTPATH}/initrd_src)"


	echo -e "\nTasks:"
	printf "\t%-20s - %s\n" "showHelp" "Shows this help message"
	printf "\t%-20s - %s\n" "buildKernel" "Downloads and compiles the Linux Kernel with the Rebuild Agent kernel configuration"
	printf "\t%-20s - %s\n" "buildInitrd" "Packages the ram disk source (initrd_src) into the final ram disk image"

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
		$task
	done

	logInfo "All tasks completed successfully!"
fi
