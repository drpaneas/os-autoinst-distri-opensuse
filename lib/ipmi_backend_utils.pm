# SUSE's openQA tests
#
# Copyright © 2012-2017 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.
#
package ipmi_backend_utils;
# Summary: This file provides fundamental utilities related with the ipmi backend from test view,
#          like switching consoles between ssh and ipmi supported
# Maintainer: alice <xlai@suse.com>

use base Exporter;
use Exporter;
use strict;
use warnings;
use testapi;
use version_utils qw/is_storage_ng is_sle/;
use utils;
use power_action_utils 'prepare_system_shutdown';

our @EXPORT = qw(use_ssh_serial_console set_serial_console_on_vh switch_from_ssh_to_sol_console);

#With the new ipmi backend, we only use the root-ssh console when the SUT boot up,
#and no longer setup the real serial console for either kvm or xen.
#When needs reboot, we will switch back to sut console which relies on ipmi.
#We will mostly rely on ikvm to continue the test flow.
#TODO: we need the serial output to debug issues in reboot, coolo will help add it.

#use it after SUT boot finish, as it requires ssh connection to SUT to interact with SUT, including window and serial console
sub use_ssh_serial_console {
    console('sol')->disable if check_var('BACKEND', 'ipmi');
    select_console('root-ssh');
    $serialdev = 'sshserial';
    set_var('SERIALDEV', $serialdev);
    bmwqemu::save_vars();
}

sub switch_from_ssh_to_sol_console {
    my (%opts) = @_;

    #close root-ssh console
    prepare_system_shutdown;
    #switch to sol console
    set_var('SERIALDEV', '');
    $serialdev = 'ttyS1';
    bmwqemu::save_vars();
    console('sol')->disable;
    if ($opts{'reset_console_flag'} eq "on") {
        reset_consoles;
    }
    select_console 'sol', await_console => 0;
    save_screenshot;
}

my $grub_ver;

sub get_dom0_serialdev {
    my $root_dir = shift;
    $root_dir //= '/';

    my $dom0_serialdev;

    script_run("clear");
    script_run("cat ${root_dir}/etc/SuSE-release || cat ${root_dir}/etc/os-release");
    save_screenshot;
    assert_screen([qw(on_host_sles_12_sp2_or_above on_host_lower_than_sles_12_sp2)]);

    if (get_var("XEN") || check_var("HOST_HYPERVISOR", "xen")) {
        if (match_has_tag("on_host_sles_12_sp2_or_above")) {
            $dom0_serialdev = "hvc0";
        }
        elsif (match_has_tag("on_host_lower_than_sles_12_sp2")) {
            $dom0_serialdev = "xvc0";
        }
    }
    else {
        $dom0_serialdev = 'ttyS1';
    }

    if (match_has_tag("grub1")) {
        $grub_ver = "grub1";
    }
    else {
        $grub_ver = "grub2";
    }

    type_string("echo \"Debug info: hypervisor serial dev should be $dom0_serialdev. Grub version is $grub_ver.\"\n");

    return $dom0_serialdev;
}

