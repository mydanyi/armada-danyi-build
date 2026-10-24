%global debug_package %{nil}

# Bump with a changelog entry; the packaged payloads and their pinned .sha256
# files under payloads/ move together with openabl_version.
%global openabl_version 1.1
# Local payload variant: OpenABL 1.1 with Simplified Chinese as the default menu
# language. The RPM release identifies the packaging revision only.
%global openabl_variant danyi-default-zh
%global openabl_url https://github.com/OpenHandheldCollective/OpenABL
# Complete corresponding source for the packaged payloads: upstream v1.1 base
# plus payloads/default-zh.patch.
%global openabl_source_url %{openabl_url}/releases/download/v%{openabl_version}/openabl-v%{openabl_version}-source.tar.xz
%global openabl_source_sha256 9aca67ccfc258dbc7baf5db2d3ee43d93780d6f577260524e269e0e182dc8b80
# Shipped SoCs, has to be updated if Armada adds more SoCs that need OpenABL
%global openabl_socs SM8250 SM8550 SM8650 SM8750

Name:           openabl-updater
Version:        %{openabl_version}
Release:        2%{?dist}.armada.danyi
Summary:        OpenABL bootloader payloads and the Armada ABL updater
# Payloads are OpenABL (GPL-3.0-or-later), the updater is Armada's.
License:        GPL-2.0-or-later AND GPL-3.0-or-later
URL:            https://github.com/armada-os/armada
BuildArch:      noarch

# Wraps the whole package directory, including the verified payloads and their
# pinned .sha256 files.
Source0:        openabl-updater.tar.gz
Source10:       https://raw.githubusercontent.com/OpenHandheldCollective/OpenABL/v%{openabl_version}/LICENSE#/OpenABL-LICENSE
Source20:       %{openabl_source_url}

Requires:       python3
Requires:       util-linux
Requires:       coreutils

%description
OpenABL %{openabl_version} for the chipsets Armada supports and the ABL updater
script. The packaged payloads are the %{openabl_variant} variant: OpenABL
%{openabl_version} whose boot menu falls back to Simplified Chinese when no
language is stored.

%prep
%autosetup -n work
# Source0 carries exactly four payloads and the pinned checksum of each.
[ "$(ls payloads/*.sha256 | wc -l)" -eq 4 ] || {
    echo "ERROR: expected exactly four pinned payload checksums" >&2
    exit 1
}
(cd payloads && cat *.sha256 | sha256sum --strict -c -)
echo '%{openabl_source_sha256}  %{SOURCE20}' | sha256sum --strict -c -
cp %{SOURCE10} OpenABL-LICENSE

%build
# Re-check every payload against its pinned checksum before recording it.
for soc in %{openabl_socs}; do
    pinned=$(cut -d' ' -f1 "payloads/abl_signed-${soc}.elf.sha256")
    actual=$(sha256sum "payloads/abl_signed-${soc}.elf" | cut -d' ' -f1)
    [ -n "${pinned}" ] && [ "${pinned}" = "${actual}" ] || {
        echo "ERROR: ${soc} payload does not match its pinned checksum" >&2
        exit 1
    }
done
{
    printf 'ARMADA_ABL_NAME=OpenABL\nARMADA_ABL_VERSION=%s\n' %{openabl_version}
    printf 'ARMADA_ABL_VARIANT=%{openabl_variant}\n'
    for soc in %{openabl_socs}; do
        printf 'ARMADA_ABL_SHA256_%s=%s\n' "${soc}" \
            "$(sha256sum "payloads/abl_signed-${soc}.elf" | cut -d' ' -f1)"
    done
} > manifest

%install
install -Dpm 0644 -t %{buildroot}%{_prefix}/lib/%{name} \
    payloads/*.elf legacy-releases.tsv personal-migrations.tsv manifest
install -Dpm 0755 -t %{buildroot}%{_libexecdir}/%{name} \
    src/abl-version src/armada-abl-update src/armada-abl-finalize
install -Dpm 0644 src/armada-bootimg-sync-openabl-updater.conf \
    %{buildroot}%{_unitdir}/armada-bootimg-sync.service.d/openabl-updater.conf
install -Dpm 0644 %{SOURCE20} \
    %{buildroot}%{_docdir}/OpenABL/openabl-v%{openabl_version}-source.tar.xz
install -Dpm 0644 payloads/default-zh.patch \
    %{buildroot}%{_docdir}/OpenABL/default-zh.patch
install -Dpm 0644 payloads/BUILD.md \
    %{buildroot}%{_docdir}/OpenABL/BUILD.md
install -Dpm 0644 payloads/PROVENANCE.md \
    %{buildroot}%{_docdir}/OpenABL/PROVENANCE.md
install -Dpm 0644 OpenABL-LICENSE \
    %{buildroot}%{_docdir}/OpenABL/OpenABL-LICENSE

%files
%license OpenABL-LICENSE
%doc README.md
%{_prefix}/lib/%{name}/
%{_libexecdir}/%{name}/
%{_unitdir}/armada-bootimg-sync.service.d/openabl-updater.conf
%{_docdir}/OpenABL/

%changelog
* Sun Oct 25 2026 Danyi <308664957+mydanyi@users.noreply.github.com> - 1.1-2
- Ship locally built default-Chinese payloads with pinned checksums and
  install the corresponding source archive and patch as documentation

* Mon Oct 19 2026 Radical <radical@radical.fun> - 1.1-1
- Package the ABL updater and ship OpenABL 1.1 in place of ROCKNIX ABL
