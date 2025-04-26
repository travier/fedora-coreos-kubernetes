# Create nodes using Fedora CoreOS QCOW2 images from the stable stream
fedora_coreos_stream := "stable"

# Default Kubernetes version to deploy
kubernetes_version := "1.32"

# Where to fetch the sysexts from
sysext_url := "https://extensions.fcos.fr/extensions/" + "kubernetes-cri-o-" + kubernetes_version

# Architecture (x86_64 or aarch64)
arch := "x86_64"

# Exact version of the sysext
sysext_version := "1.32.3-1.fc41-41"

# Number of control plane nodes (only 1 is supported right now)
control_plane_nodes := "1"

# Number of worker nodes
worker_nodes := "3"

# Print help and available recipes
all:
    #!/bin/bash
    set -euo pipefail
    echo "See README for instructions."
    echo ""
    just -l

# Generate a Butane config from the template for the given hostname and convert it to an Ignition config
generate-config +hostnames:
    #!/bin/bash
    set -euo pipefail

    butane="butane"
    if [[ -z "$(command -v butane)" ]]; then
        butane="toolbox run -c toolbox butane"
    fi

    if [[ -f ssh_authorized_keys ]]; then
    sshkeys="[ "
    while IFS= read -r key; do
        if [[ "${sshkeys}" != "[ " ]]; then
            sshkeys+=", "
        fi
        sshkeys+="\"$key\""
    done < ssh_authorized_keys
    sshkeys+=" ]"
    fi

    # Version of Fedora CoreOS, also used for the sysext version
    fcos_version="$(curl -sSL \
        https://builds.coreos.fedoraproject.org/streams/stable.json \
        | jq -r '.architectures.{{arch}}.artifacts.qemu.release'
    )"

    # Name and version of the sysext to fetch
    arch=$(echo {{arch}} | sed 's/_/-/g')
    sysext_name_version="kubernetes-cri-o-{{kubernetes_version}}-{{sysext_version}}-${arch}"

    for host in {{hostnames}}; do
        cp "kube-sysext.bu.template" "${host}.bu"
        sed -i \
            -e "s|%%HOSTNAME%%|${host}|" \
            -e "s|%%KUBERNETES_VERSION%%|{{kubernetes_version}}|" \
            -e "s|%%SYSEXT_URL%%|{{sysext_url}}|" \
            -e "s|%%SYSEXT_NAME_VERSION%%|${sysext_name_version}|" \
            -e "s|%%SSH_AUTHORIZED_KEYS%%|${sshkeys}|" \
            "${host}.bu"
        ${butane} --strict --pretty --output "${host}.ign" "${host}.bu"
    done

# Download a Fedora CoreOS QCOW2 image as needed
download-fedora-coreos:
    #!/bin/bash
    set -euo pipefail
    # set -x
    images="$(ls ./fedora-coreos-*.qcow2)"
    if [[ -z "${images}" ]]; then
        coreos-installer download \
            --stream "{{fedora_coreos_stream}}" \
            --platform qemu \
            --format qcow2.xz \
            --decompress \
            --architecture {{arch}}
    fi

# Download the sysext locally
download-sysext:
    #!/bin/bash
    set -euo pipefail
    # set -x

    # Version of Fedora CoreOS, also used for the sysext version
    fcos_version="$(curl -sSL \
        https://builds.coreos.fedoraproject.org/streams/stable.json \
        | jq -r '.architectures.x86_64.artifacts.qemu.release'
    )"

    # Name and version of the sysext to fetch
    arch=$(echo {{arch}} | sed 's/_/-/g')
    sysext_name_version="kubernetes-cri-o-{{kubernetes_version}}-${fcos_version}-${arch}"

    wget "{{sysext_url}}/${sysext_name_version}.raw"

# Generate the list of hostnames
hostnames:
    #!/bin/bash
    set -euo pipefail
    # set -x

    out=""
    for n in $(seq 1 {{control_plane_nodes}}); do
        if [[ -n "${out}" ]]; then
            out+=" "
        fi
        out+="fcos-kube-cp-$n"
    done
    for n in $(seq 1 {{worker_nodes}}); do
        out+=" fcos-kube-w-$n"
    done
    echo "${out}"

