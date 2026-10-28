#!/usr/bin/env bash
#
# 制作 Ubuntu CXL 测试镜像
#   在基础 cloud image(qcow2) 上：设置 root 密码 -> 可选扩容 -> 安装 CXL 内核 deb
#   -> 修改 grub 默认启动项 -> apt 安装 cxl/daxctl -> 生成 ssh host keys
#   -> 最后 flatten 成独立的 qcow2。
#
# 依赖: qemu-img (qemu-utils)、virt-customize (libguestfs-tools)
#
set -euo pipefail

PROG="$(basename "$0")"

# ---------------------------------------------------------------------------
# 默认值
# ---------------------------------------------------------------------------
BASE_IMG=
OUTPUT=
ROOT_PASSWORD=
# 默认空，表示不要resize；NEW_IMG_SIZE 只存放 -s/--new-img-size 的值
NEW_IMG_SIZE=
# RESIZE 是唯一的 resize 控制开关（取值由 NEW_IMG_SIZE 决定）
RESIZE=0
# 可以是deb包，或者目录，注意需要展开通配符（可以重复给多次）
KERNEL_DEB_LIST=()
# 从 KERNEL_DEB_LIST 展开为deb包的列表，空格分隔（脚本内部生成，无需从 CLI 传入）
INSTALL_DEB_LIST=
# INSTALL_PKG_LIST 默认是"cxl daxctl"，传空字符串则不安装额外包
INSTALL_PKG_LIST="cxl daxctl"
# 控制是否生成host keys，默认要生成，cli加一个选项可以置空
GEN_HOST_KEYS="ssh-keygen -A"
# grub 默认启动项：-g/--grub-entry 传入后会被规范成完整的 submenu 标题，
# 空值表示不修改 grub（即唯一控制点就是它是否为空）
GRUB_ENTRY=
# deb 在 guest 里的落脚目录
DEB_DEST_DIR=/tmp
FORCE=0
DEBUG=0

# ---------------------------------------------------------------------------
# 小工具函数
# ---------------------------------------------------------------------------
die() {
	echo "[ERROR] $*" >&2
	exit 1
}

log() {
	echo "[INFO] $*"
}