sub setup_console_in_grub {
    my ($ipmi_console, $root_dir, $virt_type) = @_;
    $ipmi_console //= $serialdev;
    $root_dir //= '/';
    #Ther is no default value for $virt_type, which has to be passed into function explicitly.

    #set grub config file
    my $grub_default_file = "${root_dir}/etc/default/grub";
    my $grub_cfg_file;
    if ($grub_ver eq "grub2") {
        $grub_cfg_file = "${root_dir}/boot/grub2/grub.cfg";
    }
    elsif ($grub_ver eq "grub1") {
        $grub_cfg_file = "${root_dir}/boot/grub/menu.lst";
    }
    else {
        die "The grub version is not supported!";
    }

    #setup serial console for xen
    my $cmd;
    if ($grub_ver eq "grub2") {
        #grub2
        if (${virt_type} eq "xen") {
            my $com_settings = get_var('IPMI_CONSOLE') ? "com2=" . get_var('IPMI_CONSOLE') : "";
            #bsc#1107572 workaround(Comment9 "This dom0 memory amount works well with hosts having 4 to 8 Gigs of RAM.
            #With host containing larger amounts of memory, you may want to increase this to something larger.")
            #dom0_mem=1024M,max:1024M
            $cmd
              = "cp $grub_cfg_file ${grub_cfg_file}.org "
              . "\&\& sed -ri '/(multiboot|module\\s*.*vmlinuz)/ "
              . "{s/(console|loglevel|log_lvl|guest_loglvl)=[^ ]*//g; "
              . "/multiboot/ s/\$/ dom0_mem=1024M,max:1024M console=com2,115200 log_lvl=all guest_loglvl=all sync_console $com_settings/; "
              . "/module\\s*.*vmlinuz/ s/\$/ console=$ipmi_console,115200 console=tty loglevel=5/;}; "
              . "s/timeout=-{0,1}[0-9]{1,}/timeout=30/g;"
              . "' $grub_cfg_file";
            assert_script_run($cmd);
            save_screenshot;
            $cmd = "sed -rn '/(multiboot|module\\s*.*vmlinuz|timeout=)/p' $grub_cfg_file";
            assert_script_run($cmd);
            save_screenshot;
        } elsif (${virt_type} eq "kvm") {
            $cmd
              = "cp $grub_cfg_file ${grub_cfg_file}.org "
              . "\&\& sed -ri 's/timeout=-{0,1}[0-9]{1,}/timeout=30/g' $grub_cfg_file "
              . "\&\& sed -ri 's/^terminal.*\$/terminal_input console serial\\nterminal_output console serial\\nterminal console serial/g' $grub_cfg_file "
              . "\&\& cat $grub_default_file $grub_cfg_file";
            assert_script_run($cmd);
            save_screenshot;
        } else { die "Host Hypervisor is not xen or kvm"; }


        $cmd = "sed -ri 's/^terminal.*\$/terminal_input console serial\\nterminal_output console serial\\nterminal console serial/g' $grub_cfg_file";
        assert_script_run($cmd);
        $cmd = "cat $grub_default_file $grub_cfg_file";
        assert_script_run($cmd);
        save_screenshot;
        upload_logs($grub_default_file);
    }
    elsif ($grub_ver eq "grub1") {
        $cmd
          = "cp $grub_cfg_file ${grub_cfg_file}.org \&\&  sed -i 's/timeout=-{0,1}[0-9]{1,}/timeout=30/g; /module \\\/boot\\\/vmlinuz/{s/console=.*,115200/console=$ipmi_console,115200/g;}' $grub_cfg_file";
        assert_script_run($cmd);
        save_screenshot;
        $cmd = "sed -rn '/module \\\/boot\\\/vmlinuz/p' $grub_cfg_file";
        assert_script_run($cmd);
    }
    else {
        die "Not supported grub version!";
    }
    save_screenshot;
    upload_logs($grub_cfg_file);
}

sub mount_installation_disk {
    my ($installation_disk, $mount_point) = @_;

    #default from yast installation
    $installation_disk //= "/dev/sda2";
    $mount_point       //= "/mnt";

    #mount
    assert_script_run("mkdir -p $mount_point");
    assert_script_run("mount $installation_disk $mount_point");
    assert_script_run("ls ${mount_point}/boot");
}

sub umount_installation_disk {
    my $mount_point = shift;

    #default from yast installation
    $mount_point //= "/mnt";

    #umount
    assert_script_run("umount -l $mount_point");
    assert_script_run("ls $mount_point");
}

# Get the partition where the new installed system is installed to
sub get_installation_partition {
    my $partition = '';

    # Confirmed with dev that the reliable way to get partition for / is via installation log, rather than fdisk
    # For details, please refer to bug 1101806.
    my $cmd        = '';
    my $y2log_file = '/var/log/YaST2/y2log';
    if (is_sle('12+')) {
        $cmd = qq{grep -o '/dev/[^ ]\\+ /mnt ' $y2log_file | head -n1 | cut -f1 -d' '};
    }
    else {
        die "Not support finding root partition for products lower than sle12.";
    }
    $partition = script_output($cmd);
    save_screenshot;

    die "Error: can not get installation partition!" unless ($partition);

    type_string "echo Debug info: The partition with the installed system is $partition .\n";
    save_screenshot;

    return $partition;
}

#Usage:
#For post installation, use set_serial_console_on_vh(,...) directly
#For during installation, use set_serial_console_on_vh("/mnt",...)
#For custom usage, use set_serial_console_on_vh($mount_point, $installation_disk, $virt_type)
#Please pass desired hypervisor type to this function explicitly. There is no default value for $virt_type
sub set_serial_console_on_vh {
    my ($mount_point, $installation_disk, $virt_type) = @_;

    #prepare accessible grub
    my $root_dir;
    if ($mount_point ne "") {
        #when mount point is not empty, needs to mount installation disk
        if ($installation_disk eq "") {
            #search for the real installation partition on the first disk, which is selected by yast in ipmi installation
            $installation_disk = &get_installation_partition;
        }
        #mount partition
        assert_script_run("cd /");
        &mount_installation_disk("$installation_disk", "$mount_point");
        $root_dir = $mount_point;
    }
    else {
        $root_dir = "/";
    }

    #set up xen serial console
    my $ipmi_console = &get_dom0_serialdev("$root_dir");
    if (${virt_type} eq "xen" || ${virt_type} eq "kvm") { &setup_console_in_grub($ipmi_console, $root_dir, $virt_type); }
    else                                                { die "Host Hypervisor is not xen or kvm"; }

    #cleanup mount
    if ($mount_point ne "") {
        assert_script_run("cd /");
        &umount_installation_disk("$mount_point");
    }

}

1;
