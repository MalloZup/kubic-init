#cloud-config

# set locale
locale: fr_FR.UTF-8

# set timezone
timezone: Europe/Paris
hostname: ${hostname}
fqdn: ${hostname}.suse.de

# set root password
chpasswd:
  list: |
    root:${password}
  expire: False

users:
  - name: qa
    gecos: User
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    groups: users
    lock_passwd: false
    passwd: ${password}

### TODO: this should be replaced by the suse_caasp module
write_files:
  - path: "/etc/caasp/caasp-init.yaml"
    permissions: "0644"
    owner: "root"
    content: |
      apiVersion: caas.suse.com/v1alpha1
      kind: CaaSInitConfiguration
      seed: ${seeder}

runcmd:
  - /usr/bin/systemctl enable --now ntpd
  - sed -i -e 's/DHCLIENT_SET_HOSTNAME="yes"/DHCLIENT_SET_HOSTNAME="no"/g' /etc/sysconfig/network/dhcp

final_message: "The system is finally up, after $UPTIME seconds"