usage() {
	cat <<EOF
Usage: ${PROG} -b BASE_IMG -o OUTPUT -p ROOT_PASSWORD -k PATH [PATH ...] [options]

Build a bootable Ubuntu test image with a CXL kernel and tools installed on top
of a cloud image (base image is never modified).

Required:
  -b, --base-img PATH        base image (qcow2, used as a backing file)
  -o, --output PATH          output image (qcow2; fails if it exists, see -f)
  -p, --root-password PASS   root password of the guest
  -k, --kernel-deb PATH [PATH ...]
                             kernel deb package(s) or directory, separated by
                             spaces (the option may also be repeated)

Optional:
  -s, --new-img-size SIZE    grow the image to SIZE, e.g. 20G or +10G;
                             default: empty, i.e. no resize (growpart +
                             resize2fs are only run when it is set)
  -i, --install-pkg LIST     extra apt packages, default "cxl daxctl";
                             pass "" to skip
  -g, --grub-entry TITLE     default grub entry. The "Advanced options for
                             Ubuntu>" prefix may be omitted. Defaults to the
                             version parsed from the kernel deb names, e.g.
                             "Ubuntu, with Linux 7.0.0-38-cxltest"
  -n, --no-host-keys         do not generate ssh host keys (ssh-keygen -A is
                             run by default)
  -f, --force                allow overwriting an existing OUTPUT
      --debug                trace executed commands (set -x)
  -h, --help                 show this help

Example:
  ${PROG} \\
      -b ../base/resolute-server-cloudimg-amd64-daily20261016.img \\
      -o ../overlay/ubuntu26-cxltest.qcow2 \\
      -p 'mysecret' \\
      -s 20G \\
      -k ../../assets/7.0.0-38.38/*.deb \\
      -i 'cxl daxctl'

Environment:
  None. Everything is passed on the command line (the script exports what
  virt-customize needs internally).
EOF
}

# 支持 --opt=value 写法
normalize_args() {
	local -a out=()
	local a
	for a in "$@"; do
		case "$a" in
			--*=*) out+=("${a%%=*}" "${a#*=}") ;;
			*) out+=("$a") ;;
		esac
	done
	printf '%s\0' "${out[@]+"${out[@]}"}"
}

# ---------------------------------------------------------------------------
# 解析命令行
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
	usage
	exit 1
fi

mapfile -d '' -t _args < <(normalize_args "$@")
set -- "${_args[@]+"${_args[@]}"}"

while [[ $# -gt 0 ]]; do
	case "$1" in
		-b | --base-img)
			[[ $# -ge 2 ]] || die "$1 requires an argument"
			BASE_IMG=$2
			shift 2
			;;
		-o | --output)
			[[ $# -ge 2 ]] || die "$1 requires an argument"
			OUTPUT=$2
			shift 2
			;;
		-p | --root-password)
			[[ $# -ge 2 ]] || die "$1 requires an argument"
			ROOT_PASSWORD=$2
			shift 2
			;;
		-s | --new-img-size)
			[[ $# -ge 2 ]] || die "$1 requires an argument"
			NEW_IMG_SIZE=$2
			shift 2
			;;
		-k | --kernel-deb)
			# 允许 shell 提前展开通配符：一次吞掉后面所有非选项参数
			[[ -n ${2:-} ]] || die "$1 must not be empty"
			shift
			while [[ $# -gt 0 && $1 != -* ]]; do
				KERNEL_DEB_LIST+=("$1")
				shift
			done
			;;
		-i | --install-pkg)
			[[ $# -ge 2 ]] || die "$1 requires an argument"
			INSTALL_PKG_LIST=$2
			shift 2
			;;
		-g | --grub-entry)
			[[ $# -ge 2 ]] || die "$1 requires an argument"
			GRUB_ENTRY=$2
			shift 2
			;;
		-n | --no-host-keys)
			GEN_HOST_KEYS=
			shift
			;;
		-f | --force)
			FORCE=1
			shift
			;;
		--debug)
			DEBUG=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		*)
			echo "[ERROR] unknown option: $1" >&2
			echo >&2
			usage >&2
			exit 1
			;;
	esac
done

[[ $DEBUG -eq 1 ]] && set -x

# ---------------------------------------------------------------------------
# 参数校验
# ---------------------------------------------------------------------------
[[ -n $BASE_IMG ]] || die "missing -b/--base-img"
[[ -n $OUTPUT ]] || die "missing -o/--output"
[[ -n $ROOT_PASSWORD ]] || die "missing -p/--root-password"

command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found, please install qemu-utils"
command -v virt-customize >/dev/null 2>&1 || die "virt-customize not found, please install libguestfs-tools"

[[ -f $BASE_IMG && -r $BASE_IMG ]] || die "base image missing or not readable: ${BASE_IMG}"
BASE_IMG=$(realpath -e "$BASE_IMG") # backing file 用绝对路径，避免相对路径失效

OUTPUT=$(realpath -m "$OUTPUT")
TMP_IMG="${OUTPUT}.tmp"

if [[ ! -d $(dirname "$OUTPUT") || ! -w $(dirname "$OUTPUT") ]]; then
	die "output directory missing or not writable: $(dirname "$OUTPUT")"
fi
if [[ -e $OUTPUT && $FORCE -ne 1 ]]; then
	die "output image already exists: ${OUTPUT} (use -f to overwrite)"
fi

# RESIZE 是唯一控制开关；NEW_IMG_SIZE 只存放值，不做改写
case "$NEW_IMG_SIZE" in
	"" | 0 | 0[GgMmTt] | +0)
		: # 保持 RESIZE=0
		;;
	+*[0-9]* | [0-9]*)
		# 形如 20G / +10G / 10240M
		[[ $NEW_IMG_SIZE =~ ^\+?[0-9]+(\.[0-9]+)?[KkMmGgTt]?$ ]] ||
			die "invalid -s/--new-img-size value: ${NEW_IMG_SIZE} (e.g. 20G or +10G)"
		RESIZE=1
		;;
	*)
		die "invalid -s/--new-img-size value: ${NEW_IMG_SIZE} (e.g. 20G or +10G)"
		;;
esac

# ---------------------------------------------------------------------------
# 展开 KERNEL_DEB_LIST -> INSTALL_DEB_LIST
#   KERNEL_DEB_LIST 里的每一项可以是:
#     - 单个 deb 文件
#     - 目录（展开为 dir/*.deb）
#     - 通配符（如 assets/*.deb，加不加引号都行；不加引号时由 shell 展开，
#       展开成多个参数也能被 -k 一次接住）
#     - 上面几种用空格/逗号拼在一起的字符串
# ---------------------------------------------------------------------------
expand_kernel_debs() {
	local -a globs=()
	local -a parts=()
	local item part f
	local -A seen=()
	DEB_FILES=()
	shopt -s nullglob
	for item in "${KERNEL_DEB_LIST[@]+"${KERNEL_DEB_LIST[@]}"}"; do
		# 允许 "a.deb b.deb" / "a.deb,b.deb" 这种写法
		IFS=$' \t\n,' read -r -a parts <<<"$item"
		for part in "${parts[@]+"${parts[@]}"}"; do
			[[ -n $part ]] || continue
			if [[ -d $part ]]; then
				globs=("$part"/*.deb)
			else
				# shellcheck disable=SC2206 # 这里故意让通配符展开
				globs=($part)
			fi
			if [[ ${#globs[@]} -eq 0 ]]; then
				die "no deb package found: ${part}"
			fi
			for f in "${globs[@]}"; do
				[[ -f $f ]] || die "deb package not found: ${f}"
				[[ $f == *.deb ]] || die "not a deb package: ${f}"
				f=$(realpath -e "$f")
				[[ -n ${seen[$f]:-} ]] && continue
				seen[$f]=1
				DEB_FILES+=("$f")
			done
		done
	done
	shopt -u nullglob
}

DEB_FILES=()
if [[ ${#KERNEL_DEB_LIST[@]} -gt 0 ]]; then
	expand_kernel_debs
fi

# copy-in 到 /tmp 时需要 basename 不冲突，否则后面的包会覆盖前面的；
# 顺便生成 guest 内的绝对路径列表（INSTALL_DEB_LIST，空格分隔）
INSTALL_DEB_LIST=
declare -A _basename_owner=()
for f in "${DEB_FILES[@]+"${DEB_FILES[@]}"}"; do
	bn=${f##*/}
	if [[ -n ${_basename_owner[$bn]:-} && ${_basename_owner[$bn]} != "$f" ]]; then
		die "duplicate deb file name in different directories (they would overwrite each other): ${_basename_owner[$bn]} and ${f}"
	fi
	_basename_owner[$bn]=$f
	INSTALL_DEB_LIST+="${DEB_DEST_DIR}/${bn} "
