#
# Author(s): Alvaro Saurin <alvaro.saurin@suse.com>
#
# Copyright (c) 2017 SUSE LINUX GmbH, Nuernberg, Germany.
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.
#

#####################
# Cluster variables #
#####################

variable "libvirt_uri" {
  default = "qemu:///system"
  description = "libvirt connection url - default to localhost"
}

variable "img_pool" {
  default = "default"
  description = "pool to be used to store all the volumes"
}

variable "img_url_base" {
  type = "string"
  default = "https://download.opensuse.org/repositories/devel:/kubic:/images:/experimental/images/"
  description = "URL to the KVM image used"
}

variable "img_src_filename" {
  type = "string"
  default = ""
  description = "Force a specific filename"
}

variable "img" {
  type = "string"
  default = "../images/kubic.qcow2"
  description = "remote URL or local copy (can be used in conjuction with img_url_base) of the image to use."
}

variable "img_refresh" {
  default = "true"
  description = "Try to get the latest image (true/false)"
}

variable "img_down_extra_args" {
  default = ""
  description = "Extra arguments for the images downloader"
}

variable "img_sudo_virsh" {
  default = "local"
  description = "Run virsh wioth sudo on [local|remote|both]"
}

variable "nodes_count" {
  default = 1
  description = "Number of non-seed nodes to be created"
}

variable "prefix" {
  type = "string"
  default = "kubic"
  description = "a prefix for resources"
}

variable "network" {
  type = "string"
  default = "default"
  description = "an existing network to use for the VMs"
}

variable "password" {
  type = "string"
  default = "linux"
  description = "password for sshing to the VMs"
}

variable "devel" {
  type = "string"
  default = "1"
  description = "enable somem steps for development environments (non-empty=true)"
}

variable "kubic_init_image" {
  type = "string"
  default = "kubic-init-latest.tar.gz"
  description = "a kubic-init container image"
}

variable "default_node_memory" {
  default = 1536
  description = "default amount of RAM of the Nodes (in bytes)"
}

variable "nodes_memory" {
  default = {
    "3" = "1024"
    "4" = "1024"
    "5" = "1024"
  }

  description = "amount of RAM for some specific nodes"
}

#######################
# Cluster declaration #
#######################

provider "libvirt" {
  uri = "${var.libvirt_uri}"
}

#######################
# Base image          #
#######################

resource "null_resource" "download_kubic_image" {
  count = "${length(var.img_url_base) == 0 ? 0 : 1}"

  provisioner "local-exec" {
    command = "../support/tf/download-image.sh --sudo-virsh '${var.img_sudo_virsh}' --src-base '${var.img_url_base}' --refresh '${var.img_refresh}' --local '${var.img}' --upload-to-img '${var.prefix}_base_${basename(var.img)}' --upload-to-pool '${var.img_pool}' --src-filename '${var.img_src_filename}' ${var.img_down_extra_args}"
  }
}

###########################
# Local IP (for seeding)  #
###########################

data "external" "local_net" {
  program = [
    "python",
    "../support/tf/local-ip.py"]
}

output "seeder_ip" {
  value = "${data.external.local_net.result.ip}"
}

###########################
# Token                   #
###########################

data "external" "token_gen" {
  program = [
    "python",
    "../support/tf/gen-token.py"]
}

output "token" {
  value = "${data.external.token_gen.result.token}"
}

###########################
# Cluster non-seed nodes #
###########################

resource "libvirt_volume" "node" {
  count = "${var.nodes_count}"
  name = "${var.prefix}_node_${count.index}.qcow2"
  pool = "${var.img_pool}"
  base_volume_name = "${var.prefix}_base_${basename(var.img)}"
  depends_on = [
    "null_resource.download_kubic_image"]
}

data "template_file" "node_cloud_init_user_data" {
  count = "${var.nodes_count}"
  template = "${file("../cloud-init/node.cfg.tpl")}"

  vars {
    seeder = "${data.external.local_net.result.ip}"
    token = "${data.external.token_gen.result.token}"
    password = "${var.password}"
    hostname = "${var.prefix}-node-${count.index}"
  }
}

resource "libvirt_cloudinit" "node" {
  count = "${var.nodes_count}"
  name = "${var.prefix}_node_cloud_init_${count.index}.iso"
  pool = "${var.img_pool}"
  user_data = "${element(data.template_file.node_cloud_init_user_data.*.rendered, count.index)}"
}

resource "libvirt_domain" "node" {
  count = "${var.nodes_count}"
  name = "${var.prefix}-node-${count.index}"
  memory = "${lookup(var.nodes_memory, count.index, var.default_node_memory)}"
  cloudinit = "${element(libvirt_cloudinit.node.*.id, count.index)}"

  disk {
    volume_id = "${element(libvirt_volume.node.*.id, count.index)}"
  }

  network_interface {
    network_name = "${var.network}"
    wait_for_lease = 1
  }

  graphics {
    type = "vnc"
    listen_type = "address"
  }
}

resource "null_resource" "upload_config_nodes" {
  count = "${length(var.devel) == 0 ? 0 : var.nodes_count}"

  connection {
    host = "${element(libvirt_domain.node.*.network_interface.0.addresses[0], count.index)}"
    password = "${var.password}"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p /etc/systemd/system/kubelet.service.d",
    ]
  }

  provisioner "file" {
    source = "../../init/kubelet.drop-in.conf"
    destination = "/etc/systemd/system/kubelet.service.d/kubelet.conf"
  }

  provisioner "file" {
    source = "../../init/kubic-init.systemd.conf"
    destination = "/etc/systemd/system/kubic-init.service"
  }

  provisioner "file" {
    source = "../../init/kubic-init.sysconfig"
    destination = "/etc/sysconfig/kubic-init"
  }

  provisioner "file" {
    source = "../../${var.kubic_init_image}"
    destination = "/tmp/${var.kubic_init_image}"
  }

  # TODO: this is only for development
  provisioner "remote-exec" {
    inline = [
      "systemctl daemon-reload",
      "mkdir -p /var/lib/etcd",
      "echo br_netfilter > /etc/modules-load.d/br_netfilter.conf",
      "modprobe br_netfilter",
      "sysctl -w net.ipv4.ip_forward=1",
      "sed -i 's/driver = \"\"/driver = \"btrfs\"/' /etc/containers/storage.conf",
      "while ! podman load -i /tmp/${var.kubic_init_image} ; do echo '(will try to load the kubic-init image again)' ; sleep 5 ; done",
      "systemctl enable --now kubic-init",
    ]
  }
}

output "nodes" {
  value = [
    "${libvirt_domain.node.*.network_interface.0.addresses[0]}"]
}
