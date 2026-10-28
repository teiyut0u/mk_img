BASE_IMG=
OUTPUT=
ROOT_PASSWORD=
# 默认0，表示不要resize
NEW_IMG_SIZE=
# 可以是deb包，或者目录，注意需要展开通配符
KERNEL_DEB_LIST=
# 从 KERNEL_DEB_LIST 展开为deb包的列表，空格分隔
INSTALL_DEB_LIST=
# INSTALL_PKG_LIST 默认是"cxl daxctl"
INSTALL_PKG_LIST=
# 控制是否生成host keys，默认要生成，cli加一个选项可以置空
GEN_HOST_KEYS="ssh-keygen -A"

qemu-img create -f qcow2 -b "${BASE_IMG}" -F qcow2 "${OUTPUT}.tmp"
trap ... # 清理 "${OUTPUT}.tmp"

# 如果resize
qemu-img resize "${OUTPUT}.tmp" "${NEW_IMG_SIZE}"
RESIZE_CMD="--run-command 'growpart /dev/sda 1' --run-command 'resize2fs /dev/sda1'"

virt-customize -a "${OUTPUT}.tmp" \
	--root-password "password:${ROOT_PASSWORD}" \
	"${RESIZE_CMD}" \
	--copy-in ... \ # KERNEL_DEB_LIST里全部copy到/tmp/下面
	--run-command "export DEBIAN_FRONTEND=noninteractive && dpkg -i ${INSTALL_DEB_LIST}" \
	--edit '/etc/default/grub: s|^GRUB_DEFAULT=.*|GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 7.0.0-38-cxltest"|' \
	--run-command 'update-grub' \
	--run-command "export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y ${INSTALL_PKG_LIST}" \
	--run-command "${GEN_HOST_KEYS}"

qemu-img convert -O qcow2 "${OUTPUT}.tmp" "${OUTPUT}"


