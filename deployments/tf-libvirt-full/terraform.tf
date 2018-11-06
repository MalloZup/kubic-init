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

module "cluster" {
 source = "modules/libvirt/kubernetes_cluster"
}

###########################
# Token                   #
###########################

data "external" "token_gen" {
  program = [
    "python",
    "../support/tf/gen-token.py",
  ]
}

output "token" {
  value = "${data.external.token_gen.result.token}"
}

##############
# Seed node #
##############

resource "libvirt_volume" "seed" {
  name             = "${var.prefix}_seed.qcow2"
  pool             = "${var.img_pool}"
  base_volume_name = "${var.prefix}_base_${basename(var.img)}"

  depends_on = [
    "null_resource.download_kubic_image",
  ]
}

data "template_file" "seed_cloud_init_user_data" {
  template = "${file("../cloud-init/seed.cfg.tpl")}"

  vars {
    password              = "${var.password}"
    hostname              = "${var.prefix}-seed"
    token                 = "${data.external.token_gen.result.token}"
    kubic_init_image_name = "${var.kubic_init_image_name}"
  }
}

resource "libvirt_cloudinit_disk" "seed" {
  name      = "${var.prefix}_seed_cloud_init.iso"
  pool      = "${var.img_pool}"
  user_data = "${data.template_file.seed_cloud_init_user_data.rendered}"
}

resource "libvirt_domain" "seed" {
  name      = "${var.prefix}-seed"
  memory    = "${var.seed_memory}"
  cloudinit = "${libvirt_cloudinit_disk.seed.id}"

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = "${libvirt_volume.seed.id}"
  }

  network_interface {
    network_name   = "${var.network}"
    wait_for_lease = 1
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
  }
}

resource "null_resource" "upload_config_seeder" {
  count = "${length(var.devel) == 0 ? 0 : 1}"

  depends_on = [
    "libvirt_domain.seed",
  ]

  connection {
    host     = "${libvirt_domain.seed.network_interface.0.addresses.0}"
    password = "${var.password}"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p /etc/systemd/system/kubelet.service.d",
    ]
  }

  provisioner "file" {
    source      = "../../init/kubelet.drop-in.conf"
    destination = "/etc/systemd/system/kubelet.service.d/kubelet.conf"
  }

  provisioner "file" {
    source      = "../../init/kubic-init.systemd.conf"
    destination = "/etc/systemd/system/kubic-init.service"
  }

  provisioner "file" {
    source      = "../../init/kubic-init.sysconfig"
    destination = "/etc/sysconfig/kubic-init"
  }

  provisioner "file" {
    source      = "../../init/kubelet-sysctl.conf"
    destination = "/etc/sysctl.d/99-kubernetes-cri.conf"
  }

  provisioner "file" {
    source      = "../../${var.kubic_init_image}"
    destination = "/tmp/${var.kubic_init_image}"
  }

  # TODO: this is only for development
  provisioner "remote-exec" {
    inline = "${data.template_file.init_script.rendered}"
  }
}

output "seeder" {
  value = "${libvirt_domain.seed.network_interface.0.addresses.0}"
}

###########################
# Cluster non-seed nodes #
###########################

resource "libvirt_volume" "node" {
  count            = "${var.nodes_count}"
  name             = "${var.prefix}_node_${count.index}.qcow2"
  pool             = "${var.img_pool}"
  base_volume_name = "${var.prefix}_base_${basename(var.img)}"

  depends_on = [
    "null_resource.download_kubic_image",
  ]
}

data "template_file" "node_cloud_init_user_data" {
  count    = "${var.nodes_count}"
  template = "${file("../cloud-init/node.cfg.tpl")}"

  vars {
    seeder   = "${libvirt_domain.seed.network_interface.0.addresses.0}"
    token    = "${data.external.token_gen.result.token}"
    password = "${var.password}"
    hostname = "${var.prefix}-node-${count.index}"
  }

  depends_on = [
    "libvirt_domain.seed",
  ]
}

resource "libvirt_cloudinit_disk" "node" {
  count     = "${var.nodes_count}"
  name      = "${var.prefix}_node_cloud_init_${count.index}.iso"
  pool      = "${var.img_pool}"
  user_data = "${element(data.template_file.node_cloud_init_user_data.*.rendered, count.index)}"
}

resource "libvirt_domain" "node" {
  count     = "${var.nodes_count}"
  name      = "${var.prefix}-node-${count.index}"
  memory    = "${lookup(var.nodes_memory, count.index, var.default_node_memory)}"
  cloudinit = "${element(libvirt_cloudinit_disk.node.*.id, count.index)}"

  depends_on = [
    "libvirt_domain.seed",
  ]

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = "${element(libvirt_volume.node.*.id, count.index)}"
  }

  network_interface {
    network_name   = "${var.network}"
    wait_for_lease = 1
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
  }
}

resource "null_resource" "upload_config_nodes" {
  count = "${length(var.devel) == 0 ? 0 : var.nodes_count}"

  connection {
    host     = "${element(libvirt_domain.node.*.network_interface.0.addresses.0, count.index)}"
    password = "${var.password}"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p /etc/systemd/system/kubelet.service.d",
    ]
  }

  provisioner "file" {
    source      = "../../init/kubelet.drop-in.conf"
    destination = "/etc/systemd/system/kubelet.service.d/kubelet.conf"
  }

  provisioner "file" {
    source      = "../../init/kubic-init.systemd.conf"
    destination = "/etc/systemd/system/kubic-init.service"
  }

  provisioner "file" {
    source      = "../../init/kubic-init.sysconfig"
    destination = "/etc/sysconfig/kubic-init"
  }

  provisioner "file" {
    source      = "../../init/kubelet-sysctl.conf"
    destination = "/etc/sysctl.d/99-kubernetes-cri.conf"
  }

  provisioner "file" {
    source      = "../../${var.kubic_init_image}"
    destination = "/tmp/${var.kubic_init_image}"
  }

  # TODO: this is only for development
  provisioner "remote-exec" {
    inline = "${data.template_file.init_script.rendered}"
  }
}

output "nodes" {
  value = "${libvirt_domain.node.*.network_interface.0.addresses}"
}
