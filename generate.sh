#!/usr/bin/env bash

typeset MYSELF="$(realpath $0)"
typeset MYPATH="${MYSELF%/*}"

# Load main library
typeset -a ammpaths=("$MYPATH/ammlib" "$HOME/.ammlib" "/etc/ammlib")
for ammpath in "${ammpaths[@]}" fail; do
	[[ -e "$ammpath/ammlib" ]] && source "$ammpath/ammlib" && break
done
if [[ "$ammpath" == "fail" ]]; then
	echo >&2 "Unable to find ammlib in paths '${ammpaths[@]}'"
	echo >&2 "Download it with 'git clone https://github.com/Saruspete/ammlib.git $MYPATH'"
	exit 1
fi


# Load the required libraries
ammLib::Require "optparse" "pkg" "string"

ammExec::Require "modinfo" "awk" "head" "tr" "head" "cp" "readlink"

typeset    PATH_ROOT=""
typeset    PATH_TEMP="$MYPATH/img"
typeset    PATH_IMAGE="$MYPATH/initramfs-$(date "+%Y-%m-%d_%H-%M-%S").img"
typeset    PATH_LDLIB=""

typeset    CORE_INIT="$MYPATH/init"

ammOptparse::AddOptGroup "path" "Path for image generation"
ammOptparse::AddOpt "-t|--tmp="    "Temporary path to store files under"   "$PATH_TEMP"
ammOptparse::AddOpt "-o|--image="  "Generated image path"                  "$PATH_IMAGE"
ammOptparse::AddOpt "-r|--chroot=" "chroot source to take bin from"        "$PATH_ROOT"
ammOptparse::AddOpt    "--ldlib="  "Additionnal LD_LIBRARY_PATH to set"    "$PATH_LDLIB"

# Early parsing for chroot
ammOptparse::Parse "chroot"
PATH_ROOT="$(ammOptparse::Get "chroot")"
if [[ -n "$PATH_ROOT" ]] && ! [[ -d "$PATH_ROOT/usr" ]]; then
	ammLog::Error "Invalid chroot '$PATH_ROOT': no /usr path inside"
	exit 1
fi

typeset -a KERN_VERSIONS=()
typeset    KERN_MODPATH="$PATH_ROOT/lib/modules"
if [[ -d "$KERN_MODPATH" ]]; then
	for i in "$KERN_MODPATH"*; do
		typeset k="${i##*/modules/}"
		k="${k%%/*}"
		KERN_VERSIONS+=($k)
	done
else
	ammLog::Error "Missing kernel modules path as '$KERN_MODPATH'"
fi

[[ -z "${KERN_VERSION:-}" ]] && KERN_VERSIONS=("$(uname -r)")

ammOptparse::AddOptGroup "core" "Core elements"
ammOptparse::AddOpt "-i|--init="    "init to be used"                       "$CORE_INIT"
ammOptparse::AddOpt "-s|--scripts=" "scripts to be run"

ammOptparse::AddOptGroup "extra"     "Extra content to add"
ammOptparse::AddOpt "-a|--add-path@"  "Add an extra file or folder into initramfs"
ammOptparse::AddOpt "-m|--add-kmod@"  "Add an extra kernel module into initramfs"
ammOptparse::AddOpt "-k|--kernel@"    "Set one or more kernel version to search modules for" "${KERN_VERSIONS[@]}"

ammOptparse::Parse --no-unknown || ammLog::Die "Options parsing error"

PATH_TEMP="$(ammOptparse::Get "tmp")"
PATH_IMAGE="$(ammOptparse::Get "image")"
PATH_LDLIB="$(ammOptparse::Get "ldlib")"

CORE_INIT="$(ammOptparse::Get "init")"
typeset -a ADD_PATHS=$(ammOptparse::Get "add-path")
typeset -a ADD_KMODS=$(ammOptparse::Get "add-kmod")
typeset CHROOT_LDLIB_PATH=""

# Use absolute path
if [[ -n "$PATH_ROOT" ]]; then
	PATH_ROOT="$(realpath "$PATH_ROOT")"

	# Add targets
	for libdir in /lib64 /usr/lib64 /usr/local/lib64 /lib /usr/lib; do
		CHROOT_LDLIB_PATH+=":$PATH_ROOT/$libdir"
	done
fi