done
unset _basename_owner
INSTALL_DEB_LIST=${INSTALL_DEB_LIST% }

# ---------------------------------------------------------------------------
# grub 默认启动项
# ---------------------------------------------------------------------------
detect_kernel_ver() {
	local f bn
	for f in "${DEB_FILES[@]+"${DEB_FILES[@]}"}"; do
		bn=$(basename "$f")
		case "$bn" in
			linux-image-*)
				bn=${bn#linux-image-}
				bn=${bn#unsigned-}
				printf '%s\n' "${bn%%_*}"
				return 0
				;;
		esac
	done
	return 1
}

# GRUB_ENTRY 若为空，尝试从内核 deb 文件名推导；推导不出来就跳过改 grub
if [[ -z $GRUB_ENTRY ]]; then
	if kver=$(detect_kernel_ver); then
		GRUB_ENTRY="Ubuntu, with Linux ${kver}"
	else
		log "warning: no kernel deb and no -g/--grub-entry given, skipping grub default entry change"
	fi
fi
# 允许不加 submenu 前缀，这里统一补全（GRUB_ENTRY 即最终写入的值，也是唯一控制点）
case "$GRUB_ENTRY" in
	"") ;;
	*'>'*) ;;
	*) GRUB_ENTRY="Advanced options for Ubuntu>${GRUB_ENTRY}" ;;
