class profile::slurm::base (String $cluster_name,
                            String $munge_key)
{
  group { 'slurm':
    ensure => 'present',
    gid    =>  '2001'
  }

  user { 'slurm':
    ensure  => 'present',
    groups  => 'slurm',
    uid     => '2001',
    home    => '/var/lib/slurm',
    comment =>  'Slurm workload manager',
    shell   => '/bin/bash',
    before  => Package['slurm']
  }

  group { 'munge':
    ensure => 'present',
    gid    =>  '2002'
  }

  user { 'munge':
    ensure  => 'present',
    groups  => 'munge',
    uid     => '2002',
    home    => '/var/lib/munge',
    comment => 'MUNGE Uid N Gid Emporium',
    shell   => '/sbin/nologin',
    before  => Package['munge']
  }

  package { ['munge', 'munge-libs'] :
    ensure  => 'installed',
    require => Yumrepo['epel']
  }

  file { '/var/spool/slurm':
    ensure => 'directory',
    owner  => 'slurm',
    group  => 'slurm'
  }

  file { '/etc/slurm':
    ensure  => 'directory',
    owner   => 'slurm',
    group   => 'slurm',
    seltype => 'usr_t'
  }

  file { '/etc/munge':
    ensure => 'directory',
    owner  => 'munge',
    group  => 'munge'
  }

  file { '/etc/slurm/cgroup.conf':
    ensure => 'present',
    owner  => 'slurm',
    group  => 'slurm',
    source => 'puppet:///modules/profile/slurm/cgroup.conf'
  }

  file { '/etc/slurm/epilog':
    ensure  => 'present',
    owner   => 'slurm',
    group   => 'slurm',
    source  => 'puppet:///modules/profile/slurm/epilog',
    mode    => "0755"
  }

  concat { '/etc/slurm/slurm.conf':
    owner   => 'slurm',
    group   => 'slurm',
    ensure  => 'present',
    mode    => '0644'
  }

  concat::fragment { 'slurm.conf_header':
    target  => '/etc/slurm/slurm.conf',
    content => epp('profile/slurm/slurm.conf', {'cluster_name' => $cluster_name}),
    order   => '01'
  }

  $node_template = @(END)
<% for i in 1..250 do -%>
NodeName=node<%= i %> State=FUTURE
<% end -%>
END

  file { '/etc/slurm/node.conf':
    ensure  => 'present',
    owner   => 'slurm',
    group   => 'slurm',
    replace => 'false',
    content => inline_template($node_template)
  }

  file { '/etc/slurm/plugstack.conf':
    ensure => 'present',
    owner  => 'slurm',
    group  => 'slurm',
    content => 'required /usr/lib64/slurm/cc-tmpfs_mounts.so bindself=/tmp bindself=/dev/shm target=/localscratch bind=/var/tmp/'
  }

  file { '/etc/munge/munge.key':
    ensure => 'present',
    owner  => 'munge',
    group  => 'munge',
    mode   => '0400',
    content => $munge_key,
    before  => Service['munge']
  }

  service { 'munge':
    ensure => 'running',
    enable => 'true',
    subscribe => File['/etc/munge/munge.key']
  }

  yumrepo { 'darrenboss-slurm':
    enabled             => 'true',
    descr               => 'Copr repo for Slurm owned by darrenboss',
    baseurl             => 'https://copr-be.cloud.fedoraproject.org/results/darrenboss/Slurm/epel-7-$basearch/',
    skip_if_unavailable => 'true',
    gpgcheck            => 1,
    gpgkey              => 'https://copr-be.cloud.fedoraproject.org/results/darrenboss/Slurm/pubkey.gpg',
    repo_gpgcheck       => 0,
  }

  package { 'slurm':
    ensure => 'installed',
    require => Yumrepo['darrenboss-slurm']
  }

  package { 'slurm-contribs':
    ensure => 'installed',
    require => Yumrepo['darrenboss-slurm']
  }

  file { 'cc-tmpfs_mount.so':
    ensure        => 'present',
    source        => 'https://gist.github.com/cmd-ntrf/a9305513809e7c9a104f79f0f15ec067/raw/da71a07f455206e21054f019d26a277daeaa0f00/cc-tmpfs_mounts.so',
    path          => '/usr/lib64/slurm/cc-tmpfs_mounts.so',
    owner         => 'slurm',
    group         => 'slurm',
    mode          => '0755',
    checksum      => 'md5',
    checksum_value => 'ff2beaa7be1ec0238fd621938f31276c',
  }
}