# @description  Find a kernel module from its name or alias
function kmodFindPath {
	typeset kmodName="$1"
	typeset kernVers="${2:-$(uname -r)}"
	typeset basePath="${3:-}"

	typeset kmodPath="$(modinfo --basedir "$basePath" -k "$kernVers" -F filename "$kmodName" 2>/dev/null)"
	# Remove the name: line that may appear when builtin
	kmodPath="${kmodPath##name:*$'\n'}"

	# No output at all (shouldn't be the case)
	if [[ -z "$kmodPath" ]]; then
		ammLog::Error "Unable to find module '$kmodName' for '$kernVers' in '${basePath:-/}'"
		return 1
	fi

	# No output but module found = builtin
	if [[ "$kmodPath" == "(builtin)" ]]; then
		ammLog::Info "Module '$kmodName' is builtin for '$kernVers' in '${basePath:-/}'"
		return 0
	fi

	echo "$kmodPath"
}

typeset -A __KMOD_DEPENDS_FOUND
# @description  Find the dependency tree of a kernel module
# @arg $1  (string) kernel module name or path
# @arg $2  (string) (optional) Kernel version to be used. default: current kernel
# @arg $3  (string) (optional) chroot to search into. default: live system
# @arg $4  (int) (internal: do no provide) depth level of recursion
# @stdout  (string[]) list of module depedencies
function kmodDepends {
	typeset kmodName="$1"
	typeset kernVers="${2:-$(uname -r)}"
	typeset basePath="${3:-}"
	typeset -i level="${4:-0}"

	# Reset on first call
	if [[ "$level" == "0" ]]; then
		#set -x
		__KMOD_DEPENDS_FOUND=()
		# Validate entry
		typeset kmodNameFound=""
		kmodNameFound="$(modinfo --basedir "$basePath" -k "$kernVers" -F name $kmodName 2>/dev/null)"
		[[ $? -ne 0 ]] && return

		# modinfo v28+ seems to add the type
		echo ${kmodNameFound#name:}
	fi
	level+=1

	# If a file is provided, guess if we can use its path to extract basePath and kernel version
	if [[ "${kmodName:0:1}" == "/" ]] && [[ -s "$kmodName" ]]; then
		if [[ "${kmodName#*/lib/modules/[0-9]*}" != "$kmodName" ]]; then
			basePath="${kmodName%/lib/modules/*}"
			kernVers="${kmodName##*/lib/modules/}"
			kernVers="${kernVers%%/*}"
		fi
	fi

	typeset depsLine
	while read depsLine; do
		# skip lines coming from (builtin) modules
		[[ "${depsLine#name:}" != "$depsLine" ]] && continue
		[[ -z "$depsLine" ]] && continue

		typeset deps="${depsLine//,/ }"
		typeset dep=
		# Replace - with _ to be constant in naming
		for dep in ${deps//-/_}; do
			# Only display once
			if ( set +u; [[ -z "${__KMOD_DEPENDS_FOUND[$dep]}" ]] ); then
				echo -n "$dep "
				# Recurse
				$FUNCNAME "$dep" "$kernVers" "$basePath" "$level"
			fi

			__KMOD_DEPENDS_FOUND[$dep]+="$kmodName "
		done

	done < <(modinfo --basedir "$basePath" -k "$kernVers" -F depends "$kmodName" 2>/dev/null)

	#[[ "$level" == "1" ]] && set +x
}

# @description  Reimplementation ldd
function _ldd {
	typeset bin="$1"

	# If we have PATH_ROOT set, we need to call directly within the env (and skip ldd)
	if [[ -n "$PATH_ROOT" ]]; then
		# Only add path once
		if [[ -z "${LD_LIBRARY_PATH:-}" ]] || ! [[ "${LD_LIBRARY_PATH//$CHROOT_LDLIB_PATH/}" != "$LD_LIBRARY_PATH" ]]; then
			export LD_LIBRARY_PATH+="$CHROOT_LDLIB_PATH"
		fi
	fi

	# test multiple runtime ld
	typeset rtldout= rtld= rtlds="$PATH_ROOT/lib64/ld-linux-x86-64.so.2 $PATH_ROOT/lib/ld-linux.so.2 $PATH_ROOT/libx32/ld-linux-x32.so.2 /lib/ld-linux.so.2 /lib64/ld-linux-x86-64.so.2"
	for rtld in $rtlds; do

		# Check if current rtld can handle given bin
		[[ -x "$rtld" ]] || continue
		rtldout="$($rtld --verify "$bin")"
		case $? in
			[02]) ;;
			*) continue
		esac

		# Use ld to run bin and deref
		rtldout="$(LD_TRACE_LOADED_OBJECTS=1 "$rtld" "$bin")"

		typeset lib arrow file address _junk
		echo "$rtldout" | while read lib arrow file address _junk; do
			[[ "$lib" == "linux-vdso.so.1" ]] && continue

			# When there is no arrow, either lib is abs, either it's name matches
			if [[ "$arrow" != "=>" ]]; then
				continue
			fi

			# Empty file: maybe vdso or ld-linux or error msg "not a dynamic executable"
			[[ -n "$file" ]] || continue

			if [[ -e "$file" ]]; then
				echo "$file"
			else
				echo >&2 "$lib"
			fi
		done
	done
}

