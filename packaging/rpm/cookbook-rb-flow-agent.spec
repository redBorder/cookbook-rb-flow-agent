%global cookbook_path /var/chef/cookbooks/rb-flow-agent

Name: cookbook-rb-flow-agent
Version: %{__version}
Release: %{__release}%{?dist}
BuildArch: noarch
Summary: redborder flow-agent cookbook to configure redborder-flow-agent in redborder environments

License: AGPL 3.0
URL: https://github.com/redBorder/cookbook-rb-flow-agent
Source0: %{name}-%{version}.tar.gz

%description
%{summary}

%prep
%setup -qn %{name}-%{version}

%build

%install
mkdir -p %{buildroot}%{cookbook_path}
cp -f -r  resources/* %{buildroot}%{cookbook_path}
chmod -R 0755 %{buildroot}%{cookbook_path}
install -D -m 0644 README.md %{buildroot}%{cookbook_path}/README.md

%pre
if [ -d /var/chef/cookbooks/rb-flow-agent ]; then
    rm -rf /var/chef/cookbooks/rb-flow-agent
fi

%post
case "$1" in
  1)
    # This is an initial install.
    # On an existing manager no one else uploads a new cookbook, and the
    # cookbooks that depend on rb-flow-agent can't be uploaded without it.
    if systemctl is-active --quiet opscode-erchef; then
      su - -s /bin/bash -c 'source /etc/profile && rvm gemset use default && env knife cookbook upload rb-flow-agent'
    fi
  ;;
  2)
    # This is an upgrade.
    su - -s /bin/bash -c 'source /etc/profile && rvm gemset use default && env knife cookbook upload rb-flow-agent'
  ;;
esac

%postun
# Deletes directory when uninstall the package
if [ "$1" = 0 ] && [ -d /var/chef/cookbooks/rb-flow-agent ]; then
  rm -rf /var/chef/cookbooks/rb-flow-agent
fi

%files
%defattr(0644,root,root)
%attr(0755,root,root)
%{cookbook_path}
%defattr(0644,root,root)
%{cookbook_path}/README.md

%doc

%changelog
* Fri Oct 09 2026 Nils <git@redborder.com>
- First cookbook-rb-flow-agent spec version