esac

# ---------------------------------------------------------------------------
# 打印本次配置
# ---------------------------------------------------------------------------
log "base image      : ${BASE_IMG}"
log "output image    : ${OUTPUT}"
log "root password   : $(printf '%*s' "${#ROOT_PASSWORD}" '' | tr ' ' '*')"
log "resize          : $(if [[ $RESIZE -eq 1 ]]; then echo "${NEW_IMG_SIZE}"; else echo "no"; fi)"
log "kernel debs     : ${#DEB_FILES[@]} file(s)"
for f in "${DEB_FILES[@]+"${DEB_FILES[@]}"}"; do log "                  $(basename "$f")"; done
log "install debs    : ${INSTALL_DEB_LIST:-<none>}"
log "install pkgs    : ${INSTALL_PKG_LIST:-<none>}"
log "grub default    : ${GRUB_ENTRY:-<skip>}"
log "gen host keys   : ${GEN_HOST_KEYS:-<no>}"

# ---------------------------------------------------------------------------
# 创建临时 overlay 并清理
# ---------------------------------------------------------------------------
cleanup() {
	local rc=$?
	if [[ -e $TMP_IMG ]]; then
		rm -f -- "$TMP_IMG"
	fi
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "creating temporary overlay: ${TMP_IMG}"
qemu-img create -f qcow2 -b "${BASE_IMG}" -F qcow2 "${TMP_IMG}"

# 如果resize
VC_ARGS=(-a "${TMP_IMG}")
if [[ $RESIZE -eq 1 ]]; then
	log "resizing to ${NEW_IMG_SIZE} and growing partition/filesystem"
	qemu-img resize "${TMP_IMG}" "${NEW_IMG_SIZE}"
	VC_ARGS+=(
		# NOCHANGE 时 growpart 返回非 0（比如 -s 传了和当前一样大的值），不算错误
		--run-command "growpart /dev/sda 1 || echo 'growpart: nothing to grow (ignored)'"
		--run-command "resize2fs /dev/sda1"
	)
fi

VC_ARGS+=(--root-password "password:${ROOT_PASSWORD}")

# KERNEL_DEB_LIST 里全部 copy 到 /tmp/ 下面
for f in "${DEB_FILES[@]+"${DEB_FILES[@]}"}"; do
	VC_ARGS+=(--copy-in "${f}:${DEB_DEST_DIR}")
done

if [[ ${#DEB_FILES[@]} -gt 0 ]]; then
	VC_ARGS+=(--run-command "export DEBIAN_FRONTEND=noninteractive && dpkg -i ${INSTALL_DEB_LIST}")
fi

if [[ -n $GRUB_ENTRY ]]; then
	VC_ARGS+=(
		--edit "/etc/default/grub: s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${GRUB_ENTRY}\"|"
		--run-command "update-grub"
	)
fi

if [[ -n $INSTALL_PKG_LIST ]]; then
	VC_ARGS+=(
		--run-command "export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y ${INSTALL_PKG_LIST}"
	)
fi

if [[ -n $GEN_HOST_KEYS ]]; then
	VC_ARGS+=(--run-command "${GEN_HOST_KEYS}")
fi

log "running virt-customize (the first run may take a few minutes)"
virt-customize "${VC_ARGS[@]}"

log "flattening into standalone image: ${OUTPUT}"
qemu-img convert -O qcow2 "${TMP_IMG}" "${OUTPUT}"

log "done: ${OUTPUT}"
qemu-img info "${OUTPUT}" || true