typeset -A __DEPS_FOUND=
function binFindDeps {

	typeset file
	for file in "$@"; do

		# Try to find from the shortname (honoring PATH_ROOT)
		typeset filePath="$file"
		if ! [[ -e "$filePath" ]]; then
			filePath="$(binFind "$file")"
		fi

		# cannot find any matching file... skipping
		if ! [[ -e "$filePath" ]]; then
			ammLog::Warning "Skipping unresolvable '$file'"
			continue
		fi

		# Try to get the real binary
		typeset realbin="$(realpath "$filePath")"
		echo "$realbin"

		# Check if shebang
		typeset firstline="$(head -n1 "$realbin" 2>/dev/null|tr -cd '[:print:]')" interp=""
		if [[ "${firstline:0:2}" == "#!" ]]; then
			interp="${firstline:2}"
			interp="$(ammString::Trim "${interp%% *}")"
			[[ -n "$PATH_ROOT" ]] && interp="${PATH_ROOT}${interp}"
		fi


		typeset lib
		for lib in $interp $(_ldd "$realbin"); do
			# Skip already found dependencies
			(set +u; [[ -n "${__DEPS_FOUND[$lib]}" ]] ) && continue
			__DEPS_FOUND[$lib]=1

			echo "$lib"
			$FUNCNAME "$lib"
		done
	done
}