# Generate all Butane and Ignition configs
generate:
    #!/bin/bash
    set -euo pipefail
    # set -x
    just generate-config $(just hostnames)

# Start the installation of the cluster
install:
    #!/bin/bash
    set -euo pipefail
    # set -x

    just generate-config $(just hostnames)

    just download-fedora-coreos

    # To make sure that the daemons get activated / started
    just virsh-list-all > /dev/null

    for host in $(just hostnames); do
        just virsh-rm "${host}"
    done

    for host in $(just hostnames); do
        just virt-install "${host}" "${host}.ign" "fedora-coreos-"*"-qemu.{{arch}}.qcow2"
    done

    for host in $(just hostnames); do
        echo "ssh core@\$(just virsh-get-ip "${host}")"
    done

# Destroy all VMs
destroy:
    #!/bin/bash
    set -euo pipefail
    # set -x

    for host in $(just hostnames); do
        just virsh-rm "${host}"
    done

# Print commands to ssh to the cluster nodes
ssh:
    #!/bin/bash
    set -euo pipefail
    # set -x

    for host in $(just hostnames); do
        echo "ssh core@\$(just virsh-get-ip "${host}")"
    done

# List all VMs
virsh-list-all:
    #!/bin/bash
    set -euo pipefail
    # set -x
    libvirt_url="qemu:///system"
    virsh --connect="${libvirt_url}" list --all

# Get the IP for a VM
virsh-get-ip +hostnames:
    #!/bin/bash
    set -euo pipefail
    # set -x
    libvirt_url="qemu:///system"
    for vm in {{hostnames}}; do
        mac="$(virsh --connect="${libvirt_url}" --quiet domiflist "${vm}" | awk '{ print $5 }')"
        virsh --connect="${libvirt_url}" --quiet net-dhcp-leases default --mac "${mac}" | awk '{ print $5 }' | sed 's|/24||'
    done

# Remove a VM
virsh-rm +hostnames:
    #!/bin/bash
    set -euo pipefail
    # set -x
    libvirt_url="qemu:///system"
    for vm in {{hostnames}}; do
        virsh --connect="${libvirt_url}" destroy --domain "${vm}" &> /dev/null || true
        virsh --connect="${libvirt_url}" undefine --remove-all-storage "${vm}" &> /dev/null || true
    done

# Install a VM
virt-install vm_name ignition_config qemu_image:
    #!/bin/bash
    set -euo pipefail
    # set -x

    if [[ ! -f {{ignition_config}} ]]; then
        echo "{{ignition_config}} is not a file!"
        exit 1
    fi
    if [[ ! -f {{qemu_image}} ]]; then
        echo "{{qemu_image}} is not a file!"
        exit 1
    fi

    IGNITION_CONFIG="$(realpath "{{ignition_config}}")"
    IMAGE="$(realpath "{{qemu_image}}")"

    # Default to the stable stream as this is only used for os-variant
    STREAM="stable"

    VCPUS="2"
    RAM_MB="4096"
    DISK_GB="20"

    IGNITION_DEVICE_ARG=(--qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${IGNITION_CONFIG}")

    chcon --verbose --type svirt_home_t "${IGNITION_CONFIG}"

    # Mark that we're using this image in a VM
    # touch "${IMAGE}.KEEP_VM_${name}"

    virt-install --connect="qemu:///system" \
        --name="{{vm_name}}" \
        --vcpus="${VCPUS}" \
        --memory="${RAM_MB}" \
        --os-variant="fedora-coreos-${STREAM}" \
        --import \
        --graphics=none \
        --disk="size=${DISK_GB},backing_store=${IMAGE}" \
        --network bridge=virbr0 \
        "${IGNITION_DEVICE_ARG[@]}" \
        --noautoconsole

# Serve the current directory over HTTP. See: https://github.com/TheWaWaR/simple-http-server
serve:
    simple-http-server .
