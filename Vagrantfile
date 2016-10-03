# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/trusty64"
  config.vm.network "private_network", ip: "192.168.56.1"
  config.vm.synced_folder "./tftp_root", "/tftpboot"

  config.vm.provision "shell", inline: <<-SHELL
    # Install the services
    sudo apt-get update
    sudo apt-get install -y isc-dhcp-server tftpd-hpa unzip

    # Updated the configuration
    sudo sed -i 's/option domain-name "example.org"/option domain-name "qa.rebuild"/' /etc/dhcp/dhcpd.conf
    sudo sed -i 's/option domain-name-servers ns1.example.org, ns2.example.org/option domain-name-servers 8.8.8.8, 8.8.4.4/' /etc/dhcp/dhcpd.conf
    sudo echo -e "subnet 192.168.56.0 netmask 255.255.255.0 {\\n  range 192.168.56.10 192.168.56.50;\\n  filename \\"pxelinux.0\\";\\n}" >> /etc/dhcp/dhcpd.conf
    sudo sed -i 's/\\/var\\/lib\\/tftpboot/\\/tftpboot/' /etc/default/tftpd-hpa

    # Restart the services
    service isc-dhcp-server restart
    service tftpd-hpa restart

    # Download the required files for the PXE Boot System
    mkdir /tmp/syslinux
    cd /tmp/syslinux
    wget https://www.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.zip
    unzip syslinux-6.04-pre1.zip

    \\cp -f bios/core/pxelinux.0 /tftpboot/
    \\cp -f bios/com32/elflink/ldlinux/ldlinux.c32 /tftpboot/
    \\cp -f bios/com32/menu/vesamenu.c32 /tftpboot/
    \\cp -f bios/com32/lib/libcom32.c32 /tftpboot/
    \\cp -f bios/com32/libutil/libutil.c32 /tftpboot/

    # Download the Debian Linux Kernel
    mkdir -p /tftpboot/kernel
    rm -f /tftpboot/kernel/linux
    cd /tftpboot/kernel
    wget http://mirror.aarnet.edu.au/debian/dists/wheezy/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux
  SHELL
end