function binFind {
	if [[ -z "$PATH_ROOT" ]]; then
		typeset bin
		for bin in "$@"; do
			type -P "$bin" 2>/dev/null || ammLog::Warning "Unable to find '$bin' with searchpath '$PATH'"
		done
	else
		typeset bin
		for bin in "$@"; do
			typeset path found=""
			for path in ${PATH//:/ }; do
				typeset t="$PATH_ROOT/$path/$bin"
				if [[ -x "$t" ]]; then
					found="$t"
					break
				fi
			done

			if [[ -z "$found" ]]; then
				ammLog::Warning "Unable to find '$bin' in '$PATH_ROOT' with searchpath '$PATH'"
			else
				echo "$found"
			fi
		done
	fi
}

function chrootFileAdd {

	typeset file
	for file in "$@"; do
		typeset src="${file%@*}"
		typeset dst="${file##*@}"

		# Remove chroot path if needed
		dst="${dst#$PATH_ROOT}"

		if ! [[ -e "$src" ]]; then
			ammLog::Warning "Cannot add non-existing file '$file'. Skipping"
			continue
		fi

		# skip existing files
		[[ -e "$PATH_TEMP/$dst" ]] && continue

		# Dereference all symlinks if needed
		if [[ -L  "$src" ]]; then
			# If there was a renaming of the symlink, dereference it
			if [[ "${src#$PATH_ROOT}" != "$dst" ]]; then
				cp --dereference "$src" "$PATH_TEMP/$dst"
				continue

			# Simple listing, copy it raw but recurse
			else
				while [[ "$(readlink "$src")" != "$src" ]] && [[ -L "$src" ]]; do
					# Skip /proc entries:
					[[ "${src#*/proc}" != "$src" ]] && break
					# Copy the symlink
					[[ -d "$PATH_TEMP/${dst%/*}" ]] || mkdir -p "$PATH_TEMP/${dst%/*}"
					cp -a "$src" "$PATH_TEMP/$dst"
					# read its target
					src="$(readlink "$src")"
					[[ "${src:0:1}" != "/" ]] && src="${PATH_ROOT}${dst%/*}/$src"
					dst="${src#$PATH_ROOT}"
				done
			fi
		fi

		# Skip /proc entries
		[[ "${src#*/proc}" != "$src" ]] && continue

		# Copy the file
		[[ -d "$PATH_TEMP/${dst%/*}" ]] || mkdir -p "$PATH_TEMP/${dst%/*}"
		cp -a "$src" "$PATH_TEMP/$dst"
	done
}

# #############################################################################
#
# Create folder hierarchy and /dev
#
# #############################################################################
mkdir -p "$PATH_TEMP/"{etc,dev/{pts,shm},proc,sys,usr,var,run,home,root}

for i in bin sbin lib lib64; do
	mkdir -p "$PATH_TEMP/$i"
	# create / => /usr symlink if not exists
	! [[ -e "$PATH_TEMP/usr/$i" ]] && ln -s "../$i" "$PATH_TEMP/usr/$i"
done

chrootFileAdd /dev/{full,null,zero,random,urandom,console,kmsg,mem,ptmx,tty,tty{0..8}}
chrootFileAdd /dev/{std{err,in,out},fd}

# #############################################################################
#
# Copy kernel modules
#
# #############################################################################
if [[ -n "${ADD_KMODS:-}" ]]; then
	for kmodNeed in "${ADD_KMODS[@]}"; do
		for krn in "${KERN_VERSIONS[@]}"; do
			ammLog::StepBegin "Adding module '$kmodNeed' and dependencies, version '$krn' in '${PATH_ROOT:-/}'"
			for kmod in $(kmodDepends "$kmodNeed" "$krn" "$PATH_ROOT"); do
				typeset filePath="$(kmodFindPath "$kmod" "$krn" "$PATH_ROOT")"
				ammLog::Debug "Found for '$kmod': '$filePath'"
				if [[ -n "$filePath" ]]; then
					ammLog::Info "Adding mod '$kmod' ($filePath)"
					chrootFileAdd "$filePath@${filePath#${PATH_ROOT}}"
				fi
			done
			ammLog::StepEnd
		done
	done
fi

# #############################################################################
#
# Copy init and core libraries
#
# #############################################################################
cp "$CORE_INIT" "$PATH_TEMP/init"
chmod +x "$PATH_TEMP/init"

# Core
chrootFileAdd /lib64/ld-linux-x86-64.so.2 /lib64/libc.so.6

# Utilities
chrootFileAdd $(binFindDeps sleep cat ls ps bash sh realpath date)

# Filesystem
chrootFileAdd $(binFindDeps mount)

# Network
chrootFileAdd $(binFindDeps ip devlink)
for file in ethtool dhcpcd dhclient wget curl; do
	binFind "$file" >/dev/null || continue
	chrootFileAdd $(binFindDeps "$file")
done

# Stress-test
#chrootFileAdd $MYPATH/extra/mersenne $(binFindDeps $MYPATH/extra/mersenne/mprime)

# Extra packages
if [[ -n "${ADD_PATHS:-}" ]]; then
	chrootFileAdd "${ADD_PATHS[@]}"
fi


# #############################################################################
#
# Generate cpio archive
#
# #############################################################################
ammLog::StepBegin "Creating archive from '$PATH_TEMP'"
(
	cd "$PATH_TEMP"
	find . -print0 | cpio --null -o --format=newc | gzip > "$PATH_IMAGE"
)
ammLog::Info "Generated: '$PATH_IMAGE'"
ammLog::StepEnd

# Create a symlink for testing
typeset imgLatest="${PATH_IMAGE%/*}/initramfs-latest.img"
ammLog::Info "Creating symlink '$imgLatest'"
[[ -L "$imgLatest" ]] && rm "$imgLatest"
ln -s "$PATH_IMAGE" "$imgLatest"

# Quick test with qemu
typeset kernCurrent="$(</proc/cmdline)"
kernCurrent="${kernCurrent#BOOT_IMAGE=}"
kernCurrent="${kernCurrent%% *}"
kernCurrent="${kernCurrent#(*)}"

ammLog::Info "You can test it with:"
cat <<-EOT
qemu-system-x86_64 -cpu Skylake-Client \
-no-reboot -nographic \
-append "console=ttyS0 panic=-1" \
-kernel /boot/$kernCurrent \
-initrd $imgLatest
EOT