class profile::slurm::accounting {
  class { 'mysql::server':
    remove_default_accounts => true
  }

  $storage_pass = lookup('profile::slurm::accounting::password')
  mysql::db { 'slurm_acct_db':
    ensure  => present,
    user     => 'slurm',
    password => $storage_pass,
    host     => 'localhost',
    grant    => ['ALL'],
  }

  $slurm_conf = "
AccountingStorageHost=$hostname
AccountingStorageType=accounting_storage/slurmdbd
"
  concat::fragment { 'slurm.conf_slurmdbd':
    target  => '/etc/slurm/slurm.conf',
    order   => '50',
    content => $slurm_conf
  }

  file { '/etc/slurm/slurmdbd.conf':
    ensure  => present,
    content => epp('profile/slurm/slurmdbd.conf', {'dbd_host' => $hostname, 'storage_pass' => $storage_pass}),
    owner   => 'slurm',
    mode    => '0600',
  }

  package { 'slurm-slurmdbd':
    ensure => present
  }

  service { 'slurmdbd':
    ensure  => running,
    enable  => true,
    require => [Package['slurm-slurmdbd'],
                File['/etc/slurm/slurmdbd.conf'],
                Concat::Fragment['slurm.conf_slurmdbd']],
    before  => Service['slurmctld']
  }

  $cluster_name = lookup('profile::slurm::base::cluster_name')
  exec { 'sacctmgr_add_cluster':
    command => "/usr/bin/sacctmgr add cluster $cluster_name",
    unless  => "/bin/test `/usr/bin/sacctmgr show cluster Names=$cluster_name -n | wc -l` == 1",
    before  => Service['slurmctld'],
    require => Service['slurmdbd']
  }

}

class profile::slurm::controller {
  include profile::slurm::base

  package { ['slurm-slurmctld']:
    ensure => 'installed',
  }
  service { 'slurmctld':
    ensure  => 'running',
    enable  => true,
    require => Package['slurm-slurmctld']
  }

  concat::fragment { 'slurm.conf_slurmctld':
    target  => '/etc/slurm/slurm.conf',
    order   => '10',
    content => "ControlMachine=$hostname"
  }
}

class profile::slurm::node {
  include profile::slurm::base

  package { 'slurm-slurmd':
    ensure => 'installed'
  }

  service { 'slurmd':
    ensure    => 'running',
    enable    => 'true',
    require   => Package['slurm-slurmd'],
    subscribe => [File['/etc/slurm/cgroup.conf'],
                  File['/etc/slurm/slurm.conf'],
                  File['/etc/slurm/plugstack.conf']]
  }

  file { '/localscratch':
    ensure => 'directory'
  }

  exec { 'slurm_config':
    command => "/bin/flock /etc/slurm/node.conf.lock /usr/bin/sed -i \"s/NodeName=$hostname .*/$(/usr/sbin/slurmd -C | /usr/bin/head -n 1)/g\" /etc/slurm/node.conf",
    unless  => "/usr/bin/grep -q \"$(/usr/sbin/slurmd -C | /usr/bin/head -n 1)\" /etc/slurm/node.conf"
  }

  exec { 'scontrol reconfigure':
    path => ['/usr/bin'],
    subscribe => Exec['slurm_config'],
    refreshonly => true,
    returns     => [0, 1]
  }

  exec { "scontrol_update_state":
    command => "scontrol update nodename=$hostname state=idle",
    path => ['/usr/bin'],
    subscribe => Service['slurmd'],
    refreshonly => true
  }
}

class profile::slurm::submitter {
  include profile::slurm::base
}