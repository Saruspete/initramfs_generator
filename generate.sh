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

typeset    PATH_ROOT=""
typeset    PATH_TEMP="$MYPATH/img"
typeset    PATH_IMAGE="$MYPATH/initramfs-$(date "+%Y-%m-%d_%H-%M-%S")"
typeset    PATH_LDLIB=""

typeset    CORE_INIT="$MYPATH/init"
typeset -a ADD_EXTRA=()

ammOptparse::AddOptGroup "path" "Path for image generation"
ammOptparse::AddOpt "-t|--tmp="    "Temporary path to store files under"   "$PATH_TEMP"
ammOptparse::AddOpt "-o|--image="  "Generated image path"                  "$PATH_IMAGE"
ammOptparse::AddOpt "-r|--chroot=" "chroot source to take bin from"        "$PATH_ROOT"
ammOptparse::AddOpt    "--ldlib="  "Additionnal LD_LIBRARY_PATH to set"    "$PATH_LDLIB"

ammOptparse::AddOptGroup "core" "Core elements"
ammOptparse::AddOpt "-i|--init="  "init to be used"                       "$CORE_INIT"

ammOptparse::AddOptGroup "extra"     "Extra content to add"
ammOptparse::AddOpt "-a|--add-file@"  "Add an extra file or folder into initramfs"


ammOptparse::Parse --no-unknown || ammLog::Die "Options parsing error"

PATH_ROOT="$(ammOptparse::Get "chroot")"
PATH_TEMP="$(ammOptparse::Get "tmp")"
PATH_IMAGE="$(ammOptparse::Get "image")"
PATH_LDLIB="$(ammOptparse::Get "ldlib")"

CORE_INIT="$(ammOptparse::Get "init")"
typeset -a ADD_EXTRA=$(ammOptparse::Get "add-file")

typeset CHROOT_LDLIB_PATH=""

# Use absolute path
if [[ -n "$PATH_ROOT" ]]; then
	PATH_ROOT="$(realpath "$PATH_ROOT")"

	# Add targets
	for libdir in /lib64 /usr/lib64 /usr/local/lib64 /lib /usr/lib; do
		CHROOT_LDLIB_PATH+=":$PATH_ROOT/$libdir"
	done
fi


function _ldd {
	typeset bin="$1" 

	# If we have PATH_ROOT set, we need to call directly within the env (and skip ldd)
	if [[ -n "$PATH_ROOT" ]]; then
		export LD_LIBRARY_PATH+="$CHROOT_LDLIB_PATH"
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
					# Absolute or relative to PWD
					#if [[ "${lib:0:1}" == "/" ]]; then
					#	echo "$lib"
					#elif [[ "${arrow:0:1}" == "(" ]]; then
					#	echo "$(pwd -P)/$lib"
					#fi
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

	else
		ldd "$1" | awk 'NF>3 && $1 != "libc.so.6"{print $3}'
	fi
}

typeset -A __DEPS_FOUND=
function binFindDeps {

	typeset file
	for file in "$@"; do

		if ! [[ -e "$file" ]]; then
			file="$(binFind "$file")"
		fi

		# Try to get the real binary
		typeset realbin="$(realpath "$file")"
		echo "$realbin"

		# Check if shebang
		typeset firstline="$(head -n1 "$file" 2>/dev/null|tr -cd '[:print:]')" interp=""
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
			ammLog::Warning "Non existing file '$file'. Skipping"
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
	# create / => /usr symlink
	ln -s "../$i" "$PATH_TEMP/usr/$i"
done

chrootFileAdd /dev/{full,null,zero,random,urandom,console,kmsg,mem,ptmx,tty,tty{0..8}}
chrootFileAdd /dev/{std{err,in,out},fd}

# #############################################################################
#
# Copy kernel modules
#
# #############################################################################


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
chrootFileAdd $(binFindDeps ip devlink ethtool dhcpcd wget curl)

# Stress-test
chrootFileAdd $MYPATH/extra/mersenne/lib* $(binFindDeps $MYPATH/extra/mersenne/mprime)

# Extra packages
if [[ -n "${ADD_EXTRA:-}" ]]; then
	chrootFileAdd "${ADD_EXTRA[@]}"
fi


# #############################################################################
#
# Generate cpio archive
#
# #############################################################################
(
	cd "$PATH_TEMP"
	find . -print0 | cpio --null -ov --format=newc | gzip > "$PATH_IMAGE"
)

echo "Generated: '$PATH_IMAGE'"
typeset imgLatest="${PATH_IMAGE%/*}/initramfs-latest.img"
[[ -L "$imgLatest" ]] && rm "$imgLatest"
ln -s "$PATH_IMAGE" "$imgLatest"

echo "You can test it with:"
cat <<-EOT
	qemu-system-x86_64 -cpu Skylake-Client \
	-no-reboot -nographic \
	-append "console=ttyS0 panic=5" \
	-kernel /boot/kernel-genkernel-x86_64-5.4.109-gentoo \
	-initrd $PATH_IMAGE
	EOT
